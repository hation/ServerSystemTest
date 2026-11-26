# Task 24 brief — v1.5.24 决定性诊断（DIAG SAS 专门定位 LSI/Broadcom 控制器 + DIAG mods 模块加载状态）

## 背景（联网澄清 + 决定性诊断需求）

v1.5.23（pci=realloc）真机 BAR13 failed to assign io 依然出现。**联网（HPE Advisory/
Red Hat）澄清：BAR13 failed to assign io size 0x1000 很可能是无害警告**（桥 I/O 窗口
无设备时不需要分配；HPE 官方：忽略）。**因此 BAR13 不是 SAS 盘不识别的原因**。
真正的关键问题：**SAS 控制器到底在不在 PCI 总线、被哪个驱动绑定**——之前 DIAG pci
打印全部设备被乱码淹没。**v1.5.24 决定性诊断**：专门找 LSI/Broadcom（vendor 0x1000）
的 PCI 设备（一行输出）+ 存储相关模块加载状态（mpt3sas 是否真加载成功）。

## 任务（精确，基于工作树——含 v1.5.20-23 未提交改动：DIAG 行、pci=realloc、VERSION 1.5.23）

### 1. `diskwipe-iso/src/menu.sh`：加 DIAG SAS + DIAG mods（决定性诊断）

在现有 DIAG 行（hosts/parts/mpt/sd/pci/scsi）基础上追加（**DIAG SAS 放在 DIAG pci
之后、DIAG mpt 之前**，保持 pci/mpt 最后两行的既有要求）：
```
# v1.5.24 决定性诊断：专门找 LSI/Broadcom（vendor 0x1000，SAS 控制器）PCI 设备——
# 地址:device:driver（mpt3sas/NONE）——一行判定 SAS 控制器在不在总线、被谁绑定。
dw_progress "DIAG SAS=$(for d in /sys/bus/pci/devices/*; do v=$(cat "$d/vendor" 2>/dev/null); if [ "$v" = "0x1000" ]; then drv=$(readlink "$d/driver" 2>/dev/null || echo NONE); printf '%s:dev=%s:drv=%s|' "${d##*/}" "$(cat "$d/device" 2>/dev/null)" "$(basename "$drv")"; fi; done)"
# v1.5.24：存储相关模块加载状态（mpt3sas/megaraid_sas/usb_storage/sd_mod/scsi_mod 等）
dw_progress "DIAG mods=$(for m in mpt3sas megaraid_sas usb_storage uas sd_mod scsi_mod libata ahci nvme virtio_blk; do [ -d "/sys/module/$m" ] && printf '%s|' "$m"; done)"
```
（vendor 0x1000 = LSI Logic/Broadcom SAS；drv NONE = 未绑定；`$d/vendor`/`$d/device`
读 PCI 厂商/设备号）

### 2. `diskwipe-iso/VERSION`：改为 `1.5.24`。

### 3. 重新构建（WSL Kylin 模式）：`output/diskwipe-v1.5.24.iso`。

## 禁止改动

- src/init、src/lib.sh、src/wipe.sh、build-lib.sh、isolinux、grub.cfg、embedded、
  BOOTX64.EFI、xorriso。pci=realloc 参数保留（无害，v1.5.23 已加）。

## 验证（必须全部通过）

- **qemu A**（UEFI -vga std 有盘）：全流程（DiskWipe Tool 1.5.24、三盘、OK x3、Exited、
  日志降级）+ DIAG SAS（qemu 无 0x1000 设备 → 行可为空但须出现）+ DIAG mods 非空。
- **qemu B**（-vga none 无盘）：无限重试 + DIAG 行 + dmesg-tail；无 reboot/关机。
- **qemu C**（BIOS isolinux 有盘）：21 项回归（VERSION 1.5.24）。
- **tests t1-t6**（WSL 跑，勿用 Git Bash）：适配（DIAG SAS/mods 断言）。全 PASS。
- 验证脚本留档 tmp/dw-smoke-uefi-v1524.sh / tmp/novid-v1524.sh / tmp/dw-smoke-v1524.sh。
- **注**：真机验证由用户执行——重点看 `DIAG SAS=` 一行：空（SAS 控制器不在 PCI 总线，
  BIOS/硬件问题）vs 有且 drv=mpt3sas（模块已绑定但无 scsi_host，mpt3sas 内部问题）vs
  drv=NONE（mpt3sas 未绑定，probe 失败）。`DIAG mods=` 确认 mpt3sas 是否真加载。

## 提交

commit：`feat(diskwipe-iso): 决定性诊断（DIAG SAS 专门定位 LSI/Broadcom vendor 0x1000
控制器绑定状态 + DIAG mods 模块加载状态）——区分 SAS 控制器不在 PCI 总线（BIOS/硬件）
vs mpt3sas 未绑定（probe 失败）vs 已绑定无 scsi_host（驱动内部）；联网澄清 BAR13 为
无害警告（HPE/Red Hat）；v1.5.24 重打包`

## 报告

写 `task-24-report.md`：改动 diff、构建关键行、A/B/C+tests 断言输出、commit hash。
返回：状态、commit hash、一行测试摘要、concerns。