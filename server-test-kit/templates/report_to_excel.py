# -*- coding: utf-8 -*-
"""报告入汇总 Excel 骨架（通用版）：Markdown 报告三表 → 幂等写入 xlsx。

机制沿用 disk-tests 的 report_to_excel.py：解析报告的总览/明细/异常三表 →
归一化列 → 以报告文件相对路径为幂等键写入 xlsx。同一报告重跑只替换自身行，
多批次追加历史行。

配置驱动：从同目录 excel_config.json 读取（不存在则用内置默认值）——
章节关键词（overview/detail/issues，默认"总览/明细/异常"）、sheet 名
（默认 总览/逐盘明细/批次汇总/异常清单，占位）、判定等级列表（默认
🔴/🟡/🟢/⚠️）、幂等键列（默认报告相对路径，存于"报告文件"列）。
列名/唯一键列名为占位符，新项目按 08 号文档映射。

openpyxl 为唯一第三方依赖（函数内 try 导入；缺失时打印提示并退出码 3）。
dry-run 不依赖 openpyxl。

用法：
    python report_to_excel.py <报告.md> [--dry-run] [--config excel_config.json] [--out <xlsx>]

退出码：
    0 = 成功
    2 = 报告文件不存在 / 缺总览表 / 表头不含唯一键或判定列
    3 = 环境缺 openpyxl
"""
import argparse
import json
import os
import re
import sys

# 内置默认配置（同目录 excel_config.json 存在时按键覆盖；dict 键深合并）
DEFAULT_CONFIG = {
    "sections": {"overview": "总览", "detail": "明细", "issues": "异常"},   # 章节关键词（匹配报告 "## " 标题）
    "sheets": {"overview": "总览", "detail": "逐盘明细",                   # sheet 名占位，按 08 号文档定
               "batch": "批次汇总", "issues": "异常清单"},
    "levels": ["🔴", "🟡", "🟢", "⚠️"],                                    # 判定等级列表
    "idem_key_col": "报告文件",                                            # 幂等键列：报告相对路径
    "overview_required": ["唯一键", "判定"],                               # 总览表必需列（占位；新项目映射为 SN/资产号、结论等）
    "detail_required": ["唯一键"],                                          # 明细表识别列（占位）
    "detail_split_cols": ["读写"],                                          # 明细复合列：按 / 拆两列（示例 "2.66MB / 26.88MB"）
}

# 容量换算到 MB 的系数（parse_number 的默认单位映射；示例，按 08 号文档覆盖）
_UNIT_FACTORS = {"KB": 1 / 1024, "MB": 1, "GB": 1024, "TB": 1048576}


# ---------------------------------------------------------------- 通用解析纯函数

def clean_cell(s):
    """去掉 Markdown 加粗、行内反引号与首尾空白。"""
    return (s or "").replace("**", "").replace("`", "").strip()


def parse_number(s, unit_map=None):
    """从单元格解析数值（去 ** ` 与千分位逗号）；带单位时按 unit_map 换算。

    返回 float（换算后）或 None。边界：空串/非数字 → None。
    复合单元格（如 "2.66MB / 26.88MB"）请先用 split_pair 拆分再各自解析。
    """
    text = clean_cell(s).replace(",", "")
    if not text:
        return None
    m = re.match(r"([\d.]+)\s*([A-Za-z]+)?", text)
    if not m:
        return None
    value = float(m.group(1))
    unit = (m.group(2) or "").upper()
    if unit and (unit_map or _UNIT_FACTORS).get(unit) is not None:
        return round(value * (unit_map or _UNIT_FACTORS)[unit], 2)
    return value


def split_pair(s):
    """按 ``/`` 把单元格拆成两段（复合单元格拆两列）；非两段返回 None。"""
    parts = [p.strip() for p in re.split(r"\s*/\s*", clean_cell(s))]
    if len(parts) != 2:
        return None
    return parts[0], parts[1]


def normalize_verdict(s):
    """把判定拆成 (等级, 说明)；等级不在 levels 内时记作「—」。

    匹配前去掉变体选择符，裸 ``⚠`` 也识别为 ``⚠️``；返回等级统一带 ``⚠️``。
    """
    levels = DEFAULT_CONFIG["levels"]
    text = clean_cell(s).replace("\ufe0f", "")
    for level in levels:
        key = level.replace("\ufe0f", "")
        if text.startswith(key):
            return level, text[len(key):].strip()
    return "—", text


# ---------------------------------------------------------------- Markdown 报告解析

class ReportParseError(Exception):
    """报告结构不满足入表要求（如缺少总览表或必需列）。"""


_TABLE_ROW_RE = re.compile(r"^\s*\|")
_TABLE_SEP_RE = re.compile(r"^\s*\|[\s:|-]+\|\s*$")


def read_text(path):
    """读取 Markdown 报告（兼容 BOM）。"""
    with open(path, encoding="utf-8-sig") as f:
        return f.read()


def _norm_header(header):
    """表头规范化：小写并去掉空格、加粗标记与反引号。"""
    return (clean_cell(header).lower().replace(" ", "").replace("\u3000", ""))


def parse_md_table(lines, i):
    """解析从第 ``i`` 行（表头）开始的 Markdown 表。

    返回 (headers, rows, 下一行下标)；第二行不是分隔行则视为非表格。
    """
    headers = [clean_cell(c) for c in lines[i].strip().strip("|").split("|")]
    j = i + 1
    if j >= len(lines) or not _TABLE_SEP_RE.match(lines[j]):
        return headers, [], j
    j += 1
    rows = []
    while j < len(lines) and _TABLE_ROW_RE.match(lines[j]):
        cells = [clean_cell(c) for c in lines[j].strip().strip("|").split("|")]
        rows.append(cells)
        j += 1
    return headers, rows, j


def _iter_tables(lines):
    """逐个产出章节内的 Markdown 表。"""
    i = 0
    while i < len(lines):
        if _TABLE_ROW_RE.match(lines[i]) and i + 1 < len(lines) and _TABLE_SEP_RE.match(lines[i + 1]):
            headers, rows, nxt = parse_md_table(lines, i)
            yield headers, rows
            i = nxt
        else:
            i += 1


def _find_section(lines, keyword):
    """返回标题含 keyword 的 ``##`` 行到下一个 ``##`` 行之间的内容；无则 None。"""
    start = None
    for idx, line in enumerate(lines):
        if line.startswith("## ") and keyword in line:
            start = idx + 1
            break
    if start is None:
        return None
    end = len(lines)
    for idx in range(start, len(lines)):
        if lines[idx].startswith("## "):
            end = idx
            break
    return lines[start:end]


def _extract_batch(text, path):
    """批次号：优先报告内的 B<YYYYMMDD>_<HHMMSS>，退回文件名开头数字。"""
    m = re.search(r"B\d{8}_\d{6}", text) or re.search(r"B\d{8}", text)
    if m:
        return m.group(0)
    m = re.match(r"(\d+)", os.path.basename(path))
    return m.group(1) if m else ""


def _extract_date(text):
    """检测日期：``检测日期：YYYY-MM-DD`` → YYYY-MM-DD。"""
    m = re.search(r"检测日期[：:]\s*(\d{4}-\d{2}-\d{2})", text)
    return m.group(1) if m else ""


def parse_report(path, cfg=None):
    """解析一份报告，返回总览/明细/异常结构。

    总览表必须含 cfg.overview_required 的全部列（默认 唯一键/判定），否则抛
    ReportParseError（main 转退出码 2）。
    """
    cfg = cfg or DEFAULT_CONFIG
    abs_path = os.path.abspath(path)
    text = read_text(abs_path)
    lines = text.splitlines()
    warnings = []

    # 总览：优先「总览」章节，找不到退回全文
    overview_section = _find_section(lines, cfg["sections"]["overview"])
    overview = []
    required = {_norm_header(c) for c in cfg["overview_required"]}
    for headers, rows in _iter_tables(overview_section if overview_section is not None else lines):
        norm = {_norm_header(h) for h in headers}
        if required <= norm:
            idx = {_norm_header(h): i for i, h in enumerate(headers)}
            for cells in rows:
                overview.append({h: (cells[idx[_norm_header(h)]] if idx[_norm_header(h)] < len(cells) else "")
                                 for h in headers})
    if not overview:
        raise ReportParseError("未找到总览表（表头需含 %s）" % "/".join(cfg["overview_required"]))

    # 明细
    detail_section = _find_section(lines, cfg["sections"]["detail"])
    details = []
    detail_req = {_norm_header(c) for c in cfg["detail_required"]}
    for headers, rows in _iter_tables(detail_section if detail_section is not None else lines):
        norm = {_norm_header(h) for h in headers}
        if detail_req <= norm and not any(k in norm for k in ("判定", "标记")):
            idx = {_norm_header(h): i for i, h in enumerate(headers)}
            for cells in rows:
                details.append({h: (cells[idx[_norm_header(h)]] if idx[_norm_header(h)] < len(cells) else "")
                                for h in headers})
    if not details:
        warnings.append("无明细表，技术字段留空")

    # 异常
    issues = []
    issues_section = _find_section(lines, cfg["sections"]["issues"])
    for headers, rows in _iter_tables(issues_section if issues_section is not None else []):
        if any(_norm_header(h) == "标记" for h in headers):
            idx = {_norm_header(h): i for i, h in enumerate(headers)}
            for cells in rows:
                issues.append({h: (cells[idx[_norm_header(h)]] if idx[_norm_header(h)] < len(cells) else "")
                               for h in headers})

    try:
        rel = os.path.relpath(abs_path, os.getcwd())
    except ValueError:
        rel = abs_path
    rel = rel.replace(os.sep, "/")

    return {
        "rel": rel,
        "abs": abs_path,
        "batch": _extract_batch(text, abs_path),
        "date": _extract_date(text),
        "overview": overview,
        "details": details,
        "issues": issues,
        "warnings": warnings,
    }


# ---------------------------------------------------------------- 行归一化

def build_rows(parsed, cfg=None):
    """把解析结果归一化为各 sheet 行字典；幂等键列 = 报告相对路径。"""
    cfg = cfg or DEFAULT_CONFIG
    idem = cfg["idem_key_col"]
    key_col = cfg["overview_required"][0]
    verdict_col = cfg["overview_required"][1]

    rows = {"overview": [], "detail": [], "issues": []}
    for ov in parsed["overview"]:
        level, note = normalize_verdict(ov.get(verdict_col, ""))
        rows["overview"].append({
            "批次": parsed["batch"],
            "检测日期": parsed["date"],
            key_col: ov.get(key_col, ""),
            "型号": ov.get("型号", ""),
            "判定等级": level,
            "判定说明": note,
            idem: parsed["rel"],
        })
    for det in parsed["details"]:
        r = {"批次": parsed["batch"], "检测日期": parsed["date"],
             key_col: det.get(key_col, ""), idem: parsed["rel"]}
        for col in cfg["detail_split_cols"]:      # 复合列拆两列（示例 "2.66MB / 26.88MB"）
            left, right = split_pair(det.get(col, "")) or ("", "")
            r["%s(左)" % col] = parse_number(left)
            r["%s(右)" % col] = parse_number(right)
        rows["detail"].append(r)
    for iss in parsed["issues"]:
        rows["issues"].append({
            "批次": parsed["batch"], "检测日期": parsed["date"],
            key_col: iss.get(key_col, ""),
            "标记": iss.get("标记", ""), "说明": iss.get("说明", ""),
            idem: parsed["rel"],
        })
    return rows


def compute_batch_summary(overview_rows, cfg=None):
    """按「检测日期 + 批次」聚合总览行，统计实体数与各等级计数。"""
    cfg = cfg or DEFAULT_CONFIG
    idem = cfg["idem_key_col"]
    groups = {}
    for r in overview_rows:
        key = (r.get("检测日期") or "", r.get("批次") or "")
        groups.setdefault(key, []).append(r)
    summary = []
    for date, batch in sorted(groups):
        levels = [r.get("判定等级") or "—" for r in groups[date, batch]]
        files = sorted({r.get(idem) or "" for r in groups[date, batch]})
        summary.append({
            "批次": batch,
            "检测日期": date,
            "实体数": len(groups[date, batch]),
            "未判定数": sum(1 for lv in levels if lv not in cfg["levels"]),
            **{lv + "数": levels.count(lv) for lv in cfg["levels"]},
            idem: "；".join(files),
        })
    return summary


# ---------------------------------------------------------------- Excel 读写（openpyxl 唯一第三方依赖）

def _overview_headers(cfg):
    key = cfg["overview_required"][0]
    return ["批次", "检测日期", key, "型号", "判定等级", "判定说明", cfg["idem_key_col"]]


def _detail_headers(cfg):
    key = cfg["overview_required"][0]
    head = ["批次", "检测日期", key]
    for col in cfg["detail_split_cols"]:
        head += ["%s(左)" % col, "%s(右)" % col]
    head.append(cfg["idem_key_col"])
    return head


def _issues_headers(cfg):
    key = cfg["overview_required"][0]
    return ["批次", "检测日期", key, "标记", "说明", cfg["idem_key_col"]]


def _batch_headers(cfg):
    return (["批次", "检测日期", "实体数"] + [lv + "数" for lv in cfg["levels"]]
            + ["未判定数", cfg["idem_key_col"]])


def _read_sheet_rows(ws, headers):
    """把工作表读成行字典列表；空表或无表头返回空列表。"""
    if ws.max_row < 1:
        return []
    sheet_headers = [str(c.value).strip() if c.value is not None else "" for c in ws[1]]
    if not any(sheet_headers):
        return []
    index = {h: i for i, h in enumerate(sheet_headers) if h}
    rows = []
    for values in ws.iter_rows(min_row=2, values_only=True):
        row = {h: (values[index[h]] if h in index and index[h] < len(values) else None)
               for h in headers}
        if all(v is None or v == "" for v in row.values()):
            continue
        rows.append(row)
    return rows


def _fill_sheet(ws, headers, rows):
    """清空数据区后整表重写（骨架：表头加粗，其余按原样写入）。"""
    from openpyxl.styles import Font
    if ws.max_row > 0:
        ws.delete_rows(1, ws.max_row)
    for col, h in enumerate(headers, start=1):
        ws.cell(row=1, column=col, value=h).font = Font(bold=True)
    for r_idx, row in enumerate(rows, start=2):
        for col, h in enumerate(headers, start=1):
            ws.cell(row=r_idx, column=col, value=row.get(h))


def upsert(out_path, parsed_reports, cfg=None):
    """把多份报告幂等写入累计工作簿，返回各表行数统计。

    幂等键 = 报告文件相对路径：重跑同一份报告只替换它自己的行，
    其他批次的历史行保留（多批次追加）。
    """
    from openpyxl import Workbook, load_workbook

    cfg = cfg or DEFAULT_CONFIG
    idem = cfg["idem_key_col"]
    rels = {p["rel"] for p in parsed_reports}

    out_abs = os.path.abspath(out_path)
    os.makedirs(os.path.dirname(out_abs) or ".", exist_ok=True)

    wb = load_workbook(out_abs) if os.path.exists(out_abs) else Workbook()
    if wb.sheetnames == ["Sheet"]:
        wb.remove(wb.active)

    all_rows = {"overview": [], "detail": [], "issues": []}
    for p in parsed_reports:
        built = build_rows(p, cfg)
        for k in all_rows:
            all_rows[k].extend(built[k])

    specs = [
        (cfg["sheets"]["overview"], _overview_headers(cfg), all_rows["overview"]),
        (cfg["sheets"]["detail"], _detail_headers(cfg), all_rows["detail"]),
        (cfg["sheets"]["issues"], _issues_headers(cfg), all_rows["issues"]),
    ]
    for name, _, _ in specs:
        if name not in wb.sheetnames:
            wb.create_sheet(name)

    stats = {}
    for name, headers, new_rows in specs:
        old = _read_sheet_rows(wb[name], headers)
        old = [r for r in old if (r.get(idem) or "") not in rels]   # 只删本批报告的行
        merged = old + new_rows
        merged.sort(key=lambda r: ((r.get("检测日期") or ""), (r.get("批次") or "")))
        _fill_sheet(wb[name], headers, merged)
        stats[name] = len(merged)

    # 批次汇总
    if cfg["sheets"]["batch"] not in wb.sheetnames:
        wb.create_sheet(cfg["sheets"]["batch"])
    batch_headers = _batch_headers(cfg)
    all_batch = _read_sheet_rows(wb[cfg["sheets"]["batch"]], batch_headers)
    all_batch = [r for r in all_batch if (r.get(idem) or "") not in rels]
    # 用全量总览行重新聚合批次汇总（历史批次行由旧文件保留）
    merged_batch = compute_batch_summary(all_rows["overview"], cfg)
    for old_b in all_batch:
        if (old_b.get(idem) or "") not in {b.get(idem) or "" for b in merged_batch}:
            merged_batch.append(old_b)
    merged_batch.sort(key=lambda r: (r.get("检测日期") or "", r.get("批次") or ""))
    _fill_sheet(wb[cfg["sheets"]["batch"]], batch_headers, merged_batch)
    stats[cfg["sheets"]["batch"]] = len(merged_batch)

    wb.save(out_abs)
    stats["added"] = len(all_rows["overview"])
    return stats


# ---------------------------------------------------------------- 配置加载与 CLI

def load_config(path=None):
    """读 excel_config.json（--config 指定或脚本同目录）；缺失键用内置默认值。"""
    cfg_path = path or os.path.join(os.path.dirname(os.path.abspath(__file__)), "excel_config.json")
    cfg = {k: dict(v) if isinstance(v, dict) else v for k, v in DEFAULT_CONFIG.items()}
    if os.path.isfile(cfg_path):
        with open(cfg_path, encoding="utf-8-sig") as f:
            loaded = json.load(f)
        for k, v in loaded.items():
            if isinstance(v, dict) and isinstance(cfg.get(k), dict):
                cfg[k].update(v)
            else:
                cfg[k] = v
    return cfg


def _dry_run_line(parsed, cfg):
    """生成摘要：批次 / 实体数 / 各等级计数 / 明细行数 / 异常条数。"""
    counts = {lv: 0 for lv in cfg["levels"]}
    verdict_col = cfg["overview_required"][1]
    for ov in parsed["overview"]:
        level, _ = normalize_verdict(ov.get(verdict_col, ""))
        if level in counts:
            counts[level] += 1
    return ("[%s] 批次 %s  实体 %d  明细 %d  异常 %d  %s"
            % (parsed["rel"], parsed["batch"], len(parsed["overview"]),
               len(parsed["details"]), len(parsed["issues"]),
               "  ".join("%s%d" % (lv, counts[lv]) for lv in cfg["levels"])))


def main(argv=None):
    """命令行入口；返回 0 成功 / 2 报告不合格 / 3 缺 openpyxl。"""
    if hasattr(sys.stdout, "reconfigure"):
        sys.stdout.reconfigure(encoding="utf-8")

    parser = argparse.ArgumentParser(
        prog="report_to_excel.py", description="把检测报告汇入累计汇总 xlsx（骨架）")
    parser.add_argument("report", help="检测报告 Markdown 路径")
    parser.add_argument("--dry-run", action="store_true", help="只打印摘要，不写文件")
    parser.add_argument("--config", default=None, help="excel_config.json（默认脚本同目录）")
    parser.add_argument("--out", default=None, help="输出工作簿（默认 脚本同目录/汇总.xlsx）")
    args = parser.parse_args(argv)

    if not os.path.isfile(args.report):
        print("错误: 报告文件不存在: %s" % args.report, file=sys.stderr)
        return 2

    cfg = load_config(args.config)
    try:
        parsed = parse_report(args.report, cfg)
    except (ReportParseError, OSError) as exc:
        print("[失败] %s：%s" % (args.report, exc), file=sys.stderr)
        return 2

    if args.dry_run:
        print(_dry_run_line(parsed, cfg))
        for w in parsed["warnings"]:
            print("[警告] %s：%s" % (parsed["rel"], w))
        return 0

    out_path = args.out or os.path.join(os.path.dirname(os.path.abspath(__file__)), "汇总.xlsx")
    try:
        stats = upsert(out_path, [parsed], cfg)
    except ImportError as exc:
        if not (exc.name or "").startswith("openpyxl"):
            raise
        print("缺少 openpyxl，请先安装：pip install openpyxl", file=sys.stderr)
        return 3

    print("已写入 %s：总览 %d 行 / 明细 %d 行 / 异常 %d 条 / 批次汇总 %d 个"
          % (out_path, stats[cfg["sheets"]["overview"]], stats[cfg["sheets"]["detail"]],
             stats[cfg["sheets"]["issues"]], stats[cfg["sheets"]["batch"]]))
    return 0


if __name__ == "__main__":
    sys.exit(main())
