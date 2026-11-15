# 一键压测命令可见性（oneclick.sh）设计

- 日期：2026-11-15
- 状态：已批准（2026-11-15，用户确认“按这个方案来”）
- 关联文件：`offline-stress-pkg/oneclick.sh`（改造）、`offline-stress-pkg/README.md`、`offline-stress-pkg/operation-manual.md`、`offline-stress-pkg.zip`
- 前置设计：`docs/superpowers/specs/2026-11-15-oneclick-stress-design.md`
- 用户口径（2026-11-15 确认）：
  - 显示粒度 = 压测命令 + 挂载命令 + 复盘命令（不显示 `__task` 编排命令）
  - 落盘 = `commands.txt` + `commands.sh` + `env.txt`
  - 开关 = 默认显示，`--quiet` 或 `ONECLICK_SHOW_CMD=0` 关闭

## 1. 意图与为什么

一键全测已经能自动挂载、按盘开窗、等待、复盘，但主终端只打印中文摘要（`启动任务：HDD01（窗口标题：压测-HDD01）`），窗口里也只有压测脚本的**输出**，没有**命令本身**。事后 `plan.txt` 里是 `HDD01|hdd|--dirs /mnt/HDD01` 这种内部计划格式，不是能复制去跑的命令行。

现场需要回答三个问题，现在都答不上：

1. 这一刻到底执行了什么命令？（怀疑参数不对、怀疑漏了 `--timeout`）
2. 某个任务结论异常，怎么原样重跑这一条？
3. 事后交接/复盘，能不能拿到这一批执行过的完整命令清单？

本次改造让每条真实执行的命令都在终端可见、可复制、可追溯，并且**显示的字符串就是实际执行的那一份**，不允许出现"显示一套、执行一套"。

## 2. 目标

- 每个任务启动前，主终端打印其真实压测命令（绝对路径 + 完整参数，可直接复制重跑）。
- 挂载、复盘各打印一条对应的真实命令。
- 任务窗口首行回显该任务的压测命令（命令—输出—监控三段清晰）。
- 批次目录落盘 `commands.txt`（可读清单）、`commands.sh`（可一键重放的脚本）、`env.txt`（环境快照）。
- 启动失败时，主终端额外打印该任务的压测命令，并提示可直接复制重跑。
- `status` 在有批次时提示命令清单位置。
- 显示默认开启，`--quiet` / `ONECLICK_SHOW_CMD=0` 可关闭；关闭不影响落盘。
- 现有全部输出文案保留（只新增 `$ ` 命令行），既有 76 项与旧 135 项测试不破。

## 3. 非目标

- 不改 `stress-test.sh` 的任何行为、参数、输出格式。
- 不改 `disk-mount.sh`（显示由 oneclick 负责）。
- 不显示 `__task` 编排命令、终端探测过程、轮询动作（用户已选粒度）。
- 不做命令回放执行入口（`commands.sh` 只是落盘脚本，oneclick 不自动调用它）。
- 不做历史批次命令检索（`status` 只指向最近批次）。
- 不引入新依赖，不改变批次目录命名规则。

## 4. 反目标（即使能跑也算失败）

- 终端显示的命令与实际执行不一致（参数、路径、顺序、转义任一不符）。
- 显示命令导致原有摘要行被替换或丢失，破坏既有测试断言。
- `--quiet` 关掉显示的同时也关掉落盘。
- `commands.sh` 未经确认被 oneclick 自动执行（会造成重复压测）。
- 含空格/特殊字符的参数（如路径含空格）在显示或重放时被拆坏。
- 无图形环境（降级后台）时命令显示缺失或报错。

## 5. 约束

- 仅 bash + 现有系统命令（Kylin V10 SP3，离线）。
- 不改 `stress-test.sh`；`oneclick.sh` 现有测试接缝（`STRESS_TEST_ROOT`、`ONECLICK_STRESS_TEST_SH`、`ONECLICK_DISK_MOUNT_SH`、`ONECLICK_POLL_INTERVAL`、`ONECLICK_READY_TIMEOUT`、`ONECLICK_GUI`、`ONECLICK_NO_TAIL`、`ONECLICK_SKIP_ROOT_CHECK`）语义不变。
- 窗口命令串形态不变：`bash <PKG_DIR>/oneclick.sh __task <BATCH> <id> <timeout> <type> [extra...]`（既有测试用正则锁定其结尾）。
- 所有输出、注释、文档为中文。
- 不执行 git commit。

## 6. 详细设计

### 6.1 新增常量与开关

```bash
SHOW_CMD="${ONECLICK_SHOW_CMD:-1}"   # 1=显示命令；0=不显示（仍落盘）
```

参数解析新增 `--quiet`：解析后置 `SHOW_CMD=0`（命令行优先于环境变量）。

`run_mode` 开始时执行 `export ONECLICK_SHOW_CMD="$SHOW_CMD"`：任务窗口是 `__task` 子进程，它不解析命令行参数，只能通过继承环境变量得知是否显示；`cmd_task` 内按 `${ONECLICK_SHOW_CMD:-1}` 判断 banner 是否打印。窗口命令串本身**不追加任何参数**（既有测试用正则锁定其结尾）。

`usage` 选项区新增一行：

```
  --quiet            不在终端打印实际执行的命令（命令仍写入批次目录）
```

### 6.2 单一来源：argv 数组 + 派生显示串

所有外部命令都以 **argv 数组** 为唯一来源；显示串由数组经 `printf '%q'` 派生；执行用同一数组。**禁止**为显示单独拼一遍字符串。

```bash
# 打印并记录一条命令；$@ 是 argv 数组
# - 显示：SHOW_CMD=1 时打印 "  $ <转义后的命令>"
# - 落盘：追加到 $BATCH/commands.txt
# - $2 之后由调用方决定是否进 commands.sh（见 6.4）
show_argv() {
    local line a
    line=""
    for a in "$@"; do
        [ -n "$line" ] && line="$line "
        line="$line$(printf '%q' "$a")"
    done
    [ "$SHOW_CMD" = "1" ] && printf '  $ %s\n' "$line"
    [ -n "$BATCH" ] && printf '%s\n' "$line" >> "$BATCH/commands.txt"
}
```

说明：

- `printf '%q'` 保证路径含空格、引号时显示与重放都正确。
- 命令显示统一为两空格 + `$ ` + 命令，便于 `grep -E '^ *\$ '` 提取。
- `BATCH` 为空（极端早调用）时只显示不落盘，不报错。

### 6.3 压测命令的唯一构造点

新增函数，输出 argv 到全局数组（bash 3.x 兼容，避免 nameref）：

```bash
# 参数：<type> <timeout> [extra...]；结果放全局数组 STRESS_ARGV
stress_argv() {
    local type="$1" timeout="$2" extra
    shift 2
    STRESS_ARGV=(bash "$ST" start "$type" --timeout "$timeout")
    for extra in "$@"; do
        STRESS_ARGV+=("$extra")
    done
}
```

`extra` 来自 `plan.txt` 的第三列（如 `--dirs /mnt/HDD01`），调用前用 `read -r -a` 拆成数组——与现有 `launch_task` 的处理方式一致。

两个使用点共用它：

1. **主终端**（`run_mode` 循环、每个任务启动前）：`stress_argv "$type" "$TIMEOUT" "${args[@]}"; show_argv "${STRESS_ARGV[@]}"`，记录进 `commands.txt` 与 `commands.sh`。
2. **任务助手**（`cmd_task`）：同样 `stress_argv "$type" "$timeout" "$@"`，先打印 banner（见 6.5），再 `"${STRESS_ARGV[@]}" 2>&1 | tee ...` 执行。

这样主终端展示的参数与窗口实际执行的参数来自同一函数、同一输入，不存在漂移。

### 6.4 落盘文件

批次目录新增三个文件（其余文件不变）：

**`commands.txt`** —— 本批全部真实命令，按执行顺序，一行一条，`printf '%q'` 转义，可直接复制：

```
bash /root/offline-stress-pkg/disk-mount.sh mount --disks all --yes
bash /root/offline-stress-pkg/stress-test.sh start hdd --timeout 10h --dirs /mnt/HDD01
bash /root/offline-stress-pkg/stress-test.sh start hdd --timeout 10h --sysdisk-only
bash /root/offline-stress-pkg/stress-test.sh start cpu --timeout 10h
bash /root/offline-stress-pkg/stress-test.sh start mem --timeout 10h
bash /root/offline-stress-pkg/stress-test.sh review --dir /root/stress-test/20261115-101512-hdd
```

`commands.txt` 中复盘命令按"同一命令行只记一次"处理（追加前用 `grep -Fxq` 判重）：`review` 子命令可对同一批次反复执行，不判重会不断产生重复行。启动类命令不去重（每次运行都应留痕）。

**`commands.sh`** —— 可重放的启动脚本（只含挂载与压测启动，**不含** review：重放后的结果目录必然变化）：

```bash
#!/bin/bash
# 由 oneclick.sh 生成：批次 /root/stress-test/oneclick-20261115-101512
# 警告：执行本脚本会重新发起一轮压测，产生新的结果目录。
# 复盘请用：bash stress-test.sh review --dir <新结果目录>
set -u
bash /root/offline-stress-pkg/disk-mount.sh mount --disks all --yes
bash /root/offline-stress-pkg/stress-test.sh start hdd --timeout 10h --dirs /mnt/HDD01
...
```

- 头部两行注释固定为批次路径与重放警告，生成时写入。
- 每个压测命令前置提示注释不需要（一行一条即可）。
- 生成后 `chmod 0644`（可读、可 `bash commands.sh` 执行，不需要执行位）。
- oneclick **不会**自动执行它。

**`env.txt`** —— 环境快照，`键=值` 一行一条：

```
BATCH=/root/stress-test/oneclick-20261115-101512
MODE=all
START_TIME=2026-11-15 10:15:12
TIMEOUT=10h
STRESS_TEST_ROOT=/root/stress-test
STRESS_TEST_SH=/root/offline-stress-pkg/stress-test.sh
DISK_MOUNT_SH=/root/offline-stress-pkg/disk-mount.sh
TERM_KIND=gnome-terminal
POLL_INTERVAL=30
READY_TIMEOUT=180
SHOW_CMD=1
```

写入时机：批次目录建好后、`write_plan` 之前（此时 `TERM_KIND` 已探测）。

### 6.5 显示点（逐处）

| 位置 | 时机 | 显示内容 | 落盘 |
|---|---|---|---|
| 挂载 | `do_mount` 执行前 | `bash <DM> mount --disks all --yes` | txt + sh |
| 任务启动 | `run_mode` 循环内、`launch_task` 之前 | 该任务压测命令，前面一行上下文 `[时间] 任务 HDD01 将执行：` | txt + sh |
| 窗口 banner | `cmd_task` 开头、执行 start 前 | 同一条压测命令，外包 `==== HDD01 启动命令 ====` 分隔线 | 不重复落盘 |
| 复盘 | `run_review_all` 每任务前 | `bash <ST> review --dir <结果目录>`，前一行 `[时间] 复盘 HDD01：` | txt（去重，不进 sh） |
| 启动失败 | `wait_ready` 返回失败后 | `该任务压测命令（可直接复制重跑）：` + 命令 | 不重复落盘 |
| `status` | `cmd_status` 末尾 | `查看本次执行过的命令：cat <批次>/commands.txt`（文件存在才打印） | 无 |

窗口 banner 示例（窗口首屏）：

```
==== HDD01 启动命令 ====
  $ bash /root/offline-stress-pkg/stress-test.sh start hdd --timeout 10h --dirs /mnt/HDD01
======================
```

主终端示例（保持既有摘要行 "启动任务：…" 不动，只在它前面加两行）：

```
[2026-11-15 10:15:12] 任务 HDD01 将执行：
  $ bash /root/offline-stress-pkg/stress-test.sh start hdd --timeout 10h --dirs /mnt/HDD01
[2026-11-15 10:15:12] 启动任务：HDD01（窗口标题：压测-HDD01）
```

### 6.6 挂载命令的显示

`do_mount` 改为：

```bash
do_mount() {
    local -a argv=(bash "$DM" mount --disks all --yes)
    show_argv "${argv[@]}"          # 显示 + commands.txt
    printf '%s\n' "bash $(printf '%q' "$DM") mount --disks all --yes" >> "$BATCH/commands.sh"
    "${argv[@]}" 2>&1 | tee "$BATCH/mount.log"
    local rc=${PIPESTATUS[0]}
    return "$rc"
}
```

为避免 `commands.sh` 与 `commands.txt` 各自拼串，实现时把"写 sh"收进一个内部函数（`record_sh`），入参同样是 argv 数组，由 `printf '%q'` 派生——与 `show_argv` 同源。设计只约束行为：`commands.sh` 每行的命令与 `commands.txt` 同序同文。

### 6.7 `--quiet` 的行为边界

- `SHOW_CMD=0`：不打印任何 `  $ …` 行与 `将执行：` 上下文行；既有中文摘要行照常打印。
- 窗口 banner 同步关闭：`run_mode` 开头 `export ONECLICK_SHOW_CMD="$SHOW_CMD"`，`cmd_task` 按该变量决定是否打印 banner（见 6.1）。
- `commands.txt` / `commands.sh` / `env.txt` 照常生成，内容与 `SHOW_CMD=1` 时完全一致（`env.txt` 中 `SHOW_CMD` 记录实际值）。
- `--quiet` 与 `status` / `review` 组合时只影响复盘命令的显示（`status` 的 `cat` 提示照常，因为它不是命令执行）。
- `--quiet` 与 `--help` / 菜单无冲突；菜单场景同样生效。
- **例外**：启动失败时的"可直接复制重跑"提示不受 `SHOW_CMD` 影响，始终打印——它是诊断结论的一部分，而不是常规进度噪声。

### 6.8 状态提示

`cmd_status` 在打印完 `bash "$ST" status` 之后追加：

```bash
if [ -n "$batch" ] && [ -f "$batch/commands.txt" ]; then
    echo "查看本次执行过的命令：cat $batch/commands.txt"
fi
```

旧批次无该文件时不打印，不报错。

### 6.9 失败时的重跑提示

`run_mode` 中 `wait_ready` 失败分支，在现有"已启动任务 / 因 … 停止启动"之前追加：

```
该任务压测命令（可直接复制重跑）：
  $ bash /root/offline-stress-pkg/stress-test.sh start hdd --timeout 10h --dirs /mnt/HDD01
```

命令来源：该任务在启动前已由 `stress_argv` 构造过，可在循环内保存到临时变量 `LAST_TASK_CMD`（显示串）复用，不重新拼。

### 6.10 路径规范化

目标要求显示"绝对路径、可复制重跑"，因此 `ST`、`DM` 在使用前必须规范化为绝对路径：若取值不以 `/` 开头，用 `cd "$(dirname "$x")" && pwd` + `basename` 拼成绝对路径（`precheck` 已保证文件存在，失败路径不会走到这里）。规范化之后，`ST`/`DM` 同时用于显示与执行，二者天然一致；`commands.sh` 换目录执行也能重放。

`--dirs` 的取值支持含空格路径（2026-11-15 修复，见 `.superpowers/sdd/2026-11-15-dirs-space-path/`）：`plan.txt` 改为“每个附加参数一个 `|` 字段”（如 `HDD 01|hdd|--dirs|/mnt/HDD 01`），`run_mode` 用 `IFS='|' read -a` 切分，空格不再参与分词；`launch_task`/`cmd_task` 全程按位置传参，`commands.sh` 由 `printf '%q'` 派生可正确重放。`collect_hdd_dirs` 跳过 `df -P` 前 5 字段、保留剩余原始字符作为挂载点，并把字面量 `\040` 精确还原为空格（不用 `printf '%b'`，避免贪婪八进制解析），只匹配 `/mnt/HDD` 开头的顶层挂载点（排除 `/mnt/HDD01/sub` 这类嵌套挂载）。目录名含 `|` 时直接报错退出。

## 7. 边界情况

| 情况 | 处理 |
|---|---|
| 安装目录含空格/引号 | `printf '%q'` 转义，显示与 `commands.sh` 均可正确重放 |
| `--dirs` 值含空格 | 支持：plan.txt 每参数一字段，枚举保留原文并还原 `\040`，见 §6.10 |
| `--quiet` 与 `ONECLICK_SHOW_CMD=0` 同时出现 | 都为关，无冲突 |
| `ONECLICK_SHOW_CMD` 取非法值 | 非 `0` 一律视为开（只有 `0` 关闭） |
| 旧批次（无 commands.txt） | `status` 不打印提示；`review` 不依赖该文件 |
| 批次目录创建失败 | 既有 `die` 逻辑，不产生半截 commands.sh |
| `__task` 被手工直接调用（无 BATCH 写入权限） | 显示与执行照常；落盘失败只影响记录，不改变启动结果（追加失败不中断） |
| 降级后台模式 | `<id>.out` 中同样含 banner，主终端同样显示命令 |
| 挂载失败 | 命令已显示；现有警告/退出逻辑不变 |
| 复盘某任务找不到结果目录 | 命令照常显示，结论仍记"未知（见 …review.txt）" |
| `commands.sh` 被用户手工执行 | 属用户主动行为；脚本头部警告已说明会重新压测 |

## 8. 测试计划（离线可复现）

新测试目录：`.superpowers/sdd/2026-11-15-oneclick-command-visibility/tests/`，沿用既有 `lib.sh` 风格（假 `stress-test.sh`、假 `disk-mount.sh`、假终端、假 `df`、假 `stress`）。

| 编号 | 场景 | 期望 |
|---|---|---|
| C1 | `all` 全流程（4 盘 + 系统盘 + CPU + 内存 = 7 个任务） | 主终端出现 7 条 `$ bash …/stress-test.sh start …`，每条参数完整 |
| C2 | 显示串 == 实际 argv | 假 `stress-test.sh` 把 `"$@"` 写入 argv 文件；逐任务比对显示串与 argv 一致（含 `--dirs`、`--timeout`、`--sysdisk-only`） |
| C3 | 挂载 | 主终端出现 `$ bash <DM> mount --disks all --yes`；`mount.log` 仍生成 |
| C4 | 复盘 | 每个任务前出现 `$ bash <ST> review --dir <结果目录>`，且 `<id>.review.txt` 仍生成 |
| C5 | 窗口 banner（`ONECLICK_GUI=0`，默认显示） | `<id>.out` 含 `==== <id> 启动命令 ====` 与该任务命令行 |
| C6 | `commands.txt` | 最终行数 = 1（挂载）+ N（启动）+ N（复盘）；前 1+N 行为启动类，均以 `bash ` 开头且为绝对路径；重复执行 `review` 不新增重复行 |
| C7 | `commands.sh` | `bash -n` 通过；含 shebang 与重放警告；含挂载与全部启动命令；**不含** `review`；`chmod 0644` |
| C8 | `env.txt` | 含 `BATCH=`、`MODE=`、`TIMEOUT=`、`STRESS_TEST_ROOT=`、`TERM_KIND=`、`SHOW_CMD=` |
| C9 | `--quiet` | 输出无 `$ bash …start`；`<id>.out` 无 banner；`commands.txt`/`commands.sh`/`env.txt` 仍存在且内容完整（`env.txt` 记录 `SHOW_CMD=0`） |
| C10 | `ONECLICK_SHOW_CMD=0` | 同 C9（环境变量路径） |
| C11 | 启动失败（第二个任务 start 返回 1） | 输出含"可直接复制重跑"与该任务命令行；仍不启动第三个任务、退出码 1 |
| C12 | 启动失败 + `--quiet` | 仍打印"可直接复制重跑"与该任务命令行（诊断例外），但不打印常规 `将执行：` 行 |
| C13 | `status` 有批次 | 末尾含 `查看本次执行过的命令：cat <批次>/commands.txt` |
| C14 | `status` 无批次 | 不打印该提示，不报错，回退 `stress-test.sh status` |
| C15 | 安装目录含空格 | `PKG_DIR` 含空格时显示串与 `commands.sh` 均带引号/转义，假件能收到完整参数 |
| C16 | 路径规范化 | `ONECLICK_STRESS_TEST_SH` 传相对路径时，显示与 `commands.sh` 中为绝对路径 |
| C17 | `bash -n` 与 `--help` | 语法通过；`--help` 含 `--quiet` 说明 |
| C18 | 回归 | 旧 76 项（oneclick）+ 旧 135 项（stress 参数）全 PASS |

断言方式沿用 `lib.sh` 的 `check_out` / `check_not_out` / `check_file` / `check_rc`，新增 `check_cmd_file`（按行精确匹配 `commands.txt`）。

## 9. 验收标准

- C1–C18 全部通过；`bash -n offline-stress-pkg/oneclick.sh` 无输出。
- 假件跑一次 `all`：主终端命令条数、顺序、参数与实际 argv 完全一致。
- `--quiet` 与 `ONECLICK_SHOW_CMD=0` 两种关法行为一致，落盘不受影响。
- 旧 `.superpowers/sdd/2026-11-15-oneclick-stress/tests/run-all.sh`（76 项）与 `.superpowers/sdd/2026-11-15-spec-driven-stress-params/tests/run-all.sh`（135 项）全绿。
- `offline-stress-pkg.zip` 重打后，zip 内 `oneclick.sh` 的 SHA256 与工作区一致。

## 10. 风险

| 风险 | 处置 |
|---|---|
| 显示与执行漂移 | argv 数组为唯一来源，显示串由同一数组派生；C2 逐任务比对 |
| 输出变长影响现场阅读 | `--quiet` 可关；每任务只增 2 行；命令单行不折行 |
| 转义不当导致复制后跑错 | 一律 `printf '%q'`；C14 用含空格路径验证 |
| `commands.sh` 被误执行造成重复压测 | 头部显式警告；oneclick 不自动执行；文件名不含 `run` 误导词 |
| 既有测试因新增输出失败 | 只新增行、不改既有行；C16 回归锁定 |
| 主终端与窗口显示不同步 | 两侧共用 `stress_argv`；参数同源（plan.txt） |

## 11. 文档与打包

- `README.md`：“一键压测”小节补充“终端会打印实际执行的命令”、`commands.txt`/`commands.sh`/`env.txt` 说明、`--quiet`。
- `operation-manual.md`：“一键全测”章节补“命令可见性与事后追溯”小节（含 `cat commands.txt`、`bash commands.sh` 的注意）。
- 重打 `offline-stress-pkg.zip`（项目惯例）。
- 不改 `cmd.txt`。

## 12. 留给实现者的决定

- `show_argv` / `record_sh` / `stress_argv` 的具体命名与内部拆分，只要行为与 6.2–6.9 一致。
- `commands.sh` 头注释的具体措辞，只要含批次路径与重放警告。
- `env.txt` 键的排列顺序（键名与语义按 6.4）。
- 测试脚本按 C1–C16 如何分组（可多个文件，也可合并），沿用 `lib.sh` + `run-all.sh` 风格。
- `show_argv` 的缩进空格数，只要保持"两空格 + `$ `"的可 grep 形态。
