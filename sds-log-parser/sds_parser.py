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
    parser.add_argument('-o', '--output', default=None, metavar='REPORT',
                        help='输出报告路径（缺省输出到输入同目录 <basename>-report.md，由 T7 计算）')
    parser.add_argument('--ai', action='store_true',
                        help='启用 AI 综合分析（需配置 SDS_AI_BASE_URL 等环境变量，未配置则跳过）')
    parser.add_argument('--no-cleanup', action='store_true',
                        help='解包后保留临时目录（调试用）')
    parser.add_argument('--verbose', action='store_true',
                        help='打印各模块解析输出的详细统计')
    args = parser.parse_args()
    # TODO(Task 7): 编排解包、解析与报告生成
    print('sds_parser: 编排逻辑尚未实现（由后续任务填充）')


if __name__ == '__main__':
    main()
