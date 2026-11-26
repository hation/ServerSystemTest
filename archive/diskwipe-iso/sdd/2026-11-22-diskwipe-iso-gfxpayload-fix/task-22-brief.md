# Task 22 brief — v1.5.22 DIAG pci/mpt 单独最后输出（屏幕最后几行必见）

## 背景（用户明确要求）

用户贴的 v1.5.20/21 日志中 DIAG pci/mpt 被其他诊断行（RAW lsblk/parts 等）刷屏覆盖，
乱码看不清。**用户要求：把 DIAG pci 和 DIAG mpt 改成单独最后输出**——每次枚举时
这两行放最后（用户 KVM 屏幕只能看到最后几行，必然看到这两行）。拿到 mpt3sas
probe 失败的具体错误后对症修复。

## 任务（精确，基于 HEAD=7ed5f40；工作树可能含 v1.5.20/21 未提交 DIAG 改动）

### 1. `diskwipe-iso/src/menu.sh`：诊断输出顺序调整——DIAG pci + DIAG mpt 放最后

在枚举处的全部诊断行中，**把 `DIAG pci` 和 `DIAG mpt` 移到枚举/诊断输出的最后**
（即：RAW lsblk → RAW enum → DIAG hosts → DIAG parts → DIAG sd → DIAG scsi →
**DIAG pci → DIAG mpt（最后两行）**）。每次枚举的最后一行是 DIAG mpt。
（用 dw_progress 依次输出，顺序调整即可；`DIAG mpt` 必须是无盘重试时的最后一屏）

### 2. 若工作树 VERSION 为 1.5.20/21，改为 `1.5.22`（与提交一致）。

### 3. 重新构建（WSL Kylin 模式）：`output/diskwipe-v1.5.22.iso`。

## 禁止改动

- src/lib.sh、src/wipe.sh、build-lib.sh、isolinux、grub.cfg、embedded、BOOTX64.EFI、xorriso。
- DIAG 行的**内容**（pci 全量含 NONE、mpt 放大 grep）不变，只调**顺序**；白名单（去
  megaraid_sas）不动；init 不动。

## 验证（必须全部通过）

- **qemu A**（UEFI -vga std 有盘）：全流程（DiskWipe Tool 1.5.22、三盘、OK x3、Exited、
  日志降级）+ 断言 DIAG pci/mpt 为枚举诊断的最后两行（输出顺序）。
- **qemu B**（-vga none 无盘）：无限重试 + DIAG 行（pci/mpt 最后）+ dmesg-tail；
  无 reboot/关机。
- **qemu C**（BIOS isolinux 有盘）：21 项回归（VERSION 1.5.22）。
- **tests t1-t6**（WSL 跑，勿用 Git Bash）：适配（DIAG pci/mpt 顺序断言）。
  全 PASS。
- 验证脚本留档 tmp/dw-smoke-uefi-v1522.sh / tmp/novid-v1522.sh / tmp/dw-smoke-v1522.sh。
- **注**：真机验证由用户执行——重点看最后两行 DIAG pci（SAS 控制器 PCI 地址+NONE/驱动名）
  与 DIAG mpt（mpt3sas probe 失败具体错误）。

## 提交

commit：`feat(diskwipe-iso): DIAG pci/mpt 单独最后输出（用户 KVM 屏幕仅见最后几行——
每轮枚举最后两行必为 DIAG pci 与 DIAG mpt，定位 mpt3sas 未初始化 SAS 控制器的具体
失败原因）；v1.5.22 重打包`

## 报告

写 `task-22-report.md`：改动 diff、构建关键行、A/B/C+tests 断言输出、commit hash。
返回：状态、commit hash、一行测试摘要、concerns。