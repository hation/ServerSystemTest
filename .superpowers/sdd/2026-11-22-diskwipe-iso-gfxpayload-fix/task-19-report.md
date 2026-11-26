# Task 19 report — v1.5.19 去掉 megaraid_sas（mpt3sas 独占控制器）

状态：**DONE**。commit hash 见文末。

## 改动 diff（相对工作树基线 = HEAD 468a737 + v1.5.18 未提交改动）

任务 19 改动叠加在 v1.5.18 工作树（init 已去 max_queue_depth/rescan/rmmod、VERSION=1.5.18、
t3 已适配）之上，全部并入一次 commit：

| 文件 | 改动 |
|---|---|
| `diskwipe-iso/VERSION` | 1.5.18 → **1.5.19** |
| `diskwipe-iso/src/init` | 白名单去掉 megaraid_sas（Ubuntu 分支 DRIVE_MODULES + Kylin ky10 分支 DRIVE_MODULES 均删）；文件头/白名单注释补 v1.5.19 竞争根因说明；mpt3sas 保持正常 modprobe（无 max_queue_depth 分支，v1.5.18 状态保留） |
| `diskwipe-iso/build-lib.sh` | DW_MODULES（Ubuntu）+ DW_KYLIN_MODULES（Kylin）均去 megaraid_sas；注释补 v1.5.19 根因（与 src/init 白名单同步） |
| `diskwipe-iso/tests/t3_init.sh` | DRIVE_MODULES 常量去 megaraid_sas；I1 与 I5（ky10）新增 `check_not_cmds 'modprobe megaraid_sas'` 断言；头部注释补 v1.5.19 适配说明 |

menu.sh/lib.sh/wipe.sh/isolinux/grub.cfg/embedded/BOOTX64.EFI/xorriso：**零改动**（git diff 核实）。

```diff
- DRIVE_MODULES="ahci libahci libata nvme nvme-core mpt3sas megaraid_sas virtio_blk virtio_pci xhci_pci sd_mod scsi_mod usb_storage uas nls_iso8859-1 exfat ntfs3"
+ DRIVE_MODULES="ahci libahci libata nvme nvme-core mpt3sas virtio_blk virtio_pci xhci_pci sd_mod scsi_mod usb_storage uas nls_iso8859-1 exfat ntfs3"
- DRIVE_MODULES="ahci libahci libata nvme nvme-core mpt3sas megaraid_sas virtio_blk sd_mod usb-storage uas nls_iso8859-1 vfat fat"
+ DRIVE_MODULES="ahci libahci libata nvme nvme-core mpt3sas virtio_blk sd_mod usb-storage uas nls_iso8859-1 vfat fat"
```

## 构建（WSL Kylin 模式）

`wsl -e bash tmp/build-v1519.sh`（DW_KERNEL_MODE=kylin 显式）→
`output/diskwipe-v1.5.19.iso`（39M），构建日志 tmp/build-v1519.log：

- 内核 4.19.90-89.11.v2401.ky10.x86_64；VERSION → /diskwipe.version（1.5.19）
- **Kylin 模块提取：白名单 + 依赖链共 25 个 .ko.xz（v1.5.18 为 26 个——megaraid_sas 已从
  白名单剔除，其依赖链不再进入 initrd）**；25 个全部 xz 解压为 .ko
- isoinfo 内建校验全部通过（isolinux/BOOTX64.EFI/双 console/init 执行位/diskwipe.version/
  dash -n/无 .ko.zst/.ko.xz 残留/Kylin 4.19 版本串/ahci+nvme+usb-storage+uas .ko）

### isoinfo 实检 initrd（tmp/chk-v1519-initrd.sh，关键证据）

```
PASS  initrd 含 mpt3sas.ko
PASS  initrd 不含 megaraid_sas.ko（.ko 文件实检）
PASS  initrd 含 usb-storage.ko
PASS  initrd 含 uas.ko
PASS  init 白名单代码行不含 megaraid_sas
PASS  init 白名单代码行含 mpt3sas + usb-storage uas
verdict: PASS
```
详情：`lib/modules/.../drivers/scsi/mpt3sas/mpt3sas.ko`、
`drivers/usb/storage/usb-storage.ko`、`uas.ko` 在；`megaraid_sas.ko` 不在。
（INFO：modules.dep 仍含 1 条 megaraid_sas 引用——kylin-src 全清单整文件拷入，.ko 未打包
即 busybox modprobe 无法加载，且白名单已无该模块，无害。）

## 验证（全部通过）

### qemu A（UEFI -vga std 有盘，tmp/dw-smoke-uefi-v1519.sh）

smoke verdict: **PASS**。全流程：DiskWipe Tool 1.5.19 横幅、Disks found: 3 (vda vdb vdc)、
SYS/DATA/UNK 三类盘、OK x3、Exited、日志降级留内存（无 Cleanup log saved to USB——
A 场景无 USB 设备预期）。产物断言全部 PASS：initrd 含 mpt3sas.ko、不含 megaraid_sas.ko、
含 usb-storage.ko/uas.ko、init 白名单代码行无 megaraid_sas。运行期 kmsg 无 megaraid_sas
加载行（模块循环 ahci→…→mpt3sas→virtio_blk→sd_mod→usb-storage→uas→…直接跳过
megaraid_sas）。

### qemu B（-vga none 无盘，tmp/novid-v1519.sh）

novid verdict: **PASS**。内核经 serial 启动（Linux version 4.19.90 + RAMDISK）、无盘无限重试
（retry 1/11 每 10 轮降噪、kmsg `no disks, retry N (never auto poweroff/reboot)`）、
零旧自动重启字符串（rebooting in 10s / reboot -f / reboot ineffective 等全无）、
qemu exit=124（timeout 收尾 = menu 永不退出）、RAW enum/lsblk 诊断行出现、
**运行期无 megaraid_sas 加载**。

### qemu C（BIOS ISOLINUX 有盘，tmp/dw-smoke-v1519.sh）

smoke verdict: **PASS**，无任何 FAIL 行。21 项关键行回归（ISOLINUX 6.04、Loading vmlinuz/initrd、
DiskWipe Tool 1.5.19、Disks found: 3、SYS/DATA/UNK、OK x3、Exited、Cleanup log saved to USB、
RAW 诊断、无 GNU GRUB/ERROR/Only boot media/No writable log media）+ v1.5.19 断言
（运行期无 megaraid_sas 加载、initrd 不含 megaraid_sas.ko 含 mpt3sas.ko）。U 盘数据区日志
文件实检存在（usb-storage 在场 → 退出写日志成功）。

### tests t1-t6（WSL 跑，勿用 Git Bash，tmp/run-tests-v1519.sh）

```
t1_wipe: ALL PASS   t2_menu: ALL PASS   t3_init: ALL PASS
t4_log:  ALL PASS   t5_ascii: ALL PASS  t6_scan: ALL PASS
```
t3 关键断言（tmp/t19-t3_init.log，通过 103 项、失败 0 项）：
```
PASS [I1 正常启动编排] 不得加载 megaraid_sas（v1.5.19：与 mpt3sas 竞争同一 LSI SAS 控制器，只留 mpt3sas 独占）
PASS [I5 Kylin ky10 模式恢复 usb-storage/uas] ky10 模式不得加载 megaraid_sas（…）
==== 结果: ALL PASS ====
```

## 注（真机疗效）

qemu 无法覆盖 mpt3sas 真机疗效（virtio 盘）；真机验证由用户执行（预期 LSI SAS 控制器由
mpt3sas 独占 → `mpt3sas_cm0: port enable: SUCCESS` + sda 447GiB 稳定带出，不再依赖加载时序）。

## Commit

```
7ed5f40 fix(diskwipe-iso): 去掉 megaraid_sas（与 mpt3sas 竞争同一 LSI SAS 控制器——
联网确认 Broadcom/Proxmox/Dell 已知问题；v1.5.6 盘在 mpt3sas 无需 megaraid_sas），
mpt3sas 独占控制器带出 SAS 盘；v1.5.19 重打包
```

（一次 commit，含 v1.5.18 工作树基线 + v1.5.19 改动；仅 4 个文件：VERSION/src/init/
build-lib.sh/tests/t3_init.sh）

## Concerns

- modules.dep 残留 1 条 megaraid_sas 引用（kylin-src 整文件拷贝所致，.ko 未打包不可加载，
  白名单无此模块，零影响；如需彻底清理需在 dw_modules_kylin 对 manifest 做白名单过滤——
  超出本任务范围，不擅动）。
- 验证脚本已留档 tmp/dw-smoke-uefi-v1519.sh / tmp/novid-v1519.sh / tmp/dw-smoke-v1519.sh
  / tmp/chk-v1519-initrd.sh / tmp/build-v1519.sh / tmp/run-tests-v1519.sh（tmp 不入库，同既往）。
