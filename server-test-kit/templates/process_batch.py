# -*- coding: utf-8 -*-
"""批次流水线骨架（通用版）：源数据 → 结构化判定数据 JSON + 报告骨架 MD。

机制沿用 disk-tests 的 process_batch.py（批次流水线）：扫描 collect 目录下的每个
实体子目录 → 逐实体解析源文件 → 判定 → 写 {number}-data.json（结构化判定数据）
+ {number}-报告骨架.md（三张固定表：总览/明细/异常 + 判定 + 判读说明占位）。

业务全部占位/参数化：
- parse_entity()：解析函数抽象，默认实现只返回文件名清单 + 空字段；
  新项目按 02-批量检测SOP模板.md 实现字段解析（判读速查表的每列对应一个字段）
- judge()：判定函数抽象，默认示例判定返回 🟢/⚠️/🔴 示例级别；
  可通过 --judge 注入外部判定模块（需导出 judge(entity_data) -> verdict dict）
- 报告骨架三表表头列名用 {列名} 占位符，列名按 08 号文档与 report_to_excel 配置定

幂等：同参数重跑覆盖输出（'w' 写入）。
纯标准库（json/argparse/os/importlib.util），不依赖第三方。

用法：
    python process_batch.py --collect <源数据目录> --number N --date YYYYMMDD
        [--judge <判定模块.py>] [--out <输出目录,默认 process_out>]
"""
import argparse
import importlib.util
import json
import os
import sys

OUT_DIR_DEFAULT = 'process_out'

# 判定等级（示例；新项目按 03-AI评测提示词模板.md 的判据层定，
# 并与 report_to_excel 的 levels 配置对齐）
LEVELS = ('🟢', '⚠️', '🔴')

# 等级 → 展示文本（示例；新项目按 03 号文档重写）
VERDICT_TXT = {'🟢': '🟢 正常', '⚠️': '⚠️ 复核', '🔴': '🔴 疑似问题'}


def parse_entity(entity_dir):
    """解析单个实体子目录 → 结构化字段 dict（解析函数抽象，骨架默认实现）。

    默认实现只返回：实体名 + 源文件名清单 + 空字段。
    ⚠️ 业务占位：新项目按 02-SOP 的真实产物结构实现字段解析——
    每个源文件对应若干字段，字段名与 report_to_excel 的列映射（08 号文档）对齐。
    """
    files = sorted(os.listdir(entity_dir)) if os.path.isdir(entity_dir) else []
    return {
        'name': os.path.basename(os.path.normpath(entity_dir)),
        'files': files,
        'fields': {},  # 业务字段占位：{字段名: 值}
    }


def judge(entity_data):
    """示例判定函数：entity_data -> verdict dict（含 level/note）。

    ⚠️ 业务占位：真实判定按 03-AI评测提示词模板.md 的判据层（如 C/H 编码规则）实现；
    可通过 --judge 注入外部模块覆盖（模块需导出 judge(entity_data) -> verdict）。
    默认示例：无字段 → ⚠️ 复核；有字段但缺关键字段 → 🔴 疑似问题；其余 → 🟢 正常。
    """
    fields = entity_data.get('fields') or {}
    if not fields:
        return {'level': '⚠️', 'note': '缺数据（示例判据：未解析到任何字段）'}
    if 'key_field' not in fields:
        return {'level': '🔴', 'note': '缺关键字段（示例判据：key_field 缺失）'}
    return {'level': '🟢', 'note': '字段齐全（示例判据）'}


def load_judge_module(path):
    """按路径加载外部判定模块（--judge），需导出 judge(entity_data)。"""
    spec = importlib.util.spec_from_file_location('custom_judge', os.path.abspath(path))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod.judge


# ---------------------------------------------------------------- 报告骨架

def _cell(entity_data, key):
    """取实体字段值；字段未解析时返回占位符。列名按 08 号文档与 report_to_excel 配置定。"""
    return (entity_data.get('fields') or {}).get(key, '—')


def gen_skeleton(entities, number, date_raw):
    """组装报告骨架：三张固定表（总览/明细/异常）+ 判定 + 判读说明占位。

    表头列名用 {列名} 占位符——列名按 08 号文档与 report_to_excel 配置定。
    """
    date_disp = '%s-%s-%s' % (date_raw[:4], date_raw[4:6], date_raw[6:8])
    parts = []
    parts.append('# 批量检测报告骨架（%s 批次）' % number)
    parts.append('')
    parts.append('> 检测日期：%s' % date_disp)
    parts.append('> 被测实体数：%d' % len(entities))
    parts.append('> 数据来源：源数据目录（新项目按 02-SOP 填写来源文件清单）')
    parts.append('> 说明：<!-- AI 润色：按 03 号提示词模板写判定依据摘要 -->')
    parts.append('')
    parts.append('---')
    parts.append('')
    # §1 总览
    parts.append('## 总览（判定汇总）')
    parts.append('')
    parts.append('| {列名：唯一键} | {列名：型号/规格} | {列名：关键判据字段} | {列名：判定} |')
    parts.append('|---|---|---|---|')
    for ent in entities:
        d = ent['data']
        v = ent['verdict']
        parts.append('| %s | %s | %s | %s |' % (
            d.get('name', '?'),
            _cell(d, '{字段名：型号/规格}'),
            _cell(d, '{字段名：关键判据}'),
            VERDICT_TXT.get(v['level'], v['level'])))
    parts.append('')
    parts.append('---')
    parts.append('')
    # §2 明细
    parts.append('## 明细（逐实体）')
    parts.append('')
    parts.append('| {列名：唯一键} | {列名} | {列名} | {列名} | {列名} |')
    parts.append('|---|---|---|---|---|')
    for ent in entities:
        d = ent['data']
        parts.append('| %s | %s | %s | %s | %s |' % (
            d.get('name', '?'),
            _cell(d, '{字段名}'), _cell(d, '{字段名}'),
            _cell(d, '{字段名}'), _cell(d, '{字段名}')))
    parts.append('')
    # 判定 + 判读说明占位
    parts.append('**判定：%s。**（示例判定文本；AI 润色按 03 号提示词模板重写判据依据）'
                 % '、'.join(VERDICT_TXT.get(e['verdict']['level'], e['verdict']['level'])
                             for e in entities))
    parts.append('')
    parts.append('**判读说明**：')
    parts.append('- 判读说明占位 1：<!-- 新项目按 04-单实体专项分析SOP模板.md 的"计数器矛盾"口径补充 -->')
    parts.append('- 判读说明占位 2：<!-- AI 润色：补充逐实体特殊点 -->')
    parts.append('')
    parts.append('---')
    parts.append('')
    # §3 异常
    parts.append('## 异常/复核标记')
    parts.append('')
    parts.append('| {列名：唯一键} | {列名：SN/资产号} | {列名：标记} | {列名：说明} |')
    parts.append('|---|---|---|---|')
    abnormal = [e for e in entities if e['verdict']['level'] != '🟢']
    for ent in abnormal:
        d = ent['data']
        v = ent['verdict']
        parts.append('| %s | %s | %s | %s |' % (
            d.get('name', '?'),
            _cell(d, '{字段名：SN/资产号}'),
            v['level'],
            v.get('note', '—')))
    if not abnormal:
        parts.append('| — | — | — | 无异常（示例骨架） |')
    return '\n'.join(parts) + '\n'


# ---------------------------------------------------------------- CLI

def main():
    ap = argparse.ArgumentParser(description='批次流水线骨架（通用版）')
    ap.add_argument('--collect', required=True, help='源数据目录（含实体子目录）')
    ap.add_argument('--number', required=True, help='批次/报告编号，如 1')
    ap.add_argument('--date', required=True, help='YYYYMMDD，文件名日期')
    ap.add_argument('--judge', default=None, help='外部判定模块 .py（导出 judge(entity_data)）')
    ap.add_argument('--out', default=OUT_DIR_DEFAULT, help='输出目录（默认 process_out）')
    args = ap.parse_args()

    judge_fn = judge
    if args.judge:
        judge_fn = load_judge_module(args.judge)

    collect = os.path.abspath(args.collect)
    if not os.path.isdir(collect):
        print('错误: collect 目录不存在: %s' % collect)
        sys.exit(1)

    # 实体子目录 = collect 下每个子目录（顶层文件忽略）
    entity_dirs = [d for d in sorted(os.listdir(collect))
                   if os.path.isdir(os.path.join(collect, d))]
    entities = []
    for name in entity_dirs:
        data = parse_entity(os.path.join(collect, name))
        verdict = judge_fn(data)
        entities.append({'data': data, 'verdict': verdict})

    if not entities:
        print('错误: 未从 %s 解析到任何实体子目录（collect 下需有实体子目录）' % collect)
        sys.exit(1)

    os.makedirs(args.out, exist_ok=True)

    # 1) 结构化判定数据 JSON（幂等：同参数重跑覆盖）
    data_path = os.path.join(args.out, '%s-data.json' % args.number)
    with open(data_path, 'w', encoding='utf-8') as f:
        json.dump(entities, f, ensure_ascii=False, indent=1)
    print('已写入: %s' % data_path)

    # 2) 报告骨架（幂等：同参数重跑覆盖）
    skeleton = gen_skeleton(entities, args.number, args.date)
    md_path = os.path.join(args.out, '%s-报告骨架.md' % args.number)
    with open(md_path, 'w', encoding='utf-8') as f:
        f.write(skeleton)
    print('已写入: %s' % md_path)

    # 3) 计数统计
    cnt = {lv: sum(1 for e in entities if e['verdict']['level'] == lv) for lv in LEVELS}
    print('统计: 实体=%d  %s' % (len(entities),
                                '  '.join('%s=%d' % (lv, c) for lv, c in cnt.items())))


if __name__ == '__main__':
    main()
