"""HDM SDS 日志解析体检工具 —— 命令行入口（占位）。

当前仅提供 argparse 骨架，完整的编排逻辑（解包 → 各模块解析 →
生成 Markdown 体检报告）由后续任务填充。
"""

import argparse


def main() -> None:
    parser = argparse.ArgumentParser(
        prog='sds_parser',
        description='解析 HDM 导出的 .sds 日志包并生成 Markdown 体检报告',
    )
    parser.add_argument('sds_path', metavar='SDS_PATH', help='HDM 导出的 .sds 日志包路径')
    parser.add_argument('-o', '--output', default='report.md', metavar='REPORT',
                        help='输出报告路径（默认 report.md）')
    parser.add_argument('-k', '--keep', action='store_true',
                        help='解包后保留临时目录（默认用完清理）')
    args = parser.parse_args()
    # TODO(Task 7): 编排解包、解析与报告生成
    print('sds_parser: 编排逻辑尚未实现（由后续任务填充）')


if __name__ == '__main__':
    main()
