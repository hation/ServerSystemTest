# 体检报告「分析汇总」置顶章节 实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 在体检报告标题块之后新增置顶 `## 0. 分析汇总` 章节（整机概览 / 健康总览 / 核心结论），先汇总后展开，详情章节与标题块保持现状。

**Architecture:** 改动集中在 `sds_report.py`：新增 `render_summary(inv, health, ai_markdown=None) -> str` 与规则结论函数 `_rule_conclusion(health) -> str`，在 `render_report` 标题块之后、`## 1.` 之前插入；核心结论 AI 优先（取 AI 首要点句、截断 ≤120 字）+ 规则兜底（类别优先级取首个异常组件）。`sds_parser.py` 无需改动（现有调用已透传 inv/health/ai_markdown）。

**Tech Stack:** Python 3.12 标准库；自研轻量测试运行器 `tests/run_tests.py`（无 pytest 依赖）。

**Spec:** [2026-11-18-sds-summary-section-design.md](file:///c:/Users/ganxin01/Documents/trae-work/ServerSystemTest/docs/superpowers/specs/2026-11-18-sds-summary-section-design.md)

## Global Constraints

- 运行时零第三方依赖：仅 Python 3.12 标准库
- 改动仅限 `sds-log-parser/sds_report.py` 与 `sds-log-parser/tests/run_tests.py`（`sds_parser.py` 不动）
- 中文输出；新章节标题逐字 `## 0. 分析汇总`
- 三要点（用户选定）：整机概览 / 健康总览 / 核心结论
- 核心结论来源：**AI 优先 + 规则兜底**——`ai_markdown` 非空时取首个非空要点句、去 Markdown 标记、截断 ≤120 字；否则规则兜底
- 规则兜底类别优先级（逐字）：硬盘 > PCIe > 电源 > 背板 > 内存 > CPU > 风扇 > 温度 > 其他；取首个异常/提示组件；无异常/提示 → `未发现异常组件。`
- 健康总览计数：`正常 X · 异常 Y · 提示 Z`；**未知仅当 > 0 时**追加 `· 未知 W`
- 现有标题块（`# 服务器体检报告` + 机器标识 + 采集时间两行）**原样保留**，`## 0.` 紧跟其后
- 测试追加到 `tests/run_tests.py`（自研运行器扫 `test_*`，失败退出码非 0）；追加后整体运行
- Git 约定（延续）：提交身份 env 注入 `ganxin01 <ganxin01@local>`、不改 config、main 分支直提、**只 add sds-report.py 与 run_tests.py 两个文件**（工作区有无关改动）
- 密钥安全：本变更不涉及任何密钥

## Review Focus

1. **`ai_markdown` 为空串 / 纯空白 / 纯 Markdown 标记** → 核心结论应回退到规则兜底，不抛异常（Task 1 `test_summary_ai_conclusion`）
2. **无异常且无提示组件** → 核心结论输出 `未发现异常组件。`（Task 1 `test_summary_rule_conclusion`）
3. **含"未知"状态组件** → 健康总览仅在有未知时展示 `· 未知 W`（Task 1 `test_summary_unknown_count`）
4. **现有章节回归** → `test_report_sections` 需同步加入 `## 0. 分析汇总` 断言，且 `## 1. 整机信息` 等原有断言仍通过（Task 1）
5. **章节顺序** → `## 0.` 必须出现在 `## 1.` 之前（Task 1 断言顺序）

---

### Task 1: 分析汇总章节（render_summary + 规则结论 + 测试）

**Files:**
- Modify: `sds-log-parser/sds_report.py`（新增函数 + render_report 插入点）
- Modify: `sds-log-parser/tests/run_tests.py`（新增 4 个用例 + 更新 test_report_sections）

**Interfaces:**
- Consumes: `InventoryData`（`machine`/`firmware` 为 dict）、`ComponentHealth(name/category/status/evidence/suggestions)`、`ai_markdown: str | None`
- Produces:
  - `render_summary(inv, health, ai_markdown=None) -> str`：返回 `## 0. 分析汇总` 整节 Markdown（`### 整机概览` / `### 健康总览` / `### 核心结论`）
  - `_rule_conclusion(health) -> str`：类别优先级取首个异常/提示组件的一句话；无则 `未发现异常组件。`
  - `_ai_conclusion(ai_markdown: str) -> str`：取 AI 首要点句、去 Markdown 标记、截断 ≤120 字（供 render_summary 内部用）
  - `render_report(...)` 签名不变，在标题块后、`## 1.` 前插入 render_summary 输出

- [ ] **Step 1: 写失败测试**（追加到 run_tests.py，断言用真实值）

```python
def test_summary_sections():
    # inv.machine 含 product_name/serial_number，inv.firmware 含 BIOS/HDM/CPLD
    # health = [ComponentHealth 正常/异常(硬盘 Disk_F23_Status)/提示(背板)]
    # 断言 render_summary 输出含 '## 0. 分析汇总'、'### 整机概览'、机型与固件、
    #   '### 健康总览'、'正常 1 · 异常 1 · 提示 1'、'### 核心结论'、规则结论含 'Disk_F23_Status'

def test_summary_rule_conclusion():
    # health 仅含 正常 组件 → _rule_conclusion == '未发现异常组件。'
    # health 含 硬盘(Disk_F23_Status)+PCIe(PCIe_Card3_HBA) 两异常 → 结论含 '硬盘' 与 'Disk_F23_Status'
    #   （硬盘优先级 > PCIe）

def test_summary_ai_conclusion():
    # ai_markdown='### 异常链路推断\n- 最可能问题集中在 HBA（PCIe slot 3）链路。\n...' →
    #   render_summary 核心结论含 '最可能问题集中在 HBA（PCIe slot 3）链路'（首要点句）
    # ai_markdown='' / '   ' / '**bold only**' → 核心结论回退规则结论（不抛异常）
    # ai_markdown 超长首句 → 截断 ≤120 字

def test_summary_unknown_count():
    # health 含 1 个 '未知' 组件 → 健康总览含 '· 未知 1'
    # health 无 '未知' → 健康总览不含 '未知'

# 更新 test_report_sections：
#   title 列表加入 '## 0. 分析汇总'；断言 '## 0. 分析汇总' 出现在 '## 1. 整机信息' 之前
```

- [ ] **Step 2: 跑测试确认失败** — `python sds-log-parser/tests/run_tests.py`，Expected: 新用例因 `render_summary` 不存在而 FAIL（`test_report_sections` 因缺 `## 0.` 断言 FAIL）
- [ ] **Step 3: 实现 `sds_report.py`**：新增 `_CATEGORY_PRIORITY`（硬盘>PCIe>电源>背板>内存>CPU>风扇>温度>其他）、`_rule_conclusion`、`_ai_conclusion`（首个非空段落去 Markdown 标记：去 `#`/`*`/`-` 行首符号与行内 `**`，strip 后截断 120 字）、`render_summary`；`render_report` 在标题块输出之后、`## 1.` 之前插入
- [ ] **Step 4: 跑全量测试确认通过** — Expected: 34 passed（30 原有 + 4 新增），退出码 0
- [ ] **Step 5: 真实样例人工核对** — `python sds-log-parser/sds_parser.py "<真实样例.sds>" -o docs\体检报告\_verify_summary.md`，核对报告开头顺序：标题块 → `## 0. 分析汇总`（三要点齐全，健康总览 `正常 50 · 异常 4 · 提示 1`）→ `## 1.`；随后删除该临时文件
- [ ] **Step 6: Commit**

```bash
git add sds-log-parser/sds_report.py sds-log-parser/tests/run_tests.py
git commit -m "feat: 体检报告新增置顶分析汇总章节（整机概览/健康总览/核心结论）"
```

---

## Self-Review 结论

- **Spec 覆盖**：三要点（render_summary）✓；核心结论 AI 优先+规则兜底（_ai_conclusion/_rule_conclusion）✓；类别优先级逐字（_CATEGORY_PRIORITY）✓；未知按需展示（test_summary_unknown_count）✓；标题块保留+章节顺序（test_report_sections 更新）✓；现有行为不回退（全量回归 + 真实样例核对）✓
- **类型一致性**：`render_summary(inv, health, ai_markdown=None)` / `_rule_conclusion(health)` / `_ai_conclusion(str)` 在任务内自洽；`render_report` 签名不变，parser 无需改动
- **Review Focus 五项**均在 Task 1 钉了测试（见文首清单）
- **比例**：1 个任务承载全部改动（同模块、同测试文件、单 review gate），计划长度与改动规模匹配
