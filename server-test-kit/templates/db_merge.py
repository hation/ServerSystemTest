#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""db_merge.py —— 把多个源库幂等合并到输出库（按 machine/batch + entity_key 归并）。

三段式骨架：batches/entities/test_runs，业务字段经 meta JSON 扩展，无需改表结构。
用法:
  python db_merge.py --src <path1> --src <path2> --db <out>
幂等：重复合并结果一致（UNIQUE 约束 + ON CONFLICT 覆盖更新，不产生重复行）。
"""
import argparse
import os
import sqlite3
import sys

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, SCRIPT_DIR)
from db_common import connect, get_or_create_batch, get_or_create_entity, upsert_run, RUN_COLS  # noqa: E402


def merge_one(conn_dst, src_path):
    """把单个源库全部记录 upsert 进目标库；返回本次写入行数。"""
    src = connect(src_path)
    src.row_factory = sqlite3.Row
    merged = 0
    try:
        rows = src.execute(
            """SELECT b.machine AS machine, b.batch AS batch, b.test_date AS test_date,
                      e.entity_key AS entity_key, e.entity_type AS entity_type,
                      e.model AS model, e.firmware AS firmware, e.meta AS meta,
                      t.entity_ref, t.verdict, t.notes, t.data
               FROM test_runs t
               JOIN batches b ON b.id=t.batch_id
               JOIN entities e ON e.id=t.entity_id""").fetchall()
        for r in rows:
            bid = get_or_create_batch(conn_dst, r["machine"], r["batch"], r["test_date"])
            eid = get_or_create_entity(
                conn_dst, r["entity_key"], r["entity_type"], r["model"],
                r["firmware"], r["meta"])
            values = {c: r[c] for c in RUN_COLS}
            if upsert_run(conn_dst, bid, eid, values):
                merged += 1
    finally:
        src.close()
    return merged


def main():
    ap = argparse.ArgumentParser(description="合并多个源库到输出库（幂等）")
    ap.add_argument("--src", action="append", required=True, help="源库路径（可多次指定）")
    ap.add_argument("--db", required=True, help="输出库路径（不存在则新建）")
    args = ap.parse_args()

    abs_out = os.path.abspath(args.db)
    conn_dst = connect(abs_out)
    total = 0
    try:
        for src_path in args.src:
            if os.path.abspath(src_path) == abs_out:
                print("[WARN] 跳过与输出库相同的源库: %s" % src_path, file=sys.stderr)
                continue
            if not os.path.isfile(src_path):
                print("[WARN] 源库不存在，跳过: %s" % src_path, file=sys.stderr)
                continue
            conn_dst.execute("BEGIN")
            try:
                total += merge_one(conn_dst, src_path)
                conn_dst.execute("COMMIT")
            except Exception:
                conn_dst.execute("ROLLBACK")
                raise
    finally:
        conn_dst.close()
    print("合并完成: %d 条 → %s" % (total, abs_out))
    return 0


if __name__ == "__main__":
    sys.exit(main())
