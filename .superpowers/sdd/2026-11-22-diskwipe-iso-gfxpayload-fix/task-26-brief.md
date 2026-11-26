# Task 26 brief — v1.5.26 完全回退 v1.5.6 配置 + mpt3sas 长等待（最后一次软件尝试）

## 背景（逐行对比结论 + 决策）

逐行对比 v1.5.6（唯一成功）与当前 init：加载方式（timeout 5 modprobe）、白名单、
等待逻辑均无解释成功/失败的确定性差异（megaraid_sas 有/无都有成功与失败记录）。
**怀疑硬件/环境状态变化**（v1.5.6 11-23 成功 → 现在失败 + 用户称系统起不来）。
**决策：最后一次完全回退 v1.5.6 配置**（恢复 megaraid_sas + 设备重试扫描 mdev 轮询 +
去掉 pci=realloc）+ **mpt3sas 加载后长等待（read -t 20）**。若仍失败 → 基本确定硬件
问题（转查 BIOS/硬件，不再让用户空跑 ISO）。

## 任务（精确，基于工作树——含 v1.5.20-25 未提交改动）

### 1. `diskwipe-iso/src/init`：恢复 v1.5.6 关键配置 + mpt3sas 长等待
- **白名单恢复 megaraid_sas**（Kylin DRIVE_MODULES 加回 megaraid_sas——v1.5.6 有它
  时成功；与 build-lib DW_KYLIN_MODULES 同步）。
- **恢复设备重试扫描**（v1.5.6 语义：mdev -s 后 3 轮重试，每轮 mdev -s + 等待；
  **等待用 read -t 2 防 sleep 失真**；mdev 仅建节点不读数据，U 盘卡死风险低——
  v1.5.6 实证安全）。
- **mpt3sas 加载后长等待**：mpt3sas modprobe 后 `read -t 20 dummy < /dev/tty0
  2>/dev/null || true`（v1.5.6 时序 mpt3sas 初始化约 5 秒，长等待确保完成；read -t
  防 sleep 失真）。
- 保留 usb-storage/uas、usbhid（输入需要）、其余诊断可保留（不删，防再需）。

### 2. `diskwipe-iso/build-lib.sh`：白名单恢复 megaraid_sas + 去掉 pci=realloc
- DW_KYLIN_MODULES 加回 megaraid_sas（与 init 同步）。
- **去掉 pci=realloc**（v1.5.23 加、v1.5.6 无——恢复 v1.5.6 内核命令行
  `console=tty0 console=ttyS0,115200n8`；isolinux.cfg/grub.cfg 同步去掉，
  相关校验断言翻转）。

### 3. `diskwipe-iso/VERSION`：改为 `1.5.26`。

### 4. 重新构建（WSL Kylin 模式）：`output/diskwipe-v1.5.26.iso`。

## 禁止改动

- src/menu.sh、src/lib.sh、src/wipe.sh、embedded、BOOTX64.EFI、xorriso。

## 验证（必须全部通过）

- **qemu A**（UEFI -vga std 有盘）：全流程（DiskWipe Tool 1.5.26、三盘、OK x3、Exited、
  日志降级）——megaraid_sas 恢复对 virtio 无影响；断言 initrd 含 megaraid_sas.ko +
  不含 pci=realloc。
- **qemu B**（-vga none 无盘）：无限重试 + mdev 轮询 3 轮 + read -t；无 reboot/关机。
- **qemu C**（BIOS isolinux 有盘）：21 项回归（VERSION 1.5.26，APPEND 无 pci=realloc）。
- **tests t1-t6**（WSL 跑，勿用 Git Bash）：适配（megaraid_sas 恢复、pci=realloc
  翻转断言、mdev 轮询 3 轮、mpt3sas read -t 20）。全 PASS。
- 验证脚本留档 tmp/dw-smoke-uefi-v1526.sh / tmp/novid-v1526.sh / tmp/dw-smoke-v1526.sh。
- **注**：真机验证由用户执行——**本次为最后一次软件尝试**；若 SAS 盘仍不出现，
  报告结论「基本确定硬件/环境问题（SAS 控制器/盘/背板/BIOS），转查 BIOS 与 BMC」。

## 提交

commit：`fix(diskwipe-iso): 完全回退 v1.5.6 配置（恢复 megaraid_sas + mdev 轮询 3 轮 +
去 pci=realloc）+ mpt3sas 加载后 read -t 20 长等待——最后一次软件尝试（逐行对比无
确定性差异，怀疑硬件/环境状态变化；仍失败则转查 BIOS/硬件）；v1.5.26 重打包`

## 报告

写 `task-26-report.md`：改动 diff、构建关键行、A/B/C+tests 断言输出、commit hash。
返回：状态、commit hash、一行测试摘要、concerns。