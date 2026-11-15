# -*- coding: utf-8 -*-
"""历史库幂等测试骨架（pytest）。

覆盖：import 同一份假数据两次 → 幂等（行数不重复增长）；query --history 返回正确；
export 出 CSV。全部用临时 --db 目录（tmp_path），测试结束自动清理，不污染真实库。

运行：pytest test_db.py -q

依赖：上层 db_common / db_import / db_query / db_export（三段式历史库：
batches/entities/test_runs，见 06-工程基建规格.md 与设计规格 §5.2）。
sys.path 处理：tests/ 的父目录（templates/）加入搜索路径。
上层库尚未落地时本文件整体 skip，落地后自动激活（夹具约定见 fixtures/README.md）。
"""
import json
import os
import subprocess
import sys

import pytest

HERE = os.path.dirname(os.path.abspath(__file__))
TEMPLATES_DIR = os.path.dirname(HERE)
sys.path.insert(0, TEMPLATES_DIR)

try:
    import db_common  # noqa: F401
    import db_import  # noqa: F401
    import db_query   # noqa: F401
    import db_export  # noqa: F401
    DB_LAYER_OK = True
    _IMPORT_ERR = None
except ImportError as exc:
    DB_LAYER_OK = False
    _IMPORT_ERR = exc

pytestmark = pytest.mark.skipif(
    not DB_LAYER_OK,
    reason="上层 db_common/db_import/db_query/db_export 尚未落地（缺失模块: %s）；"
           "新项目按 06 号规格实现三段式库后自动激活" % _IMPORT_ERR)


# ---------------------------------------------------------------- 假数据构造（格式同 fixtures/sample_entities.json）

BATCH = "B20261113_000000"


def make_fake_data(tmp_path):
    """造一份假数据文件（db_import --data 的 JSON 格式，见 db_import.py 文档串）。

    结构与 fixtures/sample_entities.json 一致：{"entities":[{entity_key, verdict, ...}]}。
    """
    data_path = tmp_path / "sample_entities.json"
    data_path.write_text(json.dumps({
        "entities": [
            {"entity_key": "ENTITY-A", "entity_type": "server", "model": "SAMPLE-MODEL",
             "firmware": "FW1", "entity_ref": "Rack1-Slot1", "verdict": "PASS",
             "data": {"temp_c": 35}},
            {"entity_key": "ENTITY-B", "entity_type": "server", "model": "SAMPLE-MODEL",
             "firmware": "FW1", "entity_ref": "Rack1-Slot2", "verdict": "FAIL",
             "notes": "压测不达标", "data": {"temp_c": 45}},
        ]
    }, ensure_ascii=False), encoding="utf-8")
    return data_path


def _run(script, *argv):
    """用 subprocess 调 templates/ 下的脚本（--db 全部指向临时目录）。"""
    cmd = [sys.executable, os.path.join(TEMPLATES_DIR, script)] + list(argv)
    return subprocess.run(cmd, capture_output=True, text=True, encoding="utf-8")


def _count_runs(db_path):
    """库内 test_runs 表行数（三段式 SCHEMA；重复导入不应增长）。"""
    conn = db_common.connect(db_path)
    try:
        return conn.execute("SELECT COUNT(*) FROM test_runs").fetchone()[0]
    finally:
        conn.close()


# ---------------------------------------------------------------- 幂等

def test_import_twice_idempotent(tmp_path):
    """同一份假数据 import 两次 → 行数不重复增长。"""
    db = str(tmp_path / "test.db")
    data = make_fake_data(tmp_path)

    r1 = _run("db_import.py", "--batch", BATCH, "--data", str(data), "--db", db)
    assert r1.returncode == 0, r1.stderr
    n1 = _count_runs(db)

    r2 = _run("db_import.py", "--batch", BATCH, "--data", str(data), "--db", db)
    assert r2.returncode == 0, r2.stderr
    n2 = _count_runs(db)

    assert n1 == 2
    assert n2 == n1  # 幂等：重复导入不增长


# ---------------------------------------------------------------- 查询

def test_query_history(tmp_path):
    """query --history 返回该实体唯一键的历史记录。"""
    db = str(tmp_path / "test.db")
    data = make_fake_data(tmp_path)
    _run("db_import.py", "--batch", BATCH, "--data", str(data), "--db", db)

    r = _run("db_query.py", "--db", db, "--entity-key", "ENTITY-A", "--history")
    assert r.returncode == 0, r.stderr
    assert "ENTITY-A" in r.stdout


# ---------------------------------------------------------------- 导出

def test_export_csv(tmp_path):
    """export 出 CSV（--db 指向临时库，不污染真实库）。"""
    db = str(tmp_path / "test.db")
    data = make_fake_data(tmp_path)
    _run("db_import.py", "--batch", BATCH, "--data", str(data), "--db", db)

    out = str(tmp_path / "export.csv")
    r = _run("db_export.py", "--db", db, "--out", out)
    assert r.returncode == 0, r.stderr
    assert os.path.isfile(out)
    content = open(out, encoding="utf-8-sig").read()
    assert "ENTITY-A" in content
    assert "ENTITY-B" in content
