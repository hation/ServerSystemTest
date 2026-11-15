# 一键压测入口（oneclick.sh）实现计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 新增 `offline-stress-pkg/oneclick.sh`：一次选择即完成“自动挂载 → 每块数据盘一个终端窗口 → 系统盘/CPU/内存 → 等待结束 → 自动逐个 review 并汇总”，并给 `disk-mount.sh` 加 `--yes` 非交互开关。

**Architecture:** `oneclick.sh` 只做编排，不碰压测逻辑：写 `plan.txt` → 逐条经终端/后台调起内部子命令 `__task` → `__task` 调 `stress-test.sh start` 并把结果目录写成就绪标记 → 主终端轮询 `status.txt` → 调 `stress-test.sh review --dir` 汇总。任务与结果目录的对应关系全部落在批次目录的文本文件里，`status` / `review` 复用同一份 `tasks.txt`。

**Tech Stack:** Bash 4+（Kylin V10 SP3）、stress 1.0.4（已内置）、gnome-terminal / mate-terminal / xterm（任一可用即可）、WSL bash 作为测试环境。

**Spec:** `docs/superpowers/specs/2026-11-15-oneclick-stress-design.md`

## Global Constraints

- 默认超时 `10h`；`--timeout` 只接受 `数字+可选 d/h/m/s`，非法即退出 1。
- 任务固定顺序：数据盘（`HDD01..nn`，按名称排序）→ 系统盘（`SYSDISK`）→ CPU → 内存（`MEM`）。
- 窗口标题：`压测-HDDxx`、`压测-系统盘`、`压测-CPU`、`压测-内存`。
- 提权脚本调用固定为 `bash "$ST" start <type> --timeout <timeout> [extra...]`，只传 `--dirs` / `--sysdisk-only`。
- 不改 `stress-test.sh`（0 行改动）；`disk-mount.sh` 只加 `--yes`。
- 仅 bash 内建 + 现有系统命令，不新增运行期依赖；所有面向用户输出用中文。
- 不执行 `git commit`；每个任务以工作区 diff 交付。
- 测试接缝：`STRESS_TEST_ROOT`、`ONECLICK_STRESS_TEST_SH`、`ONECLICK_DISK_MOUNT_SH`、`ONECLICK_POLL_INTERVAL`、`ONECLICK_READY_TIMEOUT`、`ONECLICK_GUI`、`ONECLICK_NO_TAIL`、`ONECLICK_SKIP_ROOT_CHECK`（=1 跳过 root 检查，仅测试用）。
- 批次目录内落盘文件名固定：`plan.txt`、`tasks.txt`、`<id>.start.log`、`<id>.startrc`、`<id>.dir`、`<id>.fail`、`<id>.out`、`<id>.review.txt`、`mount.log`、`summary.txt`。
- 启动阶段失败（`ABORTED=1`）时，即使已启动任务复盘全部正常，最终退出码仍为 1。

## Review Focus

1. **非交互挂载**：`--yes` 只应跳过 y 确认，不得改变“选择盘/校验系统盘/已挂载跳过/无 tty 且无 `--disks` 报错”——由 Task 1 的 T1b 覆盖。
2. **无图形环境**：SSH/无 `DISPLAY` 时必须降级后台，不能报错——由 Task 2 的 T2d 覆盖。
3. **窗口命令拼装**：标题与 `__task` 参数必须各占一个 argv，`--dirs /mnt/HDD01` 不能被合并成一个参数——由 Task 2 的 T2b/T2c 覆盖。
4. **失败即停**：启动阶段任一任务失败后，后续任务不得再被调起——由 Task 2 的 T2e 覆盖。
5. **复盘汇总**：单任务结论异常或 review 失败都不得中断汇总，整体退出码为 1——由 Task 3 的 T3b 覆盖。

---

### Task 1: `disk-mount.sh --yes` 与测试库

**Files:**
- Modify: `offline-stress-pkg/disk-mount.sh`（用法 19-40、`cmd_mount` 参数解析 224-231、确认块 316-323）
- Create: `.superpowers/sdd/2026-11-15-oneclick-stress/tests/lib.sh`
- Create: `.superpowers/sdd/2026-11-15-oneclick-stress/tests/t1_disk_yes.sh`

**Interfaces:**
- Consumes: 无（首个任务）
- Produces:
  - `bash disk-mount.sh mount --disks <逗号列表|all> [--yes]`：带 `--yes` 时不读取 stdin，直接执行计划
  - `tests/lib.sh`：`setup_tmp`、`fake_bin <name> <content>`、`run_oc <out> <args...>`、`run_dm <out> <args...>`、`wait_file <path> [seconds]`、`check_out <want> <desc>`、`check_not_out <bad> <desc>`、`check_rc <want> <desc>`、`check_file <path> <desc>`、`check_term <regex> <desc>`（对 `$ROOT/term.txt` 按行 `grep -E`，用于断言窗口 argv）、`cleanup_case`、`finish`

- [ ] **Step 1: 写共享测试库**

创建 `tests/lib.sh`，提供：

```bash
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TEST_DIR/../../../.." && pwd)"
OC="$REPO_ROOT/offline-stress-pkg/oneclick.sh"
DM_SH="$REPO_ROOT/offline-stress-pkg/disk-mount.sh"
ST_SH="$REPO_ROOT/offline-stress-pkg/stress-test.sh"
# setup_tmp: ROOT=mktemp -d；FAKE=$ROOT/fake；FAKE_BIN=$ROOT/fakebin；
#            STRESS_TEST_ROOT=$ROOT/results；OUTF=$ROOT/out.txt
# fake_bin: 在 FAKE_BIN 下生成可执行假件
# run_oc: PATH="$FAKE_BIN:$PATH" STRESS_TEST_ROOT="${STRESS_TEST_ROOT:-$ROOT/results}"
#         ONECLICK_STRESS_TEST_SH=$FAKE/stress-test.sh
#         ONECLICK_DISK_MOUNT_SH=$FAKE/disk-mount.sh ONECLICK_POLL_INTERVAL=1
#         ONECLICK_READY_TIMEOUT=10 bash "$OC" "$@" > "$OUTF" 2>&1，记录 RC
# run_dm: PATH="$FAKE_BIN:$PATH" SKIP_ROOT_CHECK=1 MOUNT_LOG=$ROOT/mount.log \
#         LSBLK_BIN=lsblk BLKID_BIN=blkid bash "$DM_SH" "$@" > "$OUTF" 2>&1
```

断言函数沿用既有测试风格：`PASS/FAIL` 计数，失败打印 `FAIL [用例] 描述`，`finish` 有失败时退出 1。

- [ ] **Step 2: 写失败测试 `tests/t1_disk_yes.sh`**

假 `lsblk`（`sda` 系统盘 + `sdb` 空盘 + `sdc` 已挂载盘）、假 `blkid`（sdb 无文件系统）、假 `mount`/`mkfs.ext4`（记录 argv 到 `$ROOT/cmds.txt` 后退出 0）。用例：

```bash
CASE="T1a --yes 非交互执行"
run_dm "$OUTF" mount --disks all --yes
check_out '已挂载 sdb → /mnt/HDD01' '应执行挂载'
check_out '已挂载 sdc → /mnt/HDD02' '应执行挂载'
check_rc 0 '应退出 0'

CASE="T1b 无 --yes 无 tty → 取消"
run_dm "$OUTF" mount --disks all
check_out '已取消，未执行任何操作' '确认读取到 EOF 应取消'
check_not_out '已挂载' '不得执行挂载'

CASE="T1c --yes 但无 --disks 且无 tty → 报错"
run_dm "$OUTF" mount --yes
check_out '非交互模式（无终端）必须指定盘' '仍须要求 --disks'
check_rc 1 '应退出 1'

CASE="T1d 含系统盘仍拒绝"
run_dm "$OUTF" mount --disks sda --yes
check_out '拒绝：sda 是系统盘' '--yes 不得绕过系统盘校验'
```

- [ ] **Step 3: 运行测试确认失败**

Run: `bash .superpowers/sdd/2026-11-15-oneclick-stress/tests/t1_disk_yes.sh`
Expected: FAIL，`mount --yes` 报 `未知参数：--yes`。

- [ ] **Step 4: 实现 `--yes`**

`cmd_mount` 增加 `local assume_yes=0`，参数循环加：

```bash
--yes) assume_yes=1; shift ;;
```

把 316-323 行的确认块改为：

```bash
for c in "${chosen[@]}"; do ... done   # 计划打印与 DRY_RUN 保持不变
if [ "$DRY_RUN" != "1" ] && [ "$assume_yes" -ne 1 ]; then
    local ans=""
    printf "请确认执行以上计划（y/N）："
    IFS= read -r ans || true
    case "$ans" in
        y|Y) ;;
        *) echo "已取消，未执行任何操作"; exit 0 ;;
    esac
fi
```

用法与文件头注释补 `--yes`（“跳过 y 确认，供 oneclick.sh 调用”）。

- [ ] **Step 5: 运行测试确认通过**

Run: `bash .superpowers/sdd/2026-11-15-oneclick-stress/tests/t1_disk_yes.sh`
Expected: `ALL PASS`（4 个用例）。

- [ ] **Step 6: 语法与改动检查（不提交）**

Run: `bash -n offline-stress-pkg/disk-mount.sh && git diff --stat`
Expected: 无语法错误；diff 仅涉及 `disk-mount.sh` 与新增测试文件。

---

### Task 2: oneclick.sh 启动编排

**Files:**
- Create: `offline-stress-pkg/oneclick.sh`
- Create: `.superpowers/sdd/2026-11-15-oneclick-stress/tests/t2_menu.sh`
- Create: `.superpowers/sdd/2026-11-15-oneclick-stress/tests/t3_window.sh`
- Create: `.superpowers/sdd/2026-11-15-oneclick-stress/tests/t4_fallback.sh`
- Create: `.superpowers/sdd/2026-11-15-oneclick-stress/tests/t5_failfast.sh`

**Interfaces:**
- Consumes: Task 1 的 `disk-mount.sh mount --disks all --yes`；既有 `stress-test.sh start <type> --timeout T [--dirs D|--sysdisk-only]`（输出含 `已启动 <type> 压测：<结果目录>`）
- Produces:
  - `bash oneclick.sh [all|hdd|sysdisk|cpu|mem] [--timeout 10h]`、无参数进菜单、`--help`
  - `bash oneclick.sh __task <batch> <id> <timeout> <type> [extra...]`：`__task` 的落盘契约见 Global Constraints
  - 内部函数：`usage`、`die`、`now`、`pick_terminal`、`launch_task`、`wait_ready`、`collect_hdd_dirs`、`do_mount`、`precheck`、`write_plan`、`cmd_task`

- [ ] **Step 1: 写失败测试 `tests/t2_menu.sh`**

假终端 `gnome-terminal`：把每个 argv 单独一行追加到 `$ROOT/term.txt`，退出 0。假 `stress-test.sh` 的 `start` 立即输出 `已启动 $type 压测：$ROOT/results/fake-$type` 并 `mkdir -p` 该目录，退出 0。用例（`run_oc` 的 stdout 写 `$OUTF`，窗口 argv 看 `term.txt`）：

```bash
CASE="T2a 菜单 4 → CPU"
printf '4\n' | DISPLAY=:0 run_oc "$OUTF"
wait_file "$ROOT/term.txt"
check_term '压测-CPU' '窗口标题应为 压测-CPU'
check_term '^CPU$' '窗口命令应含 CPU 任务'
check_rc 0

CASE="T2b 非法菜单项后退出"
printf '9\n0\n' | DISPLAY=:0 run_oc "$OUTF"
check_out '无效选择' '应提示非法输入'
check_rc 0 '0 应正常退出'

CASE="T2c 用法文案"
run_oc "$OUTF" --help
check_out 'all|hdd|sysdisk|cpu|mem' '--help 应列出子命令'
check_out '--timeout' '--help 应列出 --timeout'
check_out '7) 生成复盘' '--help 应列出菜单项'

CASE="T2d 非法 --timeout"
DISPLAY=:0 run_oc "$OUTF" cpu --timeout 8x
check_out '--timeout 取值非法' '应报错'
check_rc 1
```

- [ ] **Step 2: 写失败测试 `tests/t3_window.sh`**

假终端同时提供 `gnome-terminal` 与 `xterm`（每个 argv 一行追加到 `term.txt`）。用例：

```bash
CASE="T3a xterm 拼装"
# 只放 xterm，不提供 gnome-terminal/mate-terminal
DISPLAY=:0 run_oc "$OUTF" cpu
wait_file "$ROOT/term.txt"
check_term '^-T$' 'xterm 应使用 -T'
check_term '^压测-CPU$' '标题应为独立 argv'
check_term '^-e$' 'xterm 应使用 -e'

CASE="T3b gnome-terminal 拼装与 --dirs 单参数"
# 假 df 输出 /mnt/HDD01、/mnt/HDD02；假 disk-mount.sh 退出 0；提供 gnome-terminal
DISPLAY=:0 run_oc "$OUTF" hdd
wait_file "$ROOT/term.txt"
check_term '^--title=压测-HDD01$' '第一块盘应有独立标题'
check_term '^--title=压测-HDD02$' '第二块盘应有独立标题'
check_term '^__task$' '窗口命令应调用内部子命令'
check_term '^--dirs$' '--dirs 应单独占一个 argv'
check_term '^/mnt/HDD01$' '盘路径应单独占一个 argv'
```

- [ ] **Step 3: 写失败测试 `tests/t4_fallback.sh`**

用例：

```bash
CASE="T4a 无 GUI 降级后台"
# PATH 不含任何终端程序，且 ONECLICK_GUI=0
ONECLICK_GUI=0 run_oc "$OUTF" cpu
check_out '未检测到图形终端' '应提示降级'
check_rc 0
wait_file "$STRESS_TEST_ROOT"/oneclick-*/CPU.dir
check_file "$STRESS_TEST_ROOT"/oneclick-*/CPU.dir '应写出就绪标记'

CASE="T4b 降级模式落 tasks.txt"
check_file "$STRESS_TEST_ROOT"/oneclick-*/tasks.txt '应写任务清单'
grep -q '^CPU|cpu|' "$STRESS_TEST_ROOT"/oneclick-*/tasks.txt && _pass 'tasks.txt 应含 CPU 任务' || _fail 'tasks.txt 缺少 CPU 任务'
```

- [ ] **Step 4: 写失败测试 `tests/t5_failfast.sh`**

假 `stress-test.sh`：每个任务把 id 追加到 `$ROOT/called.txt`；`start hdd --dirs /mnt/HDD01` 建目录并退出 0；`start hdd --sysdisk-only` 打印 `系统盘可用空间不足` 后退出 1；`review --dir` 打印 `结论: 正常`。假 `df` 返回一块数据盘 `/mnt/HDD01`，假 `disk-mount.sh` 退出 0。用例：

```bash
CASE="T5a 第二个任务失败 → 不启动第三个"
ONECLICK_GUI=0 run_oc "$OUTF" all
check_out '启动失败' '应打印失败原因'
check_out '已启动任务' '应打印已启动任务清单'
grep -qx 'SYSDISK' "$ROOT/called.txt" && _pass '系统盘任务应已尝试' || _fail '系统盘任务未被尝试'
grep -qx 'CPU' "$ROOT/called.txt" && _fail 'CPU 任务不应被启动' || _pass 'CPU 未被启动'
grep -qx 'MEM' "$ROOT/called.txt" && _fail '内存任务不应被启动' || _pass '内存未被启动'
check_rc 1
```

（`all` 的任务序列为 `HDD01 → SYSDISK → CPU → MEM`；让 `SYSDISK` 失败即可验证“后续 CPU/MEM 不再启动”。）

- [ ] **Step 5: 运行四个测试确认失败**

Run: `bash .superpowers/sdd/2026-11-15-oneclick-stress/tests/t2_menu.sh`
Expected: FAIL，`oneclick.sh` 不存在。

- [ ] **Step 6: 实现 `oneclick.sh`（启动编排）**

按以下结构实现（顺序即文件顺序）：

```bash
#!/bin/bash
# oneclick.sh —— 一键压测入口（菜单/子命令）
PKG_DIR="$(cd "$(dirname "$0")" && pwd)"
STRESS_TEST_ROOT="${STRESS_TEST_ROOT:-/root/stress-test}"
ST="${ONECLICK_STRESS_TEST_SH:-$PKG_DIR/stress-test.sh}"
DM="${ONECLICK_DISK_MOUNT_SH:-$PKG_DIR/disk-mount.sh}"
POLL_INTERVAL="${ONECLICK_POLL_INTERVAL:-30}"
READY_TIMEOUT="${ONECLICK_READY_TIMEOUT:-180}"
DEFAULT_TIMEOUT="10h"
```

1. `usage`：列出用法、7 个菜单项与 5 个运行子命令、`--timeout` 默认值与窗口/降级说明。
2. `now`、`die`（打印后 `exit 1`）。
3. `precheck`：root → `command -v stress` → `ST` / `DM` 存在。
4. `pick_terminal`：按 `ONECLICK_GUI`（0/1）、`DISPLAY`/`WAYLAND_DISPLAY` 与 `command -v` 顺序设 `TERM_KIND`（`gnome-terminal|mate-terminal|xterm|none`）。
5. `launch_task <id> <type> <extra>`：

```bash
local -a args=()
[ -n "$extra" ] && read -r -a args <<< "$extra"
local cmd="bash $(printf '%q' "$PKG_DIR/oneclick.sh") __task $(printf '%q' "$BATCH") $(printf '%q' "$id") $(printf '%q' "$TIMEOUT") $(printf '%q' "$type")"
local a
for a in "${args[@]}"; do cmd="$cmd $(printf '%q' "$a")"; done
case "$TERM_KIND" in
    gnome-terminal) gnome-terminal --title="$TITLE" -- bash -c "$cmd" >/dev/null 2>&1 & ;;
    mate-terminal)  mate-terminal  --title="$TITLE" -- bash -c "$cmd" >/dev/null 2>&1 & ;;
    xterm)          xterm -T "$TITLE" -e bash -c "$cmd" >/dev/null 2>&1 & ;;
    *)              ONECLICK_NO_TAIL=1 bash -c "$cmd" >> "$BATCH/$id.out" 2>&1 & ;;
esac
```

`TITLE` 由 `task_title <id>`：`HDD*` → `压测-<id>`，`SYSDISK` → `压测-系统盘`，`CPU` → `压测-CPU`，`MEM` → `压测-内存`。

6. `wait_ready <id>`：每 1 秒检查 `$BATCH/$id.dir` / `$BATCH/$id.fail`，最多 `READY_TIMEOUT` 秒；成功时把 `id|type|dir` 追加到 `tasks.txt`；失败时打印 `start.log` 末 20 行并返回 1。
7. `collect_hdd_dirs`：`df -P 2>/dev/null | awk 'NR>1 && $6 ~ /^\/mnt\/HDD[0-9]+$/ {print $6}' | sort -u`。
8. `do_mount`：`bash "$DM" mount --disks all --yes 2>&1 | tee "$BATCH/mount.log"`，退出码取 `PIPESTATUS[0]`。
9. `write_plan <mode>`：生成 `plan.txt`：
   - `all`：先挂载并枚举数据盘（`HDD01|hdd|--dirs /mnt/HDDxx`），再 `SYSDISK|hdd|--sysdisk-only`、`CPU|cpu|`、`MEM|mem|`
   - `hdd`：只写数据盘；无盘 → `die "未发现已挂载的数据盘（/mnt/HDD*），请先运行 bash disk-mount.sh mount"`
   - `sysdisk`：只写 `SYSDISK`
   - `cpu` / `mem`：只写对应一条
   - `all` 无数据盘 → 打印 `未发现数据盘，跳过数据盘任务` 后继续
10. `cmd_task <batch> <id> <timeout> <type> [extra...]`：

```bash
mkdir -p "$batch"
bash "$ST" start "$type" --timeout "$timeout" "$@" 2>&1 | tee "$batch/$id.start.log"
rc=${PIPESTATUS[0]}
echo "$rc" > "$batch/$id.startrc"
if [ "$rc" -ne 0 ]; then
    echo "启动失败（退出码 $rc）"
    : > "$batch/$id.fail"
    exit 1
fi
dir=$(sed -n 's/^已启动 .*压测：//p' "$batch/$id.start.log" | tail -1)
if [ -z "$dir" ]; then
    echo "无法从启动输出解析结果目录"
    : > "$batch/$id.fail"
    exit 1
fi
echo "$dir" > "$batch/$id.dir"
[ "${ONECLICK_NO_TAIL:-0}" = "1" ] && exit 0
...
```

`tail` 部分：优先 `tail -f --pid="$(cat "$dir/monitor.pid")" "$dir/monitor.csv"`，无 `monitor.pid` 时 `tail -f "$dir/monitor.csv"`；结束后打印 `压测已结束，结果目录：$dir`，并 `read -r _` 等回车（窗口保持）。

11. `run_mode <mode>`：`precheck` → 建批次目录（同秒冲突追加 `-1`、`-2`）→ `pick_terminal` → `write_plan` → 顺序读 `plan.txt` 调 `launch_task` 并 `wait_ready`；任一失败打印 `已启动任务：<id,...>` 并设 `ABORTED=1`、`break`。
    - `TERM_KIND=none` 时打印一次 `未检测到图形终端，改为后台并行执行；实时数据：tail -f <结果目录>/monitor.csv`。
    - 本任务结束时打印 `已启动 N 个任务（批次目录：$BATCH）`；`ABORTED=1` 或 `N=0` 时 `exit 1`，否则 `exit 0`（等待与复盘由 Task 3 接上）。
12. 参数解析与分发：`--timeout` 先解析；`__task` 走 `cmd_task`；`status`/`review` 先留 `echo "下一步实现"` 占位（Task 3 替换）；无模式 → 菜单循环 `read -r`，`0`/EOF 退出。

- [ ] **Step 7: 运行四个测试确认通过**

Run: `for t in t2_menu t3_window t4_fallback t5_failfast; do bash .superpowers/sdd/2026-11-15-oneclick-stress/tests/$t.sh || exit 1; done`
Expected: 四个测试均 `ALL PASS`。

- [ ] **Step 8: 语法检查（不提交）**

Run: `bash -n offline-stress-pkg/oneclick.sh && git status --short`
Expected: 无语法错误。

---

### Task 3: 完成等待、自动复盘与 status/review

**Files:**
- Modify: `offline-stress-pkg/oneclick.sh`（`run_mode` 尾部、`status`/`review` 分发）
- Create: `.superpowers/sdd/2026-11-15-oneclick-stress/tests/t6_finish.sh`

**Interfaces:**
- Consumes: Task 2 的 `tasks.txt`（`id|type|dir`）、`BATCH`、`POLL_INTERVAL`
- Produces:
  - `task_done <dir>` → 0/1
  - `wait_all` → 全部完成后返回
  - `run_review_all` → 生成 `$BATCH/summary.txt`，全“正常”返回 0，否则 1
  - `bash oneclick.sh status`、`bash oneclick.sh review`

- [ ] **Step 1: 写失败测试 `tests/t6_finish.sh`**

假 `stress-test.sh`：`start` 建结果目录并立即写 `status.txt`（`state=OK`）、`stress.pids`（1 行不存在 PID）、`stress.exitcode`（`0`）、`monitor.csv`；`review --dir` 打印 `结论: 正常`（可按 `$FAKE_REVIEW_BAD` 输出 `结论: 异常（退出码非 0）`）；`status` 打印 `无运行中的压测`。用例：

```bash
CASE="T3a 全部完成 → 汇总退出 0"
ONECLICK_GUI=0 run_oc "$OUTF" cpu
check_out '==== 一键压测汇总 ====' '应打印汇总'
check_out '结论' '汇总应含结论列'
check_file "$STRESS_TEST_ROOT"/oneclick-*/summary.txt '应落盘 summary.txt'
grep -qE '^CPU +cpu +正常$' "$STRESS_TEST_ROOT"/oneclick-*/summary.txt && _pass 'CPU 结论应为正常' || _fail 'CPU 结论不为正常'
check_rc 0

CASE="T3b 某任务异常 → 汇总退出 1 且其余仍有结论"
FAKE_REVIEW_BAD=MEM ONECLICK_GUI=0 run_oc "$OUTF" all   # 假 df 一块盘
check_out '异常（退出码非 0）' '应记录异常结论'
grep -qE '^HDD01 +hdd +正常$' "$STRESS_TEST_ROOT"/oneclick-*/summary.txt && _pass '其余任务仍应复盘' || _fail '其余任务缺少结论'
check_rc 1

CASE="T3c status 无批次"
STRESS_TEST_ROOT="$ROOT/empty" run_oc "$OUTF" status
check_out '无运行中的压测' '应回退 stress-test.sh status'
check_rc 0

CASE="T3d review 有批次"
ONECLICK_GUI=0 run_oc "$OUTF" cpu
run_oc "$OUTF" review
check_out '==== 一键压测汇总 ====' 'review 应重新生成汇总'
check_rc 0
```

- [ ] **Step 2: 运行测试确认失败**

Run: `bash .superpowers/sdd/2026-11-15-oneclick-stress/tests/t6_finish.sh`
Expected: FAIL，无汇总输出。

- [ ] **Step 3: 实现等待与复盘**

1. `task_done <dir>`：`status.txt` 存在 → 0；否则 `stress.pids` 存在且 `pids>0`、存活数为 0、`*.exitcode` 数 ≥ pids 数 → 0；其余 1。
2. `wait_all`：循环对 `tasks.txt` 每行判断，未完成数 >0 时打印 `[$(now)] 进行中 N 个：<id,...>` 并 `sleep "$POLL_INTERVAL"`，全部完成退出循环。
3. `run_review_all`：

```bash
: > "$BATCH/summary.txt"
{
    echo "==== 一键压测汇总 ===="
    echo "批次目录: $BATCH"
    echo "开始时间: $START_TIME"
    echo "结束时间: $(now)"
    echo "超时: $TIMEOUT"
    echo ""
    printf '%-10s %-8s %s\n' '任务' '类型' '结论'
} >> "$BATCH/summary.txt"
bad=0
# 逐行读 tasks.txt：id|type|dir
bash "$ST" review --dir "$dir" > "$BATCH/$id.review.txt" 2>&1
concl=$(sed -n 's/^结论: //p' "$BATCH/$id.review.txt" | head -1)
[ -n "$concl" ] || concl="未知（见 $id.review.txt）"
printf '%-10s %-8s %s\n' "$id" "$type" "$concl" >> "$BATCH/summary.txt"
case "$concl" in 正常) ;; *) bad=$((bad + 1)) ;; esac
# 末尾追加“结果目录:”清单后 cat summary.txt
[ "$bad" -eq 0 ]
```

4. `run_mode` 尾部：`wait_all` → `run_review_all`；`ABORTED=1` 或复盘有异常时 `exit 1`，否则 `exit 0`。
5. `status`：取 `ls -1d "$STRESS_TEST_ROOT"/oneclick-* | sort | tail -1`；无则 `exec bash "$ST" status`。有批次则逐行读 `tasks.txt` 打印 `id / type / 状态`（`task_done` 为真 → 已完成；`<id>.fail` 存在 → 启动失败；`<id>.dir` 存在 → 进行中；否则 启动中），最后执行 `bash "$ST" status`。
6. `review`：取最新批次；有 `tasks.txt` → 执行 `run_review_all` 并按其退出码退出；否则 `exec bash "$ST" review`。

- [ ] **Step 4: 运行测试确认通过**

Run: `bash .superpowers/sdd/2026-11-15-oneclick-stress/tests/t6_finish.sh`
Expected: `ALL PASS`（4 个用例）。

- [ ] **Step 5: 回归 Task 2 的四个测试**

Run: `for t in t2_menu t3_window t4_fallback t5_failfast t6_finish; do bash .superpowers/sdd/2026-11-15-oneclick-stress/tests/$t.sh || exit 1; done`
Expected: 全部 `ALL PASS`。

- [ ] **Step 6: 语法检查（不提交）**

Run: `bash -n offline-stress-pkg/oneclick.sh`
Expected: 无输出。

---

### Task 4: 文档、重打离线包与全量回归

**Files:**
- Modify: `offline-stress-pkg/README.md`（包结构 14-28、快速上手附近新增“一键压测”小节）
- Modify: `offline-stress-pkg/operation-manual.md`（第 2 节“快速上手”之后新增“一键全测（oneclick.sh）”）
- Modify: `docs/superpowers/notes/2026-11-15-oneclick-stress.md`（交付记录，新建）
- Regenerate: `offline-stress-pkg.zip`

**Interfaces:**
- Consumes: Task 1–3 的 `oneclick.sh` 与全部测试
- Produces: 更新后的 `offline-stress-pkg/` 与 `offline-stress-pkg.zip`

- [ ] **Step 1: 更新 README**

包结构代码块加入一行：

```
├── oneclick.sh                    一键压测入口（菜单/子命令：自动挂载+分窗+自动复盘）
```

新增小节 `## 4.1 一键压测（推荐）`（放在“4. 安装”之后、“5. 验证”之前），内容必须包含：

```bash
sudo bash oneclick.sh                # 菜单：1 全测 / 2 只测硬盘 / 3 只测系统盘 / 4 只测 CPU / 5 只测内存 / 6 查看状态 / 7 生成复盘
sudo bash oneclick.sh all --timeout 10h
sudo bash oneclick.sh hdd --timeout 8h
```

以及：全测顺序、每块数据盘一个窗口（标题 `压测-HDDxx`）、无图形环境自动降级后台、失败即停、结束后自动 review 汇总（`summary.txt`）。

- [ ] **Step 2: 更新 operation-manual.md**

在第 2 节之后插入 `## 2.1 一键全测（oneclick.sh）`，写明：

- 前置：`sudo bash install.sh` 与 `bash verify.sh`；
- `sudo bash oneclick.sh` → 选 `1`；
- 全测做的事（自动 `disk-mount.sh mount --disks all --yes` → 每盘一窗 → 系统盘 → CPU → 内存 → 等待 → 自动 review）；
- 窗口标题含义与“窗口关掉不影响压测（nohup 后台）”；
- 无图形环境（SSH）自动降级；如何强制：`ONECLICK_GUI=0 sudo -E bash oneclick.sh all`；
- 结果位置：`/root/stress-test/oneclick-<时间>/summary.txt` 与各任务结果目录；
- 原第 2 节手工流程保留，标注“分步执行时使用”。

- [ ] **Step 3: 重打离线包**

Run: `python3 .superpowers/sdd/2026-11-15-spec-driven-stress-params/pack_zip.py`
Expected: `条目数` 增加，`offline-stress-pkg/oneclick.sh` 虽未在脚本固定校验清单内，但 `sha256 MATCH` 行全部 MATCH；再用 `python3 -c "import zipfile;print([n for n in zipfile.ZipFile('offline-stress-pkg.zip').namelist() if 'oneclick' in n])"` 确认包含 `oneclick.sh`。

- [ ] **Step 4: 全量回归**

Run:

```bash
bash .superpowers/sdd/2026-11-15-oneclick-stress/tests/t1_disk_yes.sh
bash .superpowers/sdd/2026-11-15-oneclick-stress/tests/run-all.sh
bash .superpowers/sdd/2026-11-15-spec-driven-stress-params/tests/run-all.sh
bash -n offline-stress-pkg/oneclick.sh offline-stress-pkg/stress-test.sh offline-stress-pkg/disk-mount.sh
```

Expected: 新测试全 PASS；旧测试 t1/t2/t3 全 PASS；`bash -n` 无输出。

- [ ] **Step 5: 写交付记录**

新建 `docs/superpowers/notes/2026-11-15-oneclick-stress.md`，包含：改动文件清单、菜单/子命令用法、批次目录文件说明、测试结果（用例数与 PASS 数）、打包校验结果、遗留事项（root 桌面下终端拉起需现场验证一次）。

- [ ] **Step 6: 最终检查（不提交）**

Run: `git status --short && git diff --stat`
Expected: 仅涉及 `offline-stress-pkg/`、`docs/superpowers/`、`.superpowers/sdd/2026-11-15-oneclick-stress/` 与 `offline-stress-pkg.zip`。
