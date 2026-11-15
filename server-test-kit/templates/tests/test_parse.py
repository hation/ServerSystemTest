# -*- coding: utf-8 -*-
"""解析纯函数断言骨架（pytest）。

覆盖 process_batch 与 report_to_excel 的纯函数：clean_cell / parse_number /
split_pair / normalize_verdict（各含边界用例：空串、非数字、复合单位），
以及 process_batch 的示例判定函数返回合法级别。

运行：pytest test_parse.py -q
"""
import os
import sys

# sys.path：tests/ 的父目录（templates/）加入搜索路径
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

import process_batch as pb          # noqa: E402
import report_to_excel as r2e       # noqa: E402


# ---------------------------------------------------------------- clean_cell

class TestCleanCell:
    def test_strips_bold(self):
        assert r2e.clean_cell("**abc**") == "abc"

    def test_strips_backtick(self):
        assert r2e.clean_cell("`abc`") == "abc"

    def test_strips_whitespace(self):
        assert r2e.clean_cell("  abc  ") == "abc"

    def test_mixed_markdown(self):
        assert r2e.clean_cell(" **a** `b` ") == "a b"

    def test_empty(self):
        assert r2e.clean_cell("") == ""
        assert r2e.clean_cell(None) == ""


# ---------------------------------------------------------------- parse_number（边界：空串/非数字/千分位/单位）

class TestParseNumber:
    def test_empty_is_none(self):
        assert r2e.parse_number("") is None

    def test_non_number_is_none(self):
        assert r2e.parse_number("N/A") is None

    def test_thousands_comma(self):
        assert r2e.parse_number("1,234") == 1234.0

    def test_markdown_wrapped(self):
        assert r2e.parse_number("**100**") == 100.0

    def test_unit_conversion(self):
        # 复合单位：632KB → 0.62 MB（默认单位映射 KB→1/1024）
        assert r2e.parse_number("632KB") == 0.62
        # 自定义单位映射（示例 "2.66MB / 26.88MB" 拆分后的左段）
        assert r2e.parse_number("2.66MB") == 2.66


# ---------------------------------------------------------------- split_pair（复合单元格拆两列）

class TestSplitPair:
    def test_two_parts(self):
        assert r2e.split_pair("2.66MB / 26.88MB") == ("2.66MB", "26.88MB")

    def test_three_parts_is_none(self):
        assert r2e.split_pair("a / b / c") is None

    def test_single_is_none(self):
        assert r2e.split_pair("无") is None

    def test_cleaned_cells(self):
        assert r2e.split_pair(" **a** / `b` ") == ("a", "b")

    def test_empty_is_none(self):
        assert r2e.split_pair("") is None


# ---------------------------------------------------------------- normalize_verdict（拆等级+说明）

class TestNormalizeVerdict:
    def test_level_with_note(self):
        assert r2e.normalize_verdict("🔴 疑似问题") == ("🔴", "疑似问题")

    def test_bare_warning_sign(self):
        # 裸 ⚠（无变体选择符）也识别为 ⚠️
        assert r2e.normalize_verdict("⚠ 复核") == ("⚠️", "复核")

    def test_unknown_level(self):
        assert r2e.normalize_verdict("无判定文字") == ("—", "无判定文字")

    def test_level_only(self):
        assert r2e.normalize_verdict("🟢") == ("🟢", "")


# ---------------------------------------------------------------- judge 示例函数

class TestJudge:
    def test_returns_legal_level(self):
        v = pb.judge({"fields": {"key_field": "x"}})
        assert v["level"] in pb.LEVELS

    def test_no_fields_is_warn(self):
        assert pb.judge({"fields": {}})["level"] == "⚠️"

    def test_missing_key_field_is_red(self):
        assert pb.judge({"fields": {"other": 1}})["level"] == "🔴"
