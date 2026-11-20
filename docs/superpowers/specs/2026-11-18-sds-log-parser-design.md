# 2026-11-18 HDM SDS 日志解析体检工具 — 设计文档

## 背景与意图（Why）

用户在服务器压力测试后遇到"SSD 盘识别不了"问题，本次已通过人工分析一份 HDM SDS 日志包（`.sds`，本质是标准 tar 归档）定位到根因（HBA/PCIe slot 3 识别失败等）。这类分析每次都要手工解包、逐个文件查看，成本高且易遗漏。希望做一个**可复用的一键工具**：输入 `.sds` 日志包，自动解包并解析，输出一份"体检报告"式的 Markdown 文档，让分析过程可自动化、可沉淀。

## 目标（Goals）

- Python CLI 工具（仅标准库，零第三方依赖）：`python sds_parser.py <xxx.sds> [-o 报告路径]`
- 自动解包 `.sds`（外层 tar + 内层 `event/*.tar.gz`），含路径穿越安全校验
- 输出 Markdown 体检报告，四个核心章节（对应四条需求）：
  1. **整机信息**：机型/SN/固件版本（BIOS/HDM/CPLD）、CPU、内存、PCIe 卡、网卡、背板、电源、传感器概要
  2. **硬件健康状态**：逐项硬件标注 正常 / 异常 / 未知（附判定依据）
  3. **异常详情**：每个异常硬件对应的报错信息（从事件日志提取：时间、级别、事件原文）
  4. **修复建议**：优先采用事件日志自带的官方 Suggestion 列；不足时按规则补充
  5. **AI 综合分析材料包（默认产出）**：每次运行自动生成 `<文件名>-ai-facts.md`——纯事实 + 分析任务指令，供"当前会话 AI"使用做综合总结（机器信息、异常组件清单、证据事件原文、官方修复建议 + 要求输出异常链路推断/根因候选排序/排查步骤）
  6. **可选后端 AI 自动章节**：加 `--ai` 开关且配置了 LLM 后端时，复用同一份事实结构直连 OpenAI 兼容 API，把"AI 综合分析"写入报告；未配置或失败时自动跳过并提示，报告其余部分不受影响
- 报告默认生成到 `.sds` 同目录 `<文件名>-report.md`，同时控制台打印关键摘要

## 非目标 / 反目标（Non-goals / Anti-goals）

- **不做 `.sbe` 私有二进制的精确解码**：无公开 schema；以"可读字符串提取"作为事件 CSV 缺失时的兜底，并提示用户从 HDM Web 导出 CSV
- **不解析 OS 系统日志 / BIOS POST 日志**：SDS 包里没有这些内容
- **不做 Web 界面 / HTML 报告**：本版本输出 Markdown（用户已选定）
- **不做自动修复**：只给建议，结论由人判定
- **不猜测并标注未知信息**：拿不到的数据显式标"未知"，不编造

## 约束（Constraints）

- 纯 Python 3.12 标准库（`tarfile`/`json`/`csv`/`configparser`/`re`/`argparse`/`shutil`/`tempfile`），Windows 与 Linux 均可运行
- 工具作为独立功能放在项目根目录 `sds-log-parser/` 子目录，不影响既有内容
- 中文输出；报告文件名与章节用中文
- 解包到临时目录，用后清理（`tempfile` + `try/finally`）
- 事件 CSV（`user/test.csv`）是首选的可靠事件来源；`.sbe` 字符串提取仅为兜底
- **编码处理**：所有文本文件读取采用 UTF-8 优先、失败回退 GBK 的双编码策略（HDM 中文环境导出的 INI 可能为 GBK），`test.csv` 另需去除 `\x00` 空字节后再解析
- **AI 后端（可选）**：OpenAI 兼容 HTTP 协议（`/chat/completions`），通过环境变量配置，不锁定厂商：
  - `SDS_AI_BASE_URL`（如 `https://ark.cn-beijing.volces.com/api/coding/v3` 或本地 `http://localhost:11434/v1`）
  - `SDS_AI_API_KEY`（本地 Ollama 可留空）
  - `SDS_AI_MODEL`（默认 `deepseek-v4-flash`）
  - 用标准库 `urllib` 实现，不引第三方依赖；未配置或调用失败 → 跳过 AI 章节并打印提示，不中断报告生成
  - **已实测**（2026-11-18）：`{base_url}/chat/completions` 对火山方舟 Ark（base_url `https://ark.cn-beijing.volces.com/api/coding/v3`、model `deepseek-v4-flash`）连通正常；该模型响应含 `reasoning_content`（思考过程）与 `reasoning_tokens`——工具取 `message.content` 为正文，`reasoning_content` 可选附注
- **密钥安全**：API Key 只经环境变量 `SDS_AI_API_KEY` 注入，**不写入任何文件、不进 git、不落报告**；本对话中的密钥仅用于本次连通性测试
- **AI 双模式**：① 当前会话模式（默认）——每次运行产出 `<basename>-ai-facts.md` 材料包，供当前会话 AI 做综合总结，零外部依赖；② 后端自动模式（`--ai`）——直连 OpenAI 兼容 API 自动写入 AI 章节。两模式共用 `build_ai_payload` 的同一份"事实 + 任务指令"文本，仅消费方不同（A 落盘给会话 AI，B 作为 API 请求 content）

### 已知样例与数据结构（已在本项目验证，实现者可直接参考）

验收与实现使用的样例：`c:\Users\ganxin01\.trae-cn\attachments\561c8ecb-f478-478c-a9b8-c0e9250fb527_035beacd-9c0e-42d3-93a4-39ccbe348f36_HDM210235A566526AN0000P_20261118.sds`（本机已解包在项目 `sds_extract/` 目录，含全部典型文件，可作 ground truth 对照）。

- `user/test.csv`：**有表头行**，逗号分隔，9 列顺序为 `Record Time Stamp, Severity Level, Severity Level ID, SensorTypeStr, SensorName, Event Dir, Event Occurred Time, DescInfo, Explanation, Suggestion`；部分行含 `\x00` 空字节；Explanation/Suggestion 列含换行（在引号内，`csv` 模块可正常处理）
- `SensorName` 命名模式（归因依据）：盘槽 `Disk_Fxx_Status`（如 `Disk_F23_Status`）、PCIe 模块 `PCIe_CardN_<类型>`（如 `PCIe_Card3_HBA`）、电源 `PSU1_Status`/`PSU2_Status`、背板 `HDD_BP3_Status`、内存 `CPU1_A0` 等；`DescInfo` 含事件描述（如 "Device Disabled: PCIe module information not obtained---Slot: 3"、"The disk is missing"）
- `.sbe`（私有二进制兜底）：事件记录以 `?`(0x3F) 字节分隔、内部含可读字符串（传感器名 + 事件描述），可做**尽力而为**的字符串提取；时间戳不可靠时标"未知"。此路径仅作兜底，产出准确度不保证
- `sensor_info.ini`：管道符分隔的文本表（名称|读数|单位|状态|阈值列）
- `hardware_info.ini`：标准 INI 段（`[Processors: Processor N]`、`[PCIe Card: PCIe N]`、`[Ethernet adapters]`、`[Power N]`、`[BaseBoard]` 等），键值 `Key : Value`
- `bios.json` / `hdm.json`：含 `machine information`（机型/SN/固件版本）与固件版本字段，作为整机信息的**补充来源**（主来源为 `firmware_version.ini` / `FruInfo.ini` / `hardware_info.ini`）

## 方案设计（How，已定）

### 目录结构

```
sds-log-parser/
├── sds_parser.py       # CLI 入口 + 编排（argparse、调用各模块、生成报告）
├── sds_extract.py      # 解包：外层 tar + 内层 event/*.tar.gz；路径穿越防护；临时目录管理
├── sds_inventory.py    # 硬件清单：hardware_info.ini / hardware.info / firmware_version.ini / FruInfo.ini
├── sds_sensors.py      # 传感器：sensor_info.ini（温度/电压/风扇/功耗/PSU 输入）
├── sds_events.py       # 事件：user/test.csv（优先）/ .sbe 字符串兜底 / visible.log 操作日志
├── sds_health.py       # 健康判定规则 + 修复建议规则（关键词/状态字段 → 结论）
├── sds_ai.py           # 可选 AI：OpenAI 兼容 /chat/completions 调用，产出"AI 综合分析"章节
├── sds_report.py       # Markdown 渲染（四章节 + 可选 AI 章节）+ 控制台摘要
└── tests/
    └── run_tests.py    # 轻量自测：真实 .sds 样例 + 容错场景
```

### 数据流

`.sds` → `extract`（临时目录）→ 各解析器产出结构化 dict → `health` 判定（正常/异常/未知 + 依据 + 建议）→ `report` 渲染 Markdown + 控制台摘要（若 `--ai` 且已配置后端：先用解析结果拼 prompt 调用 `sds_ai`，生成 AI 章节并入报告）→ 清理临时目录。

### 各模块要点

**extract**：`tarfile.open` 外层归档；识别 `event/*.tar.gz` 再解一层；对每个成员做路径规范化校验（拒绝 `..`、绝对路径、符号链接），解到临时目录；返回各关键文件的实际路径（缺文件则标记 None，不报错中断）。

**inventory**：解析 `hardware_info.ini`（INI 段：Processors/Memory Summary/PCIe Card/Ethernet adapters/Power/BaseBoard 等）、`hardware.info`（键值对段）、`firmware_version.ini`（BIOS/HDM/CPLD）、`FruInfo.ini`（机型/SN）。输出：整机标识、固件版本、CPU、内存（槽位/容量/状态）、PCIe 卡（槽位/产品名/状态/速度）、网卡、背板、电源列表。

**sensors**：解析 `sensor_info.ini` 各传感器名称/读数/单位/状态。重点关注：PSU 输入电压/状态、风扇、温度、功耗。

**events**：
- 首选 `user/test.csv`：标准 CSV（字段：Record Time Stamp, Severity Level, SensorTypeStr, SensorName, Event Dir, Event Occurred Time, DescInfo, Explanation, Suggestion）。注意其含 `\x00` 空字节，读取时用二进制读入后按 UTF-8 解码并去掉空字节。
- 兜底 `.sbe`：二进制读入，按 ASCII/UTF-8 提取可读字符串段（事件记录以 `?` 分隔的可见文本），还原"传感器名+事件描述"列表（时间戳不可靠则标未知）。
- `visible.log`：操作日志，提取登录/开关机/盘插拔等关键动作，作为上下文附在报告末尾。

**health（核心判定规则）**：
- 双来源交叉：**事件证据**（CSV 中 Major/Critical/特定 Minor 告警，按 SensorName/DescInfo 归因到组件）+ **清单状态字段**（hardware_info.ini 的 Status、sensor 状态、hardware.info 的 Present）。
- 组件分类与规则：
  - 硬盘/盘槽：`Disk_*_Status` 的 "The disk is missing"/"Drive Fault"/"disk missing" → 异常；`hardware.info` Present=NO 且有历史 SN → 提示缺失
  - PCIe 卡/模块：`PCIe_*` 事件含 "Device Disabled"/"module information not obtained" → 异常；hardware_info 的 Status≠Normal → 异常
  - 电源：PSU "input lost (AC/DC)"、"Power Supply input lost" → 异常（附 AC 断电上下文）；PSU_Status/传感器状态异常 → 异常
  - 背板：`Raid_BP_Conf_Info.ini` 含 "Failed To Match" → 提示异常
  - 内存：`Memory is not certified` → 提示（认证问题，非故障）；`* has been replaced` → 变更记录
  - 风扇/温度：传感器状态非 ok / 转速异常 → 异常（注意采集时若主机待机，风扇 0 RPM 属正常，规则需排除待机态——以 Total_Power 低功耗判定待机）
  - 其余未匹配事件 → 汇总为"其他事件"，不强行归类
- 输出：每组件 → 状态（正常/异常/未知）+ 依据（事件原文列表：时间、级别、描述，最多 N 条）+ 建议。

**修复建议规则**：优先级 1）CSV 自带 `Suggestion` 列（官方建议原文）；2）按事件关键词映射补充：盘缺失→重新安装/更换、PCIe module not obtained→重新插拔/换槽验证/更换、PSU input lost→检查 AC 输入/电源线/更换 PSU、AC lost→检查市电/插排/PSU 保护、内存 not certified→更换认证型号等；3）无匹配 → "联系技术支持/结合现场判断"。

**report**：Markdown 章节：`# 服务器体检报告`（机器标识 + 采集时间）→ `## 1. 整机信息`（表格）→ `## 2. 硬件健康状态`（表格：组件/状态/依据摘要）→ `## 3. 异常详情`（每个异常组件小节：事件列表）→ `## 4. 修复建议`（组件→建议）→ `## 5. AI 综合分析`（仅 --ai 且调用成功时）→ `## 附录`（操作日志摘录、其他事件、固件版本、传感器概要）。控制台打印：异常组件数 + 异常组件清单 + 报告路径。

**ai**：
- **材料包（默认，当前会话模式）**：每次运行调用 `build_ai_payload(inv, health, events)` 生成"事实 + 任务指令"文本，写入 `<basename>-ai-facts.md`——用户可直接把该文件内容贴给当前会话 AI 做综合总结（不调任何 API）
- **后端自动（`--ai`）**：开启后读取环境变量；缺 `SDS_AI_BASE_URL` 时打印提示并跳过（不报错）。以同一 payload 作为请求 content 调用 `{base_url}/chat/completions`，要求模型仅基于给定事实输出：① 异常链路推断（按时间线串联）；② 根因候选排序；③ 可执行的排查步骤。输出以 Markdown 写入报告 `## 5` 章节。调用失败（网络/HTTP 非 200/无 content）→ 跳过并打印原因，不中断报告。

### CLI

```
python sds_parser.py <input.sds> [-o output.md] [--ai] [--no-cleanup] [--verbose]
```
- 缺 `-o`：输出到输入同目录 `<basename>-report.md`
- **每次运行默认额外产出 `<basename>-ai-facts.md`（AI 分析材料包）**，供当前会话 AI 做综合总结
- `--ai`：启用后端自动模式，把 AI 综合分析写入报告（需配置 `SDS_AI_*` 环境变量；未配置自动跳过）
- `--no-cleanup`：保留解包临时目录便于调试
- `--verbose`：打印解析细节

## 验收标准

- 用附件样例（`c:\Users\ganxin01\.trae-cn\attachments\561c8ecb-f478-478c-a9b8-c0e9250fb527_035beacd-9c0e-42d3-93a4-39ccbe348f36_HDM210235A566526AN0000P_20261118.sds`）运行：
  1. 报告生成成功，四章节齐全
  2. 整机信息正确：H3C UniServer R4930 G5 H3、SN、BIOS 5.97、HDM 3.66 等
  3. 健康状态正确：F23 槽位/相关 HBA（PCIe slot 3）被标为**异常**，依据含 "Device Disabled: PCIe module information not obtained" 与 "The disk is missing"/"Drive Fault"；电源被标异常（含 input lost 事件依据）；其余正常组件不被误报
  4. 修复建议含：HBA 重插/换槽/更换、电源检查 AC/PSU 等
- 容错：把 `test.csv` 删掉重跑 → 走 `.sbe` 兜底仍能产出报告（硬盘异常仍可识别）；传入非 tar 文件 → 友好报错退出
- AI 降级：不配置 `SDS_AI_*` 时加 `--ai` 运行 → 报告正常生成、AI 章节缺失且控制台有明确提示；配置了不可达的 `SDS_AI_BASE_URL` → 跳过 AI 章节、打印失败原因、不中断
- 材料包：运行样例后，同目录生成 `<basename>-ai-facts.md`，内容含机器信息、异常组件（F23/HBA）、证据事件原文与分析任务指令（异常链路推断/根因排序/排查步骤）
- 零第三方依赖：仅标准库可运行（`python sds_parser.py --help` 正常）

## 设计决策记录（我的决定，可推翻）

- **语言 Python**（用户选定）、**输出 Markdown**（用户选定）
- **AI 参与程度**：规则为主 + AI 增强（用户选定）；事实章节由规则保证，AI 只做综合分析
- **AI 双模式**（用户确认）：① 当前会话模式——默认产出 `<basename>-ai-facts.md` 材料包供会话 AI 使用，零外部依赖；② 后端自动模式（`--ai`）——OpenAI 兼容 API 自动写入报告。共用 `build_ai_payload` 同一份事实结构
- **事件来源优先级**：`test.csv`（可读、含 Suggestion 列）> `.sbe` 字符串兜底；若两者皆无 → 事件章节标注"无事件数据"
- **健康判定采用"事件证据 + 状态字段"双来源**：避免单来源误判（如待机态风扇 0 RPM、PSU Output Abnormal 属正常）
- **文本编码双策略（UTF-8 → GBK 回退）**：构建者检查提出，我拍板采用（防中文 HDM 导出乱码）
- **bios.json/hdm.json 仅作整机信息补充来源**：构建者检查提出，我拍板采用（不新增独立解析模块，复用 inventory 的固件/机器信息提取）
- **`.sbe` 兜底为尽力而为**：基于本机样例观察（`?` 分隔 + 可读字符串），准确度不保证
- **临时目录用后清理**，`--no-cleanup` 调试口子
- **规则集中在 `sds_health.py`**：后续新增厂商/机型判定逻辑只改这一处

## 交给实现者（Left to the builder）

- 各解析器的健壮性细节：INI 段缺失、空文件（如 nvme_info.ini 为 0 字节）、编码异常等的容错方式
- 报告 Markdown 的排版细节（表格列宽、事件条数上限 N 的取值）
- `tests/run_tests.py` 的用例组织方式（可指向真实样例路径或内置小 fixture）
