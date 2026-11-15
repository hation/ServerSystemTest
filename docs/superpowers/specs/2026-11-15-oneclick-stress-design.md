# 一键压测入口（oneclick.sh）设计

- 日期：2026-11-15
- 状态：已批准（2026-11-15，用户确认“按这个方案来”）
- 关联文件：`offline-stress-pkg/oneclick.sh`（新增）、`offline-stress-pkg/disk-mount.sh`（仅加 `--yes`）、`offline-stress-pkg/README.md`、`offline-stress-pkg/operation-manual.md`、`offline-stress-pkg.zip`
- 依据：`offline-stress-pkg/cmd.txt`（现场现用命令与顺序）

## 1. 意图与为什么

现场的全测流程是一串手工命令：`install.sh` → `verify.sh` → `disk-mount.sh mount`（输入 all、y）→ **每块数据盘开一个终端** 跑 `stress-test.sh start hdd --dirs /mnt/HDDxx` → 再开终端跑系统盘、CPU、内存 → 等 10 小时后逐个 `review`。步骤多、容易漏项、开窗顺序靠人记，而且“哪块盘对应哪个窗口”没有记录。

`oneclick.sh` 把这条流程收成一个入口：选一次模式，自动挂载、自动按盘开窗、自动等结束、自动逐个复盘并汇总。

## 2. 已确认口径（用户确认，不得擅改）

| 项 | 口径 |
|---|---|
| 用法 | 无参数进菜单（1 全测 / 2 只测硬盘 / 3 只测系统盘 / 4 只测 CPU / 5 只测内存 / 6 查看状态 / 7 生成复盘 / 0 退出） |
| 子命令 | `all` / `hdd` / `sysdisk` / `cpu` / `mem` / `status` / `review`，可与 `--timeout 8h` 组合 |
| 全测组成 | 数据盘 + 系统盘 + CPU + 内存 |
| 执行顺序 | 前置检查 → 自动挂载 → 每块数据盘一个图形终端窗口 → 系统盘窗口 → CPU 窗口 → 内存窗口 → 主终端等待全部结束 → 自动逐个 review 并汇总 |
| 窗口内容 | `bash stress-test.sh start ...`，随后 `tail -f` 该任务的 `monitor.csv`，结束后窗口保持打开等回车 |
| 窗口程序 | 依次探测 `gnome-terminal` → `mate-terminal` → `xterm`；无图形环境（SSH）自动降级为后台并行 |
| 失败即停 | 启动阶段任一步失败，不启动后续任务，打印原因与已启动任务清单 |
| 默认时长 | 10h（`--timeout` 覆盖，所有任务同一时长） |
| 复盘 | 纯本地，全部任务结束后自动执行 |
| 挂载非交互 | 允许 `disk-mount.sh` 新增 `--yes`（仅 oneclick 调用），原交互行为保留 |

## 3. 目标

- 一条命令完成“挂载 + 按盘分窗 + 四类压测 + 自动复盘汇总”。
- 每个窗口标题可辨认（`压测-HDD01` / `压测-系统盘` / `压测-CPU` / `压测-内存`）。
- 主终端能回答：现在哪几个任务还在跑、每个任务的结论是什么。
- 任务与结果目录的对应关系落盘，事后可追溯。
- 无图形环境不报错，功能等价（只是没有窗口）。

## 4. 非目标

- 不改 `stress-test.sh` 的任何行为、参数、输出格式、`monitor.csv` 9 列、`review` 判定逻辑。
- 不改 `disk-mount.sh` 除“新增 `--yes`”以外的任何行为（选择逻辑、系统盘硬跳过、mkfs 规则、日志都不变）。
- 不改 `install.sh` / `verify.sh`。
- 不做定时启动、不做断电续跑、不做结果上传、不做断网以外的依赖。
- 不自动安装 stress（缺失时提示先跑 `install.sh`）。

## 5. 反目标（即使能跑也算失败）

- 全测时漏掉系统盘或内存。
- 没有任何数据盘时全测直接退出。
- 某块盘启动失败后仍继续启动后面的任务。
- 把所有任务塞进同一个结果目录（导致 `review` 无法按任务区分）。
- 把 `stress-test.sh` 的输出格式或 `review` 结果改坏。
- 无图形环境时报错退出而不是降级。

## 6. 详细设计

### 6.1 文件与常量

新增 `offline-stress-pkg/oneclick.sh`（bash，不 `set -e`），头部环境变量即测试接缝：

```bash
PKG_DIR="$(cd "$(dirname "$0")" && pwd)"
STRESS_TEST_ROOT="${STRESS_TEST_ROOT:-/root/stress-test}"
ST="${ONECLICK_STRESS_TEST_SH:-$PKG_DIR/stress-test.sh}"     # 压测主脚本
DM="${ONECLICK_DISK_MOUNT_SH:-$PKG_DIR/disk-mount.sh}"       # 挂载脚本
POLL_INTERVAL="${ONECLICK_POLL_INTERVAL:-30}"                # 完成轮询间隔
READY_TIMEOUT="${ONECLICK_READY_TIMEOUT:-180}"               # 等待任务就绪上限
ONECLICK_SKIP_ROOT_CHECK="${ONECLICK_SKIP_ROOT_CHECK:-0}"    # =1 跳过 root 检查（仅本地测试用）
DEFAULT_TIMEOUT="10h"
```

任务编号与窗口标题固定映射：`HDD01..HDDnn` → `压测-HDDxx`；`SYSDISK` → `压测-系统盘`；`CPU` → `压测-CPU`；`MEM` → `压测-内存`。

### 6.2 参数、菜单与模式

```bash
bash oneclick.sh                                  # 菜单
bash oneclick.sh all|hdd|sysdisk|cpu|mem [--timeout 10h]
bash oneclick.sh status
bash oneclick.sh review
```

- 先解析 `--timeout`（缺值报错退出 1），再取模式；模式缺省 → 菜单。
- 菜单读到 EOF 或 `0` → 退出 0；非法输入 → 提示后重新询问。
- 菜单项与子命令同一张映射表：`1=all 2=hdd 3=sysdisk 4=cpu 5=mem 6=status 7=review`。
- `--timeout` 只接受 `数字+可选单位 d/h/m/s`，否则报错退出 1。
- `__task` 是内部子命令（不出现在用法里），由窗口/后台调用。

### 6.3 批次目录与任务清单

每次运行建 `BATCH="$STRESS_TEST_ROOT/oneclick-<YYYYmmdd-HHMMSS>"`。该名字不以 `-cpu/-mem/-hdd/-combo` 结尾，因此不会被 `stress-test.sh status/review` 误认成结果目录。

批次目录内容：

| 文件 | 内容 |
|---|---|
| `plan.txt` | 计划任务，行格式 `id|type|extra`（如 `HDD01|hdd|--dirs /mnt/HDD01`、`SYSDISK|hdd|--sysdisk-only`、`CPU|cpu|`、`MEM|mem|`） |
| `tasks.txt` | 已就绪任务，行格式 `id|type|结果目录`（供 `status` / `review` 复用） |
| `<id>.start.log` | 该任务 `start` 的完整输出（tee） |
| `<id>.startrc` | `start` 退出码 |
| `<id>.dir` | 解析出的结果目录（就绪标记） |
| `<id>.fail` | 启动失败标记 |
| `<id>.out` | 降级模式下该任务整个助手进程的输出 |
| `<id>.review.txt` | 该任务的 `review` 输出 |
| `mount.log` | 自动挂载输出 |
| `summary.txt` | 汇总表 |

任务间用 `|` 分隔，`extra` 内不再含 `|`；`--dirs` 的取值固定为 `/mnt/HDDxx`（无空格）。

### 6.4 前置检查（仅运行类模式）

按顺序检查，任一失败即退出 1 且不建批次目录、不启动任何任务：

1. `[ "$(id -u)" -eq 0 ]`（`ONECLICK_SKIP_ROOT_CHECK=1` 时跳过），否则：`请以 root 运行：sudo bash oneclick.sh ...`
2. `command -v stress`，否则：`未找到 stress，请先运行：sudo bash install.sh`
3. `ST` 与 `DM` 文件存在，否则打印缺失路径。

`status` / `review` 不做上述检查（只读）。

### 6.5 自动挂载（仅 `all` / `hdd`）

执行 `bash "$DM" mount --disks all --yes`，输出同时写 `$BATCH/mount.log`。

- 挂载后枚举数据盘：`df -P | awk 'NR>1 && $6 ~ /^\/mnt\/HDD[0-9]+$/ {print $6}' | sort -u`。
- 全测（`all`）：无数据盘只是提示“未发现数据盘，跳过数据盘任务”，继续系统盘/CPU/内存。
- 只测硬盘（`hdd`）：无数据盘则报错退出 1。
- 已挂载的盘由 `disk-mount.sh` 自身跳过，oneclick 不重复处理。

### 6.6 `disk-mount.sh --yes`

`cmd_mount` 参数解析新增 `--yes`，只影响“请确认执行以上计划（y/N）”这一处：`--yes` 时跳过读取，直接执行。其余行为（包括非交互且无 `--disks` 时报错）不变。用法文案同步补 `--yes`。

### 6.7 窗口启动与降级

终端探测：`ONECLICK_GUI=0` 强制无图形；`ONECLICK_GUI=1` 强制有图形；未设置时要求 `DISPLAY` 或 `WAYLAND_DISPLAY` 非空且依次找到 `gnome-terminal` / `mate-terminal` / `xterm`。都找不到 → `none`。

启动命令（每个任务一条）：

```bash
gnome-terminal --title="<标题>" -- bash -c "<命令串>" >/dev/null 2>&1 &
mate-terminal  --title="<标题>" -- bash -c "<命令串>" >/dev/null 2>&1 &
xterm -T "<标题>" -e bash -c "<命令串>" >/dev/null 2>&1 &
```

命令串由以下形式拼出（各参数用 `printf %q` 单独转义）：

```bash
bash <PKG_DIR>/oneclick.sh __task <BATCH> <id> <timeout> <type> [extra...]
```

降级（`none`）：同一命令串改为

```bash
ONECLICK_NO_TAIL=1 bash -c "<命令串>" >> "$BATCH/<id>.out" 2>&1 &
```

并打印一次提示：`未检测到图形终端，改为后台并行执行；实时数据：tail -f <结果目录>/monitor.csv`。

### 6.8 `__task` 助手

```
bash oneclick.sh __task <batch> <id> <timeout> <type> [extra...]
```

1. `mkdir -p <batch>`。
2. `bash "$ST" start <type> --timeout <timeout> [extra...] 2>&1 | tee <batch>/<id>.start.log`，退出码取 `PIPESTATUS[0]`，写 `<id>.startrc`。
3. 非 0 → 写 `<id>.fail`，打印“启动失败（退出码 N）”，退出 1（窗口随即关闭，错误已落盘并由主终端打印）。
4. 从 start 输出解析结果目录：`sed -n 's/^已启动 .*压测：//p'` 取最后一行；为空 → 写 `<id>.fail` 并退出 1。
5. 写 `<id>.dir`（结果目录）。
6. `ONECLICK_NO_TAIL=1` → 直接退出 0。
7. 否则打印分隔线并 `tail -f --pid="$(cat <dir>/monitor.pid)" <dir>/monitor.csv`（无 `monitor.pid` 时退回普通 `tail -f`），结束后打印“压测已结束，结果目录：…”并 `read` 等回车，保持窗口。

### 6.9 就绪握手与失败即停

主终端按 `plan.txt` 顺序逐条启动，每启动一条就等待就绪（每 1 秒检查，最多 `READY_TIMEOUT` 秒）：

- 出现 `<id>.dir` → 就绪，追加一行到 `tasks.txt`，继续下一条。
- 出现 `<id>.fail` 或超时 → 打印该任务 `start.log` 末尾 20 行、已就绪任务清单，**停止启动后续任务**。

失败后的收尾：已有就绪任务照常等待与复盘；一个都没启动则退出 1。

### 6.10 等待完成与自动复盘

对 `tasks.txt` 中每个任务判断完成：

```bash
task_done() {   # $1=结果目录
    [ -f "$1/status.txt" ] && return 0                 # monitor-loop 结束落盘
    [ -f "$1/stress.pids" ] || return 1
    pids=$(awk 'NF{n++} END{print n+0}' "$1/stress.pids")
    [ "$pids" -gt 0 ] || return 1
    alive=$(逐 PID kill -0 计数)
    [ "$alive" -eq 0 ] || return 1
    [ "$(ls "$1"/*.exitcode 2>/dev/null | wc -l)" -ge "$pids" ] && return 0
    return 1
}
```

主终端每 `POLL_INTERVAL` 秒打印一次进度：`[时间] 进行中 N 个：HDD01, 系统盘…`。全部完成进入复盘。

复盘逐任务执行 `bash "$ST" review --dir <结果目录>`，输出写 `<id>.review.txt`，从输出取 `结论: ` 行，追加到 `summary.txt`：

```
==== 一键压测汇总 ====
批次目录: /root/stress-test/oneclick-20261115-101500
开始时间: 2026-11-15 10:15:00
结束时间: 2026-11-15 20:20:31
超时: 10h

任务      类型   结论
HDD01     hdd    正常
HDD02     hdd    正常
SYSDISK   hdd    正常
CPU       cpu    正常
MEM       mem    异常（退出码非 0）

结果目录:
  HDD01: /root/stress-test/20261115-101512-hdd
  ...
```

全部“正常”退出 0，否则退出 1；单个任务 review 失败（找不到 `结论:`）记为“未知（见 <id>.review.txt）”，不中断其余任务。

### 6.11 `status` / `review` 子命令

- `status`：取最新 `$STRESS_TEST_ROOT/oneclick-*` 批次，逐任务打印 `id / 类型 / 状态`（启动中 / 进行中 / 已完成 / 启动失败），随后执行 `bash "$ST" status` 展示实时详情。无批次 → 直接执行 `bash "$ST" status`。
- `review`：取最新批次，按其 `tasks.txt` 重新跑 6.10 的汇总（不等待、不启动）。无批次或无 `tasks.txt` → 回退 `bash "$ST" review`。

## 7. 边界情况

| 情况 | 处理 |
|---|---|
| 无数据盘（全测） | 跳过数据盘任务，继续系统盘/CPU/内存，打印提示 |
| 无数据盘（只测硬盘） | 退出 1，提示先挂载 |
| 所有盘已挂载 | `disk-mount.sh` 自行跳过并返回 0，oneclick 照常枚举 `/mnt/HDD*` |
| 挂载命令失败 | 全测打印警告后按“无数据盘”继续；只测硬盘退出 1 |
| 无图形环境 / SSH | 降级为后台并行，提示查看 monitor.csv |
| 某个任务 start 失败 | 打印原因与已就绪清单，不再启动后续任务 |
| 启动超时（窗口未拉起/命令卡住） | 视为失败，同上 |
| 内存任务因 dmidecode 缺失失败 | 由 `stress-test.sh` 报错并写 `start.log`，oneclick 原样展示 |
| 用户中途关窗口 | stress 已在 nohup 后台运行，主终端仍能等到任务结束并复盘 |
| 主终端 Ctrl-C | 只结束等待，不停止压测；提示用 `bash stress-test.sh status/stop` |
| 批次目录已存在（同秒） | 目录名追加 `-1`、`-2` 递增 |
| `--timeout` 非法 | 报错退出 1，不建目录 |

## 8. 测试计划（离线可复现）

测试放 `.superpowers/sdd/2026-11-15-oneclick-stress/tests/`，用假件：假 `stress-test.sh`（`ONECLICK_STRESS_TEST_SH`）、假 `disk-mount.sh`（`ONECLICK_DISK_MOUNT_SH`）、假 `df`、假终端命令（放进 `PATH` 并记录 argv）、假 `stress`。

| 编号 | 场景 | 期望 |
|---|---|---|
| T1 | `disk-mount.sh mount --disks all --yes`（非交互） | 执行计划并挂载，不读取 stdin |
| T2 | `disk-mount.sh mount --disks all`（无 `--yes`、无 tty） | 读不到确认 → 已取消，不执行 |
| T3 | `disk-mount.sh mount --yes`（无 `--disks`、无 tty） | 仍报“非交互模式必须指定盘”，退出 1 |
| T4 | 菜单输入 `4` | 走 `cpu` 模式，窗口命令含 `__task … CPU` |
| T5 | 菜单输入 `9` 再 `0` | 非法提示后退出 0，不启动任何任务 |
| T6 | `xterm` 存在 | argv 含 `-T 压测-CPU` 与 `-e bash -c` |
| T7 | `gnome-terminal` 存在 | argv 含 `--title=压测-CPU` |
| T8 | `ONECLICK_GUI=0` | 不调用任何终端，后台任务写出 `<id>.dir`，输出含“未检测到图形终端” |
| T9 | 第二个任务 start 返回 1 | 不启动第三个任务，输出含失败原因与已启动清单，退出 1 |
| T10 | 全部任务完成 | 每个结果目录生成 `<id>.review.txt`，`summary.txt` 含每个任务与“结论: 正常”，退出 0 |
| T11 | 某任务 review 结论异常 | 汇总表该行非“正常”，整体退出 1，其余任务仍有结论 |
| T12 | `status` 无批次 | 不报错，回退 `stress-test.sh status` |
| T13 | `review` 有批次 | 重新生成汇总，不重新启动任务 |
| T14 | `bash -n` 与 `--help` | 语法通过，用法含 `all|hdd|sysdisk|cpu|mem`、`--timeout`、菜单项 |

## 9. 验收标准

- T1–T14 全部通过；`bash -n offline-stress-pkg/oneclick.sh offline-stress-pkg/disk-mount.sh` 无输出。
- 用假终端跑一次 `all` 全流程：5 个任务（4 盘 + 系统盘 + CPU + 内存按实际盘数）全部就绪、全部复盘、汇总退出码正确。
- `stress-test.sh` 与 `disk-mount.sh` 的既有测试（`.superpowers/sdd/2026-11-15-spec-driven-stress-params/tests/run-all.sh`）保持全绿。
- 重新打包的 `offline-stress-pkg.zip` 含 `oneclick.sh`，SHA256 与磁盘文件一致。

## 10. 风险

| 风险 | 处置 |
|---|---|
| root 桌面会话下 `gnome-terminal` 起不来（DBus/权限） | 探测失败或窗口未就绪 → 超时判失败并提示改用 `ONECLICK_GUI=0 bash oneclick.sh ...` |
| 多窗口同时 `mkfs`/挂载 | 挂载集中在主终端串行完成，窗口只跑 `start` |
| 解析 `已启动 … 压测：<目录>` 依赖现有文案 | 该文案由 T14 与既有测试锁定；解析失败即判启动失败，不会静默跑偏 |
| 10 小时无人值守期间机器重启 | 不在本次范围；结果目录与 status.txt 仍可事后 `review` |
| 窗口被用户关闭 | stress 为 nohup 后台，不影响任务与复盘 |

## 11. 文档与打包

- `README.md`：包结构加 `oneclick.sh`，新增“一键压测”小节（菜单、子命令、窗口/降级说明）。
- `operation-manual.md`：新增“一键全测”章节（放在“快速上手”之后），保留原手工流程作为分步说明。
- 重新打包 `offline-stress-pkg.zip`（项目惯例）。
- 不改 `cmd.txt`（用户现场笔记）。

## 12. 留给实现者的决定

- 函数拆分与命名，只要 6.3–6.11 的落盘文件名与行为不变。
- 进度/提示文案的具体措辞，只要包含本设计列出的关键信息（任务名、结果目录、失败原因、结论）。
- 测试脚本的组织方式，沿用 `.superpowers/sdd/.../tests/` 现有风格（`lib.sh` + `run-all.sh`）。
