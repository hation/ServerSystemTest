# Task 21 brief — v1.5.21 改进诊断（DIAG pci 全量含未绑定 + DIAG mpt 完整错误行）

## 背景（v1.5.20 真机诊断结论）

v1.5.20 真机 DIAG 行（用户已贴）：
- `DIAG hosts=host0`：**只有 1 个 scsi_host** → mpt3sas 未创建控制器。
- `DIAG pci=...0000:07:00.0:ast...0000:09:00.1:xhci...`：只有 ast/xhci/pcieport，
  **没有 SAS 控制器被 mpt3sas/megaraid_sas 绑定**（脚本只打印有 driver 的设备，
  SAS 控制器可能未绑定被遗漏）。
- `DIAG parts=...sda2...`：只有 U 盘，SAS 盘不在内核块设备表。
**根因**：mpt3sas 加载成功但**未绑定/初始化 SAS 控制器**（probe 失败、无 scsi_host）。
**需看 mpt3sas 具体错误**（内存分配失败 __get_free_pages vs 固件握手失败 vs 其他）——
**DIAG mpt 行需放大**，DIAG pci 需打印**所有 PCI 设备（含未绑定显示 NONE）**。

## 任务（精确，基于 HEAD=7ed5f40；v1.5.20 未提交则基于工作树）

### 1. `diskwipe-iso/src/menu.sh`：改进 DIAG 行（v1.5.21）

- **DIAG pci 全量**（含未绑定设备，driver 无则 NONE）：
```
dw_progress "DIAG pci=$(for d in /sys/bus/pci/devices/*; do drv=$(readlink "$d/driver" 2>/dev/null || echo NONE); printf '%s:%s|' "${d##*/}" "$(basename "$drv")"; done)"
```
- **DIAG mpt 放大**（mpt3sas/megaraid/scsih/probe/fail/chain_lookup/free_pages/max_queue_depth，
  tail 15 防刷屏）：
```
dw_progress "DIAG mpt=$(dmesg 2>/dev/null | grep -iE 'mpt3sas|megaraid|megasas|scsih|probe|fail|chain_lookup|free_pages|max_queue_depth|fault' | tail -n 15 | tr '\n' '|')"
```
- **DIAG scsi 全量**（SCSI 设备列表：/sys/bus/scsi/devices）：
```
dw_progress "DIAG scsi=$(ls /sys/bus/scsi/devices 2>/dev/null | tr '\n' '|')"
```
（保留 v1.5.20 的 hosts/parts/sd 行不动）

### 2. `diskwipe-iso/VERSION`：`1.5.19` → `1.5.21`（若 v1.5.20 未提交则直接 1.5.21）。

### 3. 重新构建（WSL Kylin 模式）：`output/diskwipe-v1.5.21.iso`。

## 禁止改动

- src/lib.sh、src/wipe.sh、build-lib.sh、isolinux、grub.cfg、embedded、BOOTX64.EFI、xorriso。
- 白名单（去 megaraid_sas）不动；init 不动（除非 v1.5.20 的模块 rc 诊断未提交需一并承载）。

## 验证（必须全部通过）

- **qemu A**（UEFI -vga std 有盘）：全流程（DiskWipe Tool 1.5.21、三盘、OK x3、Exited、
  日志降级）+ DIAG pci 含 NONE 设备、DIAG mpt/scsi 行出现。
- **qemu B**（-vga none 无盘）：无限重试 + DIAG 行 + dmesg-tail；无 reboot/关机。
- **qemu C**（BIOS isolinux 有盘）：21 项回归（VERSION 1.5.21）。
- **tests t1-t6**（WSL 跑，勿用 Git Bash）：适配（DIAG pci 全量/mpt/scsi 断言）。
  全 PASS。
- 验证脚本留档 tmp/dw-smoke-uefi-v1521.sh / tmp/novid-v1521.sh / tmp/dw-smoke-v1521.sh。
- **注**：真机验证由用户执行——重点看 `DIAG pci`（SAS 控制器 PCI 地址 + NONE 或驱动名）、
  `DIAG mpt`（mpt3sas probe 失败的具体错误）。

## 提交

commit：`feat(diskwipe-iso): 改进全面诊断（DIAG pci 全量含未绑定 NONE + DIAG mpt 放大
mpt3sas probe 错误 + DIAG scsi 设备列表）——定位 mpt3sas 未绑定 SAS 控制器（无 scsi_host）
的具体失败原因；v1.5.21 重打包`

## 报告

写 `task-21-report.md`：改动 diff、构建关键行、A/B/C+tests 断言输出、commit hash。
返回：状态、commit hash、一行测试摘要、concerns。