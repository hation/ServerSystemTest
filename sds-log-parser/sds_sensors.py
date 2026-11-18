"""HDM SDS 日志包传感器解析模块。

解析解包后 static/sensor_info.ini 的传感器读数表。该文件是管道符（|）
分隔的文本表：首行为表头，其余行依次为 名称|读数|单位|状态|阈值…。
本模块只输出前 4 列（名称/读数/单位/状态），供后续健康判定（T5）使用，
重点关注 PSU1_VIN/PSU2_VIN/PSU1_Status/PSU2_Status/FANx_Status/
Total_Power/Inlet_Temp 等传感器。

空文件、缺失文件（None）或损坏文件一律返回空列表，绝不抛异常。
运行时零第三方依赖，仅用 Python 3.12 标准库。
"""

from dataclasses import dataclass

from sds_extract import read_text_file


@dataclass
class SensorReading:
    """单条传感器读数。

    name:   传感器名称（如 PSU1_VIN / FAN1_Status / Total_Power / Inlet_Temp）
    value:  读数原始字符串（可能是数值、0x 十六进制或 na）
    unit:   单位（如 Volts / Amps / Watts / degrees C / discrete）
    status: 状态（如 ok / na / 0x0180 等十六进制状态码）
    """

    name: str
    value: str
    unit: str
    status: str


def _is_comment_or_blank(line: str) -> bool:
    """判断是否为注释行（# / ; 开头）或空行。"""
    stripped = line.strip()
    if not stripped:
        return True
    return stripped.startswith(('#', ';'))


def parse_sensors(path: str | None) -> list[SensorReading]:
    """解析 sensor_info.ini 管道分隔表，返回 SensorReading 列表。

    逐行按 | 切分并 strip 各列，跳过表头行、空行、注释行与段头行
    （如 [Sensor]），前 4 列分别取 name/value/unit/status。缺文件（None）、
    空文件、文件不存在或损坏内容一律返回空列表，绝不抛异常。
    """
    if not path:
        return []
    try:
        text = read_text_file(path)
    except OSError:
        return []
    readings = []
    for raw in text.splitlines():
        line = raw.strip()
        if _is_comment_or_blank(line):
            continue
        parts = [p.strip() for p in line.split('|')]
        if len(parts) < 4:
            # 列数不足（缺列）的损坏行直接跳过
            continue
        name, value, unit, status = parts[0], parts[1], parts[2], parts[3]
        if not name:
            continue
        if name.startswith('['):
            # 段头行（如 [Sensor]）跳过
            continue
        if name.lower() == 'sensor name':
            # 表头行（Sensor Name | Reading | Unit | Status | …）跳过
            continue
        readings.append(SensorReading(name=name, value=value, unit=unit, status=status))
    return readings
