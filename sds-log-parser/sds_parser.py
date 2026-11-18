"""HDM SDS 日志解析体检工具 —— 命令行入口与全链路编排。

流程：解包（安全展开到临时目录）→ 事件三路解析（test.csv 优先、.sbe
兜底、visible.log）→ 清单 / 传感器解析 → 健康判定（含背板
Raid_BP_Conf_Info "Failed To Match" 规则）→ AI 材料包默认落盘 + 可选
`--ai` 后端综合分析 → Markdown 体检报告渲染 → 写文件（UTF-8）→ 控制台
摘要 → 清理临时目录。

- AI 双模式：① 默认每次运行用 `build_ai_payload` 产出"事实+任务指令"
  文本并落盘 `<basename>-ai-facts.md` 材料包（不调 API）；② `--ai` 且
  环境变量 SDS_AI_BASE_URL 等齐全时额外 `call_ai`，结果写入报告
  `## 5. AI 综合分析` 章节；未配置 / 失败 → 跳过该章节并打印原因，不中断。
- 非 tar 输入 → 捕获 SDSNotTarError 打印中文提示、退出码 1，无 Python 堆栈。
- 解包临时目录用 try/finally 保证一定清理；`--no-cleanup` 保留调试。

运行时零第三方依赖，仅用 Python 3.12 标准库。
"""

import argparse
import os
import sys
import traceback
from datetime import datetime

from sds_ai import build_ai_payload, call_ai
from sds_events import parse_event_csv, parse_sbe, parse_visible_log
from sds_extract import SDSNotTarError, cleanup, extract_sds, read_text_file
from sds_health import assess_health
from sds_inventory import parse_inventory
from sds_report import print_summary, render_report
from sds_sensors import parse_sensors


def _print_verbose(inv, sensors, events, visible_lines, source_desc, raid_bp_text) -> None:
    """--verbose：打印各模块解析输出的详细统计。"""
    print(f'[verbose] 事件来源：{source_desc}，事件条数：{len(events)}')
    print(f'[verbose] visible.log 行数：{len(visible_lines)}')
    print(f'[verbose] 传感器条数：{len(sensors)}')
    print(f'[verbose] CPU/内存/PCIe/网卡/背板/电源：'
          f'{len(inv.cpus)}/{len(inv.memories)}/{len(inv.pcie_cards)}/'
          f'{len(inv.nics)}/{len(inv.backplanes)}/{len(inv.psus)}')
    if raid_bp_text:
        print(f'[verbose] 背板配置原文（raid_bp_conf_ini）长度：{len(raid_bp_text)} 字符')
    else:
        print('[verbose] 背板配置原文（raid_bp_conf_ini）：无')


def _run(args) -> int:
    """全链路编排，返回进程退出码。"""
    sds_path = args.sds_path
    base = os.path.splitext(os.path.basename(sds_path))[0]
    input_dir = os.path.dirname(os.path.abspath(sds_path))
    output = args.output or os.path.join(input_dir, f'{base}-report.md')
    facts_path = os.path.join(input_dir, f'{base}-ai-facts.md')

    result = None
    try:
        try:
            result = extract_sds(sds_path, keep=args.no_cleanup)
        except SDSNotTarError as e:
            print(f'错误：{sds_path} 不是有效的 HDM SDS 日志包（原因：{e}）', file=sys.stderr)
            return 1

        files = result.files

        # 事件：test.csv 优先，缺失时用 .sbe 兜底；两者皆无 → 空列表
        events = parse_event_csv(files.get('event_csv'))
        if not events:
            events = parse_sbe(files.get('sbe'))
        source_desc = ('test.csv' if files.get('event_csv')
                       else ('.sbe 兜底' if events else '无事件来源'))

        visible_lines = parse_visible_log(files.get('visible_log'))
        inv = parse_inventory(files)
        sensors = parse_sensors(files.get('sensor_info_ini'))

        # 背板 Raid_BP_Conf_Info.ini 原文（T5 修复：含 "Failed To Match" 判提示）
        raid_bp_text = None
        raid_bp_path = files.get('raid_bp_conf_ini')
        if raid_bp_path:
            try:
                raid_bp_text = read_text_file(raid_bp_path)
            except OSError:
                raid_bp_text = None

        health = assess_health(inv, sensors, events, raid_bp_text=raid_bp_text)

        # AI 材料包：默认每次运行落盘（事实 + 任务指令，不调 API）
        payload = build_ai_payload(inv, health, events)
        with open(facts_path, 'w', encoding='utf-8') as f:
            f.write(payload)

        # 可选 --ai：env 完整时 call_ai，结果并入报告 ## 5；未配置/失败跳过并提示
        ai_markdown = None
        if args.ai:
            if not os.environ.get('SDS_AI_BASE_URL'):
                print('提示：未配置 AI 后端（SDS_AI_BASE_URL），跳过 AI 综合分析章节')
            else:
                ai_markdown = call_ai(payload)
                if ai_markdown is None:
                    print('提示：AI 调用失败或无返回内容，跳过 AI 综合分析章节')

        report_time = datetime.now().strftime('%Y-%m-%d %H:%M:%S')
        report = render_report(inv, sensors, health, events, visible_lines,
                               ai_markdown, report_time)
        os.makedirs(os.path.dirname(os.path.abspath(output)), exist_ok=True)
        with open(output, 'w', encoding='utf-8') as f:
            f.write(report)

        if args.verbose:
            _print_verbose(inv, sensors, events, visible_lines, source_desc, raid_bp_text)

        print_summary(health, output)
        return 0
    except Exception as e:  # noqa: BLE001 —— 编排层兜底：友好退出且保证临时目录清理
        if args.verbose:
            traceback.print_exc()
        print(f'处理失败：{type(e).__name__}: {e}', file=sys.stderr)
        return 1
    finally:
        cleanup(result)


def main() -> None:
    parser = argparse.ArgumentParser(
        prog='sds_parser',
        description='解析 HDM 导出的 .sds 日志包并生成 Markdown 体检报告',
    )
    parser.add_argument('sds_path', metavar='SDS_PATH', help='HDM 导出的 .sds 日志包路径')
    parser.add_argument('-o', '--output', default=None, metavar='REPORT',
                        help='输出报告路径（缺省输出到输入同目录 <basename>-report.md）')
    parser.add_argument('--ai', action='store_true',
                        help='启用 AI 综合分析（需配置 SDS_AI_BASE_URL 等环境变量，未配置则跳过）')
    parser.add_argument('--no-cleanup', action='store_true',
                        help='解包后保留临时目录（调试用）')
    parser.add_argument('--verbose', action='store_true',
                        help='打印各模块解析输出的详细统计')
    args = parser.parse_args()
    sys.exit(_run(args))


if __name__ == '__main__':
    main()
