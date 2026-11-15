#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""db_query.py —— 查询三段式历史库：按实体唯一键查历史/趋势、批次对比。

三段式骨架：batches/entities/test_runs，业务字段经 meta JSON 扩展，无需改表结构。
用法:
  python db_query.py --db <path> --history                     # 全部历史
  python db_query.py --db <path> --entity-key <key> --history  # 单实体跨批次历史
  python db_query.py --db <path> --batch <b>                   # 批次明细
  python db_query.py --db <path> --list-batches                # 批次列表
"""
import argparse
import os
import sys

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, SCRIPT_DIR)
from db_common import connect  # noqa: E402


def fmt(v):
    return "" if v is None else str(v)


def show_history(conn, entity_key=None):
    """按时间列出历史记录；--entity-key 过滤单实体跨批次历史/趋势。"""
    sql = ("""SELECT b.batch, b.test_date, b.machine, e.entity_key, e.entity_type,
                     e.model, t.entity_ref, t.verdict, t.notes
              FROM test_runs t
              JOIN batches b ON b.id=t.batch_id
              JOIN entities e ON e.id=t.entity_id""")
    params = ()
    if entity_key:
        sql += " WHERE e.entity_key=?"
        params = (entity_key,)
    sql += " ORDER BY b.created_at, e.entity_key"
    rows = conn.execute(sql, params).fetchall()
    print("共 %d 条记录:" % len(rows))
    for r in rows:
        print("  %s | %s | %s | %s(%s) | %s | verdict=%s | %s"
              % (r[0], r[1] or "", r[2], r[3], r[4] or "", r[5] or "",
                 fmt(r[7]), (r[8] or "")[:60]))
    return len(rows)


def show_batch(conn, batch):
    rows = conn.execute(
        """SELECT b.batch, e.entity_key, e.entity_type, e.model,
                  t.entity_ref, t.verdict, t.notes
           FROM test_runs t
           JOIN batches b ON b.id=t.batch_id
           JOIN entities e ON e.id=t.entity_id
           WHERE b.batch=? ORDER BY e.entity_key""", (batch,)).fetchall()
    print("批次 %s: %d 条" % (batch, len(rows)))
    for r in rows:
        print("  %s | %s | %s | ref=%s | verdict=%s | %s"
              % (r[1], r[2] or "", r[3] or "", fmt(r[4]), fmt(r[5]), (r[6] or "")[:60]))


def show_batches(conn):
    rows = conn.execute(
        "SELECT batch, test_date, machine, created_at FROM batches ORDER BY created_at").fetchall()
    print("共 %d 个批次:" % len(rows))
    for r in rows:
        print("  %s  测试日期=%s  machine=%s  入库=%s" % (r[0], r[1] or "", r[2], r[3]))


def main():
    ap = argparse.ArgumentParser(description="三段式历史库查询")
    ap.add_argument("--db", default=os.path.join("results", "server-tests.db"),
                    help="库文件（临时库测试时指定）")
    ap.add_argument("--entity-key", default=None, help="按实体唯一键查历史/趋势")
    ap.add_argument("--batch", default=None, help="按批次查明细")
    ap.add_argument("--history", action="store_true", help="查历史（全部或 --entity-key 过滤）")
    ap.add_argument("--list-batches", action="store_true", help="列批次")
    args = ap.parse_args()

    conn = connect(args.db)
    if args.list_batches:
        show_batches(conn)
    elif args.batch:
        show_batch(conn, args.batch)
    elif args.history:
        show_history(conn, entity_key=args.entity_key)
    else:
        ap.print_help()
    conn.close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
