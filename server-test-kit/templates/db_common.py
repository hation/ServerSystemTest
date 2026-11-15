#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""db_common.py —— 三段式历史库公共层：连接/建表/批次·实体·测试记录幂等写入。

三段式骨架：batches / entities / test_runs，业务字段经 meta(data) JSON 扩展，
无需改表结构。依赖仅 sqlite3 标准库（Python 3）。
"""
import os
import sqlite3

SCHEMA = """
CREATE TABLE IF NOT EXISTS batches (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  machine TEXT NOT NULL DEFAULT 'local',
  batch TEXT NOT NULL,
  test_date TEXT,
  created_at TEXT DEFAULT (datetime('now','localtime')),
  UNIQUE(machine, batch)
);
CREATE TABLE IF NOT EXISTS entities (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  entity_key TEXT NOT NULL UNIQUE,
  entity_type TEXT,
  model TEXT,
  firmware TEXT,
  meta TEXT,
  created_at TEXT DEFAULT (datetime('now','localtime'))
);
CREATE TABLE IF NOT EXISTS test_runs (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  batch_id INTEGER NOT NULL REFERENCES batches(id),
  entity_id INTEGER NOT NULL REFERENCES entities(id),
  entity_ref TEXT,
  verdict TEXT,
  notes TEXT,
  data TEXT,
  imported_at TEXT DEFAULT (datetime('now','localtime')),
  UNIQUE(batch_id, entity_id)
);
CREATE INDEX IF NOT EXISTS idx_runs_entity ON test_runs(entity_id);
CREATE INDEX IF NOT EXISTS idx_runs_batch ON test_runs(batch_id);
"""

# test_runs 可写列（不含 id/batch_id/entity_id/imported_at），导入/合并共用
RUN_COLS = ["entity_ref", "verdict", "notes", "data"]


def connect(db_path):
    """打开（必要时创建）数据库：WAL、外键、自动建表。"""
    parent = os.path.dirname(os.path.abspath(db_path))
    if parent:
        os.makedirs(parent, exist_ok=True)
    conn = sqlite3.connect(db_path, isolation_level=None)  # 关闭隐式事务，交由调用方显式 BEGIN/COMMIT
    conn.execute("PRAGMA journal_mode=WAL")
    conn.execute("PRAGMA foreign_keys=ON")
    conn.executescript(SCHEMA)
    conn.commit()
    return conn


def get_or_create_batch(conn, machine, batch, test_date=None):
    """按 UNIQUE(machine, batch) 取或建批次，返回批次 id（重复调用返回同一批次，幂等）。"""
    row = conn.execute("SELECT id FROM batches WHERE machine=? AND batch=?",
                       (machine, batch)).fetchone()
    if row:
        return row[0]
    cur = conn.execute(
        "INSERT INTO batches(machine, batch, test_date) VALUES(?,?,?)",
        (machine, batch, test_date))
    return cur.lastrowid


def get_or_create_entity(conn, entity_key, entity_type=None, model=None,
                         firmware=None, meta=None):
    """按 entity_key 归并同一被测实体；已存在则补齐信息（COALESCE 只补不覆盖）。"""
    row = conn.execute("SELECT id FROM entities WHERE entity_key=?",
                       (entity_key,)).fetchone()
    if row:
        e_id = row[0]
        conn.execute(
            """UPDATE entities SET entity_type=COALESCE(?,entity_type),
               model=COALESCE(?,model), firmware=COALESCE(?,firmware),
               meta=COALESCE(?,meta) WHERE id=?""",
            (entity_type, model, firmware, meta, e_id))
        return e_id
    cur = conn.execute(
        """INSERT INTO entities(entity_key, entity_type, model, firmware, meta)
           VALUES(?,?,?,?,?)""",
        (entity_key, entity_type, model, firmware, meta))
    return cur.lastrowid


def upsert_run(conn, batch_id, entity_id, values):
    """按 UNIQUE(batch_id, entity_id) 幂等写入；只写非 None 列，重复导入覆盖更新。"""
    cols = [c for c in RUN_COLS if values.get(c) is not None]
    if not cols:
        return False
    insert_sql = ", ".join(cols)
    placeholders = ",".join("?" * len(cols))
    set_sql = ", ".join("%s=excluded.%s" % (c, c) for c in cols)
    params = [values[c] for c in cols]
    conn.execute(
        "INSERT INTO test_runs(batch_id, entity_id, %s) VALUES(?,?,%s) "
        "ON CONFLICT(batch_id, entity_id) DO UPDATE SET %s"
        % (insert_sql, placeholders, set_sql),
        [batch_id, entity_id] + params)
    return True
