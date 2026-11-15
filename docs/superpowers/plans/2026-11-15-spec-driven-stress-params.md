# 压测参数按实测规格动态推导 实现计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 把 `stress-test.sh` 的 CPU/内存参数从“按机型查表”改为“按 `nproc`、`MemTotal`、实际 DIMM 根数推导”，保证 `--vm` 等于物理内存条根数且内存总量不超过 `MemTotal × 85%`。

**Architecture:** 在现有单文件 bash 脚本内新增三个纯函数层：CPU 推导、DIMM 探测、内存计划；`cmd_start` 只负责取值优先级和落盘。探测失败在创建结果目录前中止。所有行为通过假 `nproc` / `dmidecode` / EDAC / `/proc/meminfo` 离线验证。

**Tech Stack:** Bash 4+（Kylin V10 SP3）、stress 1.0.4（已内置）、dmidecode（运行期可选）、WSL bash 作为测试环境。

**Spec:** `docs/superpowers/specs/2026-11-15-spec-driven-stress-params-design.md`

## Global Constraints

- CPU：`workers = max(1, floor(nproc × 86%))`；显式 `--cpu` 直接使用。
- 内存：`目标 = MemTotal × 82%`，硬上限 `MemTotal × 85%`，`单 worker = round(目标 / 根数) GiB`，单 worker 不得 <1G。
- `--vm` 必须等于实际 DIMM 根数；探测顺序 `dmidecode -t 17` → EDAC；两者都失败且未显式传 `--vm` 时退出码 1，**不创建结果目录、不启动 stress**。
- 显式 `--vm` / `--vm-bytes` 优先；显式 `--vm-bytes` 超 85% 只告警不改写。
- 不改 `monitor.csv` 9 列格式；不改 `cmd_monitor_loop`、`write_status`、`cmd_review`、combo 的 hdd 启动方式、`--sysdisk` 语义。
- 仅使用 bash 内建 + 现有系统命令；不新增运行期依赖（dmidecode 缺失按失败路径处理）。
- 所有面向用户的输出用中文。
- 不执行 `git commit`（用户未要求）；每个任务以工作区 diff 交付。
- 测试接缝沿用并扩展：`MEMINFO_FILE`、`DF_BIN`、`DMESG_BIN`、`NPROC_BIN`、`DMI_BIN`、`EDAC_ROOT`。

## Review Focus

1. **dmidecode 输出格式差异**：`Size: 64 GB`、`Size: No Module Installed`、`Installed Size:` 混排时，只应统计已安装且容量为正数的槽位——由 Task 2 的 T2g 覆盖。
2. **显式参数组合**：`--vm`、`--vm-bytes` 单独或同时给出时，不得被静默改写；超 85% 必须告警——由 Task 2 的 T2l/T2m 覆盖。
3. **MemTotal 不可读**：自动推导必须中止；显式 `--vm-bytes` 必须告警后继续——由 Task 3 的 T3a/T3b 覆盖。
4. **根数与内存严重不匹配**：单 worker <1G 时必须干净报错，不留下结果目录或 stress 进程——由 Task 3 的 T3c 覆盖。
5. **combo 模式**：CPU/内存按新规则推导，hdd 的每盘启动逻辑保持原样——由 Task 3 的 T3d 覆盖。

---

### Task 1: 测试接缝与 CPU 推导

**Files:**
- Modify: `offline-stress-pkg/stress-test.sh`（环境变量区 17-23、用法 26-45、预设函数 52-55、机型解析 166-188、run-config 336-352）
- Create: `.superpowers/sdd/2026-11-15-spec-driven-stress-params/tests/lib.sh`
- Create: `.superpowers/sdd/2026-11-15-spec-driven-stress-params/tests/t1_cpu.sh`

**Interfaces:**
- Consumes: 无（首个任务）
- Produces:
  - `logical_cpus()` → stdout 整数（`$NPROC_BIN`，失败回退 `/proc/cpuinfo` 计数，再失败为 1）
  - `cpu_workers_auto()` → stdout 整数 `max(1, nproc*CPU_MAX_PCT/100)`
  - `nominal_threads(model)` → `5380→64`、`7360→96`、`7380→128`，其他输出空串
  - `check_model_threads(model, nproc)` → 无返回值；偏差 >10% 时打印中文提示并 `log_op`
  - 环境变量 `CPU_MAX_PCT`（默认 86）、`NPROC_BIN`（默认 nproc）
  - `run-config.txt` 新增行：`CPU 逻辑线程: <n>`、`CPU worker 数: <w>（nproc <n> × 86%）`；显式 `--cpu` 时写 `（显式 --cpu）`

- [ ] **Step 1: 写共享测试库**

创建 `tests/lib.sh`，提供：`setup_tmp`（mktemp + fake/out/run 目录）、`fake_bin <name> <content>`、`run_start <outfile> <args...>`（导出 `MEMINFO_FILE` / `NPROC_BIN` / `DMI_BIN` / `EDAC_ROOT` / `FAKE_DMI_FILE`，`PATH="$FAKE:$PATH"`，`STRESS_TEST_ROOT="$ROOT"`，`MONITOR_INTERVAL=1`）、`latest_dir <type>`、`check_cfg <text> <desc>`、`check_out <text> <desc>`、`cleanup_case`（调 `stop` 后清空 ROOT）、`finish`。默认假件：`stress` 为 `sleep 5` 的脚本，`nproc` 为 `echo 128`。

- [ ] **Step 2: 写失败测试 `tests/t1_cpu.sh`**

用例（全部用 `start cpu`）：

```bash
CASE="T1a nproc128→cpu110"
printf 'MemTotal:       526951212 kB\n' > "$FAKE/meminfo"
NPROC_BIN="$FAKE/nproc128" MEMINFO_FILE="$FAKE/meminfo" run_start "$OUTF" cpu
check_cfg '--cpu 110'           '128 线程应推导 110'
check_cfg 'CPU 逻辑线程: 128'     '未写入逻辑线程'
check_cfg 'nproc 128 × 86%'      '未标注推导依据'

CASE="T1b nproc96→cpu82"    # --cpu 82
CASE="T1c nproc64→cpu55"    # --cpu 55
CASE="T1d 显式--cpu 50"      # --cpu 50，含“（显式 --cpu）”，不含“× 86%”
CASE="T1e 机型校验"          # --model 7380 + nproc64：stdout 含“标称 128”与“疑似单路”
CASE="T1f 无dmidecode仍可跑cpu"  # DMI_BIN=/nonexistent，start cpu 仍成功生成 run-config
CASE="T1g 用法文案"          # 无参数运行时输出含“推导”且不含“按自动检测机型预设”
```

- [ ] **Step 3: 运行测试确认失败**

Run: `bash .superpowers/sdd/2026-11-15-spec-driven-stress-params/tests/t1_cpu.sh`
Expected: FAIL，`run-config.txt` 中没有 `CPU 逻辑线程:` 或 CPU worker 仍来自预设。

- [ ] **Step 4: 实现 CPU 推导与机型校验**

在公共工具区新增 `logical_cpus` / `cpu_workers_auto` / `nominal_threads` / `check_model_threads`；在 `cmd_start` 机型解析后，仅对 `cpu|mem|combo` 生效（`hdd` 不推导、不校验）：

```bash
local cpus=0 cpu_note=""
if [ "$type" != "hdd" ]; then
    cpus=$(logical_cpus)
    check_model_threads "$model" "$cpus"
    if [ -z "$cpu_opt" ]; then
        cpu_opt=$(cpu_workers_auto)
        cpu_note="（nproc ${cpus} × ${CPU_MAX_PCT}%）"
    else
        cpu_note="（显式 --cpu）"
    fi
fi
```

删除 `preset_cpu` 及调用；`preset_vm` / `preset_vm_bytes` 本任务保留，供内存旧路径使用。run-config 的 `cpu` / `mem` / `combo` 分支都写入 `CPU 逻辑线程:` 与 `CPU worker 数: ...` 两行（`hdd` 不写）。用法文案把 cpu 示例改为“按实测逻辑线程推导”。

- [ ] **Step 5: 运行测试确认通过**

Run: `bash .superpowers/sdd/2026-11-15-spec-driven-stress-params/tests/t1_cpu.sh`
Expected: `ALL PASS`

- [ ] **Step 6: 语法与改动检查（不提交）**

Run: `bash -n offline-stress-pkg/stress-test.sh && git diff --stat`
Expected: 无语法错误；diff 只包含本任务相关文件。

---

### Task 2: DIMM 探测与内存推导

**Files:**
- Modify: `offline-stress-pkg/stress-test.sh`（删除 `preset_vm`/`preset_vm_bytes` 52-55；新增探测/计划函数；`cmd_start` 结果目录创建前插入推导；run-config 336-352；info-before 354-365；operations.log）
- Create: `.superpowers/sdd/2026-11-15-spec-driven-stress-params/tests/t2_dimm_mem.sh`

**Interfaces:**
- Consumes: Task 1 的 `logical_cpus` / `cpu_workers_auto` / `check_model_threads`
- Produces:
  - `dimm_count_dmidecode()` → stdout 整数（0 表示无有效槽位）
  - `dimm_count_edac()` → stdout 整数
  - `dimm_count_auto()` → stdout 整数；设置全局 `DIMM_SOURCE`（`dmidecode`/`edac`/`none`）
  - `mem_plan(total_mb, workers)` → 成功返回 0 并设置 `PLAN_PER_GB`、`PLAN_TOTAL_GB`、`PLAN_TARGET_GB`；单 worker <1G 返回 1
  - 环境变量 `MEM_TARGET_PCT`（默认 82）、`DMI_BIN`、`EDAC_ROOT`
  - `run-config.txt` 新增：`内存条根数: <n>（来源: dmidecode|edac|显式 --vm）`、`单根容量: ...`、`内存目标: ...`、`内存分配上限: ...`
  - `info-before.txt` 新增 `==== dmidecode -t 17 ====` 与 `==== numactl -H ====` 两段
  - `operations.log` 新增 `mem-plan dimms=<n> source=<src> per=<x>G total=<y>G target=82% cap=85% ...`

- [ ] **Step 1: 写失败测试 `tests/t2_dimm_mem.sh`**

假 dmidecode 固定从 `$FAKE_DMI_FILE` 读取输出；EDAC 用 `mkdir -p "$FAKE/edac/mc0/dimm{0..15}"` 并写入 `size`（内容为 MB）。断言 `--vm`/`--vm-bytes` 与 run-config 字段：

```bash
# T2a 994.7GiB / 16×64GB → --vm 16 --vm-bytes 51G；内存目标: 816G；上限: 846G
# T2b 754.5GiB / 12×64GB → --vm 12 --vm-bytes 52G；内存目标: 624G
# T2c 1120.7GiB / 18×64GB → --vm 18 --vm-bytes 51G；内存目标: 918G
# T2d 502.5GiB / 16×32GB → --vm 16 --vm-bytes 26G；内存目标: 416G
# T2e 384GiB / 12×32GB   → --vm 12 --vm-bytes 26G；内存目标: 312G
# T2f 512GiB / 16×32GB   → --vm 16 --vm-bytes 26G；内存目标: 416G
# T2g DMI_BIN=/nonexistent + EDAC 16 根 → 成功，字段含“来源: edac”
# T2h DMI_BIN=/nonexistent + EDAC_ROOT 空目录 → 退出码 1，stdout 含“无法探测内存条根数”与“--vm”，ROOT 下无 *-mem 目录
# T2i 混合 4×32GB + 4×64GB（384GiB）→ --vm 8 --vm-bytes 39G；单根容量: 混合
# T2j info-before 含“==== dmidecode -t 17 ====”
# T2k operations.log 含“mem-plan dimms=16 source=dmidecode”
# T2l 502.5GiB 显式 --vm 8 → --vm 8 --vm-bytes 52G；来源“显式 --vm”
# T2m 502.5GiB 显式 --vm-bytes 54G → 不改写、告警“超过物理内存分配上限”、run-config 含“显式 --vm-bytes，超分配上限”
# T2n dmidecode 文本含 “Size: No Module Installed” 与 “Installed Size:” → 只计有效槽位
```

- [ ] **Step 2: 运行测试确认失败**

Run: `bash .superpowers/sdd/2026-11-15-spec-driven-stress-params/tests/t2_dimm_mem.sh`
Expected: FAIL（`--vm 16 --vm-bytes 54G` 或缺少新字段）。

- [ ] **Step 3: 实现探测与内存计划**

`dimm_count_dmidecode` 用 `LC_ALL=C awk -F:`，只匹配行首（可含空白）的 `Size:`，值匹配 `^[1-9][0-9]*[[:space:]]*(MB|GB|TB)`。`dimm_count_edac` 遍历 `$EDAC_ROOT/mc*/dimm*/size` 且内容 >0。`dimm_count_auto` 先 dmidecode 后 edac；`workers<1` 或 `>256` 视为失败并置 `DIMM_SOURCE=none`。

`mem_plan`（`workers<1` 直接返回 1，避免除零）：

```bash
[ "$workers" -ge 1 ] || return 1
target_mb=$(( total_mb * MEM_TARGET_PCT / 100 ))
per_gb=$(( (target_mb + workers * 512) / (workers * 1024) ))
[ "$per_gb" -lt 1 ] && return 1
cap_mb=$(( total_mb * MEM_MAX_PCT / 100 ))
while [ $(( per_gb * workers * 1024 )) -gt "$cap_mb" ] && [ "$per_gb" -gt 1 ]; do
    per_gb=$(( per_gb - 1 ))
done
[ $(( per_gb * workers * 1024 )) -gt "$cap_mb" ] && return 1
PLAN_PER_GB=$per_gb; PLAN_TOTAL_GB=$(( per_gb * workers )); PLAN_TARGET_GB=$(( target_mb / 1024 ))
```

在 `cmd_start` 中、`mkdir -p "$STRESS_TEST_ROOT"` 之前插入（仅 `mem|combo`）：

1. 显式 `--vm` → `vm_opt` 保留，`DIMM_SOURCE="显式 --vm"`；否则 `vm_opt=$(dimm_count_auto)`，为 0 或 `DIMM_SOURCE=none` 时打印失败文案并 `exit 1`。
2. 显式 `--vm-bytes` → 保留，`bytes_from_preset=0`；否则 `total_mb=$(mem_total_mb)`，为空则 `exit 1`（仅自动路径），否则 `mem_plan` 并回填 `vm_bytes_opt="${PLAN_PER_GB}G"`、`bytes_from_preset=1`。
3. 保留原裁剪块用于超限告警与“未超限”确认；自动路径下必然走“未超限”。
4. 写 `mem_*_desc`，供 run-config 使用，并在推导完成后 `log_op "mem-plan ..."`。

`内存目标` 一律写实际下发总量，理论值放括号：

```
内存目标: ${PLAN_TOTAL_GB}G（实际下发 ${vm_opt}×${PLAN_PER_GB}G；理论 MemTotal ${total_gb}G × ${MEM_TARGET_PCT}% ≈ ${PLAN_TARGET_GB}G）
```

`单根容量`：dmidecode 输出中所有有效容量一致时写该值（如 `64 GiB`）；不一致写 `混合（按总量均分）`；EDAC 或显式 `--vm` 未探测写 `均分 ${PLAN_PER_GB}G（MemTotal / 根数）` 或 `未探测`。

保留现有 `vm_from_preset` / `bytes_from_preset` 变量语义：值来自自动推导或旧预设时为 1，用户显式给出时为 0；原裁剪块据此继续工作，自动推导路径必然命中“未超限”分支。

info-before 两段用 `2>&1`；`numactl` 不存在时输出 `numactl 未安装`。用法文案同步把 mem 示例从“按 7380 预设”改为“按实测 MemTotal 与内存条根数推导”。

- [ ] **Step 4: 运行测试确认通过**

Run: `bash .superpowers/sdd/2026-11-15-spec-driven-stress-params/tests/t2_dimm_mem.sh`
Expected: `ALL PASS`

- [ ] **Step 5: 回归 Task 1 测试**

Run: `bash .superpowers/sdd/2026-11-15-spec-driven-stress-params/tests/t1_cpu.sh`
Expected: `ALL PASS`

- [ ] **Step 6: 语法检查（不提交）**

Run: `bash -n offline-stress-pkg/stress-test.sh`
Expected: 无输出（成功）。

---

### Task 3: 边界处理、combo 回归、文档与打包

**Files:**
- Modify: `offline-stress-pkg/stress-test.sh`（MemTotal 异常、单 worker <1G、根数上限）
- Modify: `offline-stress-pkg/operation-manual.md`
- Modify: `offline-stress-pkg/README.md`
- Modify: `offline-stress-pkg.zip`（重打）
- Create: `.superpowers/sdd/2026-11-15-spec-driven-stress-params/tests/t3_edge_combo.sh`
- Create: `.superpowers/sdd/2026-11-15-spec-driven-stress-params/tests/run-all.sh`

**Interfaces:**
- Consumes: Task 2 的 `dimm_count_auto` / `mem_plan` / run-config 字段
- Produces: 边界行为、文档、可分发压缩包、总测试入口

- [ ] **Step 1: 写失败测试 `tests/t3_edge_combo.sh`**

```bash
# T3a MemTotal 不可读 + start mem（自动）→ 退出码 1，stdout 含“MemTotal”，ROOT 无 *-mem
# T3b MemTotal 不可读 + start mem --vm-bytes 54G → 继续启动，run-config 含“未做内存裁剪”
# T3c 4GiB MemTotal + 16 根 → 退出码 1，stdout 含“单 worker 内存不足 1G”，ROOT 无 *-mem
# T3d start combo（无数据盘）→ --cpu 110 --vm 16 --vm-bytes 51G，且 stdout 含“无数据盘”
# T3e start hdd --dirs "" → 退出码 1，行为与改造前一致
# T3f 用法文案：含“MemTotal × 82%”与“内存条根数”
```

- [ ] **Step 2: 运行测试确认失败**

Run: `bash .superpowers/sdd/2026-11-15-spec-driven-stress-params/tests/t3_edge_combo.sh`
Expected: FAIL（单 worker <1G 未拦截或文案缺失）。

- [ ] **Step 3: 实现边界处理**

按设计 6.9 补齐：MemTotal 为空且自动路径 → 打印 `无法读取 MemTotal（/proc/meminfo），已中止` 并 `exit 1`；显式 `--vm-bytes` 路径沿用“未做内存裁剪”并继续。`mem_plan` 返回 1 时打印 `单 worker 内存不足 1G（MemTotal <X>G / <N> 根），无法压测` 并 `exit 1`。根数 >256 按探测失败处理。用法文案补上 `MemTotal × 82%` 与“内存条根数 = --vm”的说明（T3f 依赖）。

- [ ] **Step 4: 运行新增测试与全量测试**

Run: `bash .superpowers/sdd/2026-11-15-spec-driven-stress-params/tests/run-all.sh`
Expected: `t1 ALL PASS`、`t2 ALL PASS`、`t3 ALL PASS`

- [ ] **Step 5: 更新文档**

`operation-manual.md`：删除“机型预设表”的取值描述，改为推导规则（`floor(nproc×86%)`、`MemTotal×82%`、`--vm=DIMM 根数`、探测失败处理），附四种现场内存规格的回算表（502.5/754.5/994.7/1120.7 GiB）。

`README.md`：默认命令去掉 `--model` 依赖，说明 `--model` 仅用于报告标注与交叉校验。

- [ ] **Step 6: 重打离线包**

Run:

```powershell
Compress-Archive -Path 'C:\Users\ganxin01\Documents\trae-work\ServerSystemTest\offline-stress-pkg' -DestinationPath 'C:\Users\ganxin01\Documents\trae-work\ServerSystemTest\offline-stress-pkg.zip' -Force
```

校验：用 `[IO.Compression.ZipFile]::OpenRead(...)` 列出条目，必须包含 `offline-stress-pkg/stress-test.sh`、`offline-stress-pkg/operation-manual.md`、`offline-stress-pkg/rpms/stress-1.0.4-24.el8.x86_64.rpm`。

- [ ] **Step 7: 最终验证（不提交）**

Run: `bash -n offline-stress-pkg/stress-test.sh && bash .superpowers/sdd/2026-11-15-spec-driven-stress-params/tests/run-all.sh && git status --short`
Expected: 语法通过、三组测试全部 `ALL PASS`；改动只涉及计划内文件。
