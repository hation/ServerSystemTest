# 压测脚本内存预设与运行期取证修复 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 让 `stress-test.sh` 按物理内存自动裁剪内存预设、并发时不互抢内核日志、批次结束落盘机读状态，并让 `review` 能识别监控采样空洞。

**Architecture:** 全部改动集中在单文件 `offline-stress-pkg/stress-test.sh`（650 行 bash）：在 `cmd_start` 内插入内存裁剪三段分支；把 `cmd_monitor_loop` 的 `dmesg -c` 换成游标增量读取、把 `sleep` 换成可被信号打断的 `sleep & wait`、并在循环结束写 `status.txt`；`cmd_review` 优先读 `status.txt` 并按开始时间锚点算采样覆盖率。新增两个测试接缝环境变量（`MEMINFO_FILE`、`DMESG_BIN`），沿用现有 `DF_BIN` 模式。

**Tech Stack:** bash 4.x（Kylin V10 / WSL Ubuntu），无外部依赖；测试用 WSL + 假 `stress`/假 `dmesg` 二进制。

**Spec:** `docs/superpowers/specs/2026-11-15-stress-memory-guard-design.md`

## Global Constraints

- 只改 `offline-stress-pkg/stress-test.sh` 与 `offline-stress-pkg/operation-manual.md`；不改 `disk-mount.sh`/`mount-iso.sh`/`usb-eject.sh`，不改 `.superpowers/sdd/2026-11-13-combo-stress-testing/zipcheck/` 下的历史快照。
- `monitor.csv` 必须保持 9 列不变：`时间,load1,cpu_usage%,mem_total,mem_used,mem_avail,swap_used,disk_read_MBps,disk_write_MBps`。
- `MEM_MAX_PCT` 默认 **85**；它是“分配上限”，不得与解读方案的 80% 达成阈值混用。
- 显式 `--vm-bytes` 一律不裁剪；显式 `--vm` 一律不改 worker 数。
- 旧结果目录（无 `status.txt`、无 `.dmesg.cursor`）必须仍能被 `review` 处理，走原判定逻辑。
- 脚本全程不 `set -e`；保持现有中文输出风格。
- 禁止 commit（用户未要求提交），改动只落工作区。

## Review Focus

- **MemTotal 读不到或格式异常**（容器、`/proc` 被替换）：`mem_total_mb` 返回空时，`start mem` 必须照常启动（跳过裁剪并提示），不得因算术错误退出或把 `--vm-bytes` 变成 `G`。
- **`--vm-bytes` 用 K/M 单位**（如 `256M`）：`parse_size_mb` 必须正确换算；换算后不超限时不得改写原文本。
- **monitor 在 stop 时被 TERM**：必须在 2 秒内写 `status.txt=STOPPED`，否则人工停止会被误判成 `ABORTED`。
- **`dmesg` 无权限**（`kernel.dmesg_restrict=1`）：只读探测失败时整段跳过，`status.txt` 仍要写，`review` 仍要给结论。
- **旧目录 review**：没有 `status.txt`/`.dmesg.cursor` 时不得报错，覆盖率按旧语义给出且不崩溃。

---

### Task 1: 内存预设按 MemTotal 裁剪

**Files:**
- Modify: `offline-stress-pkg/stress-test.sh`（常量与工具函数区 17-20 行后；`cmd_start` 155-159 行附近；`run-config` 写入段 250-267 行）
- Test: `.superpowers/sdd/2026-11-15-stress-memory-guard/tests/t1_mem_clamp.sh`

**Interfaces:**
- Produces: 环境变量 `MEM_MAX_PCT`（默认 85）、`MEMINFO_FILE`（默认 `/proc/meminfo`）；函数 `mem_total_mb() -> 整数 MB`、`parse_size_mb <size> -> 整数 MB 或空串`。
- Produces: `run-config.txt` 新字段 `内存分配上限:` 与 `内存需求:`（`combo`/`mem` 类型才有）。

- [ ] **Step 1: 写失败测试**

创建 `.superpowers/sdd/2026-11-15-stress-memory-guard/tests/t1_mem_clamp.sh`（`set -u`；`PKG` 指向 `offline-stress-pkg`；假 `stress` 放 `FAKE/stress`，内容为 `#!/bin/bash` + `sleep 5`；每个用例前清空 `STRESS_TEST_ROOT`）：

```bash
# 用例1：502G 机器，全预设 → 期望 16×26G
printf 'MemTotal:       526951212 kB\n' > "$FAKE/meminfo-502g"
MEMINFO_FILE="$FAKE/meminfo-502g" PATH="$FAKE:$PATH" STRESS_TEST_ROOT="$ROOT" \
  bash "$PKG/stress-test.sh" start mem > "$OUT/t1a.txt" 2>&1
D=$(ls -1d "$ROOT"/*-mem | tail -1)
grep -q -- '--vm 16 --vm-bytes 26G' "$D/run-config.txt"   # 必须命中
grep -q '已裁剪' "$D/run-config.txt"
grep -q '内存分配上限: 427G' "$D/run-config.txt"

# 用例2：1024G 机器，全预设 → 不裁剪
printf 'MemTotal:      1073741824 kB\n' > "$FAKE/meminfo-1024g"
MEMINFO_FILE="$FAKE/meminfo-1024g" ... start mem
grep -q -- '--vm 16 --vm-bytes 54G' "$D/run-config.txt"
grep -q '未超限' "$D/run-config.txt"

# 用例3：502G + 显式 --vm-bytes 54G → 不裁剪 + 警告
... start mem --vm-bytes 54G
grep -q -- '--vm-bytes 54G' "$D/run-config.txt"
grep -q '超过物理内存分配上限' "$OUT/t1c.txt"
grep -q '显式 --vm-bytes，超分配上限' "$D/run-config.txt"

# 用例4：502G + 显式 --vm 32 → 不改 worker 数，字节降为 13G
... start mem --vm 32
grep -q -- '--vm 32 --vm-bytes 13G' "$D/run-config.txt"

# 用例5：MemTotal 为空 → 不裁剪、不崩
printf 'MemTotal: n/a\n' > "$FAKE/meminfo-bad"
... start mem; grep -q -- '--vm-bytes 54G' "$D/run-config.txt"

# 用例6：K/M 单位不超限 → 原文本保持不变
... start mem --vm 4 --vm-bytes 256M
grep -q -- '--vm 4 --vm-bytes 256M' "$D/run-config.txt"
grep -q '未超限' "$D/run-config.txt"
```
每个用例后 `bash "$PKG/stress-test.sh" stop` 并清空 `ROOT`。脚本以 `FAILED`/`ALL PASS` 汇总，任一断言失败 `exit 1`。

- [ ] **Step 2: 运行测试确认失败**

Run: `wsl -e bash -lc 'cd /mnt/c/Users/ganxin01/Documents/trae-work/ServerSystemTest && bash .superpowers/sdd/2026-11-15-stress-memory-guard/tests/t1_mem_clamp.sh'`
Expected: FAIL，`run-config.txt` 中仍是 `--vm-bytes 54G`，且无 `内存分配上限` 行。

- [ ] **Step 3: 实现**

1. 常量区（`DF_BIN` 之后）新增：

```bash
MEM_MAX_PCT="${MEM_MAX_PCT:-85}"
MEMINFO_FILE="${MEMINFO_FILE:-/proc/meminfo}"
```

2. 公共工具区新增两个函数：

```bash
mem_total_mb() { awk '/^MemTotal:/{if($2 ~ /^[0-9]+$/){printf "%d", $2/1024; exit}}' "$MEMINFO_FILE" 2>/dev/null; }

# 54G→55296 26G→26624 256M→256 1024→1024；无法解析输出空串
parse_size_mb() {
    local s="$1" n u
    n=$(printf '%s' "$s" | sed -n 's/^\([0-9]\+\)[KkMmGgTt]$/\1/p')
    [ -n "$n" ] || { case "$s" in ''|*[!0-9]*) return 0 ;; *) echo "$s"; return 0 ;; esac; }
    u=$(printf '%s' "$s" | sed -n 's/^[0-9]\+\([KkMmGgTt]\)$/\1/p' | tr 'kmgt' 'KMGT')
    case "$u" in K) echo $((n / 1024));; M) echo "$n";; G) echo $((n * 1024));; T) echo $((n * 1024 * 1024));; esac
}
```

3. `cmd_start` 参数解析处新增两个来源标志：在 `--vm`/`--vm-bytes` 分支里置 `vm_from_preset=0` / `bytes_from_preset=0`（两个局部变量初始值均为 1）。预设覆盖代码之后插入裁剪：

```bash
    # 内存分配上限裁剪（仅预设值；显式 --vm-bytes 只警告）
    local mem_cap_mb="" mem_need_mb="" mem_note="" mem_orig_desc=""
    if [ "$type" = "mem" ] || [ "$type" = "combo" ]; then
        local total_mb per_mb
        total_mb=$(mem_total_mb)
        per_mb=$(parse_size_mb "$vm_bytes_opt")
        if [ -z "$total_mb" ] || [ -z "$per_mb" ]; then
            echo "提示：无法读取 MemTotal 或解析 vm-bytes（$vm_bytes_opt），未做内存裁剪"
            mem_note="未裁剪（无法解析）"
        else
            mem_cap_mb=$(( total_mb * MEM_MAX_PCT / 100 ))
            mem_need_mb=$(( vm_opt * per_mb ))
            mem_orig_desc="$(( mem_need_mb / 1024 ))G"
            if [ "$mem_need_mb" -gt "$mem_cap_mb" ]; then
                if [ "$bytes_from_preset" -eq 1 ]; then
                    per_mb=$(( (mem_cap_mb / vm_opt) / 1024 * 1024 ))
                    if [ "$per_mb" -lt 1024 ]; then
                        if [ "$vm_from_preset" -eq 1 ]; then
                            vm_opt=$(( mem_cap_mb / 1024 )); [ "$vm_opt" -lt 1 ] && vm_opt=1
                        fi
                        per_mb=1024
                    fi
                    vm_bytes_opt="$(( per_mb / 1024 ))G"
                    ...
                else
                    echo "警告：内存需求 ${mem_orig_desc} 超过物理内存分配上限 $((mem_cap_mb/1024))G（MemTotal $((total_mb/1024))G × ${MEM_MAX_PCT}%），可能触发 OOM；按显式参数继续"
                    mem_note="显式 --vm-bytes，超分配上限"
                fi
            else
                mem_note="未超限"
            fi
        fi
    fi
```

   裁剪成功分支输出（stdout + `log_op`）：
   `已按物理内存裁剪内存预设：16×54G(864G) → 16×26G(416G)，分配上限 427G（MemTotal 502G × 85%）`；
   显式 `--vm` 分支输出 `已按物理内存裁剪单 worker 字节：54G → 13G（worker 数按显式 --vm 保持 32）`。
   `run-config` 的 `mem|combo` 分支追加 `内存分配上限: 427G（MemTotal 502G × 85%）` 与 `内存需求: ...`（按 `mem_note` 四选一，格式见 spec 5.1 第 5 条）。

- [ ] **Step 4: 运行测试确认通过**

Run: 同 Step 2
Expected: `ALL PASS`。

- [ ] **Step 5: 语法检查**

Run: `wsl -e bash -lc 'cd /mnt/c/Users/ganxin01/Documents/trae-work/ServerSystemTest && bash -n offline-stress-pkg/stress-test.sh && echo SYNTAX_OK'`
Expected: `SYNTAX_OK`。

---

### Task 2: `dmesg` 改为游标增量读取

**Files:**
- Modify: `offline-stress-pkg/stress-test.sh:565-568`（基线）、`:609-615`（每轮检测）
- Test: `.superpowers/sdd/2026-11-15-stress-memory-guard/tests/t2_dmesg.sh`

**Interfaces:**
- Consumes: Task 1 无依赖。
- Produces: 环境变量 `DMESG_BIN`（默认 `dmesg`）；批次目录下 `.dmesg.cursor`（内容为已处理行数）。

- [ ] **Step 1: 写失败测试**

假 `dmesg` 脚本：把 `"$@"` 追加到 `$FAKE/dmesg.args`；输出 `$FAKE/dmesg.buf` 的全部内容；`buf` 预置 5 行历史 OOM；测试运行中向 buf 追加 1 行新 OOM。

```bash
# 用例1：两个批次并发，全部调用都不带 -c
grep -c -- '-c' "$FAKE/dmesg.args"   # 必须为 0

# 用例2：历史 5 行不得写入新批次 error.log
grep -c 'dmesg:' "$D/error.log"      # 必须为 1（只记启动后的新行）
grep -q "$(tail -1 "$FAKE/dmesg.buf")" "$D/error.log"

# 用例3：dmesg 无权限（DMESG_BIN 指向 exit 1 的假命令）
# 期望：调用方不报错、error.log 无 dmesg 行、status.txt 仍生成
grep -q '^state=' "$D/status.txt"
! grep -q 'dmesg:' "$D/error.log"
```
（第二个批次同样断言；两个批次同时 start，`MONITOR_INTERVAL=1`，等待 3 秒后 `stop`。）

- [ ] **Step 2: 运行测试确认失败**

Run: `wsl -e bash -lc '... && bash .superpowers/sdd/2026-11-15-stress-memory-guard/tests/t2_dmesg.sh'`
Expected: FAIL（`dmesg.args` 中 `-c` 计数为 2）。

- [ ] **Step 3: 实现**

1. 常量区新增 `DMESG_BIN="${DMESG_BIN:-dmesg}"`。
2. 第 568 行替换为只读探测 + 游标初始化：

```bash
    dmesg_ok=1
    "$DMESG_BIN" >/dev/null 2>&1 || dmesg_ok=0
    local dmesg_cursor=0
    if [ "$dmesg_ok" -eq 1 ]; then
        dmesg_cursor=$("$DMESG_BIN" 2>/dev/null | wc -l)
        echo "$dmesg_cursor" > "$dir/.dmesg.cursor"
    fi
```

3. 第 609-615 行替换为增量读取：

```bash
        if [ "$dmesg_ok" -eq 1 ]; then
            local dmesg_total
            dmesg_total=$("$DMESG_BIN" 2>/dev/null | wc -l)
            [ "$dmesg_total" -lt "$dmesg_cursor" ] && dmesg_cursor=0
            dmesg_hits=$("$DMESG_BIN" 2>/dev/null | tail -n +$((dmesg_cursor + 1)) | grep -iE 'oom|out of memory|killed process|Killed')
            dmesg_cursor="$dmesg_total"
            echo "$dmesg_cursor" > "$dir/.dmesg.cursor"
            while IFS= read -r line; do
                [ -n "$line" ] && { echo "[$(now)] dmesg: $line" >> "$dir/error.log"; oom_seen=1; }
            done <<< "$dmesg_hits"
        fi
```

4. 循环前的局部变量声明加 `oom_seen=0`。

- [ ] **Step 4: 运行测试确认通过**

Run: 同 Step 2 → Expected: `ALL PASS`。

---

### Task 3: 结束状态落盘与可打断等待

**Files:**
- Modify: `offline-stress-pkg/stress-test.sh:565-571`（trap 与等待）、`:617-636`（结束判定）、`stop_one`（400-428 行）
- Test: `.superpowers/sdd/2026-11-15-stress-memory-guard/tests/t3_status.sh`

**Interfaces:**
- Consumes: Task 2 的 `oom_seen`。
- Produces: `$dir/status.txt`，字段固定为 `state=` / `reason=` / `pids=` / `exitcodes=` / `oom=` / `end_time=`（空格分隔，单行或分行皆可，但字段名不可改）。

- [ ] **Step 1: 写失败测试**

假 `stress` 支持三种模式（由 `FAKE_STRESS_MODE` 控制）：`exit0`（sleep 3 后 exit 0）、`kill-parent`（`kill -9 $PPID`，模拟被 OOM 杀且不留 exitcode）、`hang`（sleep 60）。

```bash
# 用例1：正常结束
FAKE_STRESS_MODE=exit0 ... start cpu; 等 5s
grep -q '^state=OK$' "$D/status.txt"

# 用例2：被 OOM 杀（假 dmesg 给一行 OOM）
FAKE_STRESS_MODE=kill-parent ... start mem --vm-bytes 1G
grep -q '^state=ABORTED$' "$D/status.txt"; grep -q '^reason=oom-killed$' "$D/status.txt"

# 用例3：stop 时 monitor 正卡在 sleep 30（MONITOR_INTERVAL=30）
FAKE_STRESS_MODE=hang ... start cpu; sleep 2
时间 bash "$PKG/stress-test.sh" stop      # 计时
grep -q '^state=STOPPED$' "$D/status.txt"
# 断言耗时 < 5 秒（monitor 在 2 秒内写出 status）
```
等待 `status.txt` 用 10×0.5s 轮询，超时判失败。

- [ ] **Step 2: 运行测试确认失败**

Expected: 失败（`status.txt` 不存在）。

- [ ] **Step 3: 实现**

1. `cmd_monitor_loop` 开头加 `local stop_flag=0` 与 `trap 'stop_flag=1' TERM`；主循环等待改为：

```bash
        sleep "$interval" & wait $! 2>/dev/null
        if [ "$stop_flag" -eq 1 ]; then
            write_status STOPPED manual-stop
            exit 0
        fi
```

2. 新增内部函数（monitor-loop 段内）：

```bash
write_status() {   # $1=state $2=reason
    local pc ecc
    pc=$(awk 'NF{n++} END{print n+0}' "$dir/stress.pids" 2>/dev/null)
    ecc=$(ls "$dir"/*.exitcode 2>/dev/null | wc -l)
    {
        echo "state=$1"
        echo "reason=$2"
        echo "pids=$pc exitcodes=$ecc"
        echo "oom=$([ "${oom_seen:-0}" -eq 1 ] && echo yes || echo no)"
        echo "end_time=$(now)"
    } > "$dir/status.txt"
}
```

3. 循环末尾用判定顺序（`STOPPED` 已在上方拦截）依次判 `FAILED` → `ABORTED(oom-killed)` → `ABORTED(missing-exitcode)` → `OK`，调用 `write_status`；原 `error.log` 追加逻辑保留。

4. `stop_one` 改为：先 `kill -TERM "$mpid"`，轮询 10 × 0.2s 等 `status.txt` 出现，未退则 `kill -KILL`；随后再按原逻辑停 stress。保持原有中文输出。

- [ ] **Step 4: 运行测试确认通过**

Expected: `ALL PASS`（含 stop 耗时断言）。

---

### Task 4: `review` 读 status.txt 并识别采样空洞

**Files:**
- Modify: `offline-stress-pkg/stress-test.sh:452-459`（覆盖率）、`:473-521`（结论与 summary）
- Test: `.superpowers/sdd/2026-11-15-stress-memory-guard/tests/t4_review.sh`

**Interfaces:**
- Consumes: Task 3 的 `status.txt` 字段名。
- Produces: `summary.txt` 新增 `运行状态:` 与 `采样空洞:` 两行。

- [ ] **Step 1: 写失败测试**

直接手工构造结果目录（不起进程，保证确定性）：

```bash
# 目录A：status=OK
mkdir -p "$ROOT/20261115-000001-cpu"; 写 run-config（开始时间=now-60s、超时=10h、监控间隔=30s）
写 monitor.csv 3 行（now-50s / now-20s / now）；写 status.txt state=OK reason=all-exitcode-zero
bash "$PKG/stress-test.sh" review --dir "$ROOT/20261115-000001-cpu"
grep -q '运行状态: OK' "$D/summary.txt"
grep -q '采样空洞: 无' "$D/summary.txt"

# 目录B：事故形态——开始时间=now-1800s，monitor.csv 只有 1 行（now）
grep -q '采样空洞: 是' "$D/summary.txt"
grep -qE '覆盖率 [0-9.]+%' "$D/summary.txt"    # 且数值 < 10

# 目录C：status=ABORTED reason=oom-killed
grep -q '异常（内存耗尽被内核杀死）' "$D/summary.txt"

# 目录D：无 status.txt（旧目录）+ 全部 exitcode=0
grep -q '正常' "$D/summary.txt"
```

- [ ] **Step 2: 运行测试确认失败**

Expected: FAIL（`summary.txt` 无 `运行状态` / `采样空洞` 行）。

- [ ] **Step 3: 实现**

1. 覆盖率：`start_epoch`（已有）与末行时间算 `span`；`expected=$(( span / interval ))`，`[ "$expected" -lt 1 ] && expected=1`；`coverage=$(( rows * 100 / expected ))`；`span` 为空或 `last_ts` 取不到 → `覆盖率=不可判定`。原 `duration`（首末行差）保留。
2. 结论：先读 `status.txt` 的 `state=`/`reason=` 映射成中文（`OK→正常`、`FAILED→异常（退出码非 0）`、`ABORTED+oom-killed→异常（内存耗尽被内核杀死）`、`ABORTED+missing-exitcode→异常（进程异常退出未留退出码）`、`STOPPED→已手动停止`）；文件缺失走原逻辑。
3. `summary.txt` 在“监控覆盖时长”后插入 `运行状态: ...` 与 `采样空洞: 是（...）/ 无（覆盖率 C%）`。

- [ ] **Step 4: 运行测试确认通过**

Expected: `ALL PASS`。

---

### Task 5: 手册同步与全量回归

**Files:**
- Modify: `offline-stress-pkg/operation-manual.md:229-245`
- Test: `.superpowers/sdd/2026-11-15-stress-memory-guard/tests/run-all.sh`

**Interfaces:**
- Consumes: Task 1-4 全部产出。

- [ ] **Step 1: 写回归聚合脚本**

`run-all.sh` 依次执行 `t1_mem_clamp.sh`、`t2_dmesg.sh`、`t3_status.sh`、`t4_review.sh`、`t5_regression.sh`，任一失败即 `exit 1`，最后跑 `bash -n` 与无参数用法检查（期望输出含 `用法:`），并打印 `ALL PASS`。

`t5_regression.sh` 覆盖 T10：假 `stress` 以 `exit0` 模式分别跑 `start cpu` 与 `start hdd --dirs "$FAKE/disk"`，断言 `run-config.txt` 命令行与原脚本一致（`--cpu 110` / `--hdd 1 --hdd-bytes 10G`）、`status.txt` 为 `OK`、`review` 结论为“正常”。

- [ ] **Step 2: 运行，确认 t1-t4 通过但用法检查未覆盖**

Expected: 四项 PASS；如需修改用法文本则此步不通过。

- [ ] **Step 3: 改手册**

- 预设表（229-231 行）下方加一段：`7380` 有 512G / 1024G 两种内存配置；脚本按 `MemTotal × 85%` 自动裁剪 `vm-bytes`（默认 `MEM_MAX_PCT=85`，可用环境变量调整）；显式 `--vm-bytes` 不裁剪只警告，显式 `--vm` 只裁单 worker 字节。
- 第 245 行“内存总量勿超物理内存”改写为指向自动裁剪机制，并注明 85% 是分配上限、不是验收门槛。
- 用法说明补 `MEMINFO_FILE`/`DMESG_BIN` 仅供测试，不需要写进用户手册。

- [ ] **Step 4: 全量回归**

Run: `wsl -e bash -lc 'cd /mnt/c/Users/ganxin01/Documents/trae-work/ServerSystemTest && bash .superpowers/sdd/2026-11-15-stress-memory-guard/tests/run-all.sh'`
Expected: `ALL PASS`。

- [ ] **Step 5: 用事故数据做一次人工核对**

Run: `wsl -e bash -lc '... && MEMINFO_FILE=<写入 526951212 kB 的文件> STRESS_TEST_ROOT=/tmp/st-verify bash offline-stress-pkg/stress-test.sh start mem'`
Expected: 输出含 `已按物理内存裁剪内存预设：16×54G(864G) → 16×26G(416G)`，`run-config.txt` 的 `命令:` 行是 `stress --vm 16 --vm-bytes 26G --timeout 10h`；随后 `stop` 清理。
