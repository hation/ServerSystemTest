#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""db_import.py —— 把测试产物导入三段式历史库（幂等，可重跑）。

三段式骨架：batches/entities/test_runs，业务字段经 meta JSON 扩展，无需改表结构。
用法:
  python db_import.py --db <path> --machine <m> --batch <b> --data <json|csv>

JSON 数据格式（单实体 dict，或 {"entities":[...]} 数组；字段名通用可自定义）：
  {"entity_key":"...", "entity_type":"...", "model":"...", "firmware":"...",
   "entity_ref":"...", "verdict":"PASS", "notes":"...",
   "data":{...业务指标...}, "meta":{...实体扩展字段...}}
CSV 数据格式：首行表头，必须含 entity_key 列；entity_type/model/firmware/
  entity_ref/verdict/notes 列按同名映射，其余列自动打包进 meta JSON（业务扩展无需改表）。
幂等：同一 (machine,batch)+entity_key 重复导入只覆盖更新（UNIQUE+ON CONFLICT），不产生重复行。
"""
import argparse
import csv
import json
import os
import sys

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, SCRIPT_DIR)

from db_common import connect, get_or_create_batch, get_or_create_entity, upsert_run  # noqa: E402

ENTITY_COLS = ("entity_type", "model", "firmware")
RUN_COLS_STD = ("entity_ref", "verdict", "notes")


def load_json(path):
    with open(path, encoding="utf-8-sig") as f:
        return json.load(f)


def import_json(conn, batch_id, data):
    """单实体 dict 或 {"entities":[...]} 数组；返回导入实体数（幂等覆盖）。"""
    if isinstance(data, dict) and "entities" in data:
        items = data["entities"]
    elif isinstance(data, dict):
        items = [data]
    elif isinstance(data, list):
        items = data
    else:
        items = []
    n = 0
    for it in items:
        key = str(it.get("entity_key") or "").strip()
        if not key:
            continue
        meta = it.get("meta") or {}
        if not isinstance(meta, dict):
            meta = {}
        eid = get_or_create_entity(
            conn, key,
            entity_type=it.get("entity_type") or None,
            model=it.get("model") or None,
            firmware=it.get("firmware") or None,
            meta=json.dumps(meta, ensure_ascii=False) if meta else None)
        payload = it.get("data") or {}
        values = {
            "entity_ref": str(it["entity_ref"]) if it.get("entity_ref") is not None else None,
            "verdict": it.get("verdict") or None,
            "notes": it.get("notes") or None,
            "data": json.dumps(payload, ensure_ascii=False) if payload else None,
        }
        if upsert_run(conn, batch_id, eid, values):
            n += 1
    return n


def import_csv(conn, batch_id, path):
    """CSV 导入（entity_key 必填列；未知列打包进 meta JSON）；返回导入实体数。"""
    n = 0
    with open(path, encoding="utf-8-sig") as f:
        for row in csv.DictReader(f):
            key = (row.get("entity_key") or "").strip()
            if not key:
                continue
            std = ("entity_key",) + ENTITY_COLS + RUN_COLS_STD
            meta = {k: v for k, v in row.items() if k not in std and v not in (None, "")}
            eid = get_or_create_entity(
                conn, key,
                entity_type=row.get("entity_type") or None,
                model=row.get("model") or None,
                firmware=row.get("firmware") or None,
                meta=json.dumps(meta, ensure_ascii=False) if meta else None)
            values = {
                "entity_ref": row.get("entity_ref") or None,
                "verdict": row.get("verdict") or None,
                "notes": row.get("notes") or None,
                "data": row.get("data") or None,
            }
            if upsert_run(conn, batch_id, eid, values):
                n += 1
    return n


def guess_test_date(batch):
    """B20261017_075159 → '20261017'，不符合返回 None。"""
    if batch.startswith("B") and len(batch) >= 9 and batch[1:9].isdigit():
        return batch[1:9]
    return None


def main():
    ap = argparse.ArgumentParser(description="测试结果入库（幂等）")
    ap.add_argument("--db", default=os.path.join("results", "server-tests.db"),
                    help="库文件（临时库测试时指定）")
    ap.add_argument("--machine", default="local", help="测试机标识")
    ap.add_argument("--batch", required=True, help="批次号（如 B20261113_093000）")
    ap.add_argument("--data", required=True, help="数据文件（.json 或 .csv）")
    ap.add_argument("--test-date", default=None, help="测试日期（默认取自批次名 B<日期> 前缀）")
    args = ap.parse_args()

    conn = connect(args.db)
    test_date = args.test_date or guess_test_date(args.batch)
    batch_id = get_or_create_batch(conn, args.machine, args.batch, test_date=test_date)
    try:
        conn.execute("BEGIN")
        if args.data.lower().endswith(".csv"):
            n = import_csv(conn, batch_id, args.data)
        else:
            n = import_json(conn, batch_id, load_json(args.data))
        conn.execute("COMMIT")
    except Exception:
        conn.execute("ROLLBACK")
        raise
    conn.close()
    print("批次 %s: 导入 %d 个实体 → %s" % (args.batch, n, args.db))
    return 0


if __name__ == "__main__":
    sys.exit(main())
