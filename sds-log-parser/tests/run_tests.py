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
