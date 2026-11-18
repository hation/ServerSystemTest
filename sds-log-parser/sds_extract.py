"""HDM SDS 日志包解包模块。

将 H3C/Huawei 服务器 HDM 导出的 .sds 日志包（本质是 tar 归档）安全解包到
临时目录，并按固定键集合定位关键文件；同时提供 UTF-8→GBK 双编码文本读取
与临时目录清理能力。运行时零第三方依赖，仅用 Python 标准库。
"""

import os
import posixpath
import shutil
import tarfile
import tempfile
from dataclasses import dataclass, field


class SDSNotTarError(Exception):
    """当 .sds 文件不是合法的 tar 归档时抛出。"""


@dataclass
class ExtractionResult:
    """解包结果。

    root_dir: 临时目录（keep=True 时保留，调用方按需 cleanup）。
    files:    固定键集合到文件绝对路径的映射，解不到的文件为 None。
    """

    root_dir: str
    files: dict = field(default_factory=dict)


# 固定键集合 → 相对路径后缀（小写）匹配规则。
# 用「相对路径后缀匹配」定位，兼容归档根目录带前缀、文件名大小写差异。
_FILE_SUFFIXES = {
    'event_csv': 'user/test.csv',
    'visible_log': 'sdmmc0p4/log/visible.log',
    'hardware_info_ini': 'static/hardware_info.ini',
    'hardware_info': 'static/hardware.info',
    'firmware_version_ini': 'static/firmware_version.ini',
    'fru_info_ini': 'static/fruinfo.ini',
    'sensor_info_ini': 'static/sensor_info.ini',
    'raid_bp_conf_ini': 'static/raid_bp_conf_info.ini',
    'nvme_info_ini': 'static/nvme_info.ini',
    'bios_json': 'static/bios.json',
    'hdm_json': 'static/hdm.json',
}


def _is_unsafe_member_name(name: str) -> bool:
    """判断 tar 成员名是否危险（路径穿越 / 绝对路径 / Windows 盘符）。"""
    if not name:
        return True
    # 统一用 posix 分隔符处理，防 Windows 反斜杠绕过
    norm = posixpath.normpath(name.replace('\\', '/'))
    if norm == '..' or norm.startswith('../') or norm.startswith('/'):
        return True
    # Windows 盘符前缀（如 C:/xxx），posixpath 无法识别
    if len(norm) >= 2 and norm[1] == ':' and norm[0].isalpha():
        return True
    return False


def _safe_extract(tar: tarfile.TarFile, dest: str) -> None:
    """逐个成员安全解包：跳过危险路径与链接类成员，绝不落盘到 dest 之外。"""
    for member in tar.getmembers():
        # 拒绝路径穿越 / 绝对路径 / 盘符 / 符号链接 / 硬链接
        if _is_unsafe_member_name(member.name):
            continue
        if member.issym() or member.islnk():
            continue
        target = os.path.join(dest, member.name.replace('\\', '/'))
        if member.isdir():
            os.makedirs(target, exist_ok=True)
            continue
        os.makedirs(os.path.dirname(target), exist_ok=True)
        src = tar.extractfile(member)
        if src is None:
            # 设备文件、fifo 等非常规成员无内容，跳过
            continue
        try:
            with open(target, 'wb') as f:
                shutil.copyfileobj(src, f)
        finally:
            src.close()


def _extract_nested_events(root: str) -> None:
    """把解出的 event/*.tar.gz 事件包再安全解一层到 root/event_extract/。"""
    ev_dir = os.path.join(root, 'event')
    if not os.path.isdir(ev_dir):
        return
    out_dir = os.path.join(root, 'event_extract')
    os.makedirs(out_dir, exist_ok=True)
    for name in sorted(os.listdir(ev_dir)):
        if not (name.endswith('.tar.gz') or name.endswith('.tgz')):
            continue
        path = os.path.join(ev_dir, name)
        try:
            with tarfile.open(path, 'r:*') as tgz:
                _safe_extract(tgz, out_dir)
        except (tarfile.TarError, EOFError, OSError):
            # 单个事件包损坏时跳过，不阻断整体解包
            continue


def _locate_files(root: str) -> dict:
    """按固定键集合定位关键文件，返回 {键: 绝对路径 | None}。"""
    # 收集 root 下所有文件的相对路径（posix 风格、小写）与绝对路径
    rel_files = []
    for dirpath, _dirnames, filenames in os.walk(root):
        for fn in filenames:
            full = os.path.join(dirpath, fn)
            rel = os.path.relpath(full, root).replace('\\', '/').lower()
            rel_files.append((rel, full))

    found = {key: None for key in _FILE_SUFFIXES}
    for key, suffix in _FILE_SUFFIXES.items():
        matches = [full for rel, full in rel_files if rel.endswith(suffix)]
        if matches:
            # 多个匹配时取路径最短者，避免误中深层同名文件
            matches.sort(key=lambda p: len(os.path.normpath(p)))
            found[key] = matches[0]

    # sbe：优先在 event_extract 内找，找不到再全局找
    sbe = None
    ev_ex = os.path.join(root, 'event_extract')
    if os.path.isdir(ev_ex):
        for dirpath, _dirnames, filenames in os.walk(ev_ex):
            for fn in filenames:
                if fn.lower().endswith('.sbe'):
                    sbe = os.path.join(dirpath, fn)
                    break
            if sbe:
                break
    if sbe is None:
        for rel, full in rel_files:
            if rel.endswith('.sbe'):
                sbe = full
                break
    found['sbe'] = sbe
    return found


def extract_sds(sds_path: str, keep: bool = False) -> ExtractionResult:
    """解包 .sds 日志包到临时目录并定位关键文件。

    keep=True 时保留临时目录；keep=False（默认）时调用方在
    使用完毕后负责调用 cleanup(result) 清理。
    """
    if not os.path.isfile(sds_path):
        raise SDSNotTarError(f'文件不存在：{sds_path}')
    root = tempfile.mkdtemp(prefix='sds_extract_')
    try:
        with tarfile.open(sds_path, 'r:*') as tar:
            _safe_extract(tar, root)
    except (tarfile.TarError, EOFError) as e:
        # 非 tar 归档：清理临时目录后抛出自定义异常
        shutil.rmtree(root, ignore_errors=True)
        raise SDSNotTarError(f'不是合法的 tar 归档：{sds_path}') from e
    _extract_nested_events(root)
    files = _locate_files(root)
    return ExtractionResult(root_dir=root, files=files)


def read_text_file(path: str) -> str:
    """读取文本文件：UTF-8 优先，解码失败回退 GBK。"""
    with open(path, 'rb') as f:
        data = f.read()
    for encoding in ('utf-8', 'gbk'):
        try:
            return data.decode(encoding)
        except UnicodeDecodeError:
            continue
    # 双编码均失败：以 replace 兜底，保证调用方拿到可处理文本
    return data.decode('utf-8', errors='replace')


def cleanup(extract_result) -> None:
    """删除解包产生的临时目录（keep=False 场景下调用）。"""
    if extract_result is None:
        return
    root = getattr(extract_result, 'root_dir', None)
    if root and os.path.isdir(root):
        shutil.rmtree(root, ignore_errors=True)
