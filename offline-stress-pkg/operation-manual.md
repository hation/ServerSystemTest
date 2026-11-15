# 压测实操手册

Kylin V10 SP3 服务器 **CPU / 内存 / 硬盘** 压力测试操作手册（适用三类机型：海光 5380 / 7380 / 7360）。

配套脚本（本离线包内）：
- `stress-test.sh` —— 压测主控：`start cpu|mem|hdd|combo` / `status` / `stop` / `review`
- `disk-mount.sh` —— 测试盘挂载辅助：`list` / `mount` / `umount`

---

## 1. 适用环境与准备

适用环境：无外网的 Kylin V10 SP3（x86_64）服务器，有 root 或可 sudo；压测工具 `stress` 1.0.4（由本离线包安装到 `/usr/bin/stress`）。三类机型：

| 机型 | 服务器 | 特征 |
|---|---|---|
| 5380 | 服务器一 | 2×海光 5380（共 64 线程），384G 内存，12×8TB HDD + 2×480G SSD + 2×1.92T NVMe |
| 7380 | 服务器二 | 2×海光 7380（共 128 线程），1024G 内存，2×3.84T NVMe + 1×480G SSD |
| 7360 | 服务器三 | 2×海光 7360（共 96 线程），512G 内存，2×3.84T NVMe + 1×480G SSD |

> 以上机型与配置仅作参考：`stress-test.sh` 的 CPU/内存参数一律按**本机实测值**推导（见第 8 节），不按机型查表。

准备步骤（先把整个 `offline-stress-pkg` 目录拷到服务器，在包目录内执行；拷贝方式见同目录 README.md）：

```bash
sudo bash install.sh   # 安装 stress 与 dmidecode（已是 root 可直接 bash install.sh；已装同版本会提示"已安装"）
bash verify.sh         # 验证：版本检查 + 10 秒冒烟压测 + dmidecode 可用性
```

- `verify.sh` 检查 A/B 为版本校验、检查 C 为 10 秒冒烟压测、检查 D 为 dmidecode 可用性（缺失只 WARN）；若机器正在跑业务不想跑冒烟压测，可 `VERIFY_SKIP_SMOKE=1 bash verify.sh`。
- 离线包已内置 `rpms/dmidecode-3.2-10.el8.x86_64.rpm`，`install.sh` 会一并安装，装好后 `start mem/combo` 可直接自动探测内存条根数。
- **EDAC 不是可安装的软件**：它是内核 sysfs 接口（`/sys/devices/system/edac/mc`），取决于内核是否加载 `edac_core` 等模块，无法打进离线包；dmidecode 不可用时脚本才回退到它。
- 两个压测脚本无需安装，直接 `bash stress-test.sh …` / `bash disk-mount.sh …` 调用（在包目录内执行，或给脚本绝对路径）。
- 所有压测数据默认落在 `/root/stress-test/`（可用环境变量 `STRESS_TEST_ROOT` 改）。

## 2. 快速上手：四条命令

> 本节为**分步执行**时使用：逐条命令手工启动，适合只想压单项或需要自行控制节奏的场景。想一条命令跑完全流程，直接用 [2.1 一键全测](#21-一键全测oneclicksh)。

默认按**本机实测规格**推导参数（CPU `floor(逻辑线程数 × 86%)`、内存 `MemTotal × 82%`、`--vm` 等于实际内存条根数，详见第 8 节），默认时长 **10 小时**（`--timeout 10h`）：

```bash
# CPU 压测
bash stress-test.sh start cpu

# 内存压测
bash stress-test.sh start mem

# 硬盘压测（先挂载测试盘，见第 3 节；默认测全部 /mnt/HDD* 挂载点）
bash stress-test.sh start hdd

# 组合压测（CPU + 内存 + 每块数据盘 hdd，见第 10 节；可加 --sysdisk 再压系统盘，见第 11 节）
bash stress-test.sh start combo
```

启动后脚本会输出结果目录与查看方式：

```
已启动 cpu 压测：/root/stress-test/20261113-143000-cpu
查看状态：bash stress-test.sh status
实时监控：tail -f /root/stress-test/20261113-143000-cpu/monitor.csv
```

压测与监控均 nohup 后台运行、全部落盘，可脱离 ssh 会话，到时自动结束。

> 建议首次先短时验证全链路（如 `--timeout 60s`），确认日志/监控/复盘可用后再正式 10h。

## 2.1 一键全测（oneclick.sh）

前置：先在本包目录内完成安装与验证（见第 1 节）：

```bash
sudo bash install.sh
bash verify.sh
```

然后启动菜单，选 `1`（全测）：

```bash
sudo bash oneclick.sh
```

菜单项：`1` 全测 / `2` 只测硬盘 / `3` 只测系统盘 / `4` 只测 CPU / `5` 只测内存 / `6` 查看状态 / `7` 生成复盘。也可用子命令，等价且便于脚本化（默认超时 10h）：

```bash
sudo bash oneclick.sh all --timeout 10h
sudo bash oneclick.sh hdd --timeout 8h
sudo bash oneclick.sh status
sudo bash oneclick.sh review
```

**全测做的事**（按顺序）：自动挂载 `disk-mount.sh mount --disks all --yes` → 每块数据盘一个任务（每个任务一个终端窗口）→ 系统盘 → CPU → 内存 → 等待全部结束 → 自动逐个 `review` 并生成汇总。

- **窗口标题**：`压测-HDDxx`（数据盘）、`压测-系统盘`、`压测-CPU`、`压测-内存`，窗口内实时 `tail -f` 该任务的 `monitor.csv`。
- **窗口关掉不影响压测**：压测与监控本身以 `nohup` 后台运行，窗口只是查看入口；关掉窗口（或 Ctrl-C 只退出查看）压测继续，可再 `sudo bash oneclick.sh status` 查看。
- **无图形环境（SSH）自动降级**：检测不到 `DISPLAY` / `WAYLAND_DISPLAY` 或无可用终端时，自动改为后台并行执行，输出写入批次目录的 `<任务>.out`。需要强制后台（不弹窗）时：

  ```bash
  ONECLICK_GUI=0 sudo -E bash oneclick.sh all
  ```

- **失败即停**：启动阶段任一任务启动失败，立即停止启动后续任务，并打印已启动任务清单与失败原因。
- **结果位置**：每次运行在 `/root/stress-test/oneclick-<时间>/` 建一个批次目录，汇总在 `/root/stress-test/oneclick-<时间>/summary.txt`（各任务的完整结果仍在各自的 `<时间戳>-<类型>/` 结果目录，`summary.txt` 末尾列出结果目录清单；存在异常结论时退出码 1）。批次目录内主要文件：

  | 文件 | 含义 |
  |---|---|
  | `summary.txt` | 一键汇总：逐任务结论 + 各任务结果目录 |
  | `plan.txt` | 任务计划（启动前），格式 `id\|类型\|附加参数` |
  | `tasks.txt` | 已启动任务，格式 `id\|类型\|结果目录` |
  | `start.time` / `timeout.txt` | 批次开始时间与统一超时 |
  | `mount.log` | 自动挂载输出 |
  | `<任务>.out` | 后台降级模式下该任务的输出 |
  | `<任务>.review.txt` | 该任务 `review` 的完整输出 |

### 2.1.1 命令可见性与事后追溯

启动前，主终端会打印实际执行的每条关键命令，任务启动前形如：

```
[2026-11-15 10:03:12] 任务 HDD01 将执行：
  $ bash /root/offline-stress-pkg/stress-test.sh start hdd --timeout 10h --dirs /mnt/HDD01
```

- 自动挂载前打印 `  $ bash /root/offline-stress-pkg/disk-mount.sh mount --disks all --yes`；
- 自动复盘前打印 `  $ bash /root/offline-stress-pkg/stress-test.sh review --dir <结果目录>`；
- 每个任务窗口的首屏也会显示同样一条启动命令 banner：`==== HDD01 启动命令 ====` / `  $ …` / `======================`（窗口标题不变）。

批次目录内同时生成三个命令记录文件（每次运行重建）：

| 文件 | 用途 |
|---|---|
| `commands.txt` | 本次实际执行过的命令，一行一条、可直接复制；复盘命令自动去重只记一次 |
| `commands.sh` | 可直接 `bash commands.sh` 重放的启动脚本（含 shebang、批次路径、重放警告、`set -u`；只含挂载与各任务启动命令，**不含** review；权限 0644） |
| `env.txt` | 本次执行环境快照：`BATCH` / `MODE` / `START_TIME` / `TIMEOUT` / `STRESS_TEST_ROOT` / `STRESS_TEST_SH` / `DISK_MOUNT_SH` / `TERM_KIND` / `POLL_INTERVAL` / `READY_TIMEOUT` / `SHOW_CMD` |

> **警告**：`bash commands.sh` 会**重新发起一轮压测（all/hdd 批次还会先重新挂载）**（生成新的结果目录），不是"查看历史"。只想回看本次执行了什么命令，用 `cat <批次>/commands.txt`；重放后复盘新结果用 `bash stress-test.sh review --dir <新结果目录>`。

- **关闭终端显示**：`sudo bash oneclick.sh all --quiet`（或 `ONECLICK_SHOW_CMD=0 sudo -E bash oneclick.sh all`）不再打印命令，但 `commands.txt` / `commands.sh` / `env.txt` 照常生成；启动失败时"该任务压测命令（可直接复制重跑）："提示**始终显示**（便于立即重试）。
- **事后查看**：`sudo bash oneclick.sh status` 在存在批次且 `commands.txt` 存在时会提示 `查看本次执行过的命令：cat <批次>/commands.txt`。

## 3. 硬盘压测完整流程

流程：`list` → `mount` → `start hdd` → 完成后 `umount`。

### 3.1 查看块设备与系统盘

```bash
bash disk-mount.sh list
```

输出会标出**系统盘**（`df /` 的底层盘，标"（系统盘，跳过）"，永不测试）以及每块非系统盘的状态：
- 已挂载（跳过）
- 有分区（将直接挂载）
- 未分区空盘（将 `mkfs.ext4 -m 0` 后挂载）

### 3.2 挂载测试盘（交互流程）

```bash
bash disk-mount.sh mount
```

交互流程：

1. 列出全部可用非系统盘（盘符、容量、状态），提示 `输入要纳入测试的盘符（逗号分隔，all 全部）：`，输入如 `sdb,sdc` 或 `all`；
2. 脚本打印**完整执行计划**：每盘一行显示设备、容量、动作（`有分区：直接挂载 /dev/sdb1 → /mnt/HDD01` 或 `无分区空盘：mkfs.ext4 -m 0 /dev/sdb 后挂载 → /mnt/HDD01`）；
3. 提示 `请确认执行以上计划（y/N）：`，**单个 `y` 确认后才执行**；输入其他任意内容则取消、不执行任何操作；
4. 执行：空盘先 `mkfs.ext4 -m 0`（预留 0% 空间）再挂载；有分区的盘直接挂载分区；**已挂载的盘跳过**（不会重复挂载）；每步写入挂载日志 `/root/stress-test/mount.log`。

要点：

- **空盘会自动格式化**（`mkfs.ext4 -m 0`）——执行前必有"计划 + y 确认"两道关卡，确认前务必核对盘符与容量；
- 挂载点按纳入顺序编号：`/mnt/HDD01`、`/mnt/HDD02` …；
- 选择含系统盘或无效盘会被拒绝并退出（exit 1）；
- 非交互环境（无终端）必须指定盘：`bash disk-mount.sh mount --disks sdb,sdc`（等价于交互选择，`all` = 全部）；
- **演练用 DRY_RUN**：`DRY_RUN=1 bash disk-mount.sh mount` 只打印执行计划、不执行任何写操作（含不写 mount.log），适合正式挂载前核对计划。

### 3.3 启动硬盘压测

```bash
bash stress-test.sh start hdd
```

- 默认扫描 `/mnt/HDD*` 全部挂载点，每盘一个 `stress --hdd 1 --hdd-bytes 10G` 后台进程，各自独立日志 `stress-HDD01.log`、`stress-HDD02.log` …（stress 的 hdd 模式在当前目录写压测文件，因此每盘必须在各自挂载点下运行，脚本已自动 cd 进各目录）；
- 只测指定盘：`bash stress-test.sh start hdd --dirs "/mnt/HDD01 /mnt/HDD02"`；
- 盘未挂载时脚本会报错并提示（见第 7 节）。

### 3.4 测试完成后卸载

```bash
bash disk-mount.sh umount          # 列出已挂载测试盘，确认（y/N）后逐个卸载
bash disk-mount.sh umount --all    # 跳过确认，直接全部卸载
```

## 4. 查看测试状态与日志

### 4.1 status：总览运行中任务

```bash
bash stress-test.sh status
```

对每个运行中压测输出：结果目录、stress 存活进程数（含 PID）、监控进程状态（运行中/已退出）、**剩余时长估算**（按开始时间+超时计算）、最近 5 行监控。无运行任务时输出"无运行中的压测"。

### 4.2 实时监控

```bash
tail -f /root/stress-test/<时间戳>-<类型>/monitor.csv
```

`monitor.csv` 每 **30 秒**一行（默认 `MONITOR_INTERVAL=30` 秒，可用环境变量调），表头：

```
时间,load1,cpu_usage%,mem_total,mem_used,mem_avail,swap_used,disk_read_MBps,disk_write_MBps
```

内存各字段单位为 kB；磁盘 IO 为全设备读写速率（MB/s）；纯文本 CSV，拷回后可直接用 Excel 打开。

### 4.3 手动停止

```bash
bash stress-test.sh stop
```

优雅停止全部运行中的压测（先 TERM，3 秒内未退出再 KILL），并同步停止监控进程；写 operations.log。

### 4.4 结果目录与各日志说明

默认根目录 `/root/stress-test/`：

```
/root/stress-test/
├── <YYYYmmdd-HHMMSS>-<cpu|mem|hdd|combo>/   # 每次测试一个目录（时间戳命名，防覆盖）
│   ├── run-config.txt     # 本次机型、类型、参数、开始时间、超时、命令原文
│   ├── info-before.txt    # 测试前快照：lscpu / free -h / df -h / lsblk / stress --version
│   ├── monitor.csv        # 30 秒一条系统状态（原始数据，可 Excel 打开）
│   ├── stress.log         # stress 原始输出（hdd 模式为 stress-HDDxx.log 每盘一份；combo 为 CPU+内存进程输出，各盘/系统盘另见 stress-HDDxx.log、stress-SYSDISK.log）
│   ├── stress.exitcode    # stress 退出码（hdd 模式为 stress-HDDxx.exitcode 每盘一份；combo 另含 stress-SYSDISK.exitcode）
│   ├── stress.pids / monitor.pid   # 进程记录（脚本内部使用）
│   └── summary.txt        # review 生成的复盘总结（见第 5 节）
├── mount.log              # 挂载/格式化/卸载全步骤日志（disk-mount.sh 写，hdd 挂载问题看这个）
└── operations.log         # 主控脚本操作记录（每次 start/stop 一行，防误操作复盘）
```

## 5. 测完复盘

```bash
bash stress-test.sh review                                              # 自动选最新结果目录
bash stress-test.sh review --dir /root/stress-test/20261113-143000-cpu  # 指定目录
```

`review` 读取该目录的监控与配置，生成并打印 `summary.txt`，包含：类型、机型、开始时间、计划超时、预计结束时间（按监控覆盖时长估算）、监控数据行数、监控覆盖时长、**CPU 使用率均值/峰值、内存峰值（kB）、磁盘读/写峰值（MB/s）**、各 stress **退出码**（0 = 正常结束，非 0 = 异常或被中断）以及原始数据文件清单。

> 说明：复盘只给出事实数据，不下"通过/不通过"结论；判定由使用者根据退出码与峰值数据自行完成。

原始数据文件清单与含义：

| 文件 | 含义 |
|---|---|
| `run-config.txt` | 本次测试参数与命令原文 |
| `info-before.txt` | 测试前系统快照 |
| `monitor.csv` | 全程 30s 一条的系统状态原始数据 |
| `stress.log` / `stress-HDDxx.log` / `stress-SYSDISK.log` | stress 原始输出（hdd 逐盘一份；combo 组合进程 + 系统盘） |
| `stress.exitcode` / `stress-HDDxx.exitcode` / `stress-SYSDISK.exitcode` | 退出码（0 正常 / 非 0 异常） |
| `mount.log` | 挂载/格式化步骤日志（hdd 流程） |
| `operations.log` | start/stop 操作历史 |

## 6. 数据拷回 U 盘

测试完成后把结果拷回 U 盘（示例，`/mnt/usb` 为 U 盘挂载点，以实际为准）：

```bash
cp -r /root/stress-test/* /mnt/usb/
```

- 建议按测试**逐个目录**拷回，便于区分多轮测试；
- 也可打包拷回：`tar czf /mnt/usb/stress-test-$(date +%Y%m%d).tar.gz -C /root stress-test`

## 7. 常见问题

**--timeout 的单位是什么？**
纯数字为**秒**（`--timeout 60` = 60 秒，适合短时验证）；也支持 `12h` / `30m` / `45s` / `1d`。**默认 `--timeout 10h`**。例：`bash stress-test.sh start cpu --timeout 60`。注意只接受整数或整单位（如 `60`、`12h`、`30m`、`45s`、`1d`），**不支持小数后缀**（如 `1.5h`）。

**进程被杀 / 中断了怎么办？**
stress 被 kill 或系统重启导致中断时，退出码文件为非 0，`review` 会如实显示；若退出码文件缺失（例如被 `kill -9` 强杀、来不及写文件），也应视为**被强制中断**。监控进程在发现 stress 进程全部消失后（最多一个采样周期）自动退出。中断后原结果目录保留已写入的数据；系统重启后需重新 `start`。也可随时用 `bash stress-test.sh stop` 手动中断（退出码非 0）。

**结果目录已存在？**
结果目录按 `<时间戳>-<类型>` 命名，同一秒冲突会自动顺延 1 秒，**不会覆盖**旧结果；重复 start 会产生新的独立目录，多轮结果可对比。

**报"未发现 /mnt/HDD* 挂载点"？**
硬盘测试前必须先挂载：`bash disk-mount.sh mount`；或显式指定 `--dirs "/mnt/HDD01 …"`。

**监控进程什么时候退出？**
`monitor-loop` 在 `stress.pids` 中所有进程消失后自动结束（正常跑完或被停止后）。若压测还在跑但 status 显示"监控进程: 已退出"，属异常，请反馈。

**--model 有什么用？**
`--model` **只影响报告标注，不参与任何参数分配**。默认 `auto`：`MemTotal ≥ 800G → 7380`；否则 `nproc ≥ 120 → 7380`；否则 `nproc ≥ 90 → 7360`；否则 `5380`。检测时打印"检测到机型 X（仅用于报告标注与交叉校验）"，并在实测线程数与机型标称值（5380=64 / 7360=96 / 7380=128）偏差 >10% 时提示疑似单路 CPU，参数仍按实测推导。CPU/内存参数不需要 `--model`，也可手动指定：`bash stress-test.sh start mem --model 7380`。

**报"未找到 stress"？**
先运行 `sudo bash install.sh` 安装，再 `bash verify.sh` 验证。

**参数记不住？**
不带参数直接运行 `bash stress-test.sh` 或 `bash disk-mount.sh`，会打印完整用法。

## 8. 参数推导规则（按实测规格，不查机型预设）

`start cpu|mem|combo` 的 CPU/内存参数在启动时由本机实测值推导，**不再按机型查表**：

| 参数 | 推导规则 | 环境变量（默认值） |
|---|---|---|
| CPU worker 数 | `floor(逻辑线程数 × 86%)`，下限 1 | `CPU_MAX_PCT=86` |
| 内存总量 | `MemTotal × 82%` | `MEM_TARGET_PCT=82` |
| `--vm` 内存条根数 | 等于实际内存条根数：`dmidecode -t 17` 统计已安装槽位；失败回退 EDAC（`/sys/devices/system/edac/mc`） | `DMI_BIN=dmidecode`、`EDAC_ROOT=…` |
| 单 worker 字节 | `round(MemTotal × 82% / 根数)` GiB（四舍五入到 1G，通常落在 81–83%） | — |
| 硬上限 | `根数 × 单 worker ≤ MemTotal × 85%`，超限逐 G 下调 | `MEM_MAX_PCT=85` |

- **内存条根数探测失败**（dmidecode 结果无效（0 或超过 256）时自动回退 EDAC；dmidecode 与 EDAC 两路来源都无效才算探测失败）：本次 `start mem/combo` 直接中止（退出码 1，不建结果目录、不启动 stress），并直接给出**可复制执行的建议命令**——按本机 MemTotal 算好 16 个 worker 与单 worker 字节（总量 = 82%，不超 85%），例如 `bash stress-test.sh start mem --vm 16 --vm-bytes 51G --timeout 10h`；若知道实际根数，推荐只填根数 `bash stress-test.sh start mem --vm <实际根数>`，单 worker 字节由脚本自动推导。MemTotal 也读不到时，建议命令改为同时给 `--vm` 与 `--vm-bytes`。根数可从开机 BIOS 内存信息、机箱/主板标签获取，或 `sudo lshw -class memory | grep -c 'bank:'`；离线包已内置 `rpms/dmidecode-3.2-10.el8.x86_64.rpm`，`sudo bash install.sh` 后即可恢复自动探测。`start cpu` 不受影响。
- **MemTotal 不可读**（`/proc/meminfo` 无 MemTotal）且走自动推导：同样中止（退出码 1）；若显式给了 `--vm-bytes`，则按显式值继续，并在 `run-config.txt` 标注"未做内存裁剪"。
- **单 worker 不足 1G**（如 MemTotal 4G / 16 根）：报错退出（退出码 1），提示"单 worker 内存不足 1G（MemTotal XG / N 根），无法压测"。
- **显式参数优先**：`--cpu` / `--vm` / `--vm-bytes` 给出即原样使用，自动推导只补未给出的参数；显式 `--vm-bytes` 不做 85% 裁剪（仅打印超限警告）。
- `--model` 仅用于 `run-config.txt` / `review` 的机型标注与"实测线程 vs 标称线程"交叉校验，**不参与参数分配**。

### 8.1 四种现场内存规格回算

| 实测 MemTotal | DIMM 根数 | 单根容量 | 推导 `--vm` | 单 worker | 实际下发总量 | 占物理内存 |
|---|---|---|---|---|---|---|
| 502.5 GiB | 16 | 32 GiB | 16 | 26G | 416G | 82.8% |
| 754.5 GiB | 12 | 64 GiB | 12 | 52G | 624G | 82.7% |
| 994.7 GiB | 16 | 64 GiB | 16 | 51G | 816G | 82.0% |
| 1120.7 GiB | 18 | 64 GiB | 18 | 51G | 918G | 81.9% |

> 四种规格均为 128 线程（7380 类），CPU worker 统一推导为 `floor(128 × 86%) = 110`；内存占物理内存比例均落在 81–83%。

默认 `--timeout 10h`。**显式参数可覆盖自动推导**：`--timeout`、`--cpu`、`--vm`、`--vm-bytes`、`--hdd-bytes`、`--dirs` 均可手动指定；hdd/combo 模式还可加 `--sysdisk`（压系统盘，见第 11 节），例如：

```bash
bash stress-test.sh start cpu --timeout 6h --cpu 64
bash stress-test.sh start mem --vm 12 --vm-bytes 60G
```

## 9. 安全提示

- **系统盘永不测试**：disk-mount.sh 按 `df /` 识别系统盘并在任何分支硬跳过，`list` 中标出；选择含系统盘的盘符会被直接拒绝。stress hdd 压测只跑在 `/mnt/HDD*` 挂载点（或 `--dirs` 指定的目录），不涉及系统盘。
- **测试盘必须为已确认的空盘**：无分区空盘会自动 `mkfs.ext4 -m 0` **格式化**——执行前必打印计划并要求 `y` 确认，确认前务必核对盘符、容量、动作。
- **执行前确认计划**：mount 的挂载计划、umount 的卸载清单都要确认无误后再执行；start 启动后可在结果目录的 `run-config.txt` 核对实际机型与参数（`status` 只显示类型、进程数、剩余时长等概览）。
- **内存总量勿超物理内存**：`start mem/combo` 默认按本机实测推导——下发总量为 `MemTotal × 82%`，并受 `MemTotal × 85%`（环境变量 `MEM_MAX_PCT`，默认 85）**分配上限**约束，超出时自动下调并在启动输出与 `run-config.txt` 中标注，无需手工换算；**85% 只是分配上限，不是 80% 的验收达成阈值**，两者不可混用。显式 `--vm-bytes` 不受该机制约束（仅打印警告），手动调大时请自行核对，避免 OOM。
- 压测会显著提升 CPU 温度与功耗，请确认机房散热环境；10h 长测已 nohup 后台化，可脱离 ssh 会话，但**请勿在压测期间重启服务器**（结果目录会保留，但进程不会自动恢复）。

## 10. 组合测试（start combo）

一条命令同时压 **CPU + 内存 + 全部数据盘 hdd**（默认 10h，CPU/内存参数按实测推导，与 cpu/mem/hdd 单测相同）：

```bash
bash stress-test.sh start combo
```

要点：

- **数据盘需先挂载**（见第 3 节）：默认扫描 `/mnt/HDD*`，每盘一个 `stress --hdd 1 --hdd-bytes 10G` 后台进程，各自独立日志 `stress-HDD01.log`、`stress-HDD02.log` …；可用 `--dirs "/mnt/HDD01 /mnt/HDD02"` 指定。若未发现 `/mnt/HDD*` 挂载点，脚本会警告"未发现 /mnt/HDD* 挂载点，combo 模式无数据盘"，并**降级为仅 CPU/内存**（可配合 `--sysdisk` 只压系统盘），不会报错退出。
- **结果目录**为 `<时间戳>-combo/`：
  - `stress.log` —— CPU+内存组合进程（`stress --cpu N --vm M --vm-bytes X`）的原始输出；
  - `stress-HDD01.log`、`stress-HDD02.log` … —— 每数据盘一份；启用 `--sysdisk` 时另有 `stress-SYSDISK.log`；
  - `stress.exitcode` / `stress-HDDxx.exitcode` / `stress-SYSDISK.exitcode` —— 对应退出码（0 正常 / 非 0 异常）；
  - `monitor.csv`（30 秒一条系统状态）、`summary.txt`（review 生成）。
- **查看日志**（运行期间）：

  ```bash
  bash stress-test.sh status                                # 总览运行中任务
  tail -f /root/stress-test/<时间戳>-combo/monitor.csv      # 实时系统监控
  tail -f /root/stress-test/<时间戳>-combo/stress.log       # CPU+内存组合进程输出
  tail -f /root/stress-test/<时间戳>-combo/stress-HDD01.log # 某数据盘 hdd 输出
  ```

- **复盘**：与单测相同，`bash stress-test.sh review`（自动选最新结果目录）或 `bash stress-test.sh review --dir <结果目录>`；`summary.txt` 会列出各退出码文件。
- 组合 `--dirs` 与 `--sysdisk` 的完整用法（与脚本 usage 示例一致）：

  ```bash
  bash stress-test.sh start combo --dirs "/mnt/HDD01 /mnt/HDD02" --sysdisk   # CPU+内存+每盘 hdd+系统盘
  ```

## 11. 系统盘测试（--sysdisk）

系统盘 hdd 压测默认**关闭**：普通 `start hdd` / `start combo` 只压数据盘，不碰系统盘（disk-mount.sh 按 `df /` 识别系统盘并永不测试）。需要压系统盘时，在命令后**显式加 `--sysdisk`**：

```bash
bash stress-test.sh start hdd --sysdisk --dirs "/mnt/HDD01 /mnt/HDD02"   # 数据盘 + 系统盘
bash stress-test.sh start hdd --sysdisk      # 无 /mnt/HDD* 时自动降级为"仅压系统盘"
bash stress-test.sh start hdd --sysdisk-only # 仅压系统盘（无论是否有数据盘）
bash stress-test.sh start combo --sysdisk    # CPU + 内存 + 数据盘 + 系统盘
```

要点：

- `--sysdisk-only`：**无论是否有数据盘都只压系统盘**，不扫描 `/mnt/HDD*`（即使存在也不压）；仅对 hdd 模式生效，`combo` 模式会提示改用 `start hdd --sysdisk-only` 并退出，`cpu`/`mem` 模式提示忽略；不能与 `--dirs` 同时使用。
- `--sysdisk` **仅对 hdd/combo 模式生效**；用于 cpu/mem 模式会被忽略并提示"`--sysdisk` 仅对 hdd/combo 模式生效，cpu/mem 模式忽略该选项"。
- **运行位置**：系统盘 hdd 进程在 `/stresstest-hdd` 目录下运行（脚本自动创建，需 root 权限，创建失败会提示"无法创建系统盘压测目录 /stresstest-hdd"）。stress 会在此目录写压测文件（大小约等于 `--hdd-bytes`），**测试结束后脚本不自动清理**，确认结果已拷回后请手动清理：`rm -f /stresstest-hdd/*`（压测运行期间请勿执行）。
- **空间预检**：启动前脚本先检查 `/` 可用空间，要求 ≥ `hdd-bytes × 1.2`（如默认 `--hdd-bytes 10G` 需 ≥ 12G），不足则整体退出、不启动任何进程、不建结果目录，并提示"系统盘 / 可用空间不足"。注意 `--sysdisk` 的空间预检要求 `--hdd-bytes` **以 G 为单位**（如 `10G`）。
- **`--dirs` 勿与系统盘重复**：`--dirs` 显式指定的目录请勿包含 `/stresstest-hdd` 或系统盘相关路径（默认 `/mnt/HDD*` 扫描不涉及系统盘）。
- **建议先冒烟**：正式 10h 前先做一次 60s 冒烟验证全链路，结束后确认结果目录出现 `stress-SYSDISK.log` 且退出码为 0：

  ```bash
  bash stress-test.sh start combo --timeout 60s --sysdisk
  ```

  （若有数据盘需先挂载或用 `--dirs` 指定；无数据盘时会按第 10 节降级为 CPU/内存 + 系统盘。）

## 12. U 盘挂载与本地 yum 源管理（mount-iso.sh）

无外网服务器安装依赖（如 stress 缺依赖）时，用 `mount-iso.sh` 一键管理本地 yum 源，四个子命令：

```bash
# 进入离线包目录（按实际位置调整）
cd /root/offline-stress-pkg

# 1) 构建 yum 源：createrepo 生成 repodata（需 root）
#    RPM 来源优先级：U盘内（已挂载且含 *.rpm） > --rpm-dir > 包内 rpms/
sudo bash mount-iso.sh build
sudo bash mount-iso.sh build --rpm-dir /root/my-rpms    # ← 换成你实际的 RPM 目录

# 2) 一键：U盘挂载 → 复制源目录到 /opt/kylin-repo → 配置本地 yum 源
sudo bash mount-iso.sh mount

# 3) 查看 U 盘挂载与本地源状态
bash mount-iso.sh status

# 4) 卸载 U 盘（不影响已复制的本地源）
sudo bash mount-iso.sh umount
```

> 注意：脚本必须在包目录内执行（或写脚本绝对路径）；`build`/`mount`/`umount` 需 root，`status` 无需；`--rpm-dir` 后必须填**实际目录**，不能照抄 `/path/to/rpms`。

要点：

- **build**：在 RPM 目录执行 `createrepo --update` 生成 `repodata/`；结果复制到 `/opt/kylin-repo`，U 盘已挂载时另写一份 `<U盘>/kylin-repo`（方便拷到其他机器）。U 盘内 RPM 识别范围为 `maxdepth 2`，优先 `<U盘>/rpms` 子目录，仅以实际含 `*.rpm` 的目录作为源（避免把整盘复制进去）。需已安装 `createrepo`（`yum install createrepo` 或 `dnf install createrepo_c`），缺失时脚本直接提示并退出。
- **mount**：自动检测首块 USB 盘（`TRAN=usb`，系统盘硬排除）→ 挂载到 `/mnt/usb` → 在 U 盘内查找含 `repodata` 的目录 → 复制到 `/opt/kylin-repo` → 写 `/etc/yum.repos.d/kylin-local.repo`（`baseurl=file:///opt/kylin-repo`）。**repo 文件已存在时不覆盖（会提示实际 baseurl）**。**复制完成后 U 盘可拔，源仍可用**。
- **umount**：仅卸载 U 盘，**不删除** `/opt/kylin-repo` 与 repo 文件；清理需手动：`rm -rf /opt/kylin-repo`、`rm -f /etc/yum.repos.d/kylin-local.repo`。
- **建议先演练**：`DRY_RUN=1 bash mount-iso.sh mount` 只打印计划不落盘，核对无误后再正式执行。
- 可覆盖路径：`USB_MOUNT_POINT`（默认 /mnt/usb）、`REPO_DEST`（默认 /opt/kylin-repo）、`YUM_REPO_FILE`（默认 /etc/yum.repos.d/kylin-local.repo）。
- **安全弹出 U 盘**：`sudo bash usb-eject.sh` 自动识别 U 盘并卸载其全部挂载点（含 `/run/media`），加 `--poweroff` 可断电。
