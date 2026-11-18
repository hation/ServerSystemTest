"""HDM SDS 日志包事件解析模块。

解析解包后的三类事件来源，供体检报告的事件章节（T6/T7）使用：

- user/test.csv：主事件来源，带表头的 10 列 CSV（Record Time Stamp, Severity
  Level, Severity Level ID, SensorTypeStr, SensorName, Event Dir, Event Occurred
  Time, DescInfo, Explanation, Suggestion）。文件含 \x00 空字节需去除；
  Explanation/Suggestion 列在引号内可含换行，由 csv 模块自动处理多行字段。
- event/*.sbe：私有二进制兜底来源，尽力而为（准确度不保证）。事件记录以
  `?`(0x3F) 字节分隔，段内以 \x00 等非可打印字节分隔可读字符串，提取
  「传感器名 + 事件描述」；时间戳不可靠统一标「未知」。
- sdmmc0p4/log/visible.log：原始日志行，行格式形如
  `%# 2026-11-13 14:37:36.621 HOST [模块] 行号 [INFO]: [...] 描述`。

空文件、缺失文件（None）或损坏文件一律返回空列表，绝不抛异常。
运行时零第三方依赖，仅用 Python 3.12 标准库。
"""

import csv
import io
import re
from dataclasses import dataclass

from sds_extract import read_text_file


@dataclass
class EventRecord:
    """单条事件记录。

    timestamp:   事件时间（csv 取 Record Time Stamp；sbe 尽力而为，标「未知」）
    severity:    严重级别（Info/Major/Minor/Critical 或 sbe 的「未知」）
    sensor_name: 传感器名（如 Disk_F23_Status / Health）
    desc:        事件描述（DescInfo 或 sbe 提取的描述文本）
    suggestion:  处理建议（Suggestion 列；sbe 无此信息为空串）
    source:      来源（'csv' | 'sbe' | 'visible'）
    """

    timestamp: str
    severity: str
    sensor_name: str
    desc: str
    suggestion: str
    source: str


# CSV 表头列名（去空格后小写）→ EventRecord 字段
_CSV_COLUMN_MAP = {
    'recordtimestamp': 'timestamp',
    'severitylevel': 'severity',
    'sensorname': 'sensor_name',
    'descinfo': 'desc',
    'suggestion': 'suggestion',
}

# 表头缺列时的默认列位置兜底（与真实样例 user/test.csv 的列顺序一致）
_CSV_DEFAULT_COLUMNS = {
    'timestamp': 0,
    'severity': 1,
    'sensor_name': 4,
    'desc': 7,
    'suggestion': 9,
}


def _decode_text(data: bytes) -> str:
    """二进制解码：UTF-8 优先，失败回退 GBK，再失败以 replace 兜底。"""
    for encoding in ('utf-8', 'gbk'):
        try:
            return data.decode(encoding)
        except UnicodeDecodeError:
            continue
    return data.decode('utf-8', errors='replace')


def _get_column(row: list[str], col: dict, field: str) -> str:
    """按列映射取字段，列缺失或越界时返回空串。"""
    idx = col.get(field)
    if idx is None or idx >= len(row):
        return ''
    value = row[idx]
    return value if isinstance(value, str) else ''


_CSV_ROW_LEAK = re.compile(r'\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2},(?:Info|Minor|Major|Critical),0x')


def _clean_suggestion(text: str) -> str:
    """截断 Suggestion 列中内嵌的原始 CSV 行残渣。

    HDM 导出的 Suggestion 列偶尔会在官方建议文本后拼接一条原始 CSV 行
    （形如 '2026-11-15 06:29:07,Info,0x0,Button / Switch,Button,...'）。
    该残渣始于时间戳+级别+0x 编号模式，从首个匹配处截断，保留官方文本。
    """
    m = _CSV_ROW_LEAK.search(text)
    if m:
        return text[: m.start()].strip()
    return text


def parse_event_csv(path: str | None) -> list[EventRecord]:
    """解析 user/test.csv 事件表，返回 EventRecord 列表（source='csv'）。

    二进制读入 → 去除 \x00 空字节 → csv.reader（表头为第 1 行，多行引号
    字段自动处理）。缺文件（None）、空文件、仅表头、损坏内容一律返回
    空列表，绝不抛异常。
    """
    if not path:
        return []
    try:
        with open(path, 'rb') as f:
            data = f.read()
    except OSError:
        return []
    if not data:
        return []
    # 去除 \x00 空字节（发生在解码前，引号内字段中的 \x00 一并去除）
    data = data.replace(b'\x00', b'')
    text = _decode_text(data)
    try:
        rows = list(csv.reader(io.StringIO(text)))
    except csv.Error:
        return []
    if not rows:
        return []
    header = rows[0]
    # 表头列名 → 列位置映射；匹配不到的字段用默认位置兜底
    col = dict(_CSV_DEFAULT_COLUMNS)
    for i, cell in enumerate(header):
        norm = ''.join(cell.split()).lower()
        field = _CSV_COLUMN_MAP.get(norm)
        if field:
            col[field] = i
    records = []
    for row in rows[1:]:
        # 跳过空行（csv.reader 对空行产出空列表）
        if not row or not any(str(cell).strip() for cell in row):
            continue
        records.append(
            EventRecord(
                timestamp=_get_column(row, col, 'timestamp').strip(),
                severity=_get_column(row, col, 'severity').strip(),
                sensor_name=_get_column(row, col, 'sensor_name').strip(),
                desc=_get_column(row, col, 'desc').strip(),
                suggestion=_clean_suggestion(_get_column(row, col, 'suggestion').strip()),
                source='csv',
            )
        )
    return records


def _ascii_runs(segment: bytes) -> list[str]:
    """提取段内的连续 ASCII 可打印子串（[0x20, 0x7E]），按非可打印字节切分。"""
    runs = []
    cur = bytearray()
    for b in segment:
        if 0x20 <= b <= 0x7E:
            cur.append(b)
        else:
            if cur:
                runs.append(bytes(cur).decode('ascii'))
                cur = bytearray()
    if cur:
        runs.append(bytes(cur).decode('ascii'))
    return runs


def parse_sbe(path: str | None) -> list[EventRecord]:
    """尽力而为解析 .sbe 私有二进制事件，返回 EventRecord 列表（source='sbe'）。

    以 `?`(0x3F) 字节切分段，段内提取长度 >= 3 的可读 ASCII 子串：
    首个子串当传感器名，其余用空格拼接为描述（仅一个子串时描述取自身）。
    时间戳与严重级别不可靠，统一标「未知」。缺文件（None）、空文件、
    损坏内容一律返回空列表，绝不抛异常。准确度不保证。
    """
    if not path:
        return []
    try:
        with open(path, 'rb') as f:
            data = f.read()
    except OSError:
        return []
    if not data:
        return []
    records = []
    for segment in data.split(b'\x3f'):
        runs = [r for r in _ascii_runs(segment) if len(r) >= 3]
        if not runs:
            continue
        sensor_name = runs[0]
        desc = ' '.join(runs[1:]) if len(runs) > 1 else runs[0]
        records.append(
            EventRecord(
                timestamp='未知',
                severity='未知',
                sensor_name=sensor_name,
                desc=desc,
                suggestion='',
                source='sbe',
            )
        )
    return records


def parse_visible_log(path: str | None) -> list[str]:
    """读取 visible.log 原始日志行，返回非空行列表（去掉纯空白行）。

    复用 read_text_file（UTF-8→GBK 双编码回退）。缺文件（None）、空文件、
    全空白行文件一律返回空列表，绝不抛异常。
    """
    if not path:
        return []
    try:
        text = read_text_file(path)
    except OSError:
        return []
    return [line for line in text.splitlines() if line.strip()]
