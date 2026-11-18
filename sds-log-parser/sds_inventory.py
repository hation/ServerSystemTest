"""HDM SDS 日志包硬件清单解析模块。

解析解包后 static/ 目录中的硬件清单相关文件：
- hardware_info.ini：CPU / 内存 / PCIe 卡 / 网卡 / 电源 / 背板 / BaseBoard 等分段信息
- firmware_version.ini：BIOS / HDM / CPLD 固件版本
- FruInfo.ini：[BaseBoard] 段的产品名称 / 序列号 / 产品部件号
- bios.json / hdm.json：machine information 对象，作为 machine / firmware 的补充来源
  （主来源优先，主来源缺字段时才补充）

空文件、缺失文件（None）或损坏文件一律返回空列表 / None 字段，绝不抛异常。
运行时零第三方依赖，仅用 Python 3.12 标准库。
"""

import configparser
import json
from dataclasses import dataclass, field

from sds_extract import read_text_file

# hardware_info.ini 与 firmware_version.ini 的键值分隔为 'Key : Value'，
# FruInfo.ini 为 'Key=Value'；统一用 ('=', ':') 双分隔符适配。
_INI_DELIMITERS = ('=', ':')

# firmware_version.ini 中版本字段 → 输出字段名
_FW_VERSION_KEYS = {
    'bios version': 'BIOS',
    'hdm version': 'HDM',
    'cpld version': 'CPLD',
}

# bios.json / hdm.json 的 machine information 中可用的字段
_JSON_MACHINE_KEYS = (
    'product name',
    'serial number',
    'product part number',
    'bios version',
    'hdm version',
    'cpld version',
)


@dataclass
class InventoryData:
    """硬件清单解析结果。

    machine:   产品信息（product_name/serial_number/product_part_number/baseboard）
    firmware:  固件版本（BIOS/HDM/CPLD，缺省 None）
    cpus:      CPU 列表（model/status/cores/threads）
    memories:  内存条列表（location/socket_id/size/status/part_number）
    pcie_cards:PCIe 卡列表（location/product_name/vendor_id/status/current_speed/current_bandwidth）
    nics:      网卡端口列表（port/location/mac/product_name/link_state）
    backplanes:背板列表（name/part_number/board_type/health_status）
    psus:      电源列表（id/model/sn/power_status）
    """

    machine: dict = field(default_factory=lambda: {
        'product_name': None,
        'serial_number': None,
        'product_part_number': None,
        'baseboard': {},
    })
    firmware: dict = field(default_factory=lambda: {'BIOS': None, 'HDM': None, 'CPLD': None})
    cpus: list = field(default_factory=list)
    memories: list = field(default_factory=list)
    pcie_cards: list = field(default_factory=list)
    nics: list = field(default_factory=list)
    backplanes: list = field(default_factory=list)
    psus: list = field(default_factory=list)


def _read_ini(path: str | None) -> dict:
    """读取并解析 .ini 文本，返回 {段名: {小写键: 值}}。

    兼容 'Key : Value' 与 'Key=Value' 两种分隔；空 / 缺失 / 损坏文件返回空 dict。
    """
    if not path:
        return {}
    try:
        text = read_text_file(path)
    except OSError:
        return {}
    if not text.strip():
        return {}
    parser = configparser.ConfigParser(
        delimiters=_INI_DELIMITERS,
        strict=False,          # 容忍重复选项
        interpolation=None,    # 值中的 % 不做插值，避免误报
    )
    try:
        parser.read_string(text)
    except (configparser.Error, ValueError):
        return {}
    return {section: {k: v for k, v in parser.items(section)} for section in parser.sections()}


def _find_section(sections: dict, name: str) -> dict:
    """按段名（大小写不敏感）查找段，返回其选项 dict；未找到返回空 dict。"""
    for section in sections:
        if section.lower() == name.lower():
            return sections[section]
    return {}


def _load_json_machine(path: str | None) -> dict:
    """读取 bios.json / hdm.json 的 'machine information' 对象；缺失/损坏返回空 dict。"""
    if not path:
        return {}
    try:
        text = read_text_file(path)
    except OSError:
        return {}
    if not text.strip():
        return {}
    try:
        data = json.loads(text)
    except (json.JSONDecodeError, ValueError):
        return {}
    if not isinstance(data, dict):
        return {}
    machine_info = data.get('machine information')
    if not isinstance(machine_info, dict):
        return {}
    result = {}
    for key in _JSON_MACHINE_KEYS:
        value = machine_info.get(key)
        if isinstance(value, str):
            result[key] = value
    return result


def _parse_machine(sections_fru: dict, json_machine: dict, sections_hw: dict) -> dict:
    """产品信息：FruInfo.ini [BaseBoard] 优先，bios.json/hdm.json 补充。"""
    fru_base = _find_section(sections_fru, 'BaseBoard')
    product_name = fru_base.get('product product name')
    serial_number = fru_base.get('product serial number')
    product_part_number = fru_base.get('product part number')
    if not product_name:
        product_name = json_machine.get('product name')
    if not serial_number:
        serial_number = json_machine.get('serial number')
    if not product_part_number:
        product_part_number = json_machine.get('product part number')

    # baseboard：hardware_info.ini [BaseBoard] 优先；FruInfo.ini 的 board* 字段兜底
    hw_bb = _find_section(sections_hw, 'BaseBoard')
    baseboard = {}
    if hw_bb:
        baseboard = dict(hw_bb)
    else:
        for key, value in fru_base.items():
            if key.startswith('board '):
                baseboard[key[len('board '):]] = value
    return {
        'product_name': product_name,
        'serial_number': serial_number,
        'product_part_number': product_part_number,
        'baseboard': baseboard,
    }


def _parse_firmware(sections_fw: dict, sections_hw: dict, json_machine: dict) -> dict:
    """固件版本：firmware_version.ini [System board] 优先，json / hardware_info.ini 补充。"""
    firmware = {'BIOS': None, 'HDM': None, 'CPLD': None}
    sys_board = _find_section(sections_fw, 'System board')
    for ini_key, out_key in _FW_VERSION_KEYS.items():
        value = sys_board.get(ini_key)
        if not value:
            value = json_machine.get(ini_key)
        if not value and out_key == 'CPLD':
            value = _find_section(sections_hw, 'BaseBoard').get('cpld_version')
        firmware[out_key] = value
    return firmware


def _parse_boards(sections: dict) -> tuple:
    """按段名归类 CPU / 内存 / PCIe / 网卡 / 电源 / 背板清单。"""
    cpus, memories, pcie_cards, nics, psus, backplanes = [], [], [], [], [], []
    for section, opts in sections.items():
        lower = section.lower()
        if lower == 'baseboard':
            continue  # BaseBoard 信息已归入 machine.baseboard
        # 汇总类 / 风扇等与清单条目无关的段直接跳过
        if (lower.startswith('fan')
                or lower.startswith('memory summary:')
                or lower.startswith('processor summary')
                or lower.startswith('power summary')):
            continue
        if lower.startswith('processors:') or lower.startswith('processor '):
            cpus.append({
                'model': opts.get('model'),
                'status': opts.get('status'),
                'cores': opts.get('cores'),
                'threads': opts.get('threads'),
            })
        elif lower.startswith('memory details:'):
            memories.append({
                'location': opts.get('location'),
                'socket_id': opts.get('socket id'),
                'size': opts.get('size'),
                'status': opts.get('status'),
                'part_number': opts.get('part number'),
            })
        elif lower.startswith('pcie card:'):
            pcie_cards.append({
                'location': opts.get('location'),
                'product_name': opts.get('product name'),
                'vendor_id': opts.get('vendor id'),
                'status': opts.get('status'),
                'current_speed': opts.get('current speed'),
                'current_bandwidth': opts.get('current bandwidth'),
            })
        elif lower.startswith('ethernet adapters:'):
            nics.append({
                'port': opts.get('network port'),
                'location': opts.get('location'),
                'mac': opts.get('mac address'),
                'product_name': opts.get('product name'),
                'link_state': opts.get('link state'),
            })
        elif lower.startswith('power '):
            psus.append({
                'id': opts.get('power id'),
                'model': opts.get('model'),
                'sn': opts.get('sn'),
                'power_status': opts.get('power status'),
            })
        elif 'part_number' in opts or 'board_type' in opts:
            # 其余含部件号 / 板型的段（如 FrontBackPlane3、Riser1）视为背板
            backplanes.append({
                'name': section,
                'part_number': opts.get('part_number'),
                'board_type': opts.get('board_type'),
                'health_status': opts.get('health_status'),
            })
    return cpus, memories, pcie_cards, nics, psus, backplanes


def parse_inventory(files: dict) -> InventoryData:
    """解析硬件清单，返回 InventoryData。

    files 为 ExtractionResult.files（固定键 → 绝对路径 | None）。主来源
    （hardware_info.ini / firmware_version.ini / FruInfo.ini）优先，
    bios.json / hdm.json 的 machine information 作为补充；空 / 缺 / 损坏
    文件返回空列表与 None 字段，绝不抛异常。
    """
    files = files or {}
    sections_hw = _read_ini(files.get('hardware_info_ini'))
    sections_fw = _read_ini(files.get('firmware_version_ini'))
    sections_fru = _read_ini(files.get('fru_info_ini'))

    json_machine = {}
    for key in ('bios_json', 'hdm_json'):
        for k, v in _load_json_machine(files.get(key)).items():
            json_machine.setdefault(k, v)

    machine = _parse_machine(sections_fru, json_machine, sections_hw)
    firmware = _parse_firmware(sections_fw, sections_hw, json_machine)
    cpus, memories, pcie_cards, nics, psus, backplanes = _parse_boards(sections_hw)
    return InventoryData(
        machine=machine,
        firmware=firmware,
        cpus=cpus,
        memories=memories,
        pcie_cards=pcie_cards,
        nics=nics,
        backplanes=backplanes,
        psus=psus,
    )
