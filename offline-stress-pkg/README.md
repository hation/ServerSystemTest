# stress 离线安装与使用说明（Kylin V10 SP3）

## 1. 背景与适用环境

- 当前包版本：v1.1.2（打包时按语义化递增：修复/小改动补丁号+1，新增功能次版本号+1，破坏性变更主版本号+1）
- 本包用于在**无网络**的服务器上离线安装 Linux 压测工具 `stress`（1.0.4）。

- 适用系统：Kylin V10 SP3 2403 **x86_64**
- 传输方式：通过 **U 盘**拷贝到服务器
- 参考服务器配置：Hygon 7380 双路 CPU（**64 物理核**）、**1024 GB 内存**（仅第 8 节的手工 `stress` 示例基于该配置；`stress-test.sh` 的正式压测参数按本机实测推导）
- 软件包：`stress-1.0.4-24.el8.x86_64.rpm`、`dmidecode-3.2-10.el8.x86_64.rpm`（含 SHA256 完整性校验；dmidecode 用于自动探测内存条根数）

## 2. 包结构说明

```
offline-stress-pkg/
├── README.md                      本说明文档
├── install.sh                     安装脚本（含 root 检查、SHA256 校验、已装同版本检测）
├── verify.sh                      验证脚本（检查安装版本 + 10 秒冒烟压测 + dmidecode 可用性）
├── stress-test.sh                 压测主控脚本入口（CPU/内存/硬盘压测：start/status/stop/review/snapshot）
├── stress-lib-common.sh           stress 公共子模块（工具/CPU 探测/DIMM 推导/参数解析）
├── stress-lib-devices.sh          stress 设备子模块（devices.txt 写入/设备名解析）
├── stress-lib-snapshot.sh         stress 快照子模块（运行时证据快照/实际参数解析）
├── stress-lib-monitor.sh          stress 监控子模块（monitor-loop/状态与结束落盘）
├── stress-lib-commands.sh         stress 命令子模块（cmd_start/status/stop/review/snapshot 实现）
├── oneclick.sh                    一键压测入口（菜单/子命令：自动挂载+分窗+自动复盘）
├── oneclick-lib-basic.sh          oneclick 基础子模块（usage/环境快照/命令显示）
├── oneclick-lib-run.sh            oneclick 运行子模块（precheck/计划/启动/等待/复盘）
├── disk-mount.sh                  挂载辅助脚本入口（list/mount/umount，硬盘压测前挂载测试盘）
├── disk-mount-lib-detect.sh       挂载探测子模块（系统盘识别/设备探测/状态判定）
├── disk-mount-lib-plan.sh         挂载计划子模块（build_plan/挂载点编号/重建步骤）
├── disk-mount-lib-commands.sh     挂载命令子模块（cmd_list/cmd_mount/cmd_umount 实现）
├── mount-iso.sh                   U盘+yum源脚本入口（build/mount/status/umount，构建源并配置本地源）
├── mount-iso-lib-usb.sh           U盘识别与挂载子模块（usb_disk/mount_usb）
├── mount-iso-lib-repo.sh          yum 源构建子模块（createrepo/复制/写 repo 文件）
├── mount-iso-lib-commands.sh      mount-iso 命令子模块（cmd_build/cmd_mount/cmd_status/cmd_umount 实现）
├── usb-eject.sh                   U盘安全弹出脚本入口（自动识别并卸载全部挂载点，--poweroff 可断电）
├── usb-eject-lib.sh               usb-eject 子模块（卸载/断电弹出/占用排查）
├── usb-mount-guide.md             U盘挂载操作说明（未挂载时先看这个，纯命令可直接复制）
├── operation-manual.md            压测操作手册（三类机型 CPU/内存/硬盘实操）
└── rpms/
    ├── stress-1.0.4-24.el8.x86_64.rpm      stress RPM 安装包
    └── dmidecode-3.2-10.el8.x86_64.rpm     dmidecode RPM（自动探测内存条根数）
```

拷贝时请**保持整个目录结构不变**：各入口脚本通过 `source` 加载同目录的 `*-lib-*.sh` 子模块，**整个目录（含全部 14 个 lib 子模块）必须整体拷贝**，缺失任一 lib 文件入口脚本会提示"缺少模块文件"并退出；脚本另按相对路径 `rpms/` 定位 RPM 文件。

> `oneclick.sh` 每次运行会在批次目录 `/root/stress-test/oneclick-<时间>/` 下**自动生成**三个记录文件（命令清单 + 重放脚本 + 环境快照）（不属于离线包内容，随每次执行重建）：
>
> | 文件 | 用途 |
> |---|---|
> | `commands.txt` | 本次实际执行过的命令逐条记录（可直接复制重跑；复盘命令自动去重） |
> | `commands.sh` | 可重放的启动脚本（含 shebang、批次路径、重放警告；只含挂载与各任务启动命令，不含复盘；权限 0644；**执行它会重新发起一轮压测**） |
> | `env.txt` | 本次执行环境快照（`BATCH`/`MODE`/`START_TIME`/`TIMEOUT`/`STRESS_TEST_ROOT`/`STRESS_TEST_SH`/`DISK_MOUNT_SH`/`TERM_KIND`/`POLL_INTERVAL`/`READY_TIMEOUT`/`SHOW_CMD`） |

## 3. U 盘拷贝步骤

> **U 盘还没挂载？** 先按 [usb-mount-guide.md](usb-mount-guide.md) 复制命令完成挂载（纯手工命令，不依赖包内脚本），再回来做拷贝。

**主路径（推荐）：拷贝整个目录**

1. 在联网的机器上（或直接从资料交接处）拿到 `offline-stress-pkg` 目录；
2. 将**整个 `offline-stress-pkg` 目录**拷贝到 U 盘（保持目录层级不变）；
3. 服务器上插入 U 盘，挂载后把整个目录拷到服务器，例如：

```bash
# 以挂载点为 /mnt/usb 为例（具体路径以实际挂载为准）
mkdir -p ~/offline-stress-pkg
cp -r /mnt/usb/offline-stress-pkg/* ~/offline-stress-pkg/
cd ~/offline-stress-pkg
```

> 说明：若为了方便将包打成 zip 拷贝，服务器上**必须已安装 unzip** 才能解压；**若服务器缺 unzip，请直接使用目录拷贝方式**，不要依赖 zip。

## 4. 安装

在包目录下执行：

```bash
sudo bash install.sh
```

- 已是 root 用户时直接执行 `bash install.sh` 即可；
- **非 root 且未加 sudo 时，脚本会提示并退出**（提示：请以 root 运行：sudo bash install.sh）；
- 脚本会自动完成：root 检查 → RPM 文件存在性检查 → SHA256 完整性校验 → 已安装同版本检测（已装则提示"已安装"并跳过）→ 逐个 `rpm -Uvh` 安装 `stress` 与 `dmidecode`；
- 安装成功输出 `stress 安装成功：stress-1.0.4-24.el8.x86_64` 与 `dmidecode 安装成功：dmidecode-3.2-10.el8.x86_64`，退出码 0。
- 若目标机不允许安装 dmidecode，`stress-test.sh` 仍可通过 EDAC 或手动 `--vm` 完成内存压测（见操作手册边界说明）。

### 4.1 一键压测（推荐）

装完 `stress` 后，用 `oneclick.sh` 一条命令跑完整个流程。

**引导菜单**（直接运行 `oneclick.sh` 进入；当前超时默认 10h，可用 `--timeout` 覆盖）：

```text
==== 一键压测 ====
  1) 求稳强度压测（CPU+内存组合 + 每盘独立 + 系统盘；参数自动推导，保守）
  2) 中高强度整机压测（同上任务构成；参数按朋友规则推导，FULL_* 显式设置可覆盖）
  3) 测 CPU+内存（排除硬盘）
  4) 只测硬盘（数据盘）
  5) 只测系统盘
  6) 只测 CPU
  7) 只测内存
  8) 查看状态
  9) 生成复盘
  0) 退出
当前超时：10h（可用 --timeout 覆盖）
```

菜单项对应子命令（CLI 等价，均可 `--timeout` 指定时长）：

| 菜单项 | 子命令等价 | 说明 |
|---|---|---|
| 1 求稳强度压测 | `all` | 全测：自动挂载 + CPU+内存组合 + 每盘 HDDxx + 系统盘；参数按本机实测自动推导（保守） |
| 2 中高强度整机压测 | `full` / `--high` | 任务构成同上；参数默认按朋友规则推导（CPU≈逻辑线程×70%、VM=DIMM 根数、vm-bytes=脚本单根推导不裁剪），`FULL_*` 显式设置可覆盖 |
| 3 测 CPU+内存（排除硬盘） | `all --no-hdd` | 仅 CPU+内存，跳过自动挂载；与 `--rebuild` 互斥 |
| 4 只测硬盘（数据盘） | `hdd` | 每块数据盘独立 HDDxx 任务 |
| 5 只测系统盘 | `sysdisk` | 根文件系统压测（`/stresstest-hdd`，不分区不格式化） |
| 6 只测 CPU | `cpu` | 仅 CPU 压测 |
| 7 只测内存 | `mem` | 仅内存压测（固定 `--vm-keep`） |
| 8 查看状态 | `status` | 查看最近批次任务状态 |
| 9 生成复盘 | `review` | 重新生成最近批次汇总复盘 |
| 0 退出 | — | — |

```bash
sudo bash oneclick.sh                # 进入引导菜单（见上）
sudo bash oneclick.sh all --timeout 10h
sudo bash oneclick.sh hdd --timeout 8h
sudo bash oneclick.sh all --no-hdd --timeout 10h   # 排除所有硬盘（数据盘+系统盘），仅测 CPU+内存（COMBO peer=0）；跳过自动挂载，与 --rebuild 互斥
sudo bash oneclick.sh full --timeout 10h           # 中高强度整机压测：全盘挂载 + COMBO 高强度参数 + 每盘 HDDxx + 系统盘
sudo bash oneclick.sh --high --timeout 10h         # 一键中高强度整机压测（等价 full，不弹菜单）
sudo bash oneclick.sh all --high                   # 等价 full（中高强度整机压测）
```

要点：

- **全测任务构成（顺序即启动顺序）**：自动挂载（`disk-mount.sh mount --disks all --yes`）→ **COMBO**（CPU+内存组合任务：一个终端、一个结果目录，不再拆成 CPU、内存两个任务）→ **每块数据盘一个 `HDDxx` 任务**（独立终端、独立结果目录）→ **SYSDISK**（系统盘任务，`--sysdisk-only`，独立终端）；
- **`full` 中高强度整机压测**：编排结构与 `all` 完全一致（自动挂载 → COMBO 先启动 → 每盘 HDDxx → SYSDISK），COMBO 参数默认按**朋友规则**推导中高强度值（CPU≈`round(逻辑线程×70%)`、VM=DIMM 根数、vm-bytes=脚本单根推导公式 单条容量−`max(单条/8,6G)`，如 32G 条→26G、64G 条→56G），推导值作为**显式参数**写入 COMBO 计划、`--vm-bytes` 只告警不裁剪；`FULL_*` 显式设置可覆盖（显式优先，未设置项仍由推导补齐）：
  - 默认参数：按朋友规则推导——未设置 `FULL_CPU`/`FULL_VM`/`FULL_VMBYTES` 时由脚本按本机实测推导（如 64 逻辑线程/12×32G → `--cpu 45 --vm 12 --vm-bytes 26G`）；显式设置任一项时该项固定为所给值，其余项继续按推导补齐；
  - 换机器可用环境变量覆盖：`FULL_CPU` / `FULL_VM` / `FULL_VMBYTES`（如 `FULL_VMBYTES=32G sudo bash oneclick.sh full --timeout 10h`）；**未设置时按朋友规则推导**，无需手动调参；
  - **求稳 vs 中高一句话**：`all`（求稳）= 脚本按本机实测自动推导参数（保守，受三道上限约束自动下调）；`full` / `--high`（中高）= 按朋友规则推导 CPU≈70% + 内存脚本单根推导（如 5380 → 45/12/26G=312G），推导值显式下发、不裁剪（强度优先，靠页缓存兜底），**大内存 + 多盘并发下注意观察是否抖动 / OOM**；`--rebuild` 对 full 生效（同 all 口径），`--no-hdd` 仅 all 模式支持（full 带 `--no-hdd` 会报错）；
- **`--high` 一键中高**：`sudo bash oneclick.sh --high --timeout 10h` 无模式直接启动中高强度整机压测（等价 `full`，不弹菜单）；`sudo bash oneclick.sh all --high` 亦等价 `full`。与 `--no-hdd` **互斥**（中高强度必含硬盘，同时给出报错）；`cpu`/`mem`/`hdd`/`sysdisk` 带 `--high` 时提示"仅对整机（all/full）生效，本次忽略"；参数覆盖口径同 `full`（`FULL_CPU` / `FULL_VM` / `FULL_VMBYTES`）。
- **COMBO 只跑 CPU+内存**：oneclick 自动为 COMBO 传 `--peer-disks <数据盘数+1>`，让内存计划把同时在跑的各数据盘与系统盘计入页缓存预留（`cap_disk`），但 COMBO 内不启动任何 hdd 进程，每块盘只由自己的 `HDDxx` 任务压一次；
- **硬盘数量影响压测（N = 数据盘数，含 1 路系统盘）**：盘数越多，内存分配上限越低、页缓存余量越紧，是内存参数的关键变量：
  - **公式**：`cap_disk(N) = MemTotal − ((N+1)×12 + 8) G`（`hdd-bytes` 默认 10G 时，12 = 每盘 10G×1.2 页缓存预留 + 8G 系统）；
  - **`all`（求稳，自动响应）**：单 worker 从 26G 按 `min(模块×88%, MemTotal×92%, cap_disk(N))` 逐 GiB 下调——N=4→25G（300G/78%）、N=7→22G（264G/69%）、**N=14→15G（180G/48%）**、N=20→9G（108G/28%）。盘越多内存压得越低，**N≥14 时内存已明显测不到位**；
  - **`full`（中高，默认按朋友规则推导不裁剪；FULL_* 显式设置时固定不裁剪）**：默认按朋友规则推导（CPU≈逻辑线程×70%、vm-bytes=脚本单根推导），推导值显式下发、**不受三道上限裁剪**（`--vm-bytes` 只告警）；显式设置 `FULL_VMBYTES`（如 288G）时固定不裁剪——页缓存可回收余量 ≈ MemTotal−288−系统 ≈ 78G；写盘页缓存峰值 = N×10G，**N≥8 时需求超余量**（持续刷盘回写、IO 波动，需监控 `free -h` / `sar -r` / `dmesg | grep -i oom`），N 更大建议降 `FULL_VMBYTES`；
  - **CPU**：N 越大 IO 线程需求越大，显式设置 `FULL_CPU` 时（如 45 ≈ 逻辑线程 70%，14 盘口径）20+ 盘建议评估降到 40；
  - **调参**：`FULL_VMBYTES ≈ (MemTotal − 系统 − N×12) / VM`（保守预留 1.2 倍盘流），`all` 无需手动（自动重算）。完整推导见 `docs/硬盘数量对压测方案的影响-20261120.md`；
- **数据盘默认复用（不清盘）**：自动挂载**默认复用已有文件系统**——有分区测首个分区（分区无文件系统时自动 `mkfs.ext4 -m 0` 该分区），无分区但整盘已有文件系统直接挂载，空盘才整盘格式化；`blkid` 探测失败（重试 5 次）的盘不格式化、直接跳过，其他盘继续（最终退出码 1）；
- **`--rebuild` 会清空数据盘**：`sudo bash oneclick.sh all --rebuild` / `sudo bash oneclick.sh hdd --rebuild` / `sudo bash oneclick.sh full --rebuild` 会卸载旧 `/mnt/HDD*`、清空该盘分区表、重建 1 个 GPT 分区并格式化；菜单选 `1`（求稳）/ `2`（中高）/ `4`（只测硬盘）时会先询问 `是否重新分区并格式化数据盘？(y/N)：`，**默认 N**（直接回车 = 复用）；未指定 `--rebuild` 时输出 `未指定 --rebuild，本次复用已有文件系统；如需重建请加 --rebuild`；`sysdisk` / `cpu` / `mem` 带 `--rebuild` 会被忽略并提示仅对 all/hdd/full 生效（full 与 all 同口径，`--rebuild` 生效）；
- **`--dry-run` 预演挂载**：`bash disk-mount.sh mount --disks all --dry-run` 只打印执行计划、不写任何数据（也不写 `mount.log`），适合正式挂载前核对盘符与动作；
- **每块数据盘一个窗口**，窗口标题为 `压测-HDDxx`；COMBO 窗口为 `压测-组合CPU+内存`，系统盘为 `压测-系统盘`（单资源模式另有 `压测-CPU` / `压测-内存`）；无图形环境（SSH、无 `DISPLAY`）自动降级为后台并行执行，输出写入批次目录的 `<任务>.out`；
- **失败策略**：**COMBO 启动失败 → 中止本批次**，不再启动数据盘与系统盘，批次退出码 1（核心 CPU+内存负载未起来）；**数据盘 / SYSDISK 启动失败 → 记录到 `failed-tasks.txt` 后跳过**，继续启动其余任务，批次最终退出码 1，`summary.txt` 的"启动失败（跳过、未计入复盘）"列出失败任务；
- **自动复盘**：全部结束后自动逐个 `review` 并生成汇总 `summary.txt`，位置为 `/root/stress-test/oneclick-<时间>/summary.txt`（存在异常结论、任务启动失败，或自动挂载阶段存在跳过/失败盘时，批次退出码 1；summary 会标注 `自动挂载: 存在跳过/失败盘（退出码 N…）` 与"启动失败（跳过、未计入复盘）"清单）；
- **命令可见性**：每个任务启动前主终端打印 `[<时间>] 任务 HDD01 将执行：` 与其后的 `  $ bash <包绝对路径>/stress-test.sh start hdd --timeout 10h --dirs /mnt/HDD01`；自动挂载前打印 `  $ bash <包绝对路径>/disk-mount.sh mount --disks all --yes`；复盘前打印 `  $ bash <包绝对路径>/stress-test.sh review --dir <结果目录>`。窗口内首屏也有同样的启动命令 banner（`==== HDD01 启动命令 ====` / `  $ …` / `======================`）；
- **命令落盘**：上述命令写入批次目录的 `commands.txt`（逐条可复制）与 `commands.sh`（可重放启动）；同目录另生成 `env.txt`（环境快照），用途见第 2 节；启动失败时始终单独打印“该任务压测命令（可直接复制重跑）：”；
- **`--quiet` 静默**：`sudo bash oneclick.sh all --quiet`（或 `ONECLICK_SHOW_CMD=0 sudo -E bash oneclick.sh all`）关闭终端命令打印，三个命令文件照常生成；
- **高级用户：`--peer-disks N`（仅 `start combo` / `start mem`）**：显式声明"同时另有 N 路并发 hdd 流"，只参与内存预留与展示（`cap_disk` 按 `max(实际盘目录数+--sysdisk, N)` 计算），**不启动任何 hdd 进程**；`start cpu` / `start hdd` 收到时只告警、不改变行为；取值须为非负整数，`--peer-disks 0` 表示纯 CPU+内存。**该参数一旦出现即禁用自动 glob**——combo/mem 不再扫描 `/mnt/HDD*`，只有显式 `--dirs` 才会在 combo 内启动 hdd 进程，从而避免与外部每盘任务重复压盘；未出现该参数时保持原有自动扫描行为。oneclick `all` 会自动传给 COMBO（值 = 数据盘数 + 1），手工单测一般无需关心。
- 其它子命令：`sudo bash oneclick.sh status` 查看最近批次状态（有批次且存在 `commands.txt` 时会额外提示 `查看本次执行过的命令：cat <批次>/commands.txt`），`sudo bash oneclick.sh review` 重新生成复盘。

### 4.2 自动挂载默认行为（disk-mount.sh mount）

`disk-mount.sh mount` **默认不清盘**，按现场口径逐盘决策：

| 盘状态 | 默认动作 |
|---|---|
| 已挂载（含 LVM/RAID 后代） | 跳过，不重复挂载 |
| 有分区 | 只测首个**非扩展**分区：分区有文件系统 → 直接挂载；分区无文件系统 → `mkfs.ext4 -m 0 <分区>` 后挂载 |
| 无分区、整盘有文件系统 | 直接挂载整盘，不重新格式化 |
| 无分区、空盘 | `mkfs.ext4 -m 0 <整盘>` 后挂载 |

要点：

- **多分区盘只测首个分区**：计划中显式提示 `本盘有 N 个分区，默认仅测第一个（sdb1，xxxG）；需要整盘覆盖请用 --rebuild`；
- **扩展分区不参与默认格式化**：msdos 扩展分区（`0x5`/`0xf`/`0x85`）本身不当作可测分区，默认取首个逻辑分区；若只发现扩展分区容器，或存在分区表但解析不到可用分区，该盘跳过、不自动格式化（需要重建请加 `--rebuild`），批次退出码 1；
- **blkid 失败不格式化**：每个设备最多探测 5 次（间隔 1 秒），仍失败则跳过该盘、其他盘继续，结束时退出码 1，并汇总 `因 blkid 失败跳过：sdb（5 次探测均失败，未格式化）`；
- **挂载点编号不复用**：已占用的 `/mnt/HDDnn` 不会被覆盖，按最小可用编号分配（如已挂 `HDD01`，新盘用 `HDD02`）；
- **`--rebuild` 会清空该盘分区表**：卸载 `/mnt/HDD*` 旧挂载 → `parted mklabel gpt` → `mkpart primary ext4 1MiB 100%` → `partprobe` → `mkfs.ext4 -m 0 <分区>` → 挂载分区（NVMe 为 `p1`，不盲拼）；同盘存在非 `/mnt/HDD*` 挂载点（含 LVM/RAID 后代，如业务目录 `/data`）时整盘跳过、不做任何写操作；
- **`--dry-run`**：`bash disk-mount.sh mount --disks all --dry-run`（等价 `DRY_RUN=1`）只打印计划、末尾输出 `（DRY RUN，未执行）`、不写 `mount.log`，退出码与真实执行一致；
- **系统盘永不参与**：`df /` 识别到的系统盘在任何模式都不分区 / 不格式化 / 不挂载；系统盘识别不可靠（如 `df /` 为 `/dev/root`）时，非 dry-run 直接中止、不执行任何写操作。

### 4.3 结果判定要点

`stress-test.sh review` 生成 `summary.txt`，首行按以下**优先级**给出 `结论:`（后者不覆盖前者）：

1. **内核 I/O 错误 → 异常**：`dmesg` 增量命中 `EXT4-fs error`、`I/O error`、`Buffer I/O error`、`blk_update_request`、`critical medium error`、`ata`/`nvme` 错误等即判 `异常（内核 I/O 错误，见 error.log）`，**即使 `status.txt` 为 `OK` 也不覆盖**；错误按设备归因（`devices.txt` 记录本任务分区名 + 整盘名 + `lsblk` KNAME），其他盘的报错进入 `error-unattributed.log`，只计数、不污染本盘结论（summary 中显示 `未归因内核 I/O 错误 N 条`）；
2. **ENOSPC → 空间不足（非磁盘故障）**：命中 `No space left on device` 时结论为 `异常（空间不足 ENOSPC，非磁盘故障）`，与磁盘硬件故障区分；
3. 其他 `error.log` 命中（`检测到 stress` / `dmesg`）→ 异常；否则按 `status.txt`（`OK` 正常 / `FAILED` 异常 / `ABORTED` 按原因 / `STOPPED` 已手动停止）。
4. **执行一致性**：`review` 会把 `run-config.txt` 的计划值与 `actual-params.txt` 的实际 CPU/VM worker、`--vm-keep`、hdd 进程数、cwd、RSS 逐项对拍，输出 `== 执行一致性 ==` 的 PASS/FAIL/UNKNOWN。UNKNOWN（旧目录、缺字段、只有 start/60s 快照）不改变结论；FAIL 只在原结论为“正常”时改为“异常（执行与计划不一致）”，I/O/ENOSPC/STOPPED 优先级不变。

**运行时证据文件**：`runtime-snapshot.txt`（启动、60s、600s、之后每 600s 及手动 `snapshot` 的进程 cmdline/cwd/VmRSS/Threads）、`actual-params.txt`（最新实际参数）、`runtime-final.txt`（结束状态与退出码）。运行中可执行 `bash stress-test.sh snapshot <结果目录>` 手动补抓一次，仅作展示、不作为一致性证据。

**系统盘压测 = 根文件系统压测**：`--sysdisk` / `--sysdisk-only` 时压测目录固定为 `/stresstest-hdd`（不分区、不格式化、不挂载），`run-config.txt` 与 `summary.txt` 写明 `压测对象: 系统盘（根文件系统压测）` 与 `覆盖边界: 不覆盖 /boot、/boot/efi、swap、未分配空间；LVM/RAID 下写入可能跨多个物理盘`。

**压测目录必须是独立挂载点**：`start hdd` / `start combo` 启动前校验每个目录（默认 `/mnt/HDD*` 或显式 `--dirs`），未挂载或落在系统盘根文件系统上会直接拒绝（退出码 1，不启动压测）。

## 5. 验证

```bash
bash verify.sh
```

- 共 4 项检查：
  - 检查 A：`rpm -q stress` 输出精确匹配 `stress-1.0.4-24.el8.x86_64`
  - 检查 B：`stress --version` 输出包含 `1.0.4`
  - 检查 C：10 秒冒烟压测（`stress --cpu 2 --vm 1 --vm-bytes 256M --timeout 10`）
  - 检查 D：`dmidecode` 是否可用（缺失只输出 `WARN`，不影响 PASS/退出码）
- 全部通过输出 `PASS`，退出码 0；任一 `FAIL` 输出 `FAIL`，退出码 1。

**跳过冒烟压测**：若不想运行 10 秒冒烟压测（例如机器正在跑业务），可跳过：

```bash
VERIFY_SKIP_SMOKE=1 bash verify.sh
```

此时检查 C 输出 `SKIP`，A、B 通过即为 `PASS`。

压测实操见同目录 operation-manual.md

## 6. NOKEY 签名警告说明

安装时 rpm 可能输出类似警告：

```
warning: rpms/stress-1.0.4-24.el8.x86_64.rpm: Header V4 RSA/SHA256 Signature, key ID xxx: NOKEY
```

原因：rpm 校验签名需要对应的 EPEL GPG 公钥，而离线服务器**未导入该公钥**，属正常现象，**不影响安装结果**。脚本以 rpm 退出码判定成败，出现 NOKEY 警告后安装仍会成功。

## 7. 卸载

```bash
rpm -e stress
rpm -e dmidecode   # 可选：仅在不需要自动探测内存条根数时卸载
```

卸载后可用 `rpm -q stress` 确认（输出"未安装"即卸载成功）。

## 8. 压测用法示例

正式压测请直接用包内 `stress-test.sh`：CPU/内存参数由脚本按**本机实测规格**自动推导（v3 通用公式），**默认命令不需要 `--model`**：

- **CPU worker** = `round(逻辑线程 × 25/32)`（逻辑线程 = 物理核 × 每核线程数，SMT 探测开=2/关=1/未知默认开；如 64 物理核 SMT 开启（128 逻辑线程）→ 100，SMT 关闭（64 逻辑线程）→ 50，5380/7360/7380 对应 50/75/100 与 25/38/50；物理核识别失败时回退 `round(nproc × 78%)`）；
- **SMT 状态参与 CPU worker 分配**（`lscpu Thread(s) per core` / sysfs smt 探测结果写入 run-config 的 `smt=` 字段；SMT 关闭时逻辑线程减半，worker 相应减半；探测结果同时用于资源计划标注与机型交叉校验）；
- **VM worker** = 实际内存条根数；**单 worker** = `单条容量 − max(6G, 单条容量/8)`（32G→26G、64G→56G、128G→112G）；
- **三道上限取最小**：`模块总容量 × 88%`、`MemTotal × 92%`、`MemTotal − (盘数 × hdd-bytes × 1.2 + 8G)`；`combo` / `mem` 的"盘数"取 `max(实际盘目录数 + --sysdisk, --peer-disks N)`（未传该参数时仅按实际盘数）。超限逐 GiB 自动下调（如 1024G/16×64G 在 12 块数据盘场景，单 worker 由 56G 自动降到 54G）。该 12 盘示例按标称容量估算，实际 MemTotal 略低，脚本按 MemTotal 计算时可能再低 1G（例如 512G 约 21G、1024G 约 53G）；
- **`mem` / `combo` 固定追加 `--vm-keep`**（内存常驻、压力持续）；`cpu` / `hdd` 不加。

```bash
bash stress-test.sh start cpu
bash stress-test.sh start mem
bash stress-test.sh start combo

# 显式覆盖示例（显式参数优先，仍受分配上限告警提示）
bash stress-test.sh start mem --vm 16 --vm-bytes 56G
```

`--model <品牌-型号|auto>` 仅用于 `run-config.txt` / `review` 的机型标注与"实测线程 vs 标称线程"交叉校验，**不影响任何压测参数**（默认 `auto` 已够用）：支持海光四位数字型号（如 5380/7380/7360/9800）、AMD EPYC（如 `EPYC-7763`）、Intel Xeon（如 `Xeon-6338`）。`auto` 优先从 CPU 信息**智能识别多品牌型号**（`lscpu "Model name"` / `/proc/cpuinfo "model name"`：海光提取 `C86-3G` 后型号数字、AMD 提取 `EPYC-<数字>`、Intel 提取 `Xeon-<数字>`，兼容中英文输出），启动时打印"检测到机型 X（来源: 智能识别 CPU 信息）"并写入 `run-config.txt` 机型字段；无品牌匹配（识别失败）才回退**逻辑线程分界**（≥120→7380、≥90→7360、≥64→5380；线程不可用时按内存兜底：MemTotal ≥800G→7380、≥450G→7360、否则 5380，来源标注"逻辑线程分界/内存兜底"）。识别结果与实测逻辑线程交叉校验：不一致（偏差 >10%）时明确提示"型号识别结果与实测线程不符"；**仅海光四位数字型号与实测矛盾时才按实测线程分界修正**（如检测 5380 但实测 128 线程 → 修正为 7380），AMD/Intel 品牌型号保留品牌标注、不做分界修正（避免把 EPYC/Xeon 误标成海光档位）；型号标称未知（如 `EPYC-9999`）时跳过标称校验不误报。CPU/内存参数一律按实测推导，型号仅用于标注，显式指定如 `bash stress-test.sh start mem --model EPYC-7763` 亦可。

以下为直接调用 `stress` 的手工示例（参考 64 核 / 1024G 配置），仅用于了解原始工具用法：

> 所有示例均带 `--timeout`，压测**到时自动结束**，避免长时间占用资源；长时间压测建议用 `nohup` 放后台运行（见下文）。参数请按实际压测需求调整。

**纯 CPU 压测**（占用全部 64 物理核，每个核一个 worker）：

```bash
stress --cpu 64 --timeout 600
```

**内存压测**（16 个 worker 各申请 8G，共约 128G，注意观察内存占用）：

```bash
stress --vm 16 --vm-bytes 8G --timeout 600
```

**组合压测**（CPU + 内存同时压，共 64 worker）：

```bash
stress --cpu 64 --vm 16 --vm-bytes 8G --timeout 600
```

**后台运行 + 日志**（长时间压测，如 1 小时，放后台并记录日志）：

```bash
nohup stress --cpu 64 --vm 16 --vm-bytes 8G --timeout 3600 > stress.log 2>&1 &
```

- 查看日志：`tail -f stress.log`；结束后用 `jobs` / `ps -ef | grep stress` 确认进程已退出；
- 其它常用选项：`--hdd`（写磁盘）、`--io`（I/O 压测）、`-q`（静默输出）等，详见 `stress --help`；
- **注意事项**：`--vm-bytes` 总量不宜超过实际可用内存（本机 1024G，示例共 128G 属安全范围）；压测会显著增加 CPU 温度与功耗，请确认散热与机房环境。

## 9. 故障回退（依赖缺失时）

以下命令需 root 权限执行。

若 `rpm -Uvh` 因依赖缺失失败（如缺 `libc` 相关依赖版本不符），可将 **Kylin V10 SP3 系统 ISO** 挂载为本地 yum 源后重试：

```bash
# 挂载 ISO（以 /dev/cdrom 为例，ISO 文件时用 mount -o loop）
mkdir -p /mnt/iso
mount -o loop /path/to/Kylin-V10-SP3.iso /mnt/iso

# 配置本地源
cat > /etc/yum.repos.d/kylin-local.repo <<'EOF'
[kylin-local]
name=Kylin Local ISO
baseurl=file:///mnt/iso
enabled=1
gpgcheck=0
EOF

# 重试安装（自动解析本地依赖）
yum localinstall rpms/*.rpm -y
```

> 安装成功后无需保留本地源，可卸载 ISO：`umount /mnt/iso`，并删除 `/etc/yum.repos.d/kylin-local.repo`。

## 10. U 盘与本地 yum 源一键管理（mount-iso.sh）

`mount-iso.sh` 提供四个子命令，打通"构建源 → 写入 U 盘 → 挂载复制 → 配置本地源"：

```bash
# 进入离线包目录（按实际位置调整）
cd /root/offline-stress-pkg

# 1) 构建 yum 源（createrepo 生成 repodata，需 root）
#    RPM 来源优先级：U盘内（已挂载且含 *.rpm） > --rpm-dir > 包内 rpms/
sudo bash mount-iso.sh build
sudo bash mount-iso.sh build --rpm-dir /root/my-rpms    # ← 换成你实际的 RPM 目录

# 2) 一键：U盘挂载 → 复制源目录到 /opt/kylin-repo → 配置本地 yum 源
sudo bash mount-iso.sh mount

# 3) 查看状态
bash mount-iso.sh status

# 4) 卸载 U 盘（不影响已复制的本地源）
sudo bash mount-iso.sh umount
```

> 注意：脚本必须在包目录内执行（或写脚本绝对路径）；`build`/`mount`/`umount` 需 root（用 `sudo`），`status` 无需。`--rpm-dir` 后是**实际目录**，不能照抄 `/path/to/rpms`。

要点：

- **build**：用 `createrepo --update` 在 RPM 目录生成 `repodata/`；构建结果复制到 `/opt/kylin-repo`，U 盘已挂载时另写一份 `<U盘>/kylin-repo` 方便拷贝到其他机器。U 盘内 RPM 识别范围为 `maxdepth 2`，优先 `<U盘>/rpms` 子目录，仅以实际含 `*.rpm` 的目录作为源（避免把整盘复制进去）。需系统已装 `createrepo`（或 `createrepo_c`），缺失时脚本提示安装命令。
- **mount**：自动检测首块 USB 盘（`TRAN=usb`，系统盘硬排除）→ 挂载到 `/mnt/usb` → 在 U 盘内查找含 `repodata` 的目录 → 复制到 `/opt/kylin-repo` → 写 `/etc/yum.repos.d/kylin-local.repo`（`baseurl=file:///opt/kylin-repo`）。**repo 文件已存在时不覆盖（会提示实际 baseurl）**。**U 盘可拔，源仍可用**。
- **umount**：仅卸载 U 盘，不删 `/opt/kylin-repo` 与 repo 文件；如需清理请手动 `rm -rf /opt/kylin-repo` 与 `rm -f /etc/yum.repos.d/kylin-local.repo`。
- **演练**：加 `DRY_RUN=1` 只打印执行计划不落盘（如 `DRY_RUN=1 bash mount-iso.sh mount`）。
- 可覆盖路径：`USB_MOUNT_POINT`（默认 /mnt/usb）、`REPO_DEST`（默认 /opt/kylin-repo）、`YUM_REPO_FILE`（默认 /etc/yum.repos.d/kylin-local.repo）。
- **安全弹出**：`sudo bash usb-eject.sh` 自动识别 U 盘并卸载其全部挂载点（含 `/run/media` 自动挂载），加 `--poweroff` 可断电。

---

若仍有问题，将 `install.sh` / `verify.sh` 的输出连同执行命令一并反馈。
