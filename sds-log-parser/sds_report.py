"""HDM SDS 日志包体检报告渲染模块（Task 7）。

将解包解析 + 健康判定的结构化结果渲染为中文 Markdown 体检报告。
章节结构（spec「report」节，标题逐字对齐）：
`# 服务器体检报告`（机器标识 + 采集时间）→ `## 1. 整机信息`（表格）→
`## 2. 硬件健康状态`（表格：组件/状态/依据摘要）→ `## 3. 异常详情`
（每个异常/提示组件小节：事件列表）→ `## 4. 修复建议`（组件→建议）→
（可选）`## 5. AI 综合分析`（仅 ai_markdown 非 None 时）→ `## 附录`
（操作日志摘录 / 其他事件 / 固件版本 / 传感器概要）。

同时提供 `print_summary` 供 CLI 打印控制台摘要
（异常组件数 + 异常组件清单 + 报告路径）。

渲染层对表格单元格 / 列表条目做单行化处理（折叠换行与空白），
避免 CSV 多行字段破坏 Markdown 排版。
运行时零第三方依赖，仅用 Python 3.12 标准库。
"""

from datetime import datetime

# 附录各子节展示条数上限
_VISIBLE_LOG_CAP = 100   # 操作日志摘录：展示最近 N 行
_OTHER_EVENTS_CAP = 30   # 其他事件：展示前 N 条
_SENSOR_CAP = 50         # 传感器概要：展示 N 个

# 传感器概要中重点传感器前缀（优先展示，其次按名称排序）
_KEY_SENSOR_PREFIXES = ('PSU', 'FAN', 'Total_Power', 'Inlet_Temp', 'Outlet_Temp')


def _one_line(value) -> str:
    """任意文本折叠为单行（合并换行与连续空白），保证 Markdown 排版不被破坏。"""
    return ' '.join(str(value).split())


def _fmt(value) -> str:
    """None / 空白 → '未知'，否则单行字符串。"""
    if value is None or (isinstance(value, str) and not value.strip()):
        return '未知'
    return _one_line(value)


def _evidence_summary(evidence, limit: int = 120) -> str:
    """依据列表压缩为单行摘要（超出截断加 …）。"""
    if not evidence:
        return '—'
    text = _one_line('；'.join(evidence))
    if len(text) > limit:
        text = text[:limit] + '…'
    return text


def _machine_header(inv) -> str:
    """报告标题下的机器标识行。"""
    machine = (inv.machine or {}) if inv is not None else {}
    product = _fmt(machine.get('product_name'))
    serial = _fmt(machine.get('serial_number'))
    return f'- 机器标识：{product}（序列号：{serial}）'


def _render_inventory(inv) -> str:
    """## 1. 整机信息：机器 / 固件 / 各组件数量概览表格。"""
    machine = (inv.machine or {}) if inv is not None else {}
    firmware = (inv.firmware or {}) if inv is not None else {}
    cpus = getattr(inv, 'cpus', None) or []
    memories = getattr(inv, 'memories', None) or []
    pcie = getattr(inv, 'pcie_cards', None) or []
    nics = getattr(inv, 'nics', None) or []
    backplanes = getattr(inv, 'backplanes', None) or []
    psus = getattr(inv, 'psus', None) or []

    cpu_desc = f'{len(cpus)} 个'
    if cpus and cpus[0].get('model'):
        cpu_desc += f'（{_one_line(cpus[0]["model"])}）'
    mem_desc = f'{len(memories)} 条'
    if memories and memories[0].get('size'):
        mem_desc += f'（{_one_line(memories[0]["size"])}）'

    rows = [
        ('产品型号', _fmt(machine.get('product_name'))),
        ('序列号', _fmt(machine.get('serial_number'))),
        ('产品部件号', _fmt(machine.get('product_part_number'))),
        ('BIOS 版本', _fmt(firmware.get('BIOS'))),
        ('HDM 版本', _fmt(firmware.get('HDM'))),
        ('CPLD 版本', _fmt(firmware.get('CPLD'))),
        ('CPU', cpu_desc),
        ('内存', mem_desc),
        ('PCIe 卡', f'{len(pcie)} 个'),
        ('网卡端口', f'{len(nics)} 个'),
        ('背板', f'{len(backplanes)} 个'),
        ('电源', f'{len(psus)} 个'),
    ]
    lines = ['## 1. 整机信息', '', '| 项目 | 内容 |', '| --- | --- |']
    for k, v in rows:
        lines.append(f'| {_one_line(k)} | {_one_line(v)} |')
    return '\n'.join(lines)


def _render_health(health) -> str:
    """## 2. 硬件健康状态：组件 / 状态 / 依据摘要表格。"""
    comps = list(health or [])
    lines = ['## 2. 硬件健康状态', '', '| 组件 | 状态 | 依据摘要 |', '| --- | --- | --- |']
    if not comps:
        lines.append('| （无组件健康判定数据） | — | — |')
    for comp in comps:
        name = getattr(comp, 'name', None) or '未知'
        category = getattr(comp, 'category', None) or ''
        status = getattr(comp, 'status', None) or '未知'
        evidence = getattr(comp, 'evidence', None) or []
        cell = f'{name}（{category}）' if category else name
        lines.append(f'| {_one_line(cell)} | {_one_line(status)} | {_evidence_summary(evidence)} |')
    return '\n'.join(lines)


def _render_abnormal(health) -> str:
    """## 3. 异常详情：每个异常/提示组件的小节（状态 + 事件依据列表 + 建议）。"""
    comps = [c for c in (health or []) if getattr(c, 'status', None) in ('异常', '提示')]
    lines = ['## 3. 异常详情', '']
    if not comps:
        lines.append('（无异常/提示组件）')
    for comp in comps:
        name = getattr(comp, 'name', None) or '未知'
        category = getattr(comp, 'category', None) or ''
        status = getattr(comp, 'status', None) or '未知'
        title = f'### {name}（{category}）' if category else f'### {name}'
        lines += [title, '', f'- 状态：{status}', '']
        evidence = getattr(comp, 'evidence', None) or []
        if evidence:
            lines.append('- 事件依据：')
            for ev in evidence:
                lines.append(f'  - {_one_line(ev)}')
        else:
            lines.append('- 事件依据：（无）')
        suggestions = getattr(comp, 'suggestions', None) or []
        if suggestions:
            lines.append('- 修复建议：')
            for s in suggestions:
                lines.append(f'  - {_one_line(s)}')
        lines.append('')
    return '\n'.join(lines)


def _render_suggestions(health) -> str:
    """## 4. 修复建议：组件 → 建议列表。"""
    comps = [c for c in (health or []) if getattr(c, 'suggestions', None)]
    lines = ['## 4. 修复建议', '']
    if not comps:
        lines.append('（无修复建议）')
    for comp in comps:
        name = getattr(comp, 'name', None) or '未知'
        category = getattr(comp, 'category', None) or ''
        title = f'### {name}（{category}）' if category else f'### {name}'
        lines.append(title)
        for s in getattr(comp, 'suggestions', []):
            lines.append(f'- {_one_line(s)}')
        lines.append('')
    return '\n'.join(lines)


def _render_ai(ai_markdown) -> str:
    """## 5. AI 综合分析（仅 ai_markdown 非 None 时输出，否则空串）。"""
    if ai_markdown is None:
        return ''
    text = str(ai_markdown).strip()
    if not text:
        return ''
    return '## 5. AI 综合分析\n\n' + text


def _render_appendix(inv, sensors, health, events, visible_lines) -> str:
    """## 附录：操作日志摘录 / 其他事件 / 固件版本 / 传感器概要。"""
    lines = ['## 附录', '']

    # 1) 操作日志摘录（visible.log，展示最近 N 行）
    lines.append('### 操作日志摘录（visible.log）')
    lines.append('')
    visible = list(visible_lines or [])
    if not visible:
        lines.append('（无操作日志数据）')
    else:
        cap = visible[-_VISIBLE_LOG_CAP:]
        lines.append(f'（共 {len(visible)} 行，展示最近 {len(cap)} 行）')
        lines.append('')
        lines.append('```')
        lines.extend(cap)
        lines.append('```')
    lines.append('')

    # 2) 其他事件：未出现在任何组件 evidence 中的事件（未归因 / 证据溢出）
    lines.append('### 其他事件')
    lines.append('')
    ev_set = set()
    for comp in (health or []):
        ev_set.update(getattr(comp, 'evidence', None) or [])
    others, seen = [], set()
    for ev in (events or []):
        ts = getattr(ev, 'timestamp', None) or '未知'
        sev = getattr(ev, 'severity', None) or ''
        desc = getattr(ev, 'desc', None) or ''
        fmt = _one_line(f'[{ts}] {sev} {desc}')
        if fmt in ev_set or fmt in seen:
            continue
        seen.add(fmt)
        others.append(ev)
    if not others:
        lines.append('（无其他事件）')
    else:
        shown = others[:_OTHER_EVENTS_CAP]
        lines.append(f'（共 {len(others)} 条，展示前 {len(shown)} 条）')
        lines.append('')
        for ev in shown:
            ts = getattr(ev, 'timestamp', None) or '未知'
            sev = getattr(ev, 'severity', None) or ''
            sensor = getattr(ev, 'sensor_name', None) or ''
            desc = getattr(ev, 'desc', None) or ''
            source = getattr(ev, 'source', None) or ''
            lines.append(f'- [{_one_line(ts)}] {_one_line(sev)} {_one_line(sensor)}: '
                         f'{_one_line(desc)}（来源: {_one_line(source)}）')
    lines.append('')

    # 3) 固件版本
    lines.append('### 固件版本')
    lines.append('')
    firmware = (inv.firmware or {}) if inv is not None else {}
    lines.append('| 项目 | 版本 |')
    lines.append('| --- | --- |')
    for key in ('BIOS', 'HDM', 'CPLD'):
        lines.append(f'| {key} | {_fmt(firmware.get(key))} |')
    lines.append('')

    # 4) 传感器概要（重点传感器优先，其次按名称排序）
    lines.append('### 传感器概要')
    lines.append('')
    readings = list(sensors or [])
    if not readings:
        lines.append('（无传感器数据）')
    else:
        def _key(s):
            name = (getattr(s, 'name', None) or '').lower()
            for i, prefix in enumerate(_KEY_SENSOR_PREFIXES):
                if name == prefix.lower() or name.startswith(prefix.lower()):
                    return (0, i, name)
            return (1, 0, name)

        shown = sorted(readings, key=_key)[:_SENSOR_CAP]
        lines.append(f'（共 {len(readings)} 个传感器，展示 {len(shown)} 个）')
        lines.append('')
        lines.append('| 传感器 | 读数 | 单位 | 状态 |')
        lines.append('| --- | --- | --- | --- |')
        for s in shown:
            lines.append(f'| {_one_line(getattr(s, "name", None) or "")} '
                         f'| {_one_line(getattr(s, "value", None) or "")} '
                         f'| {_one_line(getattr(s, "unit", None) or "")} '
                         f'| {_one_line(getattr(s, "status", None) or "")} |')
    return '\n'.join(lines)


def render_report(inv, sensors, health, events, visible_lines,
                  ai_markdown: str | None = None, report_time: str | None = None) -> str:
    """渲染完整 Markdown 体检报告。

    ai_markdown 为 None 时省略 `## 5. AI 综合分析` 章节（对应未配置/调用
    失败的后端自动模式）；非 None 时并入。report_time 缺省取当前时间。
    """
    report_time = report_time or datetime.now().strftime('%Y-%m-%d %H:%M:%S')
    parts = [
        '# 服务器体检报告',
        '',
        _machine_header(inv),
        f'- 采集时间：{report_time}',
        '',
        _render_inventory(inv),
        '',
        _render_health(health),
        '',
        _render_abnormal(health),
        '',
        _render_suggestions(health),
        '',
    ]
    ai_section = _render_ai(ai_markdown)
    if ai_section:
        parts.append(ai_section)
        parts.append('')
    parts.append(_render_appendix(inv, sensors, health, events, visible_lines))
    return '\n'.join(parts).rstrip() + '\n'


def print_summary(health, report_path) -> None:
    """控制台打印：异常组件数 + 异常组件清单 + 报告路径。"""
    comps = list(health or [])
    abnormal = [c for c in comps if getattr(c, 'status', None) == '异常']
    notice = [c for c in comps if getattr(c, 'status', None) == '提示']
    print(f'体检报告已生成：{report_path}')
    print(f'异常组件数：{len(abnormal)}')
    for comp in abnormal:
        name = getattr(comp, 'name', None) or '未知'
        category = getattr(comp, 'category', None) or ''
        print(f'  - {name}（{category}）' if category else f'  - {name}')
    if notice:
        print(f'提示组件数：{len(notice)}')
        for comp in notice:
            name = getattr(comp, 'name', None) or '未知'
            category = getattr(comp, 'category', None) or ''
            print(f'  - {name}（{category}）' if category else f'  - {name}')
