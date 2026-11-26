# diskwipe-iso 方案归档（ARCHIVE）

> 归档日期：2026-11-26
> 状态：**已放弃**（转 FirPE + DiskGenius 方案）
> 本文件是方案的最终归档说明，供后人/未来恢复参考。方案代码、设计文档与 SDD 记录已全部提交至 git。

---

## 1. 方案概述

**diskwipe-iso** 是一个可启动 ISO 一键清盘工具，用于替代「FirPE + DiskGenius 逐盘删分区」的现场清盘流程：

- 从 U 盘启动后自动进入干净终端菜单；
- 开机自动列出全部硬盘（默认全选，可输入编号排除）；
- 输入大写 `YES` 二次确认后，对整盘执行 `wipefs -a` 一键清除分区表与文件系统/RAID/LVM 签名；
- 硬盘**秒级**恢复为「未初始化」状态（供下次重建分区或交接使用）。

**安全边界**：只清分区表 + 签名（不清数据块、不清 SMART）；启动 U 盘（`TRAN=usb`）与光驱（`sr*`）硬排除；操作不可恢复，执行前需二次确认；运行时完全离线；不自动关机。

**定位**：替代现场手工逐盘操作，把「多盘逐盘删分区」压缩为「一次启动 + 输入 YES」。

## 2. 技术路线

| 组件 | 方案 |
|---|---|
| 引导（BIOS） | **ISOLINUX**（syslinux，纯文本 VGA，无视频模式概念） |
| 引导（UEFI） | **精简 GRUB**（grub-mkimage 手动打包 BOOTX64.EFI，剔除 gfxterm/video 模块，纯文本终端 + serial 兜底） |
| ISO 打包 | **xorriso 手动打包**双引导（isohdpfx.bin 混合 MBR + El Torito BIOS 项 isolinux.bin + UEFI 项 FAT efi.img + `-isohybrid-gpt-basdat`），替代 grub-mkrescue |
| 内核 | **Kylin 4.19 内核**（`kylin-src-<日期>.tar.gz` 从目标服务器提取；解决 Ubuntu 内核与该海光服务器 USB 栈不兼容导致启动卡死）；可选 WSL Ubuntu generic 内核 |
| initramfs | busybox（静态，全部 applet）+ util-linux 动态 `wipefs`/`lsblk`/`blkid` + parted `partprobe`；磁盘驱动按白名单 + `modules.dep` 依赖链提取（`.ko.xz` 构建期解压为 `.ko`） |
| 屏幕 | **全 ASCII（英文）输出**（init 提示/菜单/每盘结果），IPMI 虚拟 KVM、串口 SOL 无中文字体终端完全可读 |
| 日志 | 清理日志**无条件写内存**（`/tmp/diskwipe-log`，initramfs rootfs 即 tmpfs），0 退出时**尽力写 U 盘一次**（失败降级为仅内存日志并提示） |
| 构建 | Windows 本机经 **WSL Ubuntu-24.04 一键构建**（`build.sh`，可选 kylin|ubuntu|auto 内核模式）；产物 `output/diskwipe-v<版本>.iso` |
| 测试 | 离线假件单测（`tests/` t1-t6，400+ 用例，假命令注入接缝变量，绝不触碰真实块设备）+ qemu A/B/C 冒烟（UEFI 有盘 / -vga none 无盘 / BIOS isolinux 有盘） |

**核心交互流**：`init`（挂载 proc/sys → 按白名单加载磁盘/显卡驱动 → `mdev -s` 补建设备节点 → 进度写 `/dev/kmsg`）→ `exec menu.sh`（列盘 → 默认全选 → YES 确认 → 逐盘 `umount → wipefs -a → partprobe → wipefs -n 验证` → 结果循环）→ 0 退出。

## 3. 版本演进 v1.0.0 → v1.6.0（关键里程碑）

| 版本 | 关键内容 | git commit |
|---|---|---|
| **v1.0.0** | 初始版本：lib.sh/wipe.sh/menu.sh/init + build.sh（WSL 构建，grub-mkrescue 双引导）+ 假件单测 | 1b5fc91…9859a9b 等 |
| **v1.1.0** | **清理日志持久化**（日志落 U 盘：可写分区挂载 + 会话级日志 dw_version/dw_log；initramfs 补 usb-storage/uas） | e0728cf / 8ac3b17 / 61752a8 |
| **v1.2.0** | **屏幕全 ASCII 化**（真机 IPMI KVM 无中文字体乱码修复）+ 设备白名单扩展（`sd[a-z][a-z]`、多位 nvme/mmcblk）+ wipefs 后 partprobe 刷新分区视图 | 581d298 / f5a8ce2 |
| **v1.3.0** | **列盘卡住修复**（列盘循环零外部命令 + 只读探测 timeout 兜底 + 枚举超时降级 + 进度/日志增强） | 4cfbd16 / 4f56c3c |
| **v1.3.1** | **日志介质写超时降级**（修复「U 盘写入卡死」：写测试 timeout 3 + dw_log timeout 2 + LOG_DEGRADED 仅屏幕） | ac90bb5 / abc116e |
| **v1.3.2** | **init 零 U 盘 I/O**（不再挂载日志介质；日志无条件写内存 + 退出尽力写 U 盘，根治「U 盘 I/O 阻塞进不去菜单」） | 40a7600 / 85778e1 |
| **v1.3.3** | **批量 blkid 排除 U 盘**（menu 批量类型探测不再读 U 盘，菜单立即出现） | 0fe8011 / bd958ad |
| **v1.4.0/1.4.1** | **Kylin 4.19 内核构建模式**（解决 Ubuntu 内核 xhci/USB 栈与该海光服务器不兼容启动卡死；内核双模式 + 白名单/依赖链模块提取）+ GRUB 强制文本终端 | f860f75 / 8be3095 / 4b26952 |
| **v1.4.3** | grub.cfg 加 `gfxmode=text` + `gfxpayload=text`（压制 no suitable video mode） | 5fea84a |
| **v1.5.0** | **引导方式重构**（BIOS 改 ISOLINUX + UEFI 改精简 GRUB + xorriso 手动打包），根治真机两个问题：GRUB 视频模式**盲模式卡死** + Ventoy grub2 mode **initrd 传递丢失** | b66333f / fc586cf |
| v1.5.1 | 删 `set gfxpayload=text`（真机仍黑屏 → 非充分条件） | （并入 7a2bbc2） |
| v1.5.2 | UEFI 直启（grub.cfg 去菜单） | （并入 7a2bbc2） |
| v1.5.3 | **UEFI serial 终端兜底**（盲模式消息后内核照常启动，盲模式卡死消除） | 7a2bbc2 |
| v1.5.4 | **initrd 显卡 DRM 驱动**（ast/mgag200/smifb/bochs-drm/cirrus/virtio-gpu → fbcon 显示，不依赖 GRUB framebuffer） | 0829353 |
| v1.5.5 | init 模块加载进度输出 + timeout 兜底（定位/跳过真机卡点） | d14b9b7 |
| **v1.5.6** | 显卡循环只留 ast（其余显卡驱动无硬件时 D 状态挂起致卡死）+ 进度改 `/dev/kmsg`。**唯一一次真机 SAS 盘识别成功**：`mpt3sas_cm0 port enable SUCCESS`，sda 447GiB 出现在 scsi host 32（mpt3sas） | 3f70526 |
| v1.5.7 | 去设备重试扫描（U 盘枚举后重试 mdev 触发 D 状态 I/O 阻塞）+ menu/lib 全进度（kmsg） | cebce11 |
| v1.5.8 | 去 uas + exec/menu 启动 kmsg 诊断 + 菜单界面输出 kmsg 双通道 | 7b66568 |
| v1.5.9 | **去 usb-storage**（U 盘绑定读盘触发内核 I/O 阻塞致系统整体停滞；去后系统正常启动、menu 完整启动） | d7da880 |
| v1.5.10 | 等设备就绪加长 + 无盘自动重试/reboot（避免 PID1 退出 panic） | f3e100e |
| v1.5.11/12 | 菜单输入改 `/dev/tty0` + HID；枚举 RAW 诊断 + 勾选设备名兜底 + reboot 强制 | 4c22a7f |
| **v1.5.13** | **去无盘自动关机/重启**（真机 reboot -f 执行成关机、用户未及操作即断电——紧急安全修复；无盘改为无限重试） | 8d6a538 |
| v1.5.14 | lsblk 原始输出诊断 + `read -t` 真实等待（sleep 真机严重失真） | 873f09c |
| v1.5.15 | 强制 SCSI 重扫描（`echo - - - > scsi_host/scan`）——**真机无效**（无 scsi_host 可扫） | 9cd973b |
| v1.5.16 | mpt3sas 传 `max_queue_depth=10000`（Fedora/Broadcom 已知问题）——**真机无效** | ec74487 |
| v1.5.17 | 恢复 usb-storage/uas（v1.5.6 成功配置，就绪后卸载防 U 盘卡死）——**真机无效** | 468a737 |
| v1.5.18 | 完全回退 v1.5.6 配置（去 max_queue_depth/rescan/rmmod）——仍失败，**证实 v1.5.6 成功是概率性/时序性，非配置差异** | （未提交，并入 036f943） |
| v1.5.19 | 去 megaraid_sas（基于「与 mpt3sas 竞争同一 LSI SAS 控制器」假设，mpt3sas 独占）——**真机无效** | 7ed5f40 |
| v1.5.20-22 | 全面诊断版（DIAG pci 全量含未绑定 / DIAG mpt 完整错误行 / DIAG pci/mpt 最后输出） | （工作树，并入 036f943） |
| v1.5.23/27 | 内核参数 `pci=realloc` / `pci=realloc,nocrs`（针对 UEFI 下 `BAR13 failed to assign io`） | （工作树，并入 036f943） |
| v1.5.24 | 决定性诊断：DIAG SAS 专门定位 LSI/Broadcom 控制器 + DIAG mods 模块加载状态——**DIAG SAS 空、无 mpt3sas_cm0** | （工作树，并入 036f943） |
| v1.5.25/26 | mpt3sas 初始化自动重试；完全回退 v1.5.6 配置 + mpt3sas 长等待（**最后一次软件尝试**） | （工作树，并入 036f943） |
| v1.5.28/29 | PCI 重新扫描（`echo 1 > /sys/bus/pci/rescan`）；实时写 U 盘诊断日志（摆脱 KVM 屏幕乱码拿全证据） | （工作树，并入 036f943） |
| **v1.6.0** | **最终版本**：ISO 解包客观对比（v1.5.6 成功 vs v1.5.27 失败，initrd 模块清单**唯一差异是 megaraid_sas**，依赖链两边完整）——证伪「竞争」假设，**恢复 megaraid_sas + 去 pci=realloc,nocrs**，一波回到 v1.5.6 成功内核启动配置。**真机仍失败**，SAS 盘依旧未在 PCI 枚举阶段被发现 | 036f943 |

## 4. 未解决核心问题（放弃的直接原因）

**真机 SAS 盘（447GiB，LSI/Broadcom 0x1000 控制器）在内核 PCI 枚举阶段未被发现。**

现象（v1.5.20+ 全面诊断确认）：
- `DIAG SAS` 输出为空——**LSI/Broadcom 0x1000 控制器未被内核枚举**（不在 lspci/PCI 设备树中）；
- 无 `mpt3sas_cm0`（mpt3sas 控制器未初始化，无 scsi_host）；
- `lsblk` 只有启动 U 盘，SAS 盘完全不出现；
- 对照：v1.5.6 曾成功（`mpt3sas_cm0 port enable SUCCESS`，sda 447GiB 在 scsi host 32），但后续版本无论怎么配置都未再复现——v1.5.6 成功属概率性事件（时序/内存状态巧合）。

多轮软件修复（全部无效）：
1. 强制 SCSI 重扫描（v1.5.15，无 scsi_host 可扫）；
2. mpt3sas `max_queue_depth=10000`（v1.5.16，Fedora/Broadcom 已知内存分配问题——控制器根本没走到 probe）；
3. 去/恢复 usb-storage/uas（v1.5.17）；
4. 回退 v1.5.6 配置（v1.5.18）；
5. 去 megaraid_sas「竞争」假设（v1.5.19）；
6. mpt3sas 初始化自动重试（v1.5.25）；
7. `pci=realloc,nocrs` 内核参数（v1.5.23/27，BAR13）；
8. PCI 重新扫描 `echo 1 > /sys/bus/pci/rescan`（v1.5.28）；
9. ISO 解包对比后一波回 v1.5.6 成功配置（v1.6.0 恢复 megaraid_sas + 去 pci=realloc,nocrs）。

**判定**：设备在 Linux 内核 PCI 枚举阶段（固件→PCIe 链路→设备树）就未被发现——**PCIe 链路/固件枚举层问题，软件不可解**（业界权威结论：设备不在 `lspci` 中时，问题不在 OS/initramfs 层；控制器/链路/固件/时序层面 Linux 工具链无法干预）。

## 5. 放弃结论

- Linux 内核枚举 PCI 设备的问题**无法在工具层（initramfs/模块/内核参数）解决**——无论怎么配置模块白名单、内核参数、重扫描，控制器都不出现在 lspci 中；
- 转向 **FirPE（Windows PE，厂商驱动枚举可靠）+ DiskGenius 命令行清盘**方案：Windows PE 自带/厂商 SAS 驱动枚举可靠，DiskGenius 命令行可脚本化逐盘清分区，现场流程同样可控；
- 本方案代码与全部排查记录**完整归档**，未来若换硬件/环境（控制器在 lspci 中可见）可基于 git 历史恢复并直接复用 v1.6.0 的成熟部分（双引导、Kylin 内核、全 ASCII 界面、日志体系、400+ 离线测试）。

## 6. 归档说明

- **代码**：全部提交至 git。方案最后功能 commit 为 `036f943`（v1.6.0，`fix(diskwipe-iso): 恢复 megaraid_sas + 去 pci=realloc,nocrs`）；本次归档 commit 追加本 ARCHIVE.md、设计/计划文档与 SDD 记录。
- **已入库内容**：`diskwipe-iso/` 全部代码与测试（src/、build-lib.sh、build.sh、kylin-kernel-export.sh、VERSION、tests/、README.md、.gitignore）、`docs/superpowers/plans+specs` 方案文档、`.superpowers/sdd/2026-11-22-diskwipe-iso-*`（gfxpayload-fix / scan-hang 两个 SDD 工作区全部记录：briefs/reports/reviews/progress.md）。
- **不入库（本地保留）**：官方 `Kylin-*.iso`（4.6GB）、`kylin-src-*.tar.gz`（425M）与解压目录 `kylin-src/`（996M）、构建产物 `output/`——均已 gitignore；如需重新构建，从本地恢复材料后 `bash diskwipe-iso/build.sh` 即可。
- **SDD 记录**：本方案的完整排查历程（v1.3.0 起所有真机问题、v1.5.x 系列 30 个任务的 briefs/reports/reviews、最终整支复查）见 `.superpowers/sdd/2026-11-22-diskwipe-iso-gfxpayload-fix/` 与 `.superpowers/sdd/2026-11-22-diskwipe-iso-scan-hang/`，是恢复方案时最完整的一手资料。
