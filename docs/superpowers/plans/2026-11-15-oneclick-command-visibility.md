# 一键压测命令可见性 实现计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 让 `oneclick.sh` 把每条真实执行的命令（挂载、压测启动、复盘）在终端显示、可复制、可追溯，并把命令清单落盘为 `commands.txt` / `commands.sh` / `env.txt`。

**Architecture:** 以 argv 数组为唯一来源：`stress_argv` 构造参数数组，`cmd_line` 用 `printf '%q'` 派生显示串，`show_argv` 负责显示与落盘，执行时用同一个数组。显示开关 `SHOW_CMD` 默认开，`--quiet` 或 `ONECLICK_SHOW_CMD=0` 关闭，关闭不影响落盘；窗口通过环境变量继承该开关。

**Tech Stack:** bash（Kylin V10 SP3，离线），无新依赖；测试用假脚本替身（既有 `lib.sh` 风格）。

**Spec:** `docs/superpowers/specs/2026-11-15-oneclick-command-visibility-design.md`

## Global Constraints

- 仅 bash + 现有系统命令；不引入新依赖。
- 不改 `stress-test.sh` 行为与输出格式；不改 `disk-mount.sh`。
- 保留 `oneclick.sh` 既有全部输出文案行，只新增 `  $ <命令>` 与上下文行。
- 窗口命令串形态不变：`bash <PKG_DIR>/oneclick.sh __task <BATCH> <id> <timeout> <type> [extra...]`（既有测试正则锁定其结尾）。
- 所有命令参数一律经 `printf '%q'` 转义；`ST`/`DM` 使用前规范化为绝对路径。
- `--dirs` 支持含空格路径（plan.txt 每参数一个 `|` 字段；枚举保留挂载点原文并还原 `\040`；2026-11-15 修复）。
- 测试接缝语义不变：`STRESS_TEST_ROOT`、`ONECLICK_STRESS_TEST_SH`、`ONECLICK_DISK_MOUNT_SH`、`ONECLICK_POLL_INTERVAL`、`ONECLICK_READY_TIMEOUT`、`ONECLICK_GUI`、`ONECLICK_NO_TAIL`、`ONECLICK_SKIP_ROOT_CHECK`。
- 所有输出、注释、文档为中文。
- **不执行 git commit**（项目约束）；每个任务以测试全绿作为完成判据。SDD 控制者把完成记录写入 `.superpowers/sdd/2026-11-15-oneclick-command-visibility/progress.md`。

## Review Focus

- 命令显示与实际执行不一致（参数漏、顺序变、转义破坏）：用户会复制重跑得到不同行为。由 Task 2 的 C2 锁定。
- `--quiet` 只关了主终端、窗口仍刷命令：由 Task 3 的 C9 banner 断言锁定。
- 复盘命令在 `review` 子命令重复执行时无限追加：由 Task 2 的 C6 去重断言锁定。
- 安装目录含空格导致显示串或 `commands.sh` 复制后跑错：由 Task 1 的 C15 锁定。
- 启动失败时诊断命令被 `--quiet` 吞掉：由 Task 2 的 C12 锁定。

---

### Task 1: 命令显示基础设施与落盘

**Files:**
- Modify: `offline-stress-pkg/oneclick.sh`（头部常量、`usage`、新增显示/落盘函数、批次初始化、`do_mount`、`cmd_status`）
- Create: `.superpowers/sdd/2026-11-15-oneclick-command-visibility/tests/lib.sh`
- Create: `.superpowers/sdd/2026-11-15-oneclick-command-visibility/tests/t1_cmd_core.sh`
- Create: `.superpowers/sdd/2026-11-15-oneclick-command-visibility/tests/run-all.sh`

**Interfaces:**
- Consumes: 既有 `now`、`die`、`BATCH`、`ST`、`DM`。
- Produces（后续任务依赖）：
  - `cmd_line <argv...>` → 输出 `printf '%q'` 拼接后的单行字符串（stdout，无换行）
  - `show_argv <argv...>` → `SHOW_CMD=1` 时打印 `  $ <line>`；始终追加到 `$BATCH/commands.txt`
  - `show_once_argv <argv...>` → 同上但 `commands.txt` 按整行去重（`grep -Fxq`）
  - `record_sh <argv...>` → 追加到 `$BATCH/commands.sh`
  - `show_run <argv...>` = `show_argv` + `record_sh`
  - `write_env_file` → 生成 `$BATCH/env.txt`
  - 常量 `SHOW_CMD`（`0`/`1`）

- [ ] **Step 1: 复制测试骨架并写失败断言**

从 `.superpowers/sdd/2026-11-15-oneclick-stress/tests/lib.sh` 复制到新目录，保留全部断言函数，追加两个：

```bash
# 断言 commands.txt 含指定整行
check_cmd_file() {
    local want="$1" desc="$2"
    if grep -Fxq -- "$want" "$BATCH_OUT/commands.txt" 2>/dev/null; then _pass "$desc"
    else _fail "$desc（commands.txt 未含整行：$want）"; fi
}

# 断言文件行数
check_lines() {
    local file="$1" want="$2" desc="$3" got
    got=$(wc -l < "$file" 2>/dev/null | tr -d ' ')
    if [ "${got:-0}" = "$want" ]; then _pass "$desc"
    else _fail "$desc（行数 ${got:-0}，期望 $want）"; fi
}
```

`lib.sh` 中 `BATCH_OUT` 由用例设置（指向 `$STRESS_TEST_ROOT/oneclick-*` 唯一目录）。

`t1_cmd_core.sh` 用假 `stress-test.sh`（start 立即成功并写 `status.txt`、`stress.pids`、`stress.exitcode`、`monitor.csv`，输出 `已启动 <type> 压测：<dir>`）、假 `disk-mount.sh`（输出一行并退 0）、假 `df`、假 `stress`，`ONECLICK_GUI=0` 跑 `cpu`：

```bash
BATCH_OUT=$(ls -1d "$STRESS_TEST_ROOT"/oneclick-* | tail -1)

CASE="C3 挂载命令显示"
check_out "  \$ bash $FAKE/disk-mount.sh mount --disks all --yes" '应显示挂载命令'

CASE="C7 commands.sh"
check_file "$BATCH_OUT/commands.sh" 'commands.sh 应生成'
bash -n "$BATCH_OUT/commands.sh" && _pass 'commands.sh 语法通过' || _fail 'commands.sh 语法错误'
grep -Fq '#!/bin/bash' "$BATCH_OUT/commands.sh" && _pass '含 shebang' || _fail '缺 shebang'
grep -Fq '重新发起一轮压测' "$BATCH_OUT/commands.sh" && _pass '含重放警告' || _fail '缺重放警告'
grep -Fq 'disk-mount.sh mount --disks all --yes' "$BATCH_OUT/commands.sh" && _pass '含挂载命令' || _fail '缺挂载命令'
grep -Fq 'start cpu' "$BATCH_OUT/commands.sh" && _pass '含启动命令' || _fail '缺启动命令'
grep -Fq 'review' "$BATCH_OUT/commands.sh" && _fail 'commands.sh 不应含 review' || _pass '不含 review'
[ "$(stat -c %a "$BATCH_OUT/commands.sh")" = 644 ] && _pass '权限 0644' || _fail '权限非 0644'

CASE="C8 env.txt"
check_file "$BATCH_OUT/env.txt" 'env.txt 应生成'
for k in BATCH= MODE= TIMEOUT= STRESS_TEST_ROOT= TERM_KIND= SHOW_CMD=; do
    grep -Fq "$k" "$BATCH_OUT/env.txt" && _pass "env.txt 含 $k" || _fail "env.txt 缺 $k"
done

CASE="C13 status 有批次"
run_oc "$OUTF" status
check_out "查看本次执行过的命令：cat $BATCH_OUT/commands.txt" 'status 应提示命令清单'

CASE="C14 status 无批次"
mkdir -p "$ROOT/empty"
STRESS_TEST_ROOT="$ROOT/empty" run_oc "$OUTF" status
check_not_out '查看本次执行过的命令' '无批次不提示'

CASE="C15 安装目录含空格"
mkdir -p "$ROOT/pkg dir"
cp "$OC" "$ROOT/pkg dir/oneclick.sh"
cp "$FAKE/stress-test.sh" "$ROOT/pkg dir/stress-test.sh"
cp "$FAKE/disk-mount.sh" "$ROOT/pkg dir/disk-mount.sh"
PATH="$FAKE_BIN:$PATH" STRESS_TEST_ROOT="$ROOT/results3" ONECLICK_SKIP_ROOT_CHECK=1 \
ONECLICK_GUI=0 ONECLICK_POLL_INTERVAL=1 bash "$ROOT/pkg dir/oneclick.sh" cpu > "$OUTF" 2>&1
check_out "  \$ bash '$ROOT/pkg dir/stress-test.sh' start cpu" '含空格路径应被转义'

CASE="C16 路径规范化"
( cd "$ROOT" && PATH="$FAKE_BIN:$PATH" STRESS_TEST_ROOT="$ROOT/results2" \
  ONECLICK_STRESS_TEST_SH="fake/stress-test.sh" ONECLICK_DISK_MOUNT_SH="$FAKE/disk-mount.sh" \
  ONECLICK_SKIP_ROOT_CHECK=1 ONECLICK_GUI=0 bash "$OC" cpu ) > "$OUTF" 2>&1
check_out "  \$ bash $FAKE/stress-test.sh start cpu" '相对路径应规范化为绝对路径'

CASE="C17 --help"
bash "$OC" --help > "$OUTF" 2>&1
check_out '--quiet' '--help 应含 --quiet'
```

先运行，确认 FAIL（函数/文件尚不存在）。

- [ ] **Step 2: 运行确认失败**

Run: `bash .superpowers/sdd/2026-11-15-oneclick-command-visibility/tests/t1_cmd_core.sh`
Expected: 断言 FAIL（无 `  $ ` 行、无 commands.txt/commands.sh/env.txt）。

- [ ] **Step 3: 实现显示与落盘基础设施**

在 `oneclick.sh` 头部常量区加：

```bash
SHOW_CMD="${ONECLICK_SHOW_CMD:-1}"
[ "$SHOW_CMD" = "0" ] || SHOW_CMD=1
```

`ST`、`DM` 定义之后规范化绝对路径（相对路径用 `cd "$(dirname ...)" && pwd` 拼接；`precheck` 仍负责存在性检查）。

新增函数（放在 `now`/`die` 之后）：

```bash
cmd_line() { local s="" a; for a in "$@"; do [ -n "$s" ] && s="$s "; s="$s$(printf '%q' "$a")"; done; printf '%s' "$s"; }
show_argv()  { local l; l=$(cmd_line "$@"); [ "$SHOW_CMD" = "1" ] && printf '  $ %s\n' "$l"; [ -n "${BATCH:-}" ] && [ -d "$BATCH" ] && printf '%s\n' "$l" >> "$BATCH/commands.txt"; }
show_once_argv() { local l; l=$(cmd_line "$@"); [ "$SHOW_CMD" = "1" ] && printf '  $ %s\n' "$l"; if [ -n "${BATCH:-}" ] && [ -d "$BATCH" ]; then grep -Fxq -- "$l" "$BATCH/commands.txt" 2>/dev/null || printf '%s\n' "$l" >> "$BATCH/commands.txt"; fi; }
record_sh()  { local l; l=$(cmd_line "$@"); [ -n "${BATCH:-}" ] && [ -f "$BATCH/commands.sh" ] && printf '%s\n' "$l" >> "$BATCH/commands.sh"; }
show_run()   { show_argv "$@"; record_sh "$@"; }

write_env_file() {
    { echo "BATCH=$BATCH"; echo "MODE=$MODE"; echo "START_TIME=$START_TIME";
      echo "TIMEOUT=$TIMEOUT"; echo "STRESS_TEST_ROOT=$STRESS_TEST_ROOT";
      echo "STRESS_TEST_SH=$ST"; echo "DISK_MOUNT_SH=$DM"; echo "TERM_KIND=$TERM_KIND";
      echo "POLL_INTERVAL=$POLL_INTERVAL"; echo "READY_TIMEOUT=$READY_TIMEOUT";
      echo "SHOW_CMD=$SHOW_CMD"; } > "$BATCH/env.txt"
}
```

注意：`run_mode` 中 `MODE` 需设为模式名（`mkdir` 批次后赋值），`write_env_file` 在 `pick_terminal` 之后调用。

批次初始化（`mkdir -p "$BATCH"` 与 `START_TIME` 写入之后、`write_plan` 之前——`do_mount` 在 `write_plan` 内执行，必须先建好文件）：

```bash
MODE="$mode"
: > "$BATCH/commands.txt"
{ echo '#!/bin/bash'
  echo "# 由 oneclick.sh 生成：批次 $BATCH"
  echo "# 警告：执行本脚本会重新发起一轮压测，产生新的结果目录。"
  echo "# 复盘请用：bash $(printf '%q' "$ST") review --dir <新结果目录>"
  echo 'set -u'; } > "$BATCH/commands.sh"
chmod 0644 "$BATCH/commands.sh"
```

`do_mount` 改为 argv 数组：

```bash
do_mount() {
    local -a argv=(bash "$DM" mount --disks all --yes)
    show_run "${argv[@]}"
    "${argv[@]}" 2>&1 | tee "$BATCH/mount.log"
    local rc=${PIPESTATUS[0]}
    return "$rc"
}
```

`cmd_status` 末尾（`bash "$ST" status` 之后）追加：

```bash
if [ -n "$batch" ] && [ -f "$batch/commands.txt" ]; then
    echo "查看本次执行过的命令：cat $batch/commands.txt"
fi
```

`usage` 选项区加：`  --quiet            不在终端打印实际执行的命令（命令仍写入批次目录）`；参数解析加 `--quiet) SHOW_CMD=0; shift ;;`。

- [ ] **Step 4: 运行测试确认通过**

Run: `bash .superpowers/sdd/2026-11-15-oneclick-command-visibility/tests/run-all.sh`
Expected: `==== 结果: ALL PASS ====`（当前仅 t1）。

- [ ] **Step 5: 旧测试回归**

Run: `bash .superpowers/sdd/2026-11-15-oneclick-stress/tests/run-all.sh`
Expected: `通过 76 项，失败 0 项`。

---

### Task 2: 主终端任务命令、失败提示与复盘命令

**Files:**
- Modify: `offline-stress-pkg/oneclick.sh`（`stress_argv`/`STRESS_ARGV`、`run_mode` 循环、`wait_ready` 失败分支调用处、`run_review_all`）
- Create: `.superpowers/sdd/2026-11-15-oneclick-command-visibility/tests/t2_main_terminal.sh`

**Interfaces:**
- Consumes: Task 1 的 `cmd_line`、`show_run`、`show_once_argv`、`show_argv`。
- Produces（后续任务依赖）：
  - `STRESS_ARGV`（全局数组）
  - `stress_argv <type> <timeout> [extra...]` → 填充 `STRESS_ARGV`
  - 主终端每个任务前两行（上下文 + `$ 命令`）；失败分支变量 `LAST_TASK_CMD`（显示串）。

- [ ] **Step 1: 写失败断言**

`t2_main_terminal.sh` 用 4 盘假 `df` 跑 `all`，假 `stress-test.sh` 把参数写入 `$ROOT/argv.<id>.txt`（每行一个参数）：

```bash
BATCH_OUT=$(ls -1d "$STRESS_TEST_ROOT"/oneclick-* | tail -1)

# C1：7 条启动命令
n=$(grep -c '^  \$ bash .*stress-test\.sh start' "$OUTF")
[ "$n" = 7 ] && _pass '主终端应有 7 条启动命令' || _fail "启动命令 $n 条，期望 7"

# C2：显示串与实际 argv 一致
want="  \$ bash $(printf '%q' "$FAKE/stress-test.sh") start hdd --timeout 10h --dirs /mnt/HDD01"
grep -Fxq -- "$want" "$OUTF" && _pass 'HDD01 显示串与预期 argv 一致' || _fail 'HDD01 显示串不符'
# 假件把收到的参数（start 之后的部分）逐行写入 $ROOT/argv.HDD01.txt
mapfile -t got < "$ROOT/argv.HDD01.txt"
[ "${got[*]}" = "hdd --timeout 10h --dirs /mnt/HDD01" ] && _pass '假件收到的 argv 与显示一致' || _fail 'argv 与显示不一致'

# C4：复盘命令
grep -Fq "  \$ bash $(printf '%q' "$FAKE/stress-test.sh") review --dir " "$OUTF" && _pass '应显示复盘命令' || _fail '缺复盘命令'

# C6：重复 review 不新增行
run_oc "$OUTF" review
check_lines "$BATCH_OUT/commands.txt" "$((1 + 7 + 7))" 'commands.txt 行数不因重复 review 增长'
[ "$(grep -c ' review --dir ' "$BATCH_OUT/commands.txt")" = 7 ] && _pass '复盘命令保留 7 条' || _fail '复盘命令数量异常'

# C9：--quiet
run_oc "$OUTF" --quiet cpu
check_not_out '  $ bash' '--quiet 不打印命令'
check_not_out '任务 CPU 将执行：' '--quiet 不打印上下文行'
check_file "$(ls -1d "$STRESS_TEST_ROOT"/oneclick-* | tail -1)/commands.txt" '--quiet 仍落盘'
check_file "$(ls -1d "$STRESS_TEST_ROOT"/oneclick-* | tail -1)/commands.sh" '--quiet 仍生成 commands.sh'

# C10：环境变量关闭
ONECLICK_SHOW_CMD=0 run_oc "$OUTF" cpu
check_not_out '  $ bash' 'ONECLICK_SHOW_CMD=0 不打印命令'

# C11：第二个任务 start 失败
# 假件读 $ROOT/fail_id，id 匹配则 exit 1；断言"可直接复制重跑"与命令
check_out '该任务压测命令（可直接复制重跑）：' '失败应打印重跑提示'
check_out "  \$ bash $(printf '%q' "$FAKE/stress-test.sh") start hdd --dirs /mnt/HDD02 --timeout 10h" '重跑命令为失败任务本身'

# C12：--quiet 下失败仍打印重跑命令
run_oc "$OUTF" --quiet all
check_out '该任务压测命令（可直接复制重跑）：' '--quiet 下失败仍打印重跑提示'
check_not_out '将执行：' '--quiet 不打印常规上下文行'
```

- [ ] **Step 2: 运行确认失败**

Run: `bash .../tests/t2_main_terminal.sh`
Expected: FAIL（无主终端命令、无复盘命令）。

- [ ] **Step 3: 实现 `stress_argv` 与三个显示点**

```bash
STRESS_ARGV=()
stress_argv() {
    local type="$1" timeout="$2" e
    shift 2
    STRESS_ARGV=(bash "$ST" start "$type" --timeout "$timeout")
    for e in "$@"; do STRESS_ARGV+=("$e"); done
}
```

`run_mode` 循环内、`launch_task` 之前：

```bash
local -a targs=()
[ -n "$extra" ] && read -r -a targs <<< "$extra"
stress_argv "$type" "$TIMEOUT" "${targs[@]}"
LAST_TASK_CMD=$(cmd_line "${STRESS_ARGV[@]}")
[ "$SHOW_CMD" = "1" ] && echo "[$(now)] 任务 $id 将执行："
show_run "${STRESS_ARGV[@]}"
```

`wait_ready` 失败分支（`run_mode` 中 `else` 分支），在既有“已启动任务”之前：

```bash
echo "该任务压测命令（可直接复制重跑）："
printf '  $ %s\n' "$LAST_TASK_CMD"
```

（不受 `SHOW_CMD` 影响。）

`run_review_all` 循环内：

```bash
local -a rv=(bash "$ST" review --dir "$dir")
[ "$SHOW_CMD" = "1" ] && echo "[$(now)] 复盘 $id："
show_once_argv "${rv[@]}"
"${rv[@]}" > "$BATCH/$id.review.txt" 2>&1
```

- [ ] **Step 4: 运行测试确认通过**

Run: `bash .../tests/run-all.sh`
Expected: ALL PASS。

- [ ] **Step 5: 旧测试回归**

Run: `bash .superpowers/sdd/2026-11-15-oneclick-stress/tests/run-all.sh`
Expected: 76 项全 PASS。

---

### Task 3: 窗口 banner 与 `--quiet` 传递

**Files:**
- Modify: `offline-stress-pkg/oneclick.sh`（`run_mode` 开头 `export`、`cmd_task` banner）
- Create: `.superpowers/sdd/2026-11-15-oneclick-command-visibility/tests/t3_banner.sh`

**Interfaces:**
- Consumes: Task 1 `cmd_line`、Task 2 `stress_argv`。
- Produces: `<id>.out` 中的 `==== <id> 启动命令 ====` banner（默认开，`--quiet` 关）。

- [ ] **Step 1: 写失败断言**

`t3_banner.sh` 用 `ONECLICK_GUI=0` 跑 `cpu`：

```bash
CASE="C5 banner 默认显示"
check_out '==== CPU 启动命令 ====' '应打印 banner'
check_out '  $ bash .*stress-test\.sh start' 'banner 内含命令'
CASE="C9 quiet 关闭 banner"
bash "$OC" --quiet cpu
check_not_out '==== CPU 启动命令 ====' '--quiet 不打印 banner'
```

- [ ] **Step 2: 运行确认失败**

Run: `bash .../tests/t3_banner.sh`
Expected: FAIL（无 banner）。

- [ ] **Step 3: 实现 export 与 banner**

`run_mode` 内 `pick_terminal` 之前（或紧随 `precheck` 之后）：

```bash
export ONECLICK_SHOW_CMD="$SHOW_CMD"
```

`cmd_task` 在 `mkdir -p` 之后、执行 start 之前：

```bash
stress_argv "$type" "$timeout" "$@"
if [ "${ONECLICK_SHOW_CMD:-1}" != "0" ]; then
    echo "==== $id 启动命令 ===="
    printf '  $ %s\n' "$(cmd_line "${STRESS_ARGV[@]}")"
    echo "======================"
fi
"${STRESS_ARGV[@]}" 2>&1 | tee "$batch/$id.start.log"
```

（不得在窗口命令串里追加参数。）

- [ ] **Step 4: 运行测试确认通过**

Run: `bash .../tests/run-all.sh`
Expected: ALL PASS。

- [ ] **Step 5: 旧测试回归**

Run: `bash .superpowers/sdd/2026-11-15-oneclick-stress/tests/run-all.sh`
Expected: 76 项全 PASS（尤其 T3 窗口 argv 正则仍匹配）。

---

### Task 4: 文档、打包与整体回归

**Files:**
- Modify: `offline-stress-pkg/README.md`
- Modify: `offline-stress-pkg/operation-manual.md`
- Modify: `offline-stress-pkg.zip`（重打）
- Reuse: `.superpowers/sdd/2026-11-15-spec-driven-stress-params/pack_zip.py`

**Interfaces:**
- Consumes: Task 1–3 的最终 `oneclick.sh`。
- Produces: 与工作区一致的离线包。

- [ ] **Step 1: 更新 README**

在“一键压测”小节补充：终端会打印实际执行命令；批次目录新增 `commands.txt`（逐条可复制）、`commands.sh`（重放启动，含警告）、`env.txt`（环境快照）；`--quiet` 关闭显示但保留落盘；`status` 会提示 `cat <批次>/commands.txt`。

- [ ] **Step 2: 更新操作手册**

在“一键全测”章节新增“命令可见性与事后追溯”小节：示例输出（`任务 HDD01 将执行：` + `  $ bash …`）、三个文件用途、`bash commands.sh` 会重新压测的警告、`--quiet` 用法。

- [ ] **Step 3: 重打离线包**

Run: `python3 .superpowers/sdd/2026-11-15-spec-driven-stress-params/pack_zip.py`
Expected: 生成 `offline-stress-pkg.zip`。

- [ ] **Step 4: 校验包内一致性**

Run: `unzip -p offline-stress-pkg.zip oneclick.sh | sha256sum` 与 `sha256sum offline-stress-pkg/oneclick.sh`
Expected: 两个 SHA256 相同。

- [ ] **Step 5: 全量回归**

Run:
- `bash -n offline-stress-pkg/oneclick.sh`
- `bash .superpowers/sdd/2026-11-15-oneclick-command-visibility/tests/run-all.sh`
- `bash .superpowers/sdd/2026-11-15-oneclick-stress/tests/run-all.sh`
- `bash .superpowers/sdd/2026-11-15-spec-driven-stress-params/tests/run-all.sh`

Expected: 无语法错误；新测试全 PASS；76 项全 PASS；135 项全 PASS。
