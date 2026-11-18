"""HDM SDS 日志包健康判定与修复建议规则模块。

消费 Task 2/3/4 的结构化数据（InventoryData / SensorReading / EventRecord），
产出 ComponentHealth 列表（组件状态 + 事件证据 + 修复建议），供报告渲染
（T7）与 AI 材料包（T6）使用。

判定原则（spec「health（核心判定规则）」节）：
- 双来源交叉：事件证据（按 SensorName/DescInfo 归因到组件）+ 状态字段
  （hardware_info.ini 的 Status、传感器状态）
- 待机态不误报：Total_Power 存在且 < 100W 视为待机，风扇 0 RPM 不算异常
- 传感器 status 兼容文本态（ok/na）与十六进制离散码（0x0180）两种形态；
  十六进制状态码无公开 schema 无法可靠解码，一律不作异常判定（防误报）
- 事件按 SensorName 前缀/关键词归因（Disk_/PCIe_/PSU/HDD_BP/CPU*_A0…）；
  sbe 来源的记录可能跨记录拼接/重复，按关键词归因即尽力而为

build_suggestions 优先级：官方 Suggestion > 关键词映射 > 兜底文案。
运行时零第三方依赖，仅用 Python 3.12 标准库。
"""

import re
from dataclasses import dataclass, field

from sds_events import EventRecord


@dataclass
class ComponentHealth:
    """单个组件的健康判定结果。

    name:        组件名称（如 Disk_F23_Status / PCIe_Card3_HBA / PSU1 / FAN1）
    category:    组件类别（硬盘/PCIe/电源/背板/内存/CPU/风扇/温度）
    status:      状态：'正常' | '异常' | '未知' | '提示'
    evidence:    判定依据，格式 `[时间] 级别 描述`，最多 5 条
    suggestions: 修复建议列表
    """

    name: str
    category: str
    status: str
    evidence: list = field(default_factory=list)
    suggestions: list = field(default_factory=list)


# ---------- 状态严重度 ----------

_STATUS_RANK = {'正常': 0, '未知': 1, '提示': 2, '异常': 3}

_CATEGORY_ORDER = ('硬盘', 'PCIe', '电源', '背板', '内存', 'CPU', '风扇', '温度')


def _attribute(name: str) -> tuple | None:
    """按 SensorName 前缀/关键词归因到 (category, 规范化组件名)；无法归因返回 None。

    电源/风扇统一去后缀归一（PSU1_Status → PSU1、FAN1_Speed → FAN1），
    便于传感器、事件与清单条目合并为同一组件。
    """
    if not name:
        return None
    low = name.lower()
    if low.startswith('disk'):
        return ('硬盘', name)
    if low.startswith('pcie'):
        return ('PCIe', name)
    if low.startswith('psu'):
        m = re.match(r'psu(\d+)', low)
        return ('电源', f'PSU{m.group(1)}' if m else name)
    if low.startswith('hdd_bp'):
        return ('背板', name)
    if low.startswith('fan'):
        m = re.match(r'fan(\d+)', low)
        return ('风扇', f'FAN{m.group(1)}' if m else name)
    if low.startswith('cpu'):
        # CPU1_A0 等为内存槽传感器；CPU1_Temp 为 CPU 温度
        if re.search(r'cpu\d+_[a-z]\d', low):
            return ('内存', name)
        if 'temp' in low:
            return ('温度', name)
        return ('CPU', name)
    if low.startswith('memory') or 'dimm' in low:
        return ('内存', name)
    if 'temp' in low or low.startswith('inlet') or low.startswith('outlet'):
        return ('温度', name)
    return None


# ---------- 事件证据判定（关键词逐字取自 spec「组件分类与规则」节） ----------

# (category, 触发关键词) —— 命中判「异常」
_EVENT_ABNORMAL_KEYWORDS = {
    '硬盘': ('the disk is missing', 'drive fault', 'disk missing'),
    'PCIe': ('device disabled', 'module information not obtained'),
    '电源': ('power supply input lost', 'input lost'),
    '背板': ('failed to match',),
}

# 命中判「提示」（认证问题，非故障）
_EVENT_NOTICE_KEYWORDS = {
    '内存': ('not certified',),
}

# "* has been replaced" → 变更记录，判「提示」
_EVENT_CHANGE_KEYWORDS = ('has been replaced', 'replaced')


def _event_status(category: str, ev: EventRecord) -> str:
    """按事件描述关键词判定组件状态（异常/提示/正常）。"""
    desc = (ev.desc or '').lower()
    for kw in _EVENT_ABNORMAL_KEYWORDS.get(category, ()):
        if kw in desc:
            return '异常'
    for kw in _EVENT_NOTICE_KEYWORDS.get(category, ()):
        if kw in desc:
            return '提示'
    if any(kw in desc for kw in _EVENT_CHANGE_KEYWORDS):
        return '提示'
    return '正常'


# ---------- 传感器状态判定 ----------

def _sensor_status_abnormal(status: str) -> bool:
    """文本态传感器状态异常判定；十六进制离散码与 na 不判定（防误报）。"""
    if not status:
        return False
    low = status.strip().lower()
    if low in ('ok', 'na', 'normal', 'good'):
        return False
    if low.startswith('0x'):
        return False  # 十六进制离散码无公开解码，不判异常
    return True


def _is_standby(sensors: list) -> bool:
    """待机判定：Total_Power 存在且 < 100W 视为待机。"""
    for s in sensors:
        if s.name == 'Total_Power':
            try:
                return float(s.value) < 100.0
            except (TypeError, ValueError):
                return False
    return False


def _fan_rpm_zero(reading) -> bool:
    """FAN 转速传感器读数为 0 RPM（十进制数值 0；0x0 离散码不算）。"""
    if not reading.name.lower().startswith('fan'):
        return False
    value = (reading.value or '').strip()
    if reading.unit and 'rpm' in reading.unit.lower():
        try:
            return float(value) == 0.0
        except (TypeError, ValueError):
            return False
    return re.fullmatch(r'0(\.0+)?', value) is not None


# ---------- 清单状态字段判定 ----------

def _field_status(value) -> str:
    """清单状态字段文本 → 状态：Normal/ok 等 → 正常；其他 → 异常；缺失 → 未知。"""
    if not value:
        return '未知'
    low = str(value).strip().lower()
    if 'normal' in low or low in ('ok', 'good', 'present', 'yes'):
        return '正常'
    return '异常'


# ---------- 修复建议规则（关键词与映射逐字取自 spec「修复建议规则」节） ----------

# 优先级 2）：按事件关键词映射补充
#   盘缺失→重新安装/更换；PCIe module not obtained→重新插拔/换槽验证/更换；
#   PSU input lost→检查 AC 输入/电源线/更换 PSU；AC lost→检查市电/插排/PSU 保护；
#   内存 not certified→更换认证型号
_SUGGESTION_RULES = (
    (('the disk is missing', 'disk missing', 'drive fault'),
     '重新安装该硬盘；若反复出现故障请更换硬盘。'),
    (('module information not obtained', 'device disabled'),
     '重新插拔 PCIe 卡并更换槽位验证，必要时更换该 PCIe 模块。'),
    (('power supply input lost', 'input lost'),
     '检查 AC 输入与电源线连接，必要时更换该电源模块（PSU）。'),
    (('ac lost', 'ac power lost'),
     '检查市电与插排供电，确认 PSU 输入保护机制未触发。'),
    (('not certified',),
     '更换为厂商认证的内存型号。'),
)

# 优先级 3）：无匹配 → 兜底文案
_SUGGESTION_FALLBACK = '联系技术支持或结合现场情况进一步判断。'


def build_suggestions(events: list[EventRecord]) -> list[str]:
    """为事件列表生成修复建议（去重）。

    优先级：CSV 官方 Suggestion 原文 > 事件关键词映射 > 兜底文案。
    """
    result = []
    for ev in events:
        official = (ev.suggestion or '').strip()
        if official:
            text = official
        else:
            text = None
            desc = (ev.desc or '').lower()
            for keywords, suggestion in _SUGGESTION_RULES:
                if any(k in desc for k in keywords):
                    text = suggestion
                    break
            if text is None:
                text = _SUGGESTION_FALLBACK
        if text not in result:
            result.append(text)
    return result


# ---------- 健康判定主入口 ----------

def assess_health(inv, sensors, events, raid_bp_text: str | None = None) -> list[ComponentHealth]:
    """综合事件证据 + 状态字段双来源，输出组件健康判定列表。

    raid_bp_text: 背板 Raid_BP_Conf_Info.ini 原文（可选）。含 "Failed To Match"
    时将该背板组件置为「提示」（设计文档 binding authority 规则）。
    """
    standby = _is_standby(sensors)
    # key=(category, name) -> {'status', 'evidence', 'suggestions'}
    comps: dict = {}

    def _upsert(category, name, status, evidence=None, suggestion_texts=None):
        key = (category, name)
        # 初始取最不严重的「正常」，任何显式判定（含「未知」）均可覆盖升级
        comp = comps.setdefault(key, {'status': '正常', 'evidence': [], 'suggestions': []})
        if _STATUS_RANK[status] > _STATUS_RANK[comp['status']]:
            comp['status'] = status
        if evidence and evidence not in comp['evidence']:
            comp['evidence'].append(evidence)
        if suggestion_texts:
            for text in suggestion_texts:
                if text and text not in comp['suggestions']:
                    comp['suggestions'].append(text)

    # 1) 事件证据归因（其余未匹配事件不强行归类，报告层汇总为「其他事件」）
    for ev in events:
        attr = _attribute(ev.sensor_name)
        if attr is None:
            continue
        category, name = attr
        status = _event_status(category, ev)
        evidence = f'[{ev.timestamp}] {ev.severity} {ev.desc}'.strip()
        _upsert(category, name, status, evidence, build_suggestions([ev]))

    # 2) 传感器状态字段（风扇必现组件；电源状态；温度仅在异常时生成）
    for s in sensors:
        attr = _attribute(s.name)
        if attr is None:
            continue
        category, name = attr
        if category == '风扇':
            if _sensor_status_abnormal(s.status):
                _upsert(category, name, '异常', f'[传感器] {s.name} 状态非正常（{s.status}）')
            elif _fan_rpm_zero(s) and not standby:
                _upsert(category, name, '异常', f'[传感器] {s.name} 转速为 0 RPM（非待机态）')
            else:
                _upsert(category, name, '正常')
        elif category == '电源':
            if _sensor_status_abnormal(s.status):
                _upsert(category, name, '异常', f'[传感器] {s.name} 状态非正常（{s.status}）')
            else:
                _upsert(category, name, '正常')
        elif category == '温度':
            if _sensor_status_abnormal(s.status):
                _upsert(category, name, '异常', f'[传感器] {s.name} 状态非正常（{s.status}）')
        # CPU/内存/背板等传感器正常时不生成组件（由清单字段与事件覆盖）

    # 3) 清单状态字段（hardware_info.ini 的 Status / health_status / power_status）
    for i, cpu in enumerate(inv.cpus):
        status = _field_status(cpu.get('status'))
        name = f'CPU {i + 1}'
        evidence = None if status == '正常' else f'[清单] CPU 状态 {cpu.get("status") or "未知"}'
        _upsert('CPU', name, status, evidence)
    for i, mem in enumerate(inv.memories):
        status = _field_status(mem.get('status'))
        name = mem.get('socket_id') or f'Memory {i + 1}'
        evidence = None if status == '正常' else f'[清单] 内存状态 {mem.get("status") or "未知"}'
        _upsert('内存', name, status, evidence)
    for pcie in inv.pcie_cards:
        status = _field_status(pcie.get('status'))
        name = f'PCIe Card {pcie.get("location") or ""}'.strip()
        evidence = None if status == '正常' else f'[清单] PCIe 状态 {pcie.get("status") or "未知"}'
        _upsert('PCIe', name, status, evidence)
    for bp in inv.backplanes:
        health = bp.get('health_status')
        status = _field_status(health)
        if status == '异常':
            status = '提示'  # 背板健康字段异常按提示级处理（防误报）
        name = bp.get('name') or 'Backplane'
        evidence = None if status == '正常' else f'[清单] 背板健康状态 {health or "未知"}'
        _upsert('背板', name, status, evidence)
    for psu in inv.psus:
        name = f'PSU{psu.get("id") or "?"}'
        ps = (psu.get('power_status') or '').strip()
        if 'abnormal' in ps.lower() and not standby:
            _upsert('电源', name, '提示', f'[清单] 电源状态 {ps}')
        else:
            _upsert('电源', name, '正常')

    # 3.5) 背板 Raid_BP_Conf_Info.ini 含 "Failed To Match" → 提示
    #      （设计文档 binding authority；不区分大小写；仅升级不降级）
    #      命中已有的背板组件时取健康列表中排在最前的那个（与输出排序一致），
    #      使真实样例中的清单背板（FrontBackPlane3）而非事件传感器组件被标提示
    if raid_bp_text and 'failed to match' in raid_bp_text.lower():
        bp_evidence = '[未知] Info Raid_BP_Conf_Info: Failed To Match The Configuration'
        bp_suggestion = ['检查背板配置与当前硬件是否匹配，必要时联系技术支持。']
        order = {cat: i for i, cat in enumerate(_CATEGORY_ORDER)}
        bp_keys = sorted((k for k in comps if k[0] == '背板'),
                         key=lambda k: (order.get(k[0], len(order)), k[1]))
        if bp_keys:
            _upsert(*bp_keys[0], '提示', bp_evidence, bp_suggestion)
        else:
            _upsert('背板', 'BackPlane', '提示', bp_evidence, bp_suggestion)

    # 4) 组装输出（evidence 最多 5 条；按类别稳定排序）
    order = {cat: i for i, cat in enumerate(_CATEGORY_ORDER)}

    def _sort_key(item):
        return (order.get(item[0][0], len(order)), item[0][1])

    result = []
    for (category, name), comp in sorted(comps.items(), key=_sort_key):
        result.append(ComponentHealth(
            name=name,
            category=category,
            status=comp['status'],
            evidence=comp['evidence'][:5],
            suggestions=comp['suggestions'],
        ))
    return result
