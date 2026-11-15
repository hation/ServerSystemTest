#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""db_export.py —— 导出三段式历史库为 utf-8-sig CSV（Excel 可直接打开）。

三段式骨架：batches/entities/test_runs，业务字段经 meta JSON 扩展，无需改表结构。
用法:
  python db_export.py --db <path> [--out <csv>]
"""
import argparse
import csv
import os
import sys

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, SCRIPT_DIR)
from db_common import connect  # noqa: E402

COLS = [
    ("b.batch", "批次号"),
    ("b.test_date", "测试日期"),
    ("b.machine", "测试机"),
    ("e.entity_key", "实体唯一键"),
    ("e.entity_type", "实体类型"),
    ("e.model", "型号"),
    ("e.firmware", "固件"),
    ("t.entity_ref", "实体引用"),
    ("t.verdict", "结论"),
    ("t.notes", "备注"),
    ("t.data", "业务数据JSON"),
    ("t.imported_at", "入库时间"),
]


def main():
    ap = argparse.ArgumentParser(description="导出历史库为 CSV")
    ap.add_argument("--db", default=os.path.join("results", "server-tests.db"),
                    help="库文件（临时库测试时指定）")
    ap.add_argument("--out", default=None, help="输出 CSV（默认 <db 同目录同名>.csv）")
    args = ap.parse_args()

    out = args.out
    if not out:
        out = os.path.splitext(args.db)[0] + ".csv"

    conn = connect(args.db)
    cols_sql = ", ".join(e for e, _ in COLS)
    rows = conn.execute(
        "SELECT %s FROM test_runs t "
        "JOIN batches b ON b.id=t.batch_id "
        "JOIN entities e ON e.id=t.entity_id "
        "ORDER BY b.created_at, e.entity_key" % cols_sql).fetchall()
    with open(out, "w", encoding="utf-8-sig", newline="") as f:
        w = csv.writer(f)
        w.writerow([h for _, h in COLS])
        w.writerows(rows)
    print("已导出 %d 行 → %s" % (len(rows), out))
    conn.close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
