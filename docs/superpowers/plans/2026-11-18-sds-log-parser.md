# HDM SDS 日志解析体检工具（sds-log-parser）实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 构建一个 Python CLI 工具，输入 HDM `.sds` 日志包，自动解包解析并输出 Markdown 体检报告（整机信息 / 硬件健康状态 / 异常详情 / 修复建议 / 可选 AI 综合分析）。

**Architecture:** 单 CLI 入口编排 7 个纯标准库模块：解包（tar 安全展开）→ 清单/传感器/事件三路解析器产出结构化数据 → 健康判定规则（事件证据 + 状态字段双来源）→ Markdown 渲染 + 可选 OpenAI 兼容 AI 章节。全部函数纯标准库实现，报告事实层确定性可复现，AI 为可选增强且优雅降级。

**Tech Stack:** Python 3.12 标准库（tarfile/json/csv/configparser/re/argparse/urllib/tempfile/shutil），零第三方运行时依赖；自研轻量测试运行器 `tests/run_tests.py`（无 pytest 依赖）。

**Spec:** [2026-11-18-sds-log-parser-design.md](file:///c:/Users/ganxin01/Documents/trae-work/ServerSystemTest/docs/superpowers/specs/2026-11-18-sds-log-parser-design.md)

## Global Constraints

- 运行时零第三方依赖：仅 Python 3.12 标准库
- 工具全部代码位于项目根目录 `sds-log-parser/`，不影响既有内容
- 中文输出；报告文件名与章节标题用中文
- 文本读取：UTF-8 优先、失败回退 GBK 的双编码策略；`test.csv` 读取时去除 `\x00` 空字节
- AI 环境变量：`SDS_AI_BASE_URL` / `SDS_AI_API_KEY` / `SDS_AI_MODEL`（默认 `deepseek-v4-flash`）；端点格式 `{base_url}/chat/completions`；响应取 `message.content`（模型可能带 `reasoning_content`，忽略之）
- **密钥安全**：API Key 只经环境变量注入，绝不写入文件、不进 git、不落报告
- 解包到临时目录，用后清理（`tempfile` + `try/finally`）；`--no-cleanup` 保留调试
- CLI：`python sds_parser.py <input.sds> [-o output.md] [--ai] [--no-cleanup] [--verbose]`；缺 `-o` 输出到输入同目录 `<basename>-report.md`
- 事件来源优先级：`user/test.csv` > `.sbe` 字符串兜底；两者皆无 → 事件章节标注"无事件数据"
- Git 约定（延续项目惯例）：提交身份用 env 注入 `ganxin01 <ganxin01@local>`，不改 config；直接在 main 分支执行；每任务独立 commit

## Review Focus

以下输入/失败模式是 spec 未显式写测试、但真实使用最可能踩到的，每项已在对应任务中钉了测试：

1. **非 tar 文件传入** → 应友好报错退出（非 0 退出码 + 明确中文提示），不抛裸异常堆栈（Task 1）
2. **tar 含路径穿越/绝对路径成员** → 拒绝解包，不覆盖临时目录外路径（Task 1）
3. **缺文件 / 0 字节文件（如 nvme_info.ini）** → 不崩溃，对应数据标"未知"或留空（Task 2、Task 3）
4. **GBK 编码 INI（中文 HDM 导出）** → 不乱码不报错（Task 1 的 `read_text_file` + Task 2 测试）
5. **`test.csv` 缺失时** → `.sbe` 兜底仍能识别盘类异常，报告不中断（Task 4、Task 7 集成）
6. **主机处于待机态**（风扇 0 RPM、PSU "Output Abnormal"、Total_Power 低）→ 不误报为异常（Task 5）
7. **AI 未配置 / 调用失败** → 跳过 AI 章节、打印原因、报告主体正常生成（Task 6、Task 7 集成）

---

### Task 1: 脚手架 + 解包模块（sds_extract.py + 测试运行器）

**Files:**
- Create: `sds-log-parser/sds_extract.py`
- Create: `sds-log-parser/tests/run_tests.py`（轻量测试运行器：扫描 `test_*` 函数执行，断言失败打印并退出码非 0）
- Create: `sds-log-parser/sds_parser.py`（占位入口，仅 argparse 骨架，后续 Task 7 填充编排）

**Interfaces:**
- Produces（后续任务依赖）:
  - `extract_sds(sds_path: str, keep: bool = False) -> ExtractionResult`
  - `ExtractionResult`（dataclass）：`root_dir: str`（临时目录，keep 时保留）、`files: dict[str, str | None]`，键集合固定为：`event_csv`、`sbe`、`visible_log`、`hardware_info_ini`、`hardware_info`、`firmware_version_ini`、`fru_info_ini`、`sensor_info_ini`、`raid_bp_conf_ini`、`nvme_info_ini`、`bios_json`、`hdm_json`；解不到的文件为 `None`
  - `read_text_file(path: str) -> str`（UTF-8 → GBK 回退，读成字符串）
  - `SDSNotTarError`（异常类）
  - `cleanup(extract_result)`（`keep=False` 时删除临时目录）

- [ ] **Step 1: 写失败测试**（`tests/run_tests.py` 中的 `test_extract_basic`、`test_extract_non_tar`、`test_extract_traversal`、`test_read_text_gbk`）

```python
def test_extract_basic():
    # 用 tarfile 在临时目录造一个含 static/hardware_info.ini、user/test.csv、event/ev.tar.gz(内含 .sbe) 的 .sds
    # 断言 ExtractionResult.files 各键路径存在，event_csv 指向 user/test.csv，sbe 指向解包出的 .sbe
def test_extract_non_tar():
    # 传一个普通文本文件 → 断言抛 SDSNotTarError
def test_extract_traversal():
    # tar 内含成员名 '../evil' → 断言不落盘（临时目录中不存在该文件）
def test_read_text_gbk():
    # 用 gbk 编码写中文 ini → read_text_file 返回正确中文
```

- [ ] **Step 2: 跑测试确认失败** — `python sds-log-parser/tests/run_tests.py`，Expected: 4 个用例因 `sds_extract` 不存在而失败
- [ ] **Step 3: 实现 `sds_extract.py`**：`tarfile.open` 外层；对每个成员用 `posixpath.normpath` 校验（拒绝 `..` 前缀、绝对路径、`islink`），安全解到临时目录；识别 `event/*.tar.gz` 再解一层（同样校验）；`files` 映射用「相对路径后缀匹配」定位（如以 `user/test.csv` 结尾）；`read_text_file` 双编码回退；`cleanup` 用 `shutil.rmtree`
- [ ] **Step 4: 跑测试确认通过** — Expected: 4 PASS
- [ ] **Step 5: Commit**

```bash
git add sds-log-parser/sds_extract.py sds-log-parser/sds_parser.py sds-log-parser/tests/run_tests.py
git commit -m "feat: sds 解包模块与测试运行器"
```

### Task 2: 硬件清单解析（sds_inventory.py）

**Files:**
- Create: `sds-log-parser/sds_inventory.py`
- Test: 在 `tests/run_tests.py` 追加 `test_inventory_hardware_info_ini`、`test_inventory_firmware`、`test_inventory_empty_files`

**Interfaces:**
- Consumes: `ExtractionResult.files`（Task 1）、`read_text_file`（Task 1）
- Produces: `parse_inventory(files: dict[str, str | None]) -> InventoryData`
  - `InventoryData`（dataclass）：`machine: dict`（product_name/serial_number/product_part_number/baseboard）、`firmware: dict`（BIOS/HDM/CPLD 版本，缺省 None）、`cpus: list[dict]`（model/status/cores/threads）、`memories: list[dict]`（location/socket_id/size/status/part_number）、`pcie_cards: list[dict]`（location/product_name/vendor_id/status/current_speed/current_bandwidth）、`nics: list[dict]`（port/location/mac/product_name/link_state）、`backplanes: list[dict]`（name/part_number/board_type/health_status）、`psus: list[dict]`（id/model/sn/power_status）

- [ ] **Step 1: 写失败测试**：构造 3 组小样本文本（`hardware_info.ini` 含 `[Processors: Processor 1]`/`[PCIe Card: PCIe 3]`/`[Power 1]`/`[BaseBoard]`；`firmware_version.ini` 含 BIOS/HDM 版本行；`FruInfo.ini` 含 `[BaseBoard]` 的 Product/Serial 行）写入临时文件后调 `parse_inventory`；断言 machine.product_name、firmware.BIOS、pcie_cards[0].status、psus 等字段正确；空文件（0 字节）与缺文件（None）→ 返回空列表/None 字段，不抛异常
- [ ] **Step 2: 跑测试确认失败** — Expected: FAIL（模块不存在）
- [ ] **Step 3: 实现 `sds_inventory.py`**：`configparser`（`delimiters=(':',)` 适配 `Key : Value`，`strict=False`）解析 `hardware_info.ini`；行解析 `firmware_version.ini`（`Key : Value` 段头为 `[System board]` 等）；`FruInfo.ini` 的 `[BaseBoard]` 取 Product Name/Serial；`bios.json`/`hdm.json` 的 `machine information`/固件字段作为 machine/firmware 补充（主来源优先，缺才补）；空/缺文件直接返回默认值
- [ ] **Step 4: 跑测试确认通过**
- [ ] **Step 5: Commit** — `feat: 硬件清单解析模块`

### Task 3: 传感器解析（sds_sensors.py）

**Files:**
- Create: `sds-log-parser/sds_sensors.py`
- Test: 追加 `test_sensors_parse`、`test_sensors_empty`

**Interfaces:**
- Consumes: `files['sensor_info_ini']`、`read_text_file`（Task 1）
- Produces: `parse_sensors(path: str | None) -> list[SensorReading]`
  - `SensorReading`（dataclass）：`name: str`、`value: str`、`unit: str`、`status: str`
  - 重点关注名称：`PSU1_VIN`/`PSU2_VIN`/`PSU1_Status`/`PSU2_Status`/`FANx_Status`/`Total_Power`/`Inlet_Temp`

- [ ] **Step 1: 写失败测试**：小样本文本按「名称 | 值 | 单位 | 状态 | 阈值…」管道格式解析 → 断言 name/value/unit/status 正确；空文件/None → `[]`
- [ ] **Step 2: 跑测试确认失败**
- [ ] **Step 3: 实现 `sds_sensors.py`**：按 `|` 切分行，跳过表头/空行/注释，前 4 列取 name/value/unit/status
- [ ] **Step 4: 跑测试确认通过**
- [ ] **Step 5: Commit** — `feat: 传感器解析模块`

### Task 4: 事件解析（sds_events.py）

**Files:**
- Create: `sds-log-parser/sds_events.py`
- Test: 追加 `test_event_csv`（含 `\x00` 与多行引号字段）、`test_event_csv_missing_suggestion`、`test_sbe_fallback`、`test_visible_log`

**Interfaces:**
- Consumes: `files['event_csv']` / `files['sbe']` / `files['visible_log']`、`read_text_file`（Task 1）
- Produces:
  - `EventRecord`（dataclass）：`timestamp: str`、`severity: str`、`sensor_name: str`、`desc: str`、`suggestion: str`、`source: str`（'csv'|'sbe'|'visible'）
  - `parse_event_csv(path: str | None) -> list[EventRecord]`（缺文件 → `[]`）
  - `parse_sbe(path: str | None) -> list[EventRecord]`（尽力而为：以 `?`(0x3F) 分隔可读串，提取 `传感器名+描述`，timestamp 标 "未知"，source='sbe'；缺文件 → `[]`）
  - `parse_visible_log(path: str | None) -> list[str]`（原始行，缺文件 → `[]`）

- [ ] **Step 1: 写失败测试**：构造 CSV 内容：表头 9 列、一行 `Major` 盘事件含 `\x00` 与引号内换行、一行 `Info` 无 Suggestion → 断言 9 字段映射正确、`\x00` 被去除、suggestion 空串；构造 `b's\x00e\x00f\x00'`+分隔+`Disk_F23_Status\x00Drive Fault` 的假 `.sbe` 字节 → `parse_sbe` 提取出含 `Disk_F23_Status` 与 `Drive Fault` 的记录；visible.log 简单行提取
- [ ] **Step 2: 跑测试确认失败**
- [ ] **Step 3: 实现 `sds_events.py`**：CSV 用二进制读入 → 去 `\x00` → `csv.reader`（表头为第 1 行）；多行字段由 csv 模块自动处理；`.sbe` 读入后按可读子串切分提取；`read_text_file` 复用
- [ ] **Step 4: 跑测试确认通过**
- [ ] **Step 5: Commit** — `feat: 事件解析模块（csv/sbe/visible）`

### Task 5: 健康判定与修复建议（sds_health.py）

**Files:**
- Create: `sds-log-parser/sds_health.py`
- Test: 追加 `test_health_disk_hba`、`test_health_psu`、`test_health_standby_no_false_positive`、`test_suggestions`

**Interfaces:**
- Consumes: `InventoryData`（Task 2）、`list[SensorReading]`（Task 3）、`list[EventRecord]`（Task 4）
- Produces:
  - `assess_health(inv, sensors, events) -> list[ComponentHealth]`
  - `ComponentHealth`（dataclass）：`name: str`、`category: str`、`status: str`（'正常'|'异常'|'未知'|'提示'）、`evidence: list[str]`（格式 `[时间] 级别 描述`，最多 5 条）、`suggestions: list[str]`
  - `build_suggestions(events: list[EventRecord]) -> list[str]`

- [ ] **Step 1: 写失败测试**
```python
def test_health_disk_hba():
    # events 含 PCIe_Card3_HBA "Device Disabled: PCIe module information not obtained" 与 Disk_F23_Status "The disk is missing"/"Drive Fault"
    # 断言存在 category='PCIe' 的组件（HBA）status='异常'，evidence 含 "module information not obtained"；存在盘 F23 status='异常'
def test_health_psu():
    # events 含 PSU1_Status "Power Supply input lost (AC/DC)" → 电源组件 status='异常'，suggestions 含 'AC' 相关词
def test_health_standby_no_false_positive():
    # 无异常事件 + sensors 风扇 0 RPM + Total_Power=20W → 风扇组件 status='正常'（不误报）
def test_suggestions():
    # build_suggestions 对 'The disk is missing' 事件返回含 '重新安装'/'更换' 的建议；对带官方 Suggestion 的 CSV 事件优先返回官方文本
```
- [ ] **Step 2: 跑测试确认失败**
- [ ] **Step 3: 实现 `sds_health.py`**：按 spec 规则表实现；判定函数内部先按 SensorName 前缀/关键词归因（Disk_/PCIe_/PSU/HDD_BP/CPU*_A0…）；待机判定：`Total_Power` 存在且 < 100W 视为待机，风扇 0 RPM 不算异常；`build_suggestions` 优先级：官方 Suggestion > 关键词映射 > 兜底文案；建议规则关键词与映射逐字取自 spec「修复建议规则」节
- [ ] **Step 4: 跑测试确认通过**
- [ ] **Step 5: Commit** — `feat: 健康判定与修复建议规则模块`

### Task 6: AI 事实材料包 + 可选后端调用（sds_ai.py）

**Files:**
- Create: `sds-log-parser/sds_ai.py`
- Test: 追加 `test_ai_prompt_contains_facts`、`test_ai_prompt_has_task`、`test_ai_downgrade_no_env`、`test_ai_http_failure`（用 `unittest.mock` 替换 `urllib.request.urlopen`）

**Interfaces:**
- Consumes: `ComponentHealth` 列表、`InventoryData.machine/firmware`（Task 2/5）
- Produces:
  - `build_ai_payload(inv, health, events) -> str`（"事实先行"文本块：机器信息 + 异常组件清单（组件/状态/事件原文/建议）+ 分析任务指令"请基于以上事实输出：① 异常链路推断 ② 根因候选排序 ③ 可执行的排查步骤"。**同时供两处使用**：默认落盘为 `<basename>-ai-facts.md` 材料包；`--ai` 时作为 API 请求 content）
  - `call_ai(payload: str, base_url: str, api_key: str, model: str) -> str | None`（POST `{base_url}/chat/completions`，取 `message.content`；任何异常/非 200/无 content → 返回 None）

- [ ] **Step 1: 写失败测试**
```python
def test_ai_prompt_contains_facts():
    # build_ai_payload 输出包含 机器型号、组件名、事件原文 关键事实
def test_ai_prompt_has_task():
    # build_ai_payload 输出包含"异常链路推断"、"根因候选排序"、"排查步骤"任务指令
def test_ai_downgrade_no_env():
    # 环境变量缺 SDS_AI_BASE_URL 时 call_ai 直接返回 None（不发起请求）
def test_ai_http_failure():
    # mock urlopen 抛 URLError → call_ai 返回 None；mock 200 且 content 存在 → 返回该文本
```
- [ ] **Step 2: 跑测试确认失败**
- [ ] **Step 3: 实现 `sds_ai.py`**：`urllib.request` POST JSON（`Authorization: Bearer <key>`）；读环境变量；响应解析容错；`reasoning_content` 字段忽略
- [ ] **Step 4: 跑测试确认通过**
- [ ] **Step 5: Commit** — `feat: AI 事实材料包与可选后端调用模块`

### Task 7: 报告渲染 + 材料包落盘 + CLI 编排 + 集成验收（sds_report.py + sds_parser.py）

**Files:**
- Create: `sds-log-parser/sds_report.py`
- Modify: `sds-log-parser/sds_parser.py`（填充编排）
- Test: 追加 `test_report_sections`、`test_facts_pack_always_written`、`test_cli_non_tar_friendly`、集成用例 `test_integration_real_sds`（可用 `--sds <真实样例路径>` 指定）

**Interfaces:**
- Consumes: Task 1-6 全部接口
- Produces: `render_report(inv, sensors, health, events, visible_lines, ai_markdown: str | None, report_time: str) -> str`；`print_summary(health, report_path)`（控制台：异常组件数 + 清单 + 路径）

- [ ] **Step 1: 写失败测试**
```python
def test_report_sections():
    # 构造最小数据 → render_report 输出含 4 个必选章节标题：## 1. 整机信息 / ## 2. 硬件健康状态 / ## 3. 异常详情 / ## 4. 修复建议；ai_markdown=None 时无 ## 5 章节，非 None 时含
def test_facts_pack_always_written():
    # 对样例运行 sds_parser.py（不加 --ai）→ 同目录生成 <basename>-ai-facts.md，内容含 机器信息、异常组件（F23/HBA）、事件原文、任务指令（异常链路推断/根因候选排序/排查步骤）
def test_cli_non_tar_friendly():
    # subprocess 调 sds_parser.py 传普通文本文件 → 退出码非 0 且 stderr/stdout 含"不是有效的"中文提示，无 Python 堆栈
def test_integration_real_sds():
    # 对真实样例（路径经 --sds 注入）全链路：报告生成成功、含 "H3C UniServer"、"F23"、"module information not obtained"、电源异常条目、修复建议含"更换"/"换槽"关键词
```
- [ ] **Step 2: 跑测试确认失败**
- [ ] **Step 3: 实现**：`sds_report.py` 按 spec「report」节拼 Markdown（表格 + 事件列表 + 附录）；`sds_parser.py` 编排：extract → parse 三路 → health → **默认用 `build_ai_payload` 落盘 `<basename>-ai-facts.md`** → 可选 `--ai`（env 完整时 `call_ai` 并把结果并入报告 `## 5`）→ render → 写文件（UTF-8）→ print_summary → cleanup；`--verbose` 打印各模块输出条数；非 tar 错误捕获打印中文提示并以退出码 1 返回
- [ ] **Step 4: 跑单元测试确认通过**，再用真实样例跑集成：`python sds-log-parser/sds_parser.py "<真实样例.sds>" -o sds-log-parser/tests/_out_report.md`，人工核对：报告四章节与 F23/HBA/电源异常条目，且同目录生成 `-ai-facts.md`
- [ ] **Step 5: 验证 AI 降级**：不配置 env 加 `--ai` 运行 → 报告正常生成、材料包正常产出、控制台提示"未配置 AI 后端"
- [ ] **Step 6: Commit** — `feat: 报告渲染与 CLI 编排，全链路跑通真实样例`

---

## Self-Review 结论

- **Spec 覆盖**：四章节报告（T7 渲染）✓；AI 双模式——材料包默认产出（T6 `build_ai_payload` + T7 落盘）+ 后端自动 `--ai`（T6/T7）✓；解包安全（T1）✓；编码回退（T1/T2）✓；健康规则含待机排除（T5）✓；`.sbe` 兜底（T4/T7）✓；CLI 参数/默认输出名/临时目录清理（T1/T7）✓；密钥不进 git（Global Constraints + T6 不落盘）✓
- **类型一致性**：`ExtractionResult.files` 键集合、`EventRecord`、`SensorReading`、`InventoryData`、`ComponentHealth`、`render_report`/`build_ai_payload`/`call_ai` 签名在任务间前后一致
- **Review Focus 七项**均已在对应任务钉测试（见文首清单）
