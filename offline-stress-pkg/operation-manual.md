# 压测实操手册

Kylin V10 SP3 服务器 **CPU / 内存 / 硬盘** 压力测试操作手册（适用三类机型：海光 5380 / 7380 / 7360）。

配套脚本（本离线包内）：
- `stress-test.sh` —— 压测主控：`start cpu|mem|hdd|combo` / `status` / `stop` / `review` / `snapshot`
- `disk-mount.sh` —— 测试盘挂载/清空辅助：`list` / `mount` / `umount` / `clean`

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
sudo bash install.sh   # 安装 stress、dmidecode 与 nvme-cli（已是 root 可直接 bash install.sh；已装同版本会提示"已安装"）
bash verify.sh         # 验证：版本检查 + 10 秒冒烟压测 + dmidecode/nvme-cli 可用性
```

- `verify.sh` 检查 A/B 为版本校验、检查 C 为 10 秒冒烟压测、检查 D 为 dmidecode 可用性（缺失只 WARN）、检查 E 为 nvme-cli 可用性（缺失只 WARN）；若机器正在跑业务不想跑冒烟压测，可 `VERIFY_SKIP_SMOKE=1 bash verify.sh`。
- 离线包已内置 `rpms/dmidecode-3.2-10.el8.x86_64.rpm`，`install.sh` 会一并安装，装好后 `start mem/combo` 可直接自动探测内存条根数。
- 离线包已内置 `rpms/nvme-cli-1.14-3.el8.x86_64.rpm`，`install.sh` 会一并安装，供 `check-nvme-health.sh` 读取 NVMe SMART（`nvme smart-log` / `nvme list`）。
- **EDAC 不是可安装的软件**：它是内核 sysfs 接口（`/sys/devices/system/edac/mc`），取决于内核是否加载 `edac_core` 等模块，无法打进离线包；dmidecode 不可用时脚本才回退到它。
- 两个压测脚本无需安装，直接 `bash stress-test.sh …` / `bash disk-mount.sh …` 调用（在包目录内执行，或给脚本绝对路径）。
- 所有压测数据默认落在 `/root/stress-test/`（可用环境变量 `STRESS_TEST_ROOT` 改）。

## 2. 快速上手：四条命令

> 本节为**分步执行**时使用：逐条命令手工启动，适合只想压单项或需要自行控制节奏的场景。想一条命令跑完全流程，直接用 [2.1 一键全测](#21-一键全测oneclicksh)。

默认按**本机实测规格**推导参数（CPU `round(逻辑线程 × 25/32)`（SMT 参与分配：逻辑线程 = 物理核 × 每核线程数，SMT 探测开=2/关=1/未知默认开）、`--vm` 等于实际内存条根数、单 worker = `单条容量 − max(6G, 单条容量/8)`，三道上限取最小后自动下调，`mem`/`combo` 固定 `--vm-keep`，详见第 8 节），默认时长 **10 小时**（`--timeout 10h`）：

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

然后启动菜单，选 `1`（求稳强度压测）：

```bash
sudo bash oneclick.sh
```

菜单项：`1` 求稳强度压测 / `2` 中高强度整机压测 / `3` 测 CPU+内存（排除硬盘） / `4` 只测硬盘 / `5` 只测系统盘 / `6` 只测 CPU / `7` 只测内存 / `8` 查看状态 / `9` 生成复盘 / `10` 清空数据盘 / `0` 退出。也可用子命令，等价且便于脚本化（默认超时 10h）：

```bash
sudo bash oneclick.sh all --timeout 10h
sudo bash oneclick.sh hdd --timeout 8h
sudo bash oneclick.sh all --no-hdd --timeout 10h   # 排除所有硬盘（数据盘+系统盘），仅测 CPU+内存（COMBO peer=0）；跳过自动挂载，与 --rebuild 互斥；--no-hdd 仅 all 模式支持
sudo bash oneclick.sh full --timeout 10h           # 中高强度整机压测：全盘挂载 + COMBO 高强度参数 + 每盘 HDDxx + 系统盘
sudo bash oneclick.sh --high --timeout 10h         # 一键中高强度整机压测（等价 full，不弹菜单）
sudo bash oneclick.sh all --high                   # 等价 full（中高强度整机压测）
sudo bash oneclick.sh status
sudo bash oneclick.sh review
sudo bash oneclick.sh clean            # 清空全部非系统盘、非U盘（交互 y/N 确认；不进批次）
```

**全测做的事**（按顺序）：自动挂载 `disk-mount.sh mount --disks all --yes` → **COMBO**：CPU+内存组合任务（一个终端、一个结果目录，不再拆成独立的 CPU、内存任务）→ **每块数据盘一个 `HDDxx` 任务**（独立终端、独立结果目录）→ **SYSDISK**：系统盘任务（`--sysdisk-only`，独立终端）→ 等待全部结束 → 自动逐个 `review` 并生成汇总 → **自动清空本批数据盘**（默认开启，`--no-cleanup` 可关；范围 = 批次目录 `cleanup-devices.txt` 记录的本批盘，详见 §3.4）。

> COMBO 由 oneclick 自动带 `--peer-disks <数据盘数+1>`：内存计划会把同时在跑的各数据盘与系统盘计入页缓存预留，但 COMBO 只跑 CPU+内存，不在自己进程内启动 hdd，每块盘只由各自的 `HDDxx` 任务压一次。手工单测一般无需使用该参数（见第 10 节）。

**整机压测（`full` / `--high`，中高强度）**：编排结构与 `all` 完全一致（自动挂载 → COMBO 先启动 → 每盘 HDDxx → SYSDISK），COMBO 参数默认按**朋友规则**推导中高强度值（CPU≈`round(逻辑线程×70%)`、VM=DIMM 根数、vm-bytes=脚本单根推导公式 单条容量−`max(单条/8,6G)`），推导值作为**显式参数**写入 COMBO 计划、`--vm-bytes` 只告警不裁剪；`FULL_*` 显式设置可覆盖（显式优先，未设置项仍由推导补齐）：

- **求稳 vs 中高（何时用 `full` / 何时用 `all`）**：`full` / `--high`（中高）适合**整机验收、高负载找问题**——默认按朋友规则推导（CPU≈逻辑线程 70%、vm-bytes=脚本单根推导，如 5380 → 45/12/26G=312G），推导值显式下发不裁剪，靠页缓存兜底，**大内存 + 多盘并发下注意观察是否抖动 / OOM**；`all`（求稳）适合常规压测——脚本按本机实测自动推导参数（保守，受三道上限约束自动下调）。
- **默认参数**：按朋友规则推导——未设置 `FULL_CPU`/`FULL_VM`/`FULL_VMBYTES` 时由脚本按本机实测推导（64 逻辑线程/12×32G → `--cpu 45 --vm 12 --vm-bytes 26G`）；显式设置任一项时该项固定为所给值，其余项继续按推导补齐。
- **换机器覆盖参数**：`FULL_CPU` / `FULL_VM` / `FULL_VMBYTES` 三个环境变量可覆盖（如 `FULL_VMBYTES=32G sudo bash oneclick.sh full --timeout 10h`）；**未设置时按朋友规则推导**，换更大内存 / 更多核的机器无需调参即可自适应；显式覆盖时请按本机规格调整，避免强度不足或 OOM。
- **`--high` 一键中高**：无模式直接启动中高强度整机压测（等价 `full`，不弹菜单）——`sudo bash oneclick.sh --high --timeout 10h`；`all --high` 亦等价 `full`。与 `--no-hdd` **互斥**（中高强度必含硬盘，同时给出报错）；`cpu`/`mem`/`hdd`/`sysdisk` 带 `--high` 时提示"仅对整机（all/full）生效，本次忽略"；参数覆盖口径同 `full`（`FULL_CPU` / `FULL_VM` / `FULL_VMBYTES`）。
- **与 `all` 相同的口径**：`--rebuild` 对 full 生效（同 all）；`--no-hdd` 仅 all 模式支持，full 带 `--no-hdd` 会报错。


- **数据盘默认复用，`--rebuild` 才重建**：菜单选 `1`（求稳）/ `2`（中高）/ `4`（只测硬盘）时会在启动前询问一次 `是否重新分区并格式化数据盘？(y/N)：`，**默认 N**（直接回车即复用已有文件系统，输入 `y` 才重建）；子命令显式带 `--rebuild` 等效于回答 y，且菜单不再询问：

  ```bash
  sudo bash oneclick.sh all --rebuild
  sudo bash oneclick.sh hdd --rebuild
  sudo bash oneclick.sh full --rebuild
  ```

  未指定时输出 `未指定 --rebuild，本次复用已有文件系统；如需重建请加 --rebuild`；`sysdisk` / `cpu` / `mem` 带 `--rebuild` 会被忽略并提示"仅对 all/hdd/full 生效"。
- **部分盘挂载失败不中断**：自动挂载返回非 0 但已存在 `/mnt/HDD*` 时，`all` / `hdd` / `full` 模式会告警并继续启动已挂载盘的任务（一个挂载点都没有才退出）；批次 summary 标注 `自动挂载: 存在跳过/失败盘（退出码 N，未挂载盘未参与压测）`，批次最终退出码为 1。

- **窗口标题**：`压测-组合CPU+内存`（COMBO）、`压测-HDDxx`（每块数据盘）、`压测-系统盘`；单资源模式另有 `压测-CPU`、`压测-内存`。每个窗口内实时 `tail -f` 该任务的 `monitor.csv`，窗口之间互不影响。
- **窗口关掉不影响压测**：压测与监控本身以 `nohup` 后台运行，窗口只是查看入口；关掉窗口（或 Ctrl-C 只退出查看）压测继续，可再 `sudo bash oneclick.sh status` 查看。
- **无图形环境（SSH）自动降级**：检测不到 `DISPLAY` / `WAYLAND_DISPLAY` 或无可用终端时，自动改为后台并行执行，输出写入批次目录的 `<任务>.out`。需要强制后台（不弹窗）时：

  ```bash
  ONECLICK_GUI=0 sudo -E bash oneclick.sh all
  ```

- **失败策略**：**COMBO 启动失败 → 中止本批次**，不再启动后续数据盘与系统盘，批次退出码 1（核心 CPU+内存负载没起来）；**数据盘 / SYSDISK 启动失败 → 记录到 `failed-tasks.txt` 后跳过**，继续启动其余任务，批次最终退出码 1。现场看到最终 `rc=1` 时，先看 `summary.txt` 的"启动失败（跳过、未计入复盘）"和 `failed-tasks.txt`（含每个失败任务的完整命令）：失败的盘按记录命令单独重跑即可，已成功启动的任务结果不受影响；若 `rc=1` 但无失败任务，则看各任务结论是否有异常。
- **结果位置**：每次运行在 `/root/stress-test/oneclick-<时间>/` 建一个批次目录，汇总在 `/root/stress-test/oneclick-<时间>/summary.txt`。各任务的完整结果在各自的 `<时间戳>-<类型>/` 结果目录：**COMBO 只有一个结果目录**（`<时间戳>-combo/`，仅 CPU+内存组合进程与其 `monitor.csv`，不含任何 hdd 数据），**每块数据盘各自一个** `<时间戳>-hdd/`（该盘的 `stress-HDDxx.log`、`monitor.csv`、`summary.txt`），**系统盘一个** `<时间戳>-hdd/`（仅 `stress-SYSDISK.log` 等系统盘结果）；`summary.txt` 末尾列出全部结果目录。存在异常结论、挂载跳过/失败、或任务启动失败时，批次退出码 1。批次目录内主要文件：

  | 文件 | 含义 |
  |---|---|
  | `summary.txt` | 一键汇总：逐任务结论 + 各任务结果目录 |
  | `plan.txt` | 任务计划（启动前），格式 `id\|类型\|附加参数` |
  | `tasks.txt` | 已启动任务，格式 `id\|类型\|结果目录` |
  | `failed-tasks.txt` | 启动失败被跳过的任务，格式 `任务ID\|完整命令`（summary 同步列出） |
  | `aborted` | COMBO 启动失败、批次中止的标记文件 |
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
- 自动清理前打印 `  $ bash /root/offline-stress-pkg/disk-mount.sh clean --disks <盘列表> --yes`（仅 all/full/hdd 且未 `--no-cleanup` 的批次）；
- 每个任务窗口的首屏也会显示同样一条启动命令 banner：`==== HDD01 启动命令 ====` / `  $ …` / `======================`（窗口标题不变）。

批次目录内同时生成三个命令记录文件（每次运行重建）：

| 文件 | 用途 |
|---|---|
| `commands.txt` | 本次实际执行过的命令，一行一条、可直接复制；复盘命令自动去重只记一次 |
| `commands.sh` | 可直接 `bash commands.sh` 重放的启动脚本（含 shebang、批次路径、重放警告、`set -u`；只含挂载与各任务启动命令，**不含** review；权限 0644） |
| `env.txt` | 本次执行环境快照：`BATCH` / `MODE` / `START_TIME` / `TIMEOUT` / `STRESS_TEST_ROOT` / `STRESS_TEST_SH` / `DISK_MOUNT_SH` / `TERM_KIND` / `POLL_INTERVAL` / `READY_TIMEOUT` / `REBUILD` / `SHOW_CMD` / `CLEANUP` |

> **警告**：`bash commands.sh` 会**重新发起一轮压测（all/hdd 批次还会先重新挂载）**（生成新的结果目录），不是"查看历史"。只想回看本次执行了什么命令，用 `cat <批次>/commands.txt`；重放后复盘新结果用 `bash stress-test.sh review --dir <新结果目录>`。

- **关闭终端显示**：`sudo bash oneclick.sh all --quiet`（或 `ONECLICK_SHOW_CMD=0 sudo -E bash oneclick.sh all`）不再打印命令，但 `commands.txt` / `commands.sh` / `env.txt` 照常生成；启动失败时"该任务压测命令（可直接复制重跑）："提示**始终显示**（便于立即重试）。
- **事后查看**：`sudo bash oneclick.sh status` 在存在批次且 `commands.txt` 存在时会提示 `查看本次执行过的命令：cat <批次>/commands.txt`。

## 3. 硬盘压测完整流程

流程：`list` → `mount` → `start hdd` → 完成后清理（自动或手动，见 3.4）。

### 3.1 查看块设备与系统盘

```bash
bash disk-mount.sh list
```

输出会标出**系统盘**（`df /` 的底层盘，标"（系统盘，跳过）"，永不测试）以及每块非系统盘的状态：
- 已挂载（跳过）
- 有分区（默认测首个分区；分区有文件系统直接挂载，无文件系统先 `mkfs.ext4 -m 0` 该分区）
- 未分区但已有文件系统（将直接挂载，不重新格式化）
- 未分区空盘（将 `mkfs.ext4 -m 0` 后挂载）

### 3.2 挂载测试盘（交互流程）

```bash
bash disk-mount.sh mount
```

交互流程：

1. 列出全部可用非系统盘（盘符、容量、状态），提示 `输入要纳入测试的盘符（逗号分隔，all 全部）：`，输入如 `sdb,sdc` 或 `all`；
2. 脚本打印**完整执行计划**：每盘一行显示设备、容量、动作，例如 `有分区：直接挂载 /dev/sdb1 → /mnt/HDD01`、`分区无文件系统：mkfs.ext4 -m 0 /dev/sdb1 后挂载 → /mnt/HDD01`、`无分区空盘：mkfs.ext4 -m 0 /dev/sdb 后挂载 → /mnt/HDD01`、`重建：清空分区表 → 建 1 分区 → mkfs.ext4 -m 0 /dev/sdb1 → /mnt/HDD01`；
3. 提示 `请确认执行以上计划（y/N）：`，**单个 `y` 确认后才执行**；输入其他任意内容则取消、不执行任何操作；
4. 执行：默认模式按计划挂载/格式化，`--rebuild` 按重建步骤执行；每步写入挂载日志 `/root/stress-test/mount.log`。

**默认模式（不清盘）**：

- 有分区 → **只测首个分区**：分区已有文件系统直接挂载；分区无文件系统自动 `mkfs.ext4 -m 0 <分区>` 后挂载；
- 无分区 → 整盘已有文件系统直接挂载（不重新格式化）；空盘整盘 `mkfs.ext4 -m 0` 后挂载；
- 多分区盘计划中显式提示 `本盘有 N 个分区，默认仅测第一个（sdb1，xxxG）；需要整盘覆盖请用 --rebuild`；
- 默认只取首个**非扩展分区**：msdos 扩展分区（`0x5`/`0xf`/`0x85`）不参与格式化；若只发现扩展分区容器，或存在分区表但解析不到可用分区，该盘跳过且不自动格式化（需要重建请加 `--rebuild`），最终退出码 1；
- `blkid` 探测失败会重试 5 次（间隔 1 秒），仍失败则**跳过该盘、绝不格式化**，其他盘继续，最终退出码 1（汇总 `因 blkid 失败跳过：sdb（5 次探测均失败，未格式化）`）；
- 挂载点编号**不复用**：已占用的 `/mnt/HDDnn` 会跳过，按最小可用编号分配（预置 `HDD01` 时新盘用 `HDD02`）；
- 已挂载的盘跳过；同盘存在非 `/mnt/HDD*` 挂载点（含 LVM/RAID 后代）时显式提示并跳过。

**重建模式（`--rebuild`，会清空该盘分区表）**：

- 步骤：卸载该盘 `/mnt/HDD*` 旧挂载 → `parted -s <盘> mklabel gpt` → `mkpart primary ext4 1MiB 100%` → `partprobe` → `udevadm settle` → 解析分区（NVMe 为 `p1`，不盲拼）→ `mkfs.ext4 -m 0 <分区>` → 挂载分区；
- 任一步失败只跳过该盘、继续其他盘，结束时退出码 1 并列出失败盘与原因；
- 同盘存在非 `/mnt/HDD*` 挂载点（业务数据，含 LVM/RAID 后代）时整盘跳过、不做任何写操作；系统盘任何模式都不进入该流程；
- 重建会**清空该盘全部数据与分区表**，执行前务必核对盘符与容量。

三种常用命令：

```bash
# 1) 默认复用已有文件系统（已有 ext4 分区直接挂载；仅无文件系统的分区/空盘做 mkfs）
bash disk-mount.sh mount --disks sdb,sdc

# 2) 重建：清空分区表 → 建 1 个分区 → mkfs.ext4 → 挂载（会清空数据盘，需 y 确认）
bash disk-mount.sh mount --disks sdb,sdc --rebuild

# 3) 预演：只打印计划，不执行任何写操作、不写 mount.log
bash disk-mount.sh mount --disks sdb,sdc --dry-run
```

要点：

- **默认不清盘**：只有显式 `--rebuild` 才会清空分区表；默认复用流程中的 `mkfs` 仅针对"分区无文件系统"或"空盘"，且执行前必有"计划 + y 确认"两道关卡；
- 挂载点按最小可用编号分配：`/mnt/HDD01`、`/mnt/HDD02` …（已占用编号不复用）；
- 选择含系统盘或无效盘会被拒绝并退出（exit 1）；
- 系统盘识别不可靠（`df /` 不是 `/dev/*`、`lsblk` 不认识该设备等）时，非 dry-run 直接中止、不执行任何写操作；
- 非交互环境（无终端）必须指定盘：`bash disk-mount.sh mount --disks sdb,sdc`（等价于交互选择，`all` = 全部）；
- **预演用 `--dry-run`（等价 `DRY_RUN=1`）**：`bash disk-mount.sh mount --disks all --dry-run` 只打印执行计划、不执行任何写操作（含不写 mount.log），末尾固定输出 `（DRY RUN，未执行）`，退出码与真实执行一致。

### 3.3 启动硬盘压测

```bash
bash stress-test.sh start hdd
```

- 默认扫描 `/mnt/HDD*` 全部挂载点，每盘一个 `stress --hdd 1 --hdd-bytes 10G` 后台进程，各自独立日志 `stress-HDD01.log`、`stress-HDD02.log` …（stress 的 hdd 模式在当前目录写压测文件，因此每盘必须在各自挂载点下运行，脚本已自动 cd 进各目录）；
- **压测目录必须是独立挂载点**：脚本启动前逐个校验（默认 `/mnt/HDD*` 与显式 `--dirs` 都校验），未挂载或落在系统盘根文件系统上会直接拒绝（退出码 1，不启动压测、不建结果目录）；
- 只测指定盘：`bash stress-test.sh start hdd --dirs "/mnt/HDD01 /mnt/HDD02"`；
- 盘未挂载时脚本会报错并提示（见第 7 节）。

### 3.4 测试完成后清理

压测结束、结果已拷回后，按需清空数据盘（恢复到空白状态，便于下次直接重建或交接）。

**一键全测自动清理（默认开启）**：`oneclick` 的 `all` / `full` / `hdd` 批次在复盘结束后**自动清空本批数据盘**（范围 = 批次目录 `cleanup-devices.txt` 中记录的本批数据盘整盘名）；不需要时加 `--no-cleanup` 关闭（如 `sudo bash oneclick.sh all --no-cleanup`）。清理结果追加进批次 `summary.txt`（`数据盘清理: ...`）；盘已不存在、或盘上出现非 `/mnt/HDD*` 挂载点（业务数据）时自动跳过并在 summary 标注，不整批失败；清理失败只标注并提示手动命令，**不改变复盘结论与批次退出码**。仅想卸载测试盘、保留数据时用 `bash disk-mount.sh umount`（确认后逐个卸载；`--all` 跳过确认）。

**手动一键清空（disk-mount.sh clean）**：

```bash
bash disk-mount.sh clean                        # 清空全部非系统盘、非U盘（逐盘打印计划后 y 确认）
bash disk-mount.sh clean --disks sdb,sdc        # 只清指定盘（分区自动归一为整盘）
bash disk-mount.sh clean --disks sdb,sdc --yes  # 跳过 y 确认（供脚本化调用）
bash disk-mount.sh clean --dry-run              # 只打印执行计划，不执行任何写操作
```

- **语义**：逐盘 `umount` 全部子树挂载点（含业务挂载点盘，计划中醒目标注、需自行确认）→ `wipefs -a <整盘>` 清空文件系统/分区表签名 → `partprobe` 刷新，盘回到**空白状态**（无分区、无签名）；只清理、**不重建分区表**（重建用 mount `--rebuild`，见 §3.2）；
- **安全**：**系统盘与 U 盘永不清理**——默认范围只含非系统盘、非U盘，`--disks` 显式指定系统盘 / U 盘 / 不存在的盘会直接拒绝退出（退出码 1）；系统盘识别不可靠时非 dry-run 中止、零写操作；空白盘自动跳过；执行前必打印计划并要求 `y` 确认（`--yes` 跳过，供 oneclick 自动清理调用）；
- **不影响 SMART 数据**：`wipefs` 只清块设备上的文件系统/分区签名，**不读写 SMART 属性**——清理后盘的**通电时间、通电次数**等统计保持不变（SMART 属固件统计，与块设备内容无关）。

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
│   ├── runtime-snapshot.txt # 启动/60s/600s/每 600s 的进程快照（cmdline、cwd、VmRSS、Threads）
│   ├── actual-params.txt  # 最新实际参数（CPU/VM worker、vm-bytes、vm-keep、hdd 进程与 cwd）
│   ├── runtime-final.txt  # 结束时的最终状态、退出码与实际参数副本
│   ├── stress.log         # stress 原始输出（hdd 模式为 stress-HDDxx.log 每盘一份；combo 为 CPU+内存进程输出，各盘/系统盘另见 stress-HDDxx.log、stress-SYSDISK.log）
│   ├── stress.exitcode    # stress 退出码（hdd 模式为 stress-HDDxx.exitcode 每盘一份；combo 另含 stress-SYSDISK.exitcode）
│   ├── error.log / error-HDDxx.log / error-SYSDISK.log  # stress stderr 与内核 I/O/OOM 报错（空=无错误；I/O 报错带 `dmesg io:` 前缀）
│   ├── error-unattributed.log  # 无法归因到本盘的 I/O 报错条数来源（只计数，不计入本盘结论）
│   ├── devices.txt        # 本任务压测盘设备名（分区名 + 整盘名 + lsblk KNAME，用于 I/O 报错归因）
│   ├── disk-map.txt       # 全机数据盘定位表（每行 `设备名 | SN | 挂载点`，SN 经 sysfs 零依赖采集，供按 SN 定位物理盘）
│   ├── status.txt         # 运行状态（state=OK/FAILED/ABORTED/STOPPED、oom、io 等）
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

`review` 读取该目录的监控与配置，生成并打印 `summary.txt`，包含：`结论:`、类型、机型、开始时间、计划超时、预计结束时间（按监控覆盖时长估算）、监控数据行数、监控覆盖时长、**CPU 使用率均值/峰值、内存峰值（kB）、磁盘读/写峰值（MB/s）**、各 stress **退出码**（0 = 正常结束，非 0 = 异常或被中断）、**执行一致性**以及原始数据文件清单。

**执行一致性**：`review` 把 `run-config.txt` 的计划值与 `actual-params.txt` 的实际 CPU/VM worker、`--vm-keep`、hdd 进程数、cwd、RSS 逐项对拍，输出 `== 执行一致性 ==` 的 PASS/FAIL/UNKNOWN。UNKNOWN（旧目录、缺字段、只有 start/60s 快照）不改变结论；FAIL 只在原结论为“正常”时改为“异常（执行与计划不一致）”，I/O/ENOSPC/STOPPED 优先级不变。运行中可用 `bash stress-test.sh snapshot <结果目录>` 手动补抓一次快照，仅作展示。

**结果判定（结论优先级，后者不覆盖前者）**：

| 优先级 | 命中条件 | 结论 |
|---|---|---|
| 1 | 内核 I/O 错误：`error.log` 含 `dmesg io:`（如 `EXT4-fs error`、`I/O error`、`Buffer I/O error`、`blk_update_request`、`critical medium error`、`ata`/`nvme` 错误） | `异常（内核 I/O 错误，见 error.log）`——**`status.txt` 为 `OK` 也不改变** |
| 2 | `error.log` / `error-HDD*.log` / `error-SYSDISK.log` 命中 `No space left on device` | `异常（空间不足 ENOSPC，非磁盘故障）` |
| 3 | `error.log` 命中 `检测到 stress` / `dmesg` | `异常（压测进程/内核报错，见 error.log）` |
| 4 | 按 `status.txt` | `OK` → 正常；`FAILED` → 异常（退出码非 0）；`ABORTED` → 按原因；`STOPPED` → 已手动停止 |

- **I/O 错误即异常**：内核 I/O 报错优先于 `status=OK`；报错按设备归因，`devices.txt` 记录本任务的分区名与整盘名（如 `sdb1`、`sdb`、`dm-0`），只有本盘设备的报错写入 `error.log`；报错行带 SN 标注（`dmesg io: (dev=nvme2n1 SN=SH231801357) <原始行>`，SN 经 sysfs 零依赖采集）；
- **未归因条数含义**：无法归因到本盘（或 `devices.txt` 缺失，如同机其他盘报错）的 I/O 报错写入 `error-unattributed.log`，`summary.txt` 显示 `未归因内核 I/O 错误 N 条（error-unattributed.log，不计入本盘结论）`——不改变本盘结论，但说明整机存在其他 I/O 报错，需人工核查；
- **ENOSPC 与盘故障区分**：`No space left on device` 表示写入量超过可用空间（如首分区小于 `--hdd-bytes`），结论单独标注"非磁盘故障"，不要按坏盘处理；
- **系统盘口径**：系统盘任务的 `run-config.txt` 与 `summary.txt` 回显 `压测对象: 系统盘（根文件系统压测）` 与 `覆盖边界: 不覆盖 /boot、/boot/efi、swap、未分配空间；LVM/RAID 下写入可能跨多个物理盘`。

> 说明：结论基于上述证据（错误日志 + 状态文件）自动给出，最终判定仍建议结合业务影响与硬件巡检结果。

原始数据文件清单与含义：

| 文件 | 含义 |
|---|---|
| `run-config.txt` | 本次测试参数与命令原文（资源计划含 `smt=` SMT 状态字段，SMT 参与 CPU worker 分配；系统盘任务另含压测对象/覆盖边界） |
| `info-before.txt` | 测试前系统快照 |
| `monitor.csv` | 全程 30s 一条的系统状态原始数据 |
| `runtime-snapshot.txt` | 启动/60s/600s/每 600s 的进程快照（cmdline、cwd、VmRSS、Threads） |
| `actual-params.txt` | 最新实际参数（CPU/VM worker、vm-bytes、vm-keep、hdd 进程与 cwd） |
| `runtime-final.txt` | 结束时的最终状态、退出码与实际参数副本 |
| `stress.log` / `stress-HDDxx.log` / `stress-SYSDISK.log` | stress 原始输出（hdd 逐盘一份；combo 组合进程 + 系统盘） |
| `stress.exitcode` / `stress-HDDxx.exitcode` / `stress-SYSDISK.exitcode` | 退出码（0 正常 / 非 0 异常） |
| `error.log` / `error-HDDxx.log` / `error-SYSDISK.log` | stress stderr 与内核 I/O/OOM 报错（I/O 报错带 `dmesg io:` 前缀） |
| `error-unattributed.log` | 无法归因到本盘的 I/O 报错（只计数，不改本盘结论） |
| `devices.txt` | 本任务压测盘设备名（分区名 + 整盘名 + lsblk KNAME） |
| `disk-map.txt` | 全机数据盘定位表（设备名 \| SN \| 挂载点，SN 经 sysfs 零依赖采集） |
| `status.txt` | 运行状态（`state=`、`oom=`、`io=` 等） |
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
硬盘测试前必须先挂载：`bash disk-mount.sh mount`；或显式指定 `--dirs "/mnt/HDD01 …"`。显式 `--dirs` 的目录同样会校验是否为独立挂载点，不是则直接拒绝启动（退出码 1）。

**挂载时提示"因 blkid 失败跳过：sdb"？**
表示该盘/分区的文件系统探测连续 5 次失败（设备忙、未就绪、权限等），脚本**不会格式化该盘**、直接跳过，其他盘照常挂载，结束时退出码 1。请等设备就绪（`udevadm settle`）后重跑；若多块盘中只有部分失败，可先用已挂载成功的 `/mnt/HDD*` 开始压测。

**结论为"异常（空间不足 ENOSPC，非磁盘故障）"？**
压测写入量超过该盘可用空间（常见于首分区容量小于 `--hdd-bytes`，默认 10G）。属空间不足、不是坏盘，可换大分区或调小 `--hdd-bytes` 后重测；`disk-mount.sh mount` 计划中会提前提示"首分区容量可能不足以写入 10G，可能 ENOSPC"。

**结论为"异常（内核 I/O 错误，见 error.log）"？**
`dmesg` 增量检测到该盘设备的 I/O 报错（`EXT4-fs error`、`I/O error`、`Buffer I/O error`、`blk_update_request`、`critical medium error`、`ata`/`nvme` 错误等），即使 `status.txt` 为 `OK` 也判异常。需结合 `error.log` 原始行与硬件巡检判断是否换盘；`summary.txt` 中"未归因内核 I/O 错误 N 条"表示另有报错无法归因到本盘（不计入本盘结论），也建议一并核查。

**监控进程什么时候退出？**
`monitor-loop` 在 `stress.pids` 中所有进程消失后自动结束（正常跑完或被停止后）。若压测还在跑但 status 显示"监控进程: 已退出"，属异常，请反馈。

**--model 有什么用？**
`--model` **只影响报告标注，不参与任何参数分配**：支持海光四位数字型号（如 5380/7380/7360/9800）、AMD EPYC（如 `EPYC-7763`）、Intel Xeon（如 `Xeon-6338`）。默认 `auto` 优先从 CPU 信息**智能识别多品牌型号**：从 `lscpu "Model name"`（或 `/proc/cpuinfo "model name"`）按品牌提取——海光 `C86-3G` 后型号数字（如 `Hygon C86-3G 9800` → 9800）、AMD `EPYC` 后型号（如 `AMD EPYC 7763` → `EPYC-7763`）、Intel `Xeon` 后型号（如 `Intel(R) Xeon(R) Gold 6338` → `Xeon-6338`），兼容中英文输出（Model name / 型号名称）、大小写与多空格；无品牌匹配返回空、不误报。识别成功时启动日志打印"检测到机型 X（来源: 智能识别 CPU 信息）"，识别值写入 `run-config.txt` 机型字段，复核可一眼看到型号来源；识别失败才回退**逻辑线程分界**：`逻辑线程 ≥ 120 → 7380`；`≥ 90 → 7360`；`≥ 64 → 5380`；线程不可用（n=0）时按内存兜底：`MemTotal ≥ 800G → 7380`、`≥ 450G → 7360`、否则 `5380`（来源标注"逻辑线程分界/内存兜底"）。识别结果还会与实测逻辑线程**交叉校验**：不一致（偏差 >10%）时明确提示"型号识别结果与实测线程不符"；**仅海光四位数字型号与实测矛盾时才按实测线程分界修正**并提示（如检测 5380 标称 64 线程、实测 128 线程 → 修正为 7380）；AMD/Intel 品牌型号（EPYC-xxxx / Xeon-xxxx）保留品牌标注、不做分界修正；型号标称未知（如 `EPYC-9999`）跳过标称校验、不误报。实测线程数与机型标称值（海光 5380=64 / 7360=96 / 7380=128；AMD EPYC-7763=128 / EPYC-7543=64；Intel Xeon-6338=64 / Xeon-8380=112，未知型号跳过交叉校验）偏差 >10% 时提示疑似单路 CPU，参数仍按实测推导。CPU/内存参数不需要 `--model`，也可手动指定：`bash stress-test.sh start mem --model EPYC-7763`。

**报"未找到 stress"？**
先运行 `sudo bash install.sh` 安装，再 `bash verify.sh` 验证。

**参数记不住？**
不带参数直接运行 `bash stress-test.sh` 或 `bash disk-mount.sh`，会打印完整用法。

## 8. 参数推导规则（按实测规格，不查机型预设）

`start cpu|mem|combo` 的 CPU/内存参数在启动时由本机实测值推导，**不再按机型查表**：

| 参数 | 推导规则 | 环境变量（默认值） |
|---|---|---|
| CPU worker 数 | `round(逻辑线程 × 25/32)`，下限 1；逻辑线程 = 物理核 × 每核线程数（SMT 探测：开=2、关=1、未知默认开）；SMT 开启 5380/7360/7380 → 50/75/100，SMT 关闭 → 25/38/50 | 物理核识别失败时回退 `round(nproc × 78%)`：`CPU_MAX_PCT=78` |
| `--vm` 内存条根数 | 等于实际内存条根数：`dmidecode -t 17` 统计已安装槽位；失败回退 EDAC（`/sys/devices/system/edac/mc`） | `DMI_BIN=dmidecode`、`EDAC_ROOT=…` |
| 单 worker 字节 | `单条容量 − max(6G, 单条容量/8)`（32G→26G、64G→56G、128G→112G） | — |
| 兜底单 worker | 混合容量 / EDAC 无容量 / 显式 `--vm` ≠ DIMM 根数：`MemTotal × 82% ÷ 根数` | `MEM_TARGET_PCT=82`（仅兜底路径） |
| 分配上限 | `min(模块总容量 × 88%, MemTotal × 92%, MemTotal − (盘数 × hdd-bytes × 1.2 + 8G))`，超限逐 GiB 下调单 worker | `MEM_MAX_PCT=88`、`MEM_TOTAL_MAX_PCT=92`、`DISK_CACHE_FACTOR_PCT=120`、`DISK_CACHE_MIN_G=8` |
| `--vm-keep` | `mem` / `combo` 固定追加（内存常驻、压力持续），`cpu` / `hdd` 不加 | — |

- **SMT 状态参与 CPU worker 分配**：`smt_tpc`/`smt_status`（`lscpu Thread(s) per core` → `/sys/devices/system/cpu/smt/active` → `control` → 未知）探测每核线程数，逻辑线程 = 物理核 × tpc（未知默认按开 tpc=2），CPU worker = `round(逻辑线程 × 25/32)`；结果写入 run-config 的 `smt=` 字段，同时用于资源计划标注与机型交叉校验；SMT 关闭（每核1线程）时逻辑线程减半，worker 相应减半（5380→25、7360→38、7380→50）。
- **三道上限取最小**：`cap_module`（模块总容量 × 88%，避免吃穿模块容量）、`cap_mem`（MemTotal × 92%，防 OOM）、`cap_disk`（MemTotal − 盘数 × hdd-bytes × 1.2 − 8G，给页缓存/脏页留空间）。盘越多、内存越小，自动压得越低。`combo` / `mem` 的"盘数"取 `max(实际盘目录数 + --sysdisk, --peer-disks N)`（未传 `--peer-disks` 时仅按实际盘数）。
- **多盘自动下调示例**（12 块数据盘、`--hdd-bytes 10G`，磁盘预留 12×10G×1.2+8G = 152G）：

  | 内存规格 | `cap_disk` | 单 worker | 实际下发总量 |
  |---|---|---|---|
  | 512G / 16×32G | 360G | 22G | 352G |
  | 768G / 24×32G | 616G | 25G | 600G |
  | 1024G / 16×64G | 872G | 54G | 864G |
  | 1152G / 18×64G | 1000G | 55G | 990G |

  > 上表按标称容量估算；实际 MemTotal 略低，脚本按 MemTotal 计算时单 worker 可能再低 1G（例如 512G 场景约 21G、1024G 场景约 53G）。

- **内存条根数探测失败**（dmidecode 结果无效（0 或超过 256）时自动回退 EDAC；dmidecode 与 EDAC 两路来源都无效才算探测失败）：本次 `start mem/combo` 直接中止（退出码 1，不建结果目录、不启动 stress），并直接给出**可复制执行的建议命令**——按本机 MemTotal 算好 16 个 worker 与单 worker 字节（兜底总量 = 82%，不超 92%），例如 `bash stress-test.sh start mem --vm 16 --vm-bytes <脚本推导值>G --timeout 10h`；若知道实际根数，推荐只填根数 `bash stress-test.sh start mem --vm <实际根数>`，单 worker 字节由脚本自动推导。MemTotal 也读不到时，建议命令改为同时给 `--vm` 与 `--vm-bytes`。根数可从开机 BIOS 内存信息、机箱/主板标签获取，或 `sudo lshw -class memory | grep -c 'bank:'`；离线包已内置 `rpms/dmidecode-3.2-10.el8.x86_64.rpm`，`sudo bash install.sh` 后即可恢复自动探测。`start cpu` 不受影响。
- **MemTotal 不可读**（`/proc/meminfo` 无 MemTotal）且走自动推导：同样中止（退出码 1）；若显式给了 `--vm-bytes`，则按显式值继续，并在 `run-config.txt` 标注"未做内存裁剪"。
- **单 worker 不足 1G**（如 MemTotal 4G / 16 根）：报错退出（退出码 1），提示"单 worker 内存不足 1G（MemTotal XG / N 根），无法压测"。
- **显式参数优先**：`--cpu` / `--vm` / `--vm-bytes` 给出即原样使用，自动推导只补未给出的参数；显式 `--vm-bytes` 不做分配上限裁剪（仅打印超限警告）。
- `--model` 仅用于 `run-config.txt` / `review` 的机型标注与"实测线程 vs 标称线程"交叉校验，**不参与参数分配**。

### 8.1 四组标定案例回算（v3 回归样本）

| 内存规格 | DIMM 根数 | 单根容量 | 推导 `--vm` | 单 worker | 实际下发总量 | 占模块总容量 |
|---|---|---|---|---|---|---|
| 512G | 16 | 32 GiB | 16 | 26G | 416G | 81.25% |
| 1024G | 16 | 64 GiB | 16 | 56G | 896G | 87.5% |
| 1152G | 18 | 64 GiB | 18 | 56G | 1008G | 87.5% |
| 768G | 24 | 32 GiB | 24 | 26G | 624G | 81.25% |

> 四组均为 64 物理核、SMT 开启（128 逻辑线程），CPU worker 统一推导为 `round(128 × 25/32) = 100`；单 worker 按单条容量规则推导，总量均落在模块总容量 88% 上限内。数据盘较多时再受 `cap_disk` 约束自动下调（见上表）。

默认 `--timeout 10h`。**显式参数可覆盖自动推导**：`--timeout`、`--cpu`、`--vm`、`--vm-bytes`、`--hdd-bytes`、`--dirs`、`--peer-disks`（仅 combo/mem）均可手动指定；hdd/combo 模式还可加 `--sysdisk`（压系统盘，见第 11 节），例如：

```bash
bash stress-test.sh start cpu --timeout 6h --cpu 64
bash stress-test.sh start mem --vm 12 --vm-bytes 60G
```

## 9. 安全提示

- **系统盘永不测试**：disk-mount.sh 按 `df /` 识别系统盘并在任何分支硬跳过，`list` 中标出；选择含系统盘的盘符会被直接拒绝。stress hdd 压测只跑在 `/mnt/HDD*` 挂载点（或 `--dirs` 指定的目录），不涉及系统盘。
- **默认复用、不整盘清空**：`disk-mount.sh mount` 默认只挂载已有文件系统，仅对"无文件系统的分区"或"空盘"执行 `mkfs.ext4 -m 0`；但请注意 `mkfs` 仍会覆盖该分区/整盘原有内容——执行前必打印计划并要求 `y` 确认，确认前务必核对盘符、容量、动作。
- **`--rebuild` 会清空数据盘分区表**：只有显式 `--rebuild`（或 oneclick 菜单输入 `y`）才卸载旧 `/mnt/HDD*`、清空分区表并重建 1 个分区；同盘存在非 `/mnt/HDD*` 挂载点（业务数据）时整盘跳过。正式执行前建议先 `bash disk-mount.sh mount --disks all --dry-run` 核对计划。
- **执行前确认计划**：mount 的挂载计划、umount 的卸载清单都要确认无误后再执行；start 启动后可在结果目录的 `run-config.txt` 核对实际机型与参数（`status` 只显示类型、进程数、剩余时长等概览）。
- **内存总量勿超物理内存**：`start mem/combo` 默认按本机实测推导——单 worker 按 `单条容量 − max(6G, 单条容量/8)`，总量受**三道上限取最小**约束（`模块总容量 × 88%`、`MemTotal × 92%`、`MemTotal − (盘数 × hdd-bytes × 1.2 + 8G)`，环境变量 `MEM_MAX_PCT` / `MEM_TOTAL_MAX_PCT` / `DISK_CACHE_FACTOR_PCT` / `DISK_CACHE_MIN_G`），超出时自动下调并在启动输出与 `run-config.txt` 中标注，无需手工换算；**分配上限不是验收达成阈值**，两者不可混用。显式 `--vm-bytes` 不受该机制约束（仅打印警告），手动调大时请自行核对，避免 OOM。
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
- **高级：`--peer-disks N`**（仅 `combo` / `mem`）：声明"外部另有多少路并发 hdd 流"，只参与内存预留（`cap_disk` 取 `max(实际盘目录数+--sysdisk, N)`）与展示，不启动 hdd 进程；**出现该参数即不再自动扫描 `/mnt/HDD*`**，此时只有显式 `--dirs` 才会在 combo 内起 hdd，`--peer-disks 0` 表示纯 CPU+内存。oneclick `all` 会自动传（值 = 数据盘数+1），手工单测一般不用。
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
- **压测对象与覆盖边界**：系统盘压测即**根文件系统压测**（不分区、不格式化、不挂载），`run-config.txt` 与 `summary.txt` 会写明 `压测对象: 系统盘（根文件系统压测）` 与 `覆盖边界: 不覆盖 /boot、/boot/efi、swap、未分配空间；LVM/RAID 下写入可能跨多个物理盘`——结论只代表根文件系统所在存储链路，不代表整块系统盘或全部物理盘。
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
