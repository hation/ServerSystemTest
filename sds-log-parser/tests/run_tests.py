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
