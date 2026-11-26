# Task 16 brief — v1.5.16 mpt3sas max_queue_depth 参数（修复 scsih_probe 失败、盘未识别）

## 背景（联网调研确认根因）

真机 v1.5.15：`mpt3sas version ... loaded`（驱动加载成功）但**始终无 `mpt3sas_cm0`
控制器初始化成功**（无 scsi_host）→ sda 从未被内核带出（lsblk 空，rescan 无效——
无 host 可扫）。

**根因（Fedora/红帽/Broadcom 已知问题）**：mpt3sas 默认 `max_queue_depth=32455`（很大），
在高核数服务器（海光 Hygon 多核）+ 内存受限环境（initramfs）下，内核无法分配大
队列深度所需内存 → `scsih_probe()` 失败 → 控制器未初始化 → 盘不识别。
**官方解决方案：modprobe mpt3sas 时传 `max_queue_depth=10000`**。

## 任务（精确，基于 HEAD=9cd973b）

### 1. `diskwipe-iso/src/init`：mpt3sas 加载加 max_queue_depth 参数

init 的白名单驱动加载循环中，**mpt3sas 单独处理**（其余模块正常 modprobe）：
```
# v1.5.16 修复：mpt3sas 默认 max_queue_depth=32455，高核数服务器（海光）+ initramfs
# 内存受限时内核无法分配大队列内存 → scsih_probe 失败 → 控制器不初始化、盘不识别
# （Fedora/Broadcom 已知问题）。传 max_queue_depth=10000 降低内存需求（官方方案）。
if [ "$m" = "mpt3sas" ]; then
    modprobe mpt3sas max_queue_depth=10000
else
    modprobe "$m"
fi
```
（**保持现有循环结构**，仅 mpt3sas 分支加参数；`$m` 为当前模块名）

### 2. `diskwipe-iso/VERSION`：`1.5.15` → `1.5.16`。

### 3. 重新构建（WSL Kylin 模式）：`output/diskwipe-v1.5.16.iso`。

## 禁止改动

- src/menu.sh、src/lib.sh、src/wipe.sh、build-lib.sh、isolinux、grub.cfg、embedded、
  BOOTX64.EFI、xorriso。**只改 src/init 的 mpt3sas 加载分支 + VERSION + tests 适配**。

## 验证（必须全部通过）

- **qemu A**（UEFI -vga std 有盘）：全流程（DiskWipe Tool 1.5.16、三盘、OK x3、Exited、
  日志降级）——qemu 三盘为 virtio（无 mpt3sas），mpt3sas 分支不执行，流程须不变；
  断言 init 的 modprobe 循环中 mpt3sas 分支逻辑（xtrace 显示参数）。
- **qemu B**（-vga none 无盘）：无限重试 + read -t + rescan；无 reboot/关机。
- **qemu C**（BIOS isolinux 有盘）：21 项回归（VERSION 1.5.16）。
- **tests t1-t6**（WSL 跑，勿用 Git Bash）：适配（mpt3sas max_queue_depth 分支断言）。
  全 PASS。
- 验证脚本留档 tmp/dw-smoke-uefi-v1516.sh / tmp/novid-v1516.sh / tmp/dw-smoke-v1516.sh。
- **注**：qemu 无法覆盖 mpt3sas 真机行为（virtio 盘），真机验证由用户执行。

## 提交

commit：`fix(diskwipe-iso): mpt3sas 加载传 max_queue_depth=10000（Fedora/Broadcom 已知问题：默认 32455 高核数服务器内存分配失败致 scsih_probe 失败、盘不识别）；v1.5.16 重打包`

## 报告

写 `task-16-report.md`：改动 diff、构建关键行、A/B/C+tests 断言输出、commit hash。
返回：状态、commit hash、一行测试摘要、concerns。