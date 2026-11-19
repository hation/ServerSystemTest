"""HDM SDS 日志解析体检工具 —— 轻量测试运行器。

用法：python sds-log-parser/tests/run_tests.py

扫描本模块内所有 test_* 函数逐一执行，逐个打印 PASS/FAIL，
任一用例失败则进程退出码为非 0。后续任务可不断向本文件追加
test_* 函数，追加后仍可整体运行（不依赖 pytest 等第三方库）。
"""

import io
import json
import os
import shutil
import subprocess
import sys
import tarfile
import tempfile
import urllib.error
from unittest import mock

# 保证从任意工作目录运行时都能 import 到 sds-log-parser 下的模块
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from sds_ai import build_ai_payload, call_ai
from sds_extract import SDSNotTarError, cleanup, extract_sds, read_text_file
from sds_events import EventRecord, parse_event_csv, parse_sbe, parse_visible_log
from sds_health import ComponentHealth, _field_status, assess_health, build_suggestions
from sds_inventory import InventoryData, parse_inventory
from sds_sensors import SensorReading, parse_sensors


# ---------- 子进程调用 CLI（T7 集成用例用） ----------

_REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# 真实样例路径：可用 `python run_tests.py --sds <路径>` 注入覆盖
_REAL_SDS_DEFAULT = (
    r'c:\Users\ganxin01\.trae-cn\attachments'
    r'\561c8ecb-f478-478c-a9b8-c0e9250fb527_035beacd-9c0e-42d3-93a4-39ccbe348f36_HDM210235A566526AN0000P_20261118.sds'
)
_REAL_SDS_PATH = None


def _real_sds_path() -> str:
    """返回真实样例路径（--sds 注入优先，缺省用固定默认路径）。"""
    return _REAL_SDS_PATH or _REAL_SDS_DEFAULT


def _run_cli(args_list: list) -> subprocess.CompletedProcess:
    """以子进程调用 sds_parser.py（强制 UTF-8 输出），供 CLI 级用例使用。"""
    env = dict(os.environ)
    env['PYTHONIOENCODING'] = 'utf-8'
    return subprocess.run(
        [sys.executable, os.path.join(_REPO_ROOT, 'sds_parser.py'), *args_list],
        capture_output=True, text=True, encoding='utf-8', errors='replace',
        cwd=_REPO_ROOT, timeout=180,
    )


# ---------- 测试用例 ----------

def _build_sample_sds(tmp_dir: str) -> str:
    """构造含 static/hardware_info.ini、user/test.csv、event/ev.tar.gz(内含 .sbe) 的样例 .sds。"""
    # 先造内层事件包：event/ev.tar.gz 内含 00000001_20261118.sbe
    sbe_path = os.path.join(tmp_dir, '00000001_20261118.sbe')
    with open(sbe_path, 'w', encoding='utf-8') as f:
        f.write('EVENT_SBE_CONTENT')
    ev_gz_path = os.path.join(tmp_dir, 'ev.tar.gz')
    with tarfile.open(ev_gz_path, 'w:gz') as tgz:
        tgz.add(sbe_path, arcname=os.path.basename(sbe_path))

    # 再造外层 .sds 归档
    sds_path = os.path.join(tmp_dir, 'sample.sds')
    with tarfile.open(sds_path, 'w') as tar:
        for arcname, content in {
            'static/hardware_info.ini': '[Hardware]\nModel=test\n',
            'user/test.csv': 'a,b\n1,2\n',
        }.items():
            data = content.encode('utf-8')
            info = tarfile.TarInfo(arcname)
            info.size = len(data)
            tar.addfile(info, io.BytesIO(data))
        with open(ev_gz_path, 'rb') as f:
            info = tarfile.TarInfo('event/ev.tar.gz')
            info.size = os.path.getsize(ev_gz_path)
            tar.addfile(info, f)
    return sds_path


def test_extract_basic():
    """正常 .sds 归档：各键定位正确，未提供的文件为 None。"""
    tmp_dir = tempfile.mkdtemp()
    try:
        sds_path = _build_sample_sds(tmp_dir)
        result = extract_sds(sds_path)
        try:
            assert result.root_dir and os.path.isdir(result.root_dir)
            # 键集合固定
            expected_keys = {
                'event_csv', 'sbe', 'visible_log', 'hardware_info_ini',
                'hardware_info', 'firmware_version_ini', 'fru_info_ini',
                'sensor_info_ini', 'raid_bp_conf_ini', 'nvme_info_ini',
                'bios_json', 'hdm_json',
            }
            assert set(result.files.keys()) == expected_keys
            # event_csv 指向 user/test.csv
            assert result.files['event_csv'] is not None
            assert os.path.isfile(result.files['event_csv'])
            assert result.files['event_csv'].replace('\\', '/').endswith('user/test.csv')
            # sbe 指向解包出的 .sbe
            assert result.files['sbe'] is not None
            assert os.path.isfile(result.files['sbe'])
            assert result.files['sbe'].lower().endswith('.sbe')
            # hardware_info_ini 存在
            assert result.files['hardware_info_ini'] is not None
            assert os.path.isfile(result.files['hardware_info_ini'])
            # 未提供的文件为 None
            assert result.files['visible_log'] is None
            assert result.files['bios_json'] is None
            assert result.files['hdm_json'] is None
        finally:
            cleanup(result)
            assert not os.path.isdir(result.root_dir), 'cleanup 后临时目录应被删除'
    finally:
        shutil.rmtree(tmp_dir, ignore_errors=True)


def test_extract_non_tar():
    """普通文本文件不是 tar 归档 → 抛 SDSNotTarError。"""
    tmp_dir = tempfile.mkdtemp()
    try:
        sds_path = os.path.join(tmp_dir, 'not_tar.sds')
        with open(sds_path, 'w', encoding='utf-8') as f:
            f.write('this is definitely not a tar archive at all 12345')
        try:
            extract_sds(sds_path)
            assert False, '应当抛出 SDSNotTarError'
        except SDSNotTarError:
            pass  # 预期异常
    finally:
        shutil.rmtree(tmp_dir, ignore_errors=True)


def test_extract_traversal():
    """含 ../、绝对路径与 a/.. 折叠成员的恶意 tar → 不落盘、不抛异常。"""
    tmp_dir = tempfile.mkdtemp()
    try:
        sds_path = os.path.join(tmp_dir, 'evil.sds')
        with tarfile.open(sds_path, 'w') as tar:
            evil = tarfile.TarInfo('../evil')
            evil.size = 4
            tar.addfile(evil, io.BytesIO(b'evil'))
            abs_member = tarfile.TarInfo('/tmp/abs_evil')
            abs_member.size = 3
            tar.addfile(abs_member, io.BytesIO(b'abs'))
            # 病态成员 a/..：normpath 折叠为 '.'，应被拒绝而非触发 PermissionError
            dot_member = tarfile.TarInfo('a/..')
            dot_member.size = 4
            tar.addfile(dot_member, io.BytesIO(b'evil'))
        result = extract_sds(sds_path)
        try:
            # '../evil' 不应落到临时目录或其父目录
            assert not os.path.exists(os.path.join(result.root_dir, 'evil'))
            parent = os.path.dirname(os.path.abspath(result.root_dir))
            assert not os.path.exists(os.path.join(parent, 'evil'))
            # 绝对路径成员不应落盘
            assert not os.path.exists(os.path.join(result.root_dir, 'tmp', 'abs_evil'))
            # a/.. 折叠为 '.'：root 下应无任何落盘内容，且整体不崩溃
            assert os.listdir(result.root_dir) == []
        finally:
            cleanup(result)
    finally:
        shutil.rmtree(tmp_dir, ignore_errors=True)


def test_cleanup_respects_keep():
    """keep=True（对应 CLI --no-cleanup 保留调试）时 cleanup 应跳过删除。"""
    tmp_dir = tempfile.mkdtemp()
    try:
        sds_path = _build_sample_sds(tmp_dir)
        result = extract_sds(sds_path, keep=True)
        try:
            assert result.keep is True
            cleanup(result)
            assert os.path.isdir(result.root_dir), 'keep=True 时 cleanup 不应删除临时目录'
        finally:
            shutil.rmtree(result.root_dir, ignore_errors=True)
    finally:
        shutil.rmtree(tmp_dir, ignore_errors=True)


def test_read_text_gbk():
    """GBK 编码的中文文本 → read_text_file 正确解码（UTF-8 失败回退 GBK）。"""
    tmp_dir = tempfile.mkdtemp()
    try:
        path = os.path.join(tmp_dir, 'gbk.ini')
        with open(path, 'w', encoding='gbk') as f:
            f.write('[硬件信息]\n型号=HDM_GBK_中文测试\n')
        text = read_text_file(path)
        assert '型号=HDM_GBK_中文测试' in text
    finally:
        shutil.rmtree(tmp_dir, ignore_errors=True)


def test_inventory_hardware_info_ini():
    """hardware_info.ini / FruInfo.ini / firmware_version.ini 主来源解析正确。"""
    tmp_dir = tempfile.mkdtemp()
    try:
        hw = os.path.join(tmp_dir, 'hardware_info.ini')
        with open(hw, 'w', encoding='utf-8') as f:
            f.write(
                '[Processors: Processor 1]\n'
                'Model                         : Hygon C86-3G 7380 32-core Processor\n'
                'Status                        : Normal\n'
                'Cores                         : 32\n'
                'Threads                       : 64\n'
                '[Memory Details: Dimm Index 0]\n'
                'Location                      : Processor 1\n'
                'Socket ID                     : A0\n'
                'Status                        : Normal\n'
                'Size                          : 65536 MiB\n'
                'Part Number                   : M393A8G40AB2-CWE\n'
                '[PCIe Card: PCIe 3]\n'
                'Location                      : 3\n'
                'Product Name                  : NIC-620F-B2-25Gb-2P-1-X\n'
                'Status                        : Normal\n'
                'Vendor ID                     : 0x15B3\n'
                'Current Speed                 : 8.0GT/s\n'
                'Current Bandwidth             : x8\n'
                '[Ethernet adapters: Port 1]\n'
                'Network Port                  : Port 1\n'
                'Location                      : PCIE-[1]\n'
                'MAC Address                   : 68:19:77:CE:B0:72\n'
                'Product Name                  : NIC-620F-B2-25Gb-2P-1-X\n'
                'Link State                    : N/A\n'
                '[FrontBackPlane3]\n'
                'health_status                 : Normal\n'
                'part_number                   : 0302A64B\n'
                'board_type                    : 8SFF Unibay\n'
                '[Power 1]\n'
                'Power Id                      : 1\n'
                'Model                         : GW-CRPS800N2\n'
                'SN                            : 210231AMPQ526AN0002V\n'
                'Power Status                  : Input Normal, Output Abnormal\n'
                '[BaseBoard]\n'
                'health_status                 : Normal\n'
                'manufacture                   : H3C\n'
                'part_number                   : 0302AA1N\n'
                'serial_number                 : 02AA1N5269C001VV\n'
                'cpld_version                  : V00D\n'
            )
        fru = os.path.join(tmp_dir, 'FruInfo.ini')
        with open(fru, 'w', encoding='utf-8') as f:
            f.write(
                '[BaseBoard]\n'
                'Product Product Name=H3C UniServer R4930 G5 H3\n'
                'Product Serial Number=210235A566526AN0000P\n'
                'Product Part Number=0235A566\n'
            )
        fw = os.path.join(tmp_dir, 'firmware_version.ini')
        with open(fw, 'w', encoding='utf-8') as f:
            f.write(
                '[System board]\n'
                'BIOS Version                  : 5.97 V500R001B01D097\n'
                'HDM Version                   : 3.66 HDM V100R001B05D110\n'
                'CPLD Version                  : V00D\n'
            )
        # 补充来源提供与主来源不同的值，验证「主来源优先」
        bios = os.path.join(tmp_dir, 'bios.json')
        with open(bios, 'w', encoding='utf-8') as f:
            f.write('{"machine information": {"bios version": "9.99 FAKE", "product name": "FAKE-MODEL"}}\n')
        files = {
            'hardware_info_ini': hw,
            'fru_info_ini': fru,
            'firmware_version_ini': fw,
            'bios_json': bios,
            'hdm_json': None,
        }
        inv = parse_inventory(files)
        # machine
        assert inv.machine['product_name'] == 'H3C UniServer R4930 G5 H3'
        assert inv.machine['serial_number'] == '210235A566526AN0000P'
        assert inv.machine['product_part_number'] == '0235A566'
        assert inv.machine['baseboard']['manufacture'] == 'H3C'
        assert inv.machine['baseboard']['part_number'] == '0302AA1N'
        assert inv.machine['baseboard']['cpld_version'] == 'V00D'
        # firmware：主来源优先于补充来源
        assert inv.firmware['BIOS'] == '5.97 V500R001B01D097'
        assert inv.firmware['HDM'] == '3.66 HDM V100R001B05D110'
        assert inv.firmware['CPLD'] == 'V00D'
        # cpus
        assert len(inv.cpus) == 1
        assert inv.cpus[0]['model'] == 'Hygon C86-3G 7380 32-core Processor'
        assert inv.cpus[0]['status'] == 'Normal'
        assert inv.cpus[0]['cores'] == '32'
        assert inv.cpus[0]['threads'] == '64'
        # memories
        assert len(inv.memories) == 1
        assert inv.memories[0]['location'] == 'Processor 1'
        assert inv.memories[0]['socket_id'] == 'A0'
        assert inv.memories[0]['size'] == '65536 MiB'
        assert inv.memories[0]['status'] == 'Normal'
        assert inv.memories[0]['part_number'] == 'M393A8G40AB2-CWE'
        # pcie_cards
        assert len(inv.pcie_cards) == 1
        assert inv.pcie_cards[0]['location'] == '3'
        assert inv.pcie_cards[0]['product_name'] == 'NIC-620F-B2-25Gb-2P-1-X'
        assert inv.pcie_cards[0]['status'] == 'Normal'
        assert inv.pcie_cards[0]['vendor_id'] == '0x15B3'
        assert inv.pcie_cards[0]['current_speed'] == '8.0GT/s'
        assert inv.pcie_cards[0]['current_bandwidth'] == 'x8'
        # nics
        assert len(inv.nics) == 1
        assert inv.nics[0]['port'] == 'Port 1'
        assert inv.nics[0]['location'] == 'PCIE-[1]'
        assert inv.nics[0]['mac'] == '68:19:77:CE:B0:72'
        assert inv.nics[0]['product_name'] == 'NIC-620F-B2-25Gb-2P-1-X'
        # backplanes
        assert len(inv.backplanes) == 1
        assert inv.backplanes[0]['name'] == 'FrontBackPlane3'
        assert inv.backplanes[0]['part_number'] == '0302A64B'
        assert inv.backplanes[0]['board_type'] == '8SFF Unibay'
        assert inv.backplanes[0]['health_status'] == 'Normal'
        # psus
        assert len(inv.psus) == 1
        assert inv.psus[0]['id'] == '1'
        assert inv.psus[0]['model'] == 'GW-CRPS800N2'
        assert inv.psus[0]['sn'] == '210231AMPQ526AN0002V'
        assert inv.psus[0]['power_status'] == 'Input Normal, Output Abnormal'
    finally:
        shutil.rmtree(tmp_dir, ignore_errors=True)


def test_inventory_firmware():
    """firmware_version.ini / FruInfo.ini 缺失时，bios.json 的 machine information 补充。"""
    tmp_dir = tempfile.mkdtemp()
    try:
        hw = os.path.join(tmp_dir, 'hardware_info.ini')
        with open(hw, 'w', encoding='utf-8') as f:
            f.write('[BaseBoard]\nmanufacture                   : H3C\ncpld_version                  : V00D\n')
        bios = os.path.join(tmp_dir, 'bios.json')
        with open(bios, 'w', encoding='utf-8') as f:
            f.write(
                '{\n'
                '  "machine information": {\n'
                '    "product name": "RS41M2C5SCH",\n'
                '    "serial number": "02AA1N5269C001VV",\n'
                '    "bios version": "5.97 V500R001B01D097",\n'
                '    "hdm version": "3.66 HDM V100R001B05D110",\n'
                '    "cpld version": "V00D"\n'
                '  }\n'
                '}\n'
            )
        files = {
            'hardware_info_ini': hw,
            'fru_info_ini': None,
            'firmware_version_ini': None,
            'bios_json': bios,
            'hdm_json': None,
        }
        inv = parse_inventory(files)
        # 主来源缺失 → 由 bios.json 补充
        assert inv.machine['product_name'] == 'RS41M2C5SCH'
        assert inv.machine['serial_number'] == '02AA1N5269C001VV'
        assert inv.firmware['BIOS'] == '5.97 V500R001B01D097'
        assert inv.firmware['HDM'] == '3.66 HDM V100R001B05D110'
        assert inv.firmware['CPLD'] == 'V00D'
        # baseboard 由 hardware_info.ini [BaseBoard] 提供
        assert inv.machine['baseboard']['manufacture'] == 'H3C'
        assert inv.machine['baseboard']['cpld_version'] == 'V00D'
    finally:
        shutil.rmtree(tmp_dir, ignore_errors=True)


def test_inventory_empty_files():
    """空文件（0 字节）与缺文件（None）→ 返回空列表/None 字段，绝不抛异常。"""
    tmp_dir = tempfile.mkdtemp()
    try:
        empty = os.path.join(tmp_dir, 'empty.ini')
        with open(empty, 'w', encoding='utf-8') as f:
            f.write('')
        files_all_none = {
            'hardware_info_ini': None,
            'firmware_version_ini': None,
            'fru_info_ini': None,
            'bios_json': None,
            'hdm_json': None,
        }
        inv = parse_inventory(files_all_none)
        assert inv.machine['product_name'] is None
        assert inv.machine['serial_number'] is None
        assert inv.machine['product_part_number'] is None
        assert inv.machine['baseboard'] == {}
        assert inv.firmware['BIOS'] is None
        assert inv.firmware['HDM'] is None
        assert inv.firmware['CPLD'] is None
        assert inv.cpus == []
        assert inv.memories == []
        assert inv.pcie_cards == []
        assert inv.nics == []
        assert inv.backplanes == []
        assert inv.psus == []
        # 0 字节文件同样视为缺数据
        files_empty = {
            'hardware_info_ini': empty,
            'firmware_version_ini': empty,
            'fru_info_ini': empty,
            'bios_json': empty,
            'hdm_json': empty,
        }
        inv2 = parse_inventory(files_empty)
        assert inv2.cpus == []
        assert inv2.firmware['BIOS'] is None
        assert inv2.machine['product_name'] is None
        assert inv2.machine['baseboard'] == {}
        # 无段头的垃圾内容 → 不抛异常、返回空数据
        garbage = os.path.join(tmp_dir, 'garbage.ini')
        with open(garbage, 'w', encoding='utf-8') as f:
            f.write('this is not ini at all\nno sections here\n')
        inv3 = parse_inventory({'hardware_info_ini': garbage})
        assert inv3.cpus == []
        assert inv3.machine['baseboard'] == {}
        assert inv3.firmware['CPLD'] is None
        # 键完全缺失（空 dict）也不抛异常
        inv4 = parse_inventory({})
        assert inv4.psus == []
        assert inv4.firmware['HDM'] is None
    finally:
        shutil.rmtree(tmp_dir, ignore_errors=True)


def test_sensors_parse():
    """sensor_info.ini 管道分隔表：跳过表头/注释/空行，前 4 列解析 name/value/unit/status。"""
    tmp_dir = tempfile.mkdtemp()
    try:
        path = os.path.join(tmp_dir, 'sensor_info.ini')
        with open(path, 'w', encoding='utf-8') as f:
            f.write(
                'Sensor Name      | Reading    | Unit       | Status| Crit low  | Major low | Minor low | Minor high| Major high| Crit high \n'
                '# 注释行：应被跳过\n'
                '; 分号注释行：也应被跳过\n'
                'PSU1_VIN         | 223.200    | Volts      | ok    | na        | na        | na        | na        | na        | na        \n'
                'PSU2_VIN         | 223.200    | Volts      | ok    | na        | na        | na        | na        | na        | na        \n'
                '\n'
                'PSU1_Status      | 0x0        | discrete   | 0x0180| na        | na        | na        | na        | na        | na        \n'
                'FAN1_Status      | 0x0        | discrete   | 0x0180| na        | na        | na        | na        | na        | na        \n'
                'Total_Power      | 320.0      | Watts      | ok    | na        | na        | na        | na        | na        | na        \n'
                'Inlet_Temp       | 24.5       | degrees C  | ok    | na        | na        | na        | 50.000    | 52.000    | 55.000    \n'
            )
        readings = parse_sensors(path)
        assert len(readings) == 6
        by_name = {r.name: r for r in readings}
        # 重点关注传感器：值/单位/状态四列解析正确
        assert by_name['PSU1_VIN'].value == '223.200'
        assert by_name['PSU1_VIN'].unit == 'Volts'
        assert by_name['PSU1_VIN'].status == 'ok'
        assert by_name['PSU2_VIN'].value == '223.200'
        assert by_name['PSU2_VIN'].unit == 'Volts'
        assert by_name['PSU1_Status'].status == '0x0180'
        assert by_name['PSU1_Status'].unit == 'discrete'
        assert by_name['FAN1_Status'].status == '0x0180'
        assert by_name['Total_Power'].value == '320.0'
        assert by_name['Total_Power'].unit == 'Watts'
        assert by_name['Inlet_Temp'].value == '24.5'
        assert by_name['Inlet_Temp'].unit == 'degrees C'
        assert by_name['Inlet_Temp'].status == 'ok'
    finally:
        shutil.rmtree(tmp_dir, ignore_errors=True)


def test_sensors_empty():
    """缺文件（None）与空文件（0 字节）→ 返回空列表，绝不抛异常。"""
    tmp_dir = tempfile.mkdtemp()
    try:
        assert parse_sensors(None) == []
        empty = os.path.join(tmp_dir, 'empty.ini')
        with open(empty, 'w', encoding='utf-8') as f:
            f.write('')
        assert parse_sensors(empty) == []
        # 不存在的路径同样不抛异常
        assert parse_sensors(os.path.join(tmp_dir, 'missing.ini')) == []
    finally:
        shutil.rmtree(tmp_dir, ignore_errors=True)


def test_event_csv():
    """test.csv：表头 10 列、\x00 去除、引号内多行字段、severity/sensor/desc/suggestion 映射。"""
    tmp_dir = tempfile.mkdtemp()
    try:
        path = os.path.join(tmp_dir, 'test.csv')
        content = (
            'Record Time Stamp,Severity Level,Severity Level ID,SensorTypeStr,'
            'SensorName,Event Dir,Event Occurred Time,DescInfo,Explanation,Suggestion\n'
            '2026-11-13 08:00:01,Major,0x1,Drive Backplane,Disk_F23_Status,'
            'Assertion event,2026-11-13 08:00:00\x00,"Drive Fault\x00 on slot F23\n'
            'Please replace the disk"," ",\n'
            '2026-11-13 08:05:00,Info,0x0,Management Subsystem Health,Health,'
            'Assertion event,2026-11-13 08:05:00,"HDM reset ok"," "," "\n'
        )
        with open(path, 'w', encoding='utf-8') as f:
            f.write(content)
        records = parse_event_csv(path)
        assert len(records) == 2
        r0 = records[0]
        assert r0.source == 'csv'
        assert r0.timestamp == '2026-11-13 08:00:01'
        assert r0.severity == 'Major'
        assert r0.sensor_name == 'Disk_F23_Status'
        # \x00 已去除、引号内换行保留为多行字段
        assert 'Drive Fault on slot F23' in r0.desc
        assert '\n' in r0.desc
        assert '\x00' not in r0.desc
        # 行尾无 Suggestion 列值 → 空串
        assert r0.suggestion == ''
        r1 = records[1]
        assert r1.severity == 'Info'
        assert r1.sensor_name == 'Health'
        assert r1.desc == 'HDM reset ok'
        assert r1.suggestion == ''  # " "（空格）视为空
    finally:
        shutil.rmtree(tmp_dir, ignore_errors=True)


def test_event_csv_missing_suggestion():
    """Suggestion 列为空 + 缺文件/空文件/仅表头 → 空串与空列表，绝不抛异常。"""
    tmp_dir = tempfile.mkdtemp()
    try:
        path = os.path.join(tmp_dir, 'test.csv')
        with open(path, 'w', encoding='utf-8') as f:
            f.write(
                'Record Time Stamp,Severity Level,Severity Level ID,SensorTypeStr,'
                'SensorName,Event Dir,Event Occurred Time,DescInfo,Explanation,Suggestion\n'
                '2026-11-13 09:00:00,Info,0x0,NA,NA,NA,,No suggestion here,,\n'
            )
        records = parse_event_csv(path)
        assert len(records) == 1
        r = records[0]
        assert r.suggestion == ''
        assert r.desc == 'No suggestion here'
        assert r.source == 'csv'
        # 缺文件 / 空文件 / 仅表头 / 不存在路径 → 空列表
        assert parse_event_csv(None) == []
        empty = os.path.join(tmp_dir, 'empty.csv')
        with open(empty, 'w', encoding='utf-8') as f:
            f.write('')
        assert parse_event_csv(empty) == []
        header_only = os.path.join(tmp_dir, 'header.csv')
        with open(header_only, 'w', encoding='utf-8') as f:
            f.write(
                'Record Time Stamp,Severity Level,Severity Level ID,SensorTypeStr,'
                'SensorName,Event Dir,Event Occurred Time,DescInfo,Explanation,Suggestion\n'
            )
        assert parse_event_csv(header_only) == []
        assert parse_event_csv(os.path.join(tmp_dir, 'missing.csv')) == []
    finally:
        shutil.rmtree(tmp_dir, ignore_errors=True)


def test_sbe_fallback():
    """假 .sbe：0x3F 分段、\x00 分隔的可读串提取传感器名+描述；timestamp 标未知。"""
    tmp_dir = tempfile.mkdtemp()
    try:
        path = os.path.join(tmp_dir, 'event.sbe')
        payload = (
            b's\x00e\x00f\x00'                       # 全为 <3 字符碎片：应被跳过
            + b'\x3f' + b'Disk_F23_Status\x00Drive Fault'
            + b'\x3f' + b'Restore Factory Defaults'
        )
        with open(path, 'wb') as f:
            f.write(payload)
        records = parse_sbe(path)
        assert len(records) == 2
        r0 = records[0]
        assert r0.source == 'sbe'
        assert r0.timestamp == '未知'
        assert r0.sensor_name == 'Disk_F23_Status'
        assert 'Drive Fault' in r0.desc
        # 单段单串：desc 兜底取自身
        r1 = records[1]
        assert r1.sensor_name == 'Restore Factory Defaults'
        assert r1.desc == 'Restore Factory Defaults'
        # 缺文件 / 空文件 → 空列表
        assert parse_sbe(None) == []
        empty = os.path.join(tmp_dir, 'empty.sbe')
        with open(empty, 'wb') as f:
            f.write(b'')
        assert parse_sbe(empty) == []
    finally:
        shutil.rmtree(tmp_dir, ignore_errors=True)


def test_visible_log():
    """visible.log：UTF-8 主路径读取，返回非空原始行；缺文件 → []。"""
    tmp_dir = tempfile.mkdtemp()
    try:
        path = os.path.join(tmp_dir, 'visible.log')
        lines = [
            '%# 2026-11-13 14:37:36.621 HOST [hdm] 123 [INFO]: [sys] HDM service started',
            '%# 2026-11-13 14:38:02.100 HOST [sensor] 456 [INFO]: [sensor] Inlet_Temp read ok 中文描述',
            '',
        ]
        with open(path, 'w', encoding='utf-8') as f:
            f.write('\n'.join(lines))
        parsed = parse_visible_log(path)
        assert len(parsed) == 2
        assert parsed[0].startswith('%# 2026-11-13 14:37:36.621')
        # UTF-8 主路径解码（走 read_text_file，顺带覆盖其 UTF-8 用例）
        assert '中文描述' in parsed[1]
        # 缺文件 / 空文件 / 全空行 → 空列表
        assert parse_visible_log(None) == []
        empty = os.path.join(tmp_dir, 'empty.log')
        with open(empty, 'w', encoding='utf-8') as f:
            f.write('')
        assert parse_visible_log(empty) == []
        blank = os.path.join(tmp_dir, 'blank.log')
        with open(blank, 'w', encoding='utf-8') as f:
            f.write('   \n\n\t\n')
        assert parse_visible_log(blank) == []
    finally:
        shutil.rmtree(tmp_dir, ignore_errors=True)


def test_health_disk_hba():
    """事件含 PCIe_Card3_HBA 与 Disk_F23_Status → PCIe(HBA)/盘 F23 组件判异常，evidence 含关键词。"""
    events = [
        EventRecord('2026-11-13 08:00:01', 'Major', 'PCIe_Card3_HBA',
                    'Device Disabled: PCIe module information not obtained---Slot: 3', '', 'csv'),
        EventRecord('2026-11-13 08:01:00', 'Major', 'Disk_F23_Status', 'The disk is missing', '', 'csv'),
        EventRecord('2026-11-13 08:02:00', 'Major', 'Disk_F23_Status', 'Drive Fault on slot F23', '', 'csv'),
    ]
    health = assess_health(InventoryData(), [], events)
    pcie = [c for c in health if c.category == 'PCIe']
    assert any(c.status == '异常' for c in pcie), 'PCIe(HBA) 组件应判异常'
    assert any('module information not obtained' in e for c in pcie for e in c.evidence), \
        'HBA evidence 应含 "module information not obtained"'
    disks = [c for c in health if c.category == '硬盘']
    assert any('F23' in c.name and c.status == '异常' for c in disks), '盘 F23 组件应判异常'


def test_health_psu():
    """PSU input lost 事件 → 电源组件判异常，修复建议含 AC 相关词。"""
    events = [
        EventRecord('2026-11-13 08:03:00', 'Critical', 'PSU1_Status',
                    'Power Supply input lost (AC/DC)', '', 'csv'),
    ]
    health = assess_health(InventoryData(), [], events)
    psus = [c for c in health if c.category == '电源']
    assert any(c.status == '异常' for c in psus), '电源组件应判异常'
    assert any('AC' in s for c in psus for s in c.suggestions), '电源修复建议应含 AC 相关词'


def test_health_standby_no_false_positive():
    """待机态（Total_Power=20W）+ 风扇 0 RPM → 风扇判正常；非待机 0 RPM → 判异常。"""
    sensors = [
        SensorReading('FAN1_Speed', '0', 'RPM', 'ok'),
        SensorReading('Total_Power', '20.0', 'Watts', 'ok'),
    ]
    health = assess_health(InventoryData(), sensors, [])
    fans = [c for c in health if c.category == '风扇']
    assert fans, '待机态下仍应输出风扇组件'
    assert all(c.status == '正常' for c in fans), '待机态风扇 0 RPM 不应误报异常'
    # 非待机态（Total_Power=320W）0 RPM → 转速异常
    sensors2 = [
        SensorReading('FAN1_Speed', '0', 'RPM', 'ok'),
        SensorReading('Total_Power', '320.0', 'Watts', 'ok'),
    ]
    health2 = assess_health(InventoryData(), sensors2, [])
    fans2 = [c for c in health2 if c.category == '风扇']
    assert any(c.status == '异常' for c in fans2), '非待机态风扇 0 RPM 应判异常'


def test_suggestions():
    """build_suggestions：关键词映射（重新安装/更换）与官方 Suggestion 优先、兜底文案。"""
    ev_disk = EventRecord('t1', 'Major', 'Disk_F23_Status', 'The disk is missing', '', 'csv')
    ev_psu = EventRecord('t2', 'Critical', 'PSU1_Status', 'Power Supply input lost (AC/DC)',
                         '官方建议：请检查 AC 电源输入并联系厂商处理', 'csv')
    suggs = build_suggestions([ev_disk, ev_psu])
    assert any('重新安装' in s for s in suggs), '盘缺失建议应含 重新安装'
    assert any('更换' in s for s in suggs), '盘缺失建议应含 更换'
    assert any('官方建议' in s for s in suggs), '带官方 Suggestion 的事件应优先返回官方文本'
    # 无匹配关键词 → 兜底文案
    ev_other = EventRecord('t3', 'Info', 'Health', 'HDM reset ok', '', 'csv')
    suggs2 = build_suggestions([ev_other])
    assert suggs2 and '联系技术支持' in suggs2[0], '无匹配事件应返回兜底建议'


def test_health_backplane_failed_match():
    """raid_bp_text 含 "Failed To Match" → 背板判提示；不传该参数行为不变。"""
    inv = InventoryData()
    inv.backplanes = [{'name': 'FrontBackPlane3', 'health_status': 'Normal'}]
    health = assess_health(inv, [], [], raid_bp_text='[NOTE: Failed To Match The Configuration...]')
    bps = [c for c in health if c.category == '背板']
    assert bps, '应存在背板组件'
    assert bps[0].status == '提示', '背板应判提示'
    assert any('failed to match' in e.lower() for e in bps[0].evidence), \
        '背板 evidence 应含 "failed to match"（大小写不敏感）'
    # 不传 raid_bp_text → 背板保持正常（不因该参数变异常）
    health2 = assess_health(inv, [], [])
    bps2 = [c for c in health2 if c.category == '背板']
    assert bps2 and bps2[0].status == '正常', '不传 raid_bp_text 时背板应保持正常'


def test_field_status_values():
    """_field_status：黑名单优先（Abnormal→异常），精确白名单（Healthy→正常），
    未知词（Not Present/N/A/Unknown）→ 未知，不再把非故障词误判为异常。"""
    # 黑名单优先：'abnormal' 含于 'Abnormal'，必须判异常（不能因'normal'子串漏报）
    assert _field_status('Abnormal') == '异常'
    # 未知词 → 未知（修复前被误判为异常）
    assert _field_status('Not Present') == '未知'
    assert _field_status('N/A') == '未知'
    assert _field_status('Unknown') == '未知'
    assert _field_status('none') == '未知'
    # 精确白名单（修复前 Healthy/Enabled 被误判为异常）
    assert _field_status('Healthy') == '正常'
    assert _field_status('Normal') == '正常'
    assert _field_status('ok') == '正常'
    assert _field_status('present') == '正常'
    # 缺失 → 未知
    assert _field_status(None) == '未知'
    assert _field_status('') == '未知'


def test_ai_prompt_contains_facts():
    """build_ai_payload 输出含 机器型号、固件版本、组件名、事件原文 关键事实；sbe 来源标注尽力而为。"""
    inv = InventoryData()
    inv.machine = {
        'product_name': 'H3C UniServer R4930 G5 H3',
        'serial_number': '210235A566526AN0000P',
        'product_part_number': '0235A566',
        'baseboard': {},
    }
    inv.firmware = {'BIOS': '5.97 V500R001B01D097', 'HDM': '3.66 HDM V100R001B05D110', 'CPLD': 'V00D'}
    health = [
        ComponentHealth(
            name='Disk_F23_Status', category='硬盘', status='异常',
            evidence=['[2026-11-13 08:00:01] Major The disk is missing'],
            suggestions=['重新安装该硬盘；若反复出现故障请更换硬盘。'],
        ),
        ComponentHealth(
            name='PCIe_Card3_HBA', category='PCIe', status='异常',
            evidence=['[2026-11-13 08:00:02] Critical Device Disabled: PCIe module information not obtained---Slot: 3'],
            suggestions=['重新插拔 PCIe 卡并更换槽位验证，必要时更换该 PCIe 模块。'],
        ),
    ]
    events = [
        EventRecord('2026-11-13 08:00:01', 'Major', 'Disk_F23_Status', 'The disk is missing', '', 'csv'),
        EventRecord('未知', '未知', 'PCIe_Card3_HBA', 'Device Disabled', '', 'sbe'),
    ]
    payload = build_ai_payload(inv, health, events)
    assert 'H3C UniServer R4930 G5 H3' in payload, '应含机器型号'
    assert '5.97 V500R001B01D097' in payload, '应含固件版本'
    assert 'Disk_F23_Status' in payload, '应含组件名'
    assert 'PCIe_Card3_HBA' in payload, '应含组件名'
    assert 'The disk is missing' in payload, '应含事件原文'
    assert 'Device Disabled: PCIe module information not obtained' in payload, '应含事件原文'
    assert '来自尽力而为的 .sbe 解析' in payload, 'sbe 来源事件应标注尽力而为'


def test_ai_prompt_has_task():
    """build_ai_payload 输出含三段分析任务指令锚点词（异常链路推断/根因候选排序/排查步骤）。"""
    payload = build_ai_payload(InventoryData(), [], [])
    for token in ('异常链路推断', '根因候选排序', '排查步骤'):
        assert token in payload, f'任务指令应含 {token}'
    assert '①' in payload and '②' in payload and '③' in payload, '任务指令应为三点编号'


def test_ai_downgrade_no_env():
    """缺 SDS_AI_BASE_URL 环境变量 → call_ai 返回 None 且不发起 HTTP 请求。"""
    with mock.patch.dict(os.environ, {}, clear=True):
        with mock.patch('urllib.request.urlopen') as urlopen:
            assert call_ai('任意 payload') is None
            urlopen.assert_not_called()


def test_ai_http_failure():
    """urlopen 异常 / HTTP 非 200 / 无 content → None；200 且有 content → 返回该文本。"""
    payload = '测试 payload'
    # 1) 网络异常（URLError）→ None
    with mock.patch('urllib.request.urlopen', side_effect=urllib.error.URLError('network down')):
        assert call_ai(payload, 'http://localhost:11434/v1', 'fake-key', 'm') is None
    # 2) HTTP 非 200 → None
    resp500 = mock.Mock()
    resp500.status = 500
    resp500.read.return_value = b'{"error": "boom"}'
    with mock.patch('urllib.request.urlopen', return_value=resp500):
        assert call_ai(payload, 'http://localhost:11434/v1', 'fake-key', 'm') is None
    # 3) 200 且有 content → 返回 content（reasoning_content 忽略）
    resp_ok = mock.Mock()
    resp_ok.status = 200
    resp_ok.read.return_value = json.dumps({
        'choices': [{'message': {
            'content': '这是 AI 综合结论',
            'reasoning_content': '内部推理不应出现在返回中',
        }}],
    }).encode('utf-8')
    with mock.patch('urllib.request.urlopen', return_value=resp_ok):
        assert call_ai(payload, 'http://localhost:11434/v1', 'fake-key', 'm') == '这是 AI 综合结论'
    # 4) 200 但无 content → None
    resp_empty = mock.Mock()
    resp_empty.status = 200
    resp_empty.read.return_value = json.dumps({'choices': [{'message': {}}]}).encode('utf-8')
    with mock.patch('urllib.request.urlopen', return_value=resp_empty):
        assert call_ai(payload, 'http://localhost:11434/v1', 'fake-key', 'm') is None


def test_call_ai_timeout_config():
    """SDS_AI_TIMEOUT 环境变量生效：call_ai 传给 urlopen 的 timeout 缺省 300，
    设 env 后取其值（推理模型大 payload 可能超过旧的 60s 上限）。"""
    payload = 'x'
    resp_ok = mock.Mock()
    resp_ok.status = 200
    resp_ok.read.return_value = json.dumps(
        {'choices': [{'message': {'content': 'ok'}}]}).encode('utf-8')
    with mock.patch.dict(os.environ, {'SDS_AI_BASE_URL': 'http://x/v1'}), \
            mock.patch('urllib.request.urlopen', return_value=resp_ok) as uo:
        call_ai(payload, api_key='k', model='m')
        assert uo.call_args.kwargs.get('timeout') == 600, \
            f'缺省超时应为 600s，实际 {uo.call_args.kwargs.get("timeout")}'
    with mock.patch.dict(os.environ, {
            'SDS_AI_BASE_URL': 'http://x/v1', 'SDS_AI_TIMEOUT': '150'}), \
            mock.patch('urllib.request.urlopen', return_value=resp_ok) as uo:
        call_ai(payload, api_key='k', model='m')
        assert uo.call_args.kwargs.get('timeout') == 150, \
            f'SDS_AI_TIMEOUT 应覆盖超时，实际 {uo.call_args.kwargs.get("timeout")}'


def test_report_sections():
    """构造最小数据 → render_report 输出含 5 个必选章节标题（0-4）与附录，
    `## 0. 分析汇总` 位于 `## 1. 整机信息` 之前；
    ai_markdown=None 时无 ## 5 章节，非 None 时含。"""
    from sds_report import render_report
    inv = InventoryData()
    inv.machine = {
        'product_name': 'H3C UniServer R4930 G5 H3',
        'serial_number': '210235A566526AN0000P',
        'product_part_number': '0235A566',
        'baseboard': {},
    }
    inv.firmware = {'BIOS': '5.97 V500R001B01D097', 'HDM': '3.66', 'CPLD': 'V00D'}
    health = [
        ComponentHealth(
            name='Disk_F23_Status', category='硬盘', status='异常',
            evidence=['[2026-11-13 08:00:01] Major The disk is missing'],
            suggestions=['重新安装该硬盘；若反复出现故障请更换硬盘。'],
        ),
    ]
    events = [
        EventRecord('2026-11-13 08:00:01', 'Major', 'Disk_F23_Status',
                    'The disk is missing', '', 'csv'),
    ]
    sensors = [SensorReading('Total_Power', '320.0', 'Watts', 'ok')]
    visible = ['%# 2026-11-13 14:37:36.621 HOST [hdm] 1 [INFO]: HDM service started']
    base = render_report(inv, sensors, health, events, visible, None, '2026-11-18 12:00:00')
    for title in ('# 服务器体检报告', '## 0. 分析汇总', '## 1. 整机信息',
                  '## 2. 硬件健康状态', '## 3. 异常详情', '## 4. 修复建议', '## 附录'):
        assert title in base, f'报告应含章节 {title}'
    assert base.index('## 0. 分析汇总') < base.index('## 1. 整机信息'), \
        '分析汇总章节应位于整机信息章节之前'
    assert '## 5. AI 综合分析' not in base, 'ai_markdown=None 时不应含 AI 章节'
    assert 'H3C UniServer R4930 G5 H3' in base, '整机信息应含机器型号'
    with_ai = render_report(inv, sensors, health, events, visible, '这是 AI 综合结论', '2026-11-18 12:00:00')
    assert '## 5. AI 综合分析' in with_ai, 'ai_markdown 非 None 时应含 AI 章节'
    assert '这是 AI 综合结论' in with_ai, 'AI 章节应含 AI 结论原文'


def test_summary_sections():
    """render_summary 输出 `## 0. 分析汇总` 与三要点；整机概览含机型/序列号/固件版本；
    健康总览计数 正常 1 · 异常 1 · 提示 1；核心结论为规则结论（含 Disk_F23_Status）。"""
    from sds_report import render_summary
    inv = InventoryData()
    inv.machine = {
        'product_name': 'H3C UniServer R4930 G5 H3',
        'serial_number': '210235A566526AN0000P',
        'product_part_number': '0235A566',
        'baseboard': {},
    }
    inv.firmware = {'BIOS': '5.97 V500R001B01D097', 'HDM': '3.66 HDM V100R001B05D110', 'CPLD': 'V00D'}
    health = [
        ComponentHealth(
            name='Disk_F23_Status', category='硬盘', status='异常',
            evidence=['[2026-11-15 06:24:39] Major The disk is missing'],
            suggestions=['重新安装该硬盘；若反复出现故障请更换硬盘。'],
        ),
        ComponentHealth(
            name='FrontBackPlane3', category='背板', status='提示',
            evidence=['[未知] Info Raid_BP_Conf_Info: Failed To Match The Configuration'],
            suggestions=['核对背板配置与硬盘槽位映射。'],
        ),
        ComponentHealth(name='A0', category='内存', status='正常', evidence=[], suggestions=[]),
    ]
    out = render_summary(inv, health)
    assert '## 0. 分析汇总' in out, '应含章节标题'
    for key in ('### 整机概览', '### 健康总览', '### 核心结论'):
        assert key in out, f'应含要点 {key}'
    # 整机概览：机型 / 序列号 / 固件
    assert 'H3C UniServer R4930 G5 H3' in out, '整机概览应含机型'
    assert '210235A566526AN0000P' in out, '整机概览应含序列号'
    assert '5.97 V500R001B01D097' in out, '整机概览应含 BIOS 版本'
    assert '3.66 HDM V100R001B05D110' in out, '整机概览应含 HDM 版本'
    assert 'V00D' in out, '整机概览应含 CPLD 版本'
    # 健康总览
    assert '正常 1 · 异常 1 · 提示 1' in out, '健康总览计数应为 正常 1 · 异常 1 · 提示 1'
    # 核心结论：规则兜底（硬盘优先级高于背板）
    assert 'Disk_F23_Status' in out, '核心结论应含 Disk_F23_Status'


def test_summary_rule_conclusion():
    """_rule_conclusion：无异常/提示 → '未发现异常组件。'；
    硬盘 + PCIe 两异常 → 硬盘优先级更高（取硬盘）。"""
    from sds_report import _rule_conclusion
    # 仅正常组件 → 未发现异常组件
    ok_health = [ComponentHealth(name='A0', category='内存', status='正常', evidence=[], suggestions=[])]
    assert _rule_conclusion(ok_health) == '未发现异常组件。'
    # 硬盘 + PCIe 两异常 → 硬盘优先
    both = [
        ComponentHealth(
            name='Disk_F23_Status', category='硬盘', status='异常',
            evidence=['[2026-11-15 06:24:39] Major The disk is missing'], suggestions=[],
        ),
        ComponentHealth(
            name='PCIe_Card3_HBA', category='PCIe', status='异常',
            evidence=['[2026-11-15 06:16:53] Minor Device Disabled: PCIe module information not obtained---Slot: 3'],
            suggestions=[],
        ),
    ]
    concl = _rule_conclusion(both)
    assert '硬盘' in concl and 'Disk_F23_Status' in concl, '硬盘优先级应高于 PCIe'
    assert 'The disk is missing' in concl, '关键词应取最高严重度（Major）证据描述'


def test_summary_ai_conclusion():
    """核心结论 AI 优先：跳过标题行、取首个列表要点句、去 Markdown 标记；
    空/纯空白回退规则结论；纯加粗文本去标记后作为结论；超长首句截断 ≤120 字。"""
    from sds_report import render_summary
    inv = InventoryData()
    inv.machine = {
        'product_name': 'H3C UniServer R4930 G5 H3',
        'serial_number': '210235A566526AN0000P',
        'product_part_number': '0235A566',
        'baseboard': {},
    }
    inv.firmware = {'BIOS': '5.97 V500R001B01D097', 'HDM': '3.66', 'CPLD': 'V00D'}
    health = [
        ComponentHealth(
            name='Disk_F23_Status', category='硬盘', status='异常',
            evidence=['[2026-11-15 06:24:39] Major The disk is missing'], suggestions=[],
        ),
    ]
    # AI 优先：跳过 '### 异常链路推断' 标题行，取首个 '- ' 列表要点句
    ai = '### 异常链路推断\n- 最可能问题集中在 HBA（PCIe slot 3）链路。\n- 次要点：请更换硬盘。'
    out = render_summary(inv, health, ai_markdown=ai)
    assert '最可能问题集中在 HBA（PCIe slot 3）链路' in out, '核心结论应为 AI 首要点句'
    # 空 / 纯空白 → 回退规则结论，不抛异常
    for empty in ('', '   '):
        out2 = render_summary(inv, health, ai_markdown=empty)
        assert 'Disk_F23_Status' in out2, f'ai_markdown={empty!r} 应回退规则结论'
    # 纯加粗文本 → 去 ** 标记后作为核心结论，不抛异常
    out3 = render_summary(inv, health, ai_markdown='**bold only**')
    assert 'bold only' in out3, '纯加粗文本应去 ** 标记后作为核心结论'
    # 超长首句 → 截断 ≤120 字
    long_ai = '这是非常长的 AI 第一要点句内容。' * 12
    out4 = render_summary(inv, health, ai_markdown=long_ai)
    conclusion_line = [l for l in out4.split('### 核心结论')[1].splitlines() if l.startswith('- ')][0]
    assert len(conclusion_line) - 2 <= 120, f'AI 结论应截断 ≤120 字，实际 {len(conclusion_line) - 2}'
    # 元数据行（对象/SN）不应被当作核心结论；应取含 "核心异常" 的结论行
    ai2 = ('## 体检 AI 分析结论\n\n'
           '**对象**：H3C UniServer R4930 G5 H3 / SN 210235A566526AN0000P\n'
           '**核心异常**：PSU1/PSU2 电源输入异常、PCIe_Card3_HBA 未被识别、Disk_F23 掉盘/故障。\n'
           'CPU、内存、风扇、背板均正常。')
    out5 = render_summary(inv, health, ai_markdown=ai2)
    assert 'PSU1/PSU2 电源输入异常' in out5, '核心结论应取"核心异常"行而非"对象"元数据行'
    assert '对象：' not in out5.split('### 核心结论')[1].splitlines()[1], '元数据行不应作为核心结论'


def test_summary_unknown_count():
    """健康总览：未知组件 >0 时追加 '· 未知 W'；无未知组件时不出现 '未知'。"""
    from sds_report import render_summary
    inv = InventoryData()
    inv.machine = {
        'product_name': 'H3C UniServer R4930 G5 H3',
        'serial_number': '210235A566526AN0000P',
        'product_part_number': '0235A566',
        'baseboard': {},
    }
    inv.firmware = {'BIOS': '5.97 V500R001B01D097', 'HDM': '3.66', 'CPLD': 'V00D'}
    # 含 1 个未知组件 → 追加 '· 未知 1'
    health = [
        ComponentHealth(name='CPU1_A0', category='内存', status='未知', evidence=[], suggestions=[]),
        ComponentHealth(name='A0', category='内存', status='正常', evidence=[], suggestions=[]),
    ]
    out = render_summary(inv, health)
    overview = [l for l in out.splitlines() if l.startswith('- 正常')][0]
    assert '· 未知 1' in overview, '未知 >0 应追加 · 未知 1'
    # 无未知组件 → 不出现 '未知'
    health2 = [ComponentHealth(name='A0', category='内存', status='正常', evidence=[], suggestions=[])]
    out2 = render_summary(inv, health2)
    assert '未知' not in out2, '无未知组件时不应出现 未知'


def test_facts_pack_always_written():
    """对真实样例运行 sds_parser.py（不加 --ai）→ 输入同目录生成 <basename>-ai-facts.md，
    内容含 机器信息、异常组件（F23/HBA）、事件原文、任务指令锚点。"""
    real = _real_sds_path()
    assert os.path.isfile(real), f'真实样例缺失：{real}'
    tmp_dir = tempfile.mkdtemp()
    try:
        copy = os.path.join(tmp_dir, os.path.basename(real))
        shutil.copyfile(real, copy)
        proc = _run_cli([copy])
        assert proc.returncode == 0, f'CLI 失败：{proc.stdout}\n{proc.stderr}'
        facts = os.path.join(tmp_dir, os.path.splitext(os.path.basename(copy))[0] + '-ai-facts.md')
        assert os.path.isfile(facts), f'材料包未生成：{facts}'
        with open(facts, encoding='utf-8') as f:
            text = f.read()
        # 机器信息
        assert '机器信息' in text and '产品型号' in text, '材料包应含机器信息'
        # 异常组件（F23 / HBA）
        assert 'F23' in text, '材料包应含 F23 组件'
        assert 'HBA' in text, '材料包应含 HBA 组件'
        # 事件原文
        assert 'module information not obtained' in text, '材料包应含事件原文'
        # 任务指令锚点
        for token in ('异常链路推断', '根因候选排序', '排查步骤'):
            assert token in text, f'任务指令应含 {token}'
    finally:
        shutil.rmtree(tmp_dir, ignore_errors=True)


def test_cli_non_tar_friendly():
    """普通文本文件传给 sds_parser.py → 退出码非 0、含"不是有效的"中文提示、无 Python 堆栈。"""
    tmp_dir = tempfile.mkdtemp()
    try:
        txt = os.path.join(tmp_dir, 'not_a_sds.sds')
        with open(txt, 'w', encoding='utf-8') as f:
            f.write('this is definitely not a tar archive at all 12345')
        proc = _run_cli([txt])
        out = (proc.stdout or '') + (proc.stderr or '')
        assert proc.returncode != 0, f'非 tar 输入应非零退出：{out}'
        assert '不是有效的' in out, f'应打印"不是有效的"中文提示：{out}'
        assert 'Traceback' not in out, f'不应出现 Python 堆栈：{out}'
        assert 'File "' not in out, f'不应出现 Python 堆栈（File 行）：{out}'
    finally:
        shutil.rmtree(tmp_dir, ignore_errors=True)


def test_integration_real_sds():
    """真实样例全链路：报告生成成功、含机器型号/F23/HBA 依据/电源异常条目、
    修复建议含"更换"/"换槽"关键词，且同目录生成材料包。"""
    real = _real_sds_path()
    assert os.path.isfile(real), f'真实样例缺失：{real}'
    tmp_dir = tempfile.mkdtemp()
    try:
        copy = os.path.join(tmp_dir, os.path.basename(real))
        shutil.copyfile(real, copy)
        out = os.path.join(tmp_dir, 'report.md')
        proc = _run_cli([copy, '-o', out])
        assert proc.returncode == 0, f'CLI 失败：{proc.stdout}\n{proc.stderr}'
        assert os.path.isfile(out), f'报告未生成：{out}'
        with open(out, encoding='utf-8') as f:
            text = f.read()
        # 四章节 + 附录
        for title in ('# 服务器体检报告', '## 1. 整机信息', '## 2. 硬件健康状态',
                      '## 3. 异常详情', '## 4. 修复建议', '## 附录'):
            assert title in text, f'报告应含章节 {title}'
        # 验收锚点
        assert 'H3C UniServer' in text, '整机信息应含 H3C UniServer'
        assert 'F23' in text, '应含 F23 盘槽异常条目'
        assert 'module information not obtained' in text, '应含 HBA 依据原文'
        assert 'PSU1（电源）' in text, '应含电源组件条目'
        assert '状态：异常' in text, '应含异常状态条目'
        # 修复建议关键词
        assert '更换' in text, '修复建议应含 更换'
        assert '换槽' in text, '修复建议应含 换槽'
        # 材料包同目录生成
        facts = os.path.join(tmp_dir, os.path.splitext(os.path.basename(copy))[0] + '-ai-facts.md')
        assert os.path.isfile(facts), f'材料包未生成：{facts}'
    finally:
        shutil.rmtree(tmp_dir, ignore_errors=True)


def test_event_csv_suggestion_junk_cleaned():
    """HDM 导出 CSV 的 Suggestion 列会在官方文本后拼接原始 CSV 行残渣
    （形如 '2026-11-15 06:29:07,Info,0x0,Button / Switch,Button,...'）。
    parse_event_csv 应截断该残渣，仅保留官方建议文本。"""
    tmp_dir = tempfile.mkdtemp()
    try:
        csv_path = os.path.join(tmp_dir, 'junk.csv')
        # 含 \x00 空字节（模拟 HDM 导出），Suggestion 内嵌一条完整 CSV 行残渣
        header = ('Record Time Stamp,Severity Level,Severity Level ID,SensorTypeStr,SensorName,'
                  'Event Dir,Event Occurred Time,DescInfo,Explanation,Suggestion\n')
        row = ('2026-11-15 06:24:40,Major,0x2,Drive Slot (Bay),Disk_F23_Status,Assertion event,'
               '2026-11-15 06:24:39,"Drive Fault"," ",'
               '"1. Log in to HDM and verify all drives are identified. If the drive cannot be '
               'identified, re-install the drive. 2026-11-15 06:29:07,Info,0x0,Button / Switch,'
               'Button,Assertion event,2026-11-15 06:29:07,Power Button pressed"\n')
        with open(csv_path, 'wb') as f:
            f.write(header.encode('utf-8').replace(b'\x00', b'') + row.encode('utf-8').replace(b'\x00', b''))
        evs = parse_event_csv(csv_path)
        assert len(evs) == 1
        sug = evs[0].suggestion
        assert 'Log in to HDM and verify all drives are identified' in sug, '应保留官方建议文本'
        assert '2026-11-15 06:29:07' not in sug, '应截断内嵌的 CSV 行残渣'
        assert ',Info,0x0,' not in sug, '应截断内嵌的 CSV 行残渣'
    finally:
        shutil.rmtree(tmp_dir, ignore_errors=True)


def test_event_csv_suggestion_dangling_trimmed():
    """Suggestion 若因源数据截断而以半截句子结尾（无句末标点）→
    回退到最后一个完整句子；正常结尾（有句末标点）保持不变。"""
    tmp_dir = tempfile.mkdtemp()
    try:
        csv_path = os.path.join(tmp_dir, 'dangling.csv')
        header = ('Record Time Stamp,Severity Level,Severity Level ID,SensorTypeStr,SensorName,'
                  'Event Dir,Event Occurred Time,DescInfo,Explanation,Suggestion\n')
        # 场景 1：结尾是半截句子 "...If the d"（源截断，无内嵌 CSV 残渣）
        row1 = ('2026-11-15 06:24:40,Major,0x2,Drive Slot (Bay),Disk_F23_Status,Assertion event,'
                '2026-11-15 06:24:39,"Drive Fault"," ",'
                '"1. Log in to HDM and verify all drives are identified. If a drive cannot be '
                'identified, re-install the drive. 2. View the drive status. If the d"\n')
        # 场景 2：正常以句号结尾 → 不变
        row2 = ('2026-11-15 06:24:40,Major,0x2,Drive Slot (Bay),Disk_F23_Status,Assertion event,'
                '2026-11-15 06:24:39,"Drive Fault"," ","1. Log in to HDM and verify. No action is required."\n')
        with open(csv_path, 'wb') as f:
            f.write(header.encode('utf-8') + row1.encode('utf-8') + row2.encode('utf-8'))
        evs = parse_event_csv(csv_path)
        assert len(evs) == 2
        expected = ('1. Log in to HDM and verify all drives are identified. '
                    'If a drive cannot be identified, re-install the drive. '
                    '2. View the drive status.')
        assert evs[0].suggestion == expected, \
            f'半截结尾应回退到完整句子，实际：{evs[0].suggestion!r}'
        assert 'If the d' not in evs[0].suggestion, '不应保留半截结尾'
        assert evs[1].suggestion == '1. Log in to HDM and verify. No action is required.', \
            '正常结尾应保持不变'
    finally:
        shutil.rmtree(tmp_dir, ignore_errors=True)


# ---------- 运行器 ----------

def main() -> int:
    # 支持 `--sds <真实样例路径>` 注入（供集成用例覆盖默认样例路径）
    argv = sys.argv[1:]
    global _REAL_SDS_PATH
    if '--sds' in argv:
        idx = argv.index('--sds')
        if idx + 1 < len(argv):
            _REAL_SDS_PATH = argv[idx + 1]
    test_funcs = sorted(
        (name, obj) for name, obj in globals().items()
        if name.startswith('test_') and callable(obj)
    )
    if not test_funcs:
        print('未发现任何 test_* 测试函数')
        return 1
    failed = []
    for name, fn in test_funcs:
        try:
            fn()
        except Exception as e:  # noqa: BLE001 —— 运行器需捕获一切异常
            failed.append((name, e))
            print(f'FAIL  {name}: {type(e).__name__}: {e}')
        else:
            print(f'PASS  {name}')
    print(f'\n{len(test_funcs) - len(failed)} passed, {len(failed)} failed, total {len(test_funcs)}')
    return 1 if failed else 0


if __name__ == '__main__':
    sys.exit(main())
