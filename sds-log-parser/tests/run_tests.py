"""HDM SDS 日志解析体检工具 —— 轻量测试运行器。

用法：python sds-log-parser/tests/run_tests.py

扫描本模块内所有 test_* 函数逐一执行，逐个打印 PASS/FAIL，
任一用例失败则进程退出码为非 0。后续任务可不断向本文件追加
test_* 函数，追加后仍可整体运行（不依赖 pytest 等第三方库）。
"""

import io
import os
import shutil
import sys
import tarfile
import tempfile

# 保证从任意工作目录运行时都能 import 到 sds-log-parser 下的模块
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from sds_extract import SDSNotTarError, cleanup, extract_sds, read_text_file
from sds_inventory import parse_inventory
from sds_sensors import parse_sensors
from sds_events import parse_event_csv, parse_sbe, parse_visible_log


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
    """含 ../ 与绝对路径成员的恶意 tar → 不落盘、不抛异常。"""
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
        result = extract_sds(sds_path)
        try:
            # '../evil' 不应落到临时目录或其父目录
            assert not os.path.exists(os.path.join(result.root_dir, 'evil'))
            parent = os.path.dirname(os.path.abspath(result.root_dir))
            assert not os.path.exists(os.path.join(parent, 'evil'))
            # 绝对路径成员不应落盘
            assert not os.path.exists(os.path.join(result.root_dir, 'tmp', 'abs_evil'))
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


# ---------- 运行器 ----------

def main() -> int:
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
