# diskwipe-iso 旧方案归档（文档与 SDD 记录）

> 归档日期：2026-11-26
> 状态：**已放弃**（转 FirPE + DiskGenius 新工具，见 `docs/superpowers/plans/2026-11-26-firpe-diskgenius-cleanup-design.md`）
> 归档范围：本文档 + `plans/`、`specs/`、`sdd/`。代码归档见 `diskwipe-iso/ARCHIVE.md`（commit `c7a1bdb`）。

---

## 1. 方案概述

**diskwipe-iso** 是自研的可启动 ISO 一键清盘工具，用于替代「FirPE + DiskGenius 逐盘删分区」的现场清盘流程：

- 从 U 盘启动后自动进入干净终端菜单（全 ASCII 输出，兼容 IPMI 虚拟 KVM / 串口 SOL）；
- 开机自动列出全部硬盘（默认全选，可输入编号排除）；
- 输入大写 `YES` 二次确认后，对整盘执行 `wipefs -a` 一键清除分区表与文件系统/RAID/LVM 签名；
- 硬盘秒级恢复为「未初始化」状态；启动 U 盘（`TRAN=usb`）与光驱（`sr*`）硬排除；完全离线运行。

技术路线：ISOLINUX（BIOS）+ 精简 GRUB（UEFI）+ xorriso 手动打包双引导 ISO；Kylin 4.19 内核（解决 Ubuntu 内核与该海光服务器 USB 栈不兼容启动卡死）；busybox initramfs + util-linux `wipefs`/`lsblk`/`blkid`；离线假件单测（400+ 用例）+ qemu 冒烟。演进至 v1.6.0。

## 2. 为何放弃

**真机 SAS 盘（447GiB，LSI/Broadcom 0x1000 控制器）在内核 PCI 枚举阶段未被发现**——软件不可解：

- `DIAG SAS` 输出为空：控制器未被内核枚举（不在 lspci/PCI 设备树中），无 `mpt3sas_cm0`，`lsblk` 只有启动 U 盘；
- 仅 v1.5.6 一次成功（概率性/时序巧合），此后无论模块白名单、内核参数（`pci=realloc,nocrs`）、强制 SCSI/PCI 重扫描、mpt3sas 调参等 9 轮软件修复均无效；
- 结论：设备在固件→PCIe 链路→枚举层即缺失，问题不在 OS/initramfs 层，Linux 工具链无法干预。

转向 **FirPE（Windows PE，厂商驱动枚举可靠）+ DiskGenius 命令行清盘** 新方案。

## 3. 代码归档位置

- 代码目录：`diskwipe-iso/`（src/、build.sh、build-lib.sh、kylin-kernel-export.sh、tests/、VERSION、README.md）
- 归档说明：`diskwipe-iso/ARCHIVE.md`（含 v1.0.0→v1.6.0 全部版本演进与 commit 索引）
- 代码归档 commit：**`c7a1bdb`**（方案最后功能 commit 为 `036f943`，v1.6.0）
- 不入库（本地保留，已 gitignore）：官方 Kylin ISO、`kylin-src-*.tar.gz`、构建产物 `output/`；如需重新构建，从本地恢复材料后 `bash diskwipe-iso/build.sh`。

## 4. 文档索引（本归档）

| 目录 | 内容 | 数量 |
|---|---|---|
| `plans/` | 实施计划（2026-11-21 主计划 / field-fix / log；2026-11-22 gfxpayload-fix / scan-hang） | 5 |
| `specs/` | 设计文档（2026-11-21 design / field-fix-design / log-design；2026-11-22 init-usb-hang / log-write-hang / scan-hang design） | 6 |
| `sdd/` | SDD 工作区记录（gfxpayload-fix、scan-hang 两目录：全部 briefs/reports/reviews/progress.md，含本次归档 brief 与报告） | 2 目录 |

## 5. 保留未归档（新方案/无关内容）

- `docs/superpowers/plans/2026-11-26-firpe-diskgenius-cleanup-design.md`——**新方案文档，保留在原处**；
- `diskwipe-iso/` 代码目录（保持 commit `c7a1bdb` 状态）；
- `docs/superpowers/plans|specs` 下 offline-stress-pkg / hdd-cleanup / disk-map 等非 diskwipe 方案文件（未归入）。

> 本归档为纯文件移动（git mv 保留历史），未修改任何代码与新方案文档。
