# Task 27 brief — v1.5.27 内核参数 pci=realloc,nocrs（根治 UEFI 下 BAR13 PCI 资源分配失败）

## 背景（重新分析 BAR13——确定性根因）

用户否认硬件问题。重新分析真机 `BAR13: failed to assign io size 0x1000`：
**UEFI 下 PCI I/O 资源分配失败**——内核按 ACPI 固件表（_CRS）分配，但固件表给的
I/O 空间不足（SAS 控制器在 0x80+ 总线段，I/O 空间 64K 不够分）→ SAS 控制器分不到
I/O → mpt3sas 无法初始化（无 scsi_host）→ 盘不识别。
**pci=realloc 无效**：realloc 只是「基于现有 ACPI 表重新分配」，表资源不足则重分配
也分不到。**正确修复：pci=nocrs**（内核不用 ACPI _CRS，从零重新分配全部 PCI 资源）——
NVIDIA/Red Hat 针对 BAR 分配失败的标准方案，常与 realloc 组合：`pci=realloc,nocrs`。
**这是确定性修复**（针对 BAR13 机制），非概率。

## 任务（精确，基于工作树——含 v1.5.20-26 未提交改动；Task 26 回退未执行，保持现状）

### 1. 内核命令行改 `pci=realloc,nocrs`
- `diskwipe-iso/build-lib.sh`：isolinux.cfg APPEND 与 grub.cfg linux 行的
  `pci=realloc` 改为 **`pci=realloc,nocrs`**（保留双 console 参数；注释更新：
  v1.5.27——nocrs 不用 ACPI _CRS 从零分配 PCI 资源，根治 UEFI 下 BAR13 failed to
  assign io（realloc 基于 ACPI 表重分配无效）；校验断言同步改 pci=realloc,nocrs）。
- **注意**：若工作树仍为 pci=realloc（v1.5.23 加），直接改成 realloc,nocrs；
  若已含其他改动，保持一致。

### 2. `diskwipe-iso/VERSION`：改为 `1.5.27`。

### 3. 重新构建（WSL Kylin 模式）：`output/diskwipe-v1.5.27.iso`。
**关键**：isoinfo 校验 isolinux.cfg 与 grub.cfg 含 `pci=realloc,nocrs`。

## 禁止改动

- src/init、src/menu.sh、src/lib.sh、src/wipe.sh、embedded、BOOTX64.EFI、xorriso、
  白名单。现有 DIAG 行保留。

## 验证（必须全部通过）

- **qemu A**（UEFI -vga std 有盘）：全流程（DiskWipe Tool 1.5.27、三盘、OK x3、Exited、
  日志降级）——pci=realloc,nocrs 对 qemu 无副作用；断言 grub.cfg 含 pci=realloc,nocrs。
- **qemu B**（-vga none 无盘）：无限重试 + DIAG 行；无 reboot/关机。
- **qemu C**（BIOS isolinux 有盘）：21 项回归（VERSION 1.5.27）+ 断言 APPEND 含
  pci=realloc,nocrs。
- **tests t1-t6**（WSL 跑，勿用 Git Bash）：适配（pci=realloc,nocrs 断言）。
  全 PASS。
- 验证脚本留档 tmp/dw-smoke-uefi-v1527.sh / tmp/novid-v1527.sh / tmp/dw-smoke-v1527.sh。
- **注**：真机验证由用户执行——预期 BAR13 failed 消失、mpt3sas 创建 scsi_host、
  SAS 盘（447GiB）带出（UEFI 路径）。

## 提交

commit：`fix(diskwipe-iso): 内核参数 pci=realloc,nocrs（根治 UEFI 下 BAR13 failed to
assign io——内核按 ACPI _CRS 分配 I/O 空间不足致 SAS 控制器无法初始化；realloc 基于
ACPI 表重分配无效，nocrs 从零分配 PCI 资源，NVIDIA/Red Hat 标准方案）；v1.5.27 重打包`

## 报告

写 `task-27-report.md`：改动 diff、构建关键行（isolinux.cfg/grub.cfg 含
pci=realloc,nocrs 证据）、A/B/C+tests 断言输出、commit hash。返回：状态、commit hash、
一行测试摘要、concerns。