# 硬盘压测：现场流程 vs 项目实现 对比分析（定稿）

- 日期：2026-11-16
- 状态：定稿（L1 静态走查 + L2 沙箱复现，未做现场只读核查）
- 依据：`docs/superpowers/notes/2026-11-16-hdd-stress-verification-plan.md`
- 被核查文件：`offline-stress-pkg/disk-mount.sh`、`stress-test.sh`、`oneclick.sh`
- 沙箱证据：`.superpowers/sdd/2026-11-16-hdd-verify/`（`logs/*.cmdseq.log`、`logs/C9.run-config`、`runs/*/results`）
- 安全声明：核查全程未调用真实 `parted/mkfs/mount/stress`，未操作真实块设备

## 1. 结论摘要

**整体判定：部分符合。**

- **符合**：每盘一个挂载目录、`cd` 进入该目录后压测、stress 参数（`--hdd 1 --hdd-bytes 10G`）、每盘一个窗口/进程、系统盘不参与数据盘挂载。
- **不符合（3 项）**：
  1. 不创建分区，空盘时对**整盘** `mkfs.ext4 -m 0 /dev/sdX`，不是 `/dev/sdX1`；
  2. 已有分区时**从不重新格式化**；分区上无文件系统时直接 `mount`（真实环境会失败）；
  3. 结论判定有双重缺陷：**内核 I/O 错误完全不检测**；且 `status=OK` 时**忽略 `error.log`**，连已检测到的 OOM 也判“正常”。
- **部分符合（4 项）**：盘枚举规则、挂载点编号、启动时序、危险操作确认。

## 2. 逐项对比（现场动作 → 实际行为）

| # | 现场动作 | 项目实际行为 | 证据 | 判定 |
|---|---|---|---|---|
| 1 | `lsblk` 找 12 块数据盘 | 从 `df /` 上溯得系统盘整盘并硬跳过；仅认 `TYPE=disk` 的 `sd*/nvme*`；多分区只取第一个分区；`stress-test.sh` 默认 glob `/mnt/HDD*` 并用 `findmnt/df` 排除根设备 | disk-mount.sh:54-75、93-107、117；stress-test.sh:363-394；沙箱 C2/C8/C11 | 部分符合 |
| 2 | `mkdir -p /mnt/HDD{01..12}` | 挂载点 `/mnt/HDD%02d`，执行时 `mkdir -p`；编号按“本次未挂载的盘”从 1 递增，**已挂载盘占用的编号会被新盘复用** | disk-mount.sh:298、338-339；沙箱 C2、C6b | 部分符合 |
| 3 | 每盘分区，得到 `/dev/sdb1` | **不建分区**：全序列 0 次 `parted/partprobe/udevadm`；有分区时只取首个分区名 | disk-mount.sh:145-150、341；沙箱 C2/C3 | **不符合** |
| 4 | `mkfs.ext4 -m 0 /dev/sdb1` | 仅当“无任何分区 + 整盘无文件系统”时执行 `mkfs.ext4 -m 0 /dev/<整盘>`；有分区则直接挂载分区，**不重新格式化**；整盘已有文件系统直接挂载；已挂载跳过 | disk-mount.sh:293-306、341-364；沙箱 C2/C3/C4/C5/C6 | **不符合** |
| 5 | `cd /mnt/HDD01` 后压测 | `cd "$dir" && stress ...`，实测 cwd 为对应挂载目录；系统盘 cwd=`/stresstest-hdd` | stress-test.sh:647、652；沙箱 C9/C10 | 符合 |
| 6 | `stress --hdd 1 --hdd-bytes 10G --timeout 24h` | 默认 `--hdd 1 --hdd-bytes 10G --timeout 10h`，可覆盖为 20G/24h | stress-test.sh:270、347、585；沙箱 C9 run-config、C13 | 符合（默认 10h 为已确认口径） |
| 7 | 每盘新开窗口，12 个并发 | oneclick 每个数据盘一个任务：有图形开窗口，无图形降级后台；逐任务就绪后启动（间隔约 1 秒），启动失败即停；单个 `stress-test.sh` 多目录时是单窗口多进程 | oneclick.sh:173-189、570-598；沙箱 C12 | 符合（启动非严格同时，差异可接受） |
| 8 | 系统盘单独压测 | 不分区不挂载；`mkdir -p /stresstest-hdd` 后 `cd` 该目录，参数与数据盘相同 | stress-test.sh:404、651-653；沙箱 C10 | 符合（按已确认口径保留 `/stresstest-hdd`） |
| 9 | 压完看结果是否正常 | monitor 采 load/cpu/mem/swap/disk IO；dmesg 仅匹配 OOM；`review` 以 `status.txt` 为准，`state=OK` 直接判“正常”。实测：`EXT4-fs error` 不进 `error.log`；OOM 已进 `error.log` 且 `status` 记 `oom=yes`，结论仍“正常” | stress-test.sh:1067、888-909；沙箱 C9/C9b | **不符合** |
| 10 | —（现场无脚本化确认） | 需 root；系统盘在收集阶段即剔除，显式选中则拒绝；执行前一次 y/N，`--yes` 跳过（oneclick 固定 `--disks all --yes`）；`--dry-run` 只支持 `DRY_RUN=1` 环境变量，CLI 传 `--dry-run` 报未知参数 | disk-mount.sh:45-50、277-286、313-327；oneclick.sh:243；沙箱 C1a/C1b/C7a/C7b/C8 | 部分符合 |

## 3. 潜藏风险

| 编号 | 级别 | 风险 | 触发条件 | 是否可逆 | 证据 |
|---|---|---|---|---|---|
| R1 | **高** | 已检测到的内核异常不影响结论：`review` 在 `state=OK` 时直接判“正常”，不看 `error.log` | 发生 OOM 或任何已写入 `error.log` 的错误，但 stress 进程退出码为 0 | 结论可重算，但已出的报告会误导 | stress-test.sh:891-896；沙箱 C9b（`oom=yes` + 结论“正常”） |
| R2 | **高** | 坏盘的 I/O 错误完全漏检：dmesg 只匹配 OOM，`EXT4-fs error`、`I/O error`、`blk_update_request`、ata/nvme 错误都不入库 | 磁盘出现介质/链路错误但 stress 未退出 | 不可逆（漏判已发生），需重测或人工看 dmesg | stress-test.sh:1067；沙箱 C9（`EXT4-fs error` 未进 `error.log`，结论“正常”） |
| R3 | **高** | 挂载失败后仍会“压测系统盘”：分区存在但无文件系统时直接 `mount`，失败后脚本继续；手工用 `--dirs /mnt/HDDxx` 时该目录只是根文件系统上的空目录，`cd` 成功，10G 实际写到系统盘 | 分区未格式化或 mount 失败 | 系统盘可能被写满；结果完全失真 | disk-mount.sh:341-346；沙箱 C3（mount 假件返回 0 掩盖，真实应失败） |
| R4 | 中 | 挂载点编号复用：已挂载盘占着 `/mnt/HDD01` 时，新盘仍会挂到 `/mnt/HDD01`，把前一个挂载遮住，导致一块盘实际未被测试 | 先手工挂载部分盘，再跑 `disk-mount.sh mount` | 可恢复（重新挂载），但本轮数据作废 | disk-mount.sh:298、331-339；沙箱 C6b |
| R5 | 中 | 不建分区：测的是整盘 ext4，与现场 `/dev/sdX1` 的拓扑、容量口径不等价 | 始终 | 需按分区口径复测 | disk-mount.sh:354-360；沙箱 C2 |
| R6 | 中 | 复用旧文件系统：旧数据占用、默认 5% 保留块仍在，10G 写入可能 `ENOSPC`，被误判为盘故障 | 盘上已有文件系统且空间不足 | 可恢复（重建文件系统后重测） | disk-mount.sh:347-353；沙箱 C4/C5 |
| R7 | 中 | 默认 10h 与现场 24h 不同，容易漏加 `--timeout` | 未显式传参 | 可恢复（重跑） | stress-test.sh:270；沙箱 C9 |
| R8 | 低 | 预演不便：`--dry-run` 只能通过 `DRY_RUN=1` 环境变量，CLI 传 `--dry-run` 直接报未知参数 | 现场想先看计划 | 无数据影响 | disk-mount.sh:45-50；沙箱 C1a/C1b |
| R9 | 低 | 12 个任务非严格同时启动（逐个就绪握手，约 1 秒间隔） | oneclick 全测 | 无 | oneclick.sh:570-598；沙箱 C12 |

## 4. 与初稿的差异（已修正）

1. R1 触发条件收窄：只有“无分区且整盘无文件系统”才整盘 `mkfs`；有分区绝不 `mkfs`。
2. 补充分支：**有分区但分区无文件系统时直接 mount**，真实环境会失败（初稿漏）。
3. 新增更严重的问题：`state=OK` 时忽略 `error.log`，OOM 也不改变结论（初稿未发现）。
4. “每盘一窗口、并发”改为“符合但有约 1 秒启动间隔”。
5. 补充挂载点编号复用缺陷。

## 5. 本次核查未能验证的项

- 真实现场盘态：真实 `lsblk/blkid` 输出、LVM/NVMe/mmcblk、真实 mount 失败、真实 ENOSPC。
- 图形终端分支（gnome/mate/xterm）未执行，仅验证无图形后台降级路径。
- `stress-test.sh` 默认 `/mnt/HDD*` 的 `findmnt/df` 根设备排除分支（本机无 `/mnt/HDD*`），仅静态覆盖。
- oneclick → stress-test 的真实 `/mnt/HDDxx` 路径（沙箱用包装脚本重写到镜像目录，原始 argv 已记录）。

## 6. 待确认口径（进入新方案前）

1. 是否要求“每盘 1 分区 + `mkfs.ext4 -m 0 /dev/sdX1`”，还是整盘 ext4 也可接受？
2. 分区存在但无文件系统时，应自动格式化还是报错停止？
3. `review` 的优先级：`error.log` 有记录时是否一律判异常（即使 `status=OK`）？
4. 挂载点编号是否必须稳定绑定“物理盘 ↔ HDDxx”，避免复用？
5. 挂载失败时是否必须终止该任务，禁止在空目录上压测？
