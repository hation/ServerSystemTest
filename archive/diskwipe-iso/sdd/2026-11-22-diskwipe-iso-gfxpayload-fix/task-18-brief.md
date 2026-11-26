# Task 18 brief — v1.5.18 回退 v1.5.6 纯净 mpt3sas 配置（去 rescan/max_queue_depth/rmmod，保留 usb-storage）

## 背景（v1.5.17 真机证据 + 复盘）

v1.5.17 真机 lsblk：**U 盘被识别为 sda（59G USB）**（usb-storage 恢复生效），但
**SAS 盘（447GiB）依然未出现**。v1.5.6（唯一 SAS 盘识别成功版本）是**纯净配置**：
- 有 usb-storage/uas（v1.5.17 已恢复）
- **无** max_queue_depth 参数（v1.5.16 加）、**无** init rescan（v1.5.15 加）、
  **无** rmmod usb-storage（v1.5.17 加）
v1.5.6 时 mpt3sas 正常完成 `mpt3sas_cm0: port enable: SUCCESS` + sda(447GiB) 带出。
**结论**：v1.5.15/16/17 加的 mpt3sas 相关改动可能干扰控制器初始化。**修复 = 去掉这三项，
回到 v1.5.6 纯净 mpt3sas 状态**（usb-storage/uas 保留；menu rescan 保留——枚举前兜底
不干扰初始化）。

## 任务（精确，基于 HEAD=468a737）

### 1. `diskwipe-iso/src/init`：去掉 mpt3sas 相关干扰项（回到 v1.5.6 状态）

- **去掉 max_queue_depth 分支**：mpt3sas 恢复正常 `modprobe "$m"`（与其余模块一致）。
- **去掉 init 的 rescan 循环**（「Disk driver modules loaded」后的 scsi_host scan 循环）。
- **去掉 rmmod usb-storage uas**（settle 后卸载段删除——usb-storage 保持在场，
  menu 排除 USB + blkid 只扫非 USB 已防应用层；v1.5.6 即此状态）。
- 保留：usb-storage/uas 白名单、settle wait、usbhid、stdin 相关（若在 init）。

### 2. `diskwipe-iso/src/menu.sh`：**保留**枚举前 rescan（不动，兜底无害）。

### 3. `diskwipe-iso/VERSION`：`1.5.17` → `1.5.18`。

### 4. 重新构建（WSL Kylin 模式）：`output/diskwipe-v1.5.18.iso`。
**关键**：isoinfo 解包校验 initrd 仍含 usb-storage.ko/uas.ko（保留）。

## 禁止改动

- src/menu.sh（保留 menu rescan，不动）、src/lib.sh、src/wipe.sh、build-lib.sh（白名单
  保留 usb-storage uas，不动其余）、isolinux、grub.cfg、embedded、BOOTX64.EFI、xorriso。

## 验证（必须全部通过）

- **qemu A**（UEFI -vga std 有盘）：全流程（DiskWipe Tool 1.5.18、三盘、OK x3、Exited、
  日志降级）——无 max_queue_depth/rescan/rmmod 分支，流程不变；断言 initrd 含
  usb-storage.ko/uas.ko。
- **qemu B**（-vga none 无盘）：无限重试 + menu rescan + read -t；无 reboot/关机。
- **qemu C**（BIOS isolinux 有盘）：21 项回归（VERSION 1.5.18）。
- **tests t1-t6**（WSL 跑，勿用 Git Bash）：适配（去掉 max_queue_depth/rescan/rmmod
  分支断言，恢复 v1.5.6 语义）。全 PASS。
- 验证脚本留档 tmp/dw-smoke-uefi-v1518.sh / tmp/novid-v1518.sh / tmp/dw-smoke-v1518.sh。
- **注**：qemu 无法覆盖 mpt3sas 真机疗效，真机验证由用户执行。

## 提交

commit：`fix(diskwipe-iso): 回退 v1.5.6 纯净 mpt3sas 配置（去 max_queue_depth/init rescan/rmmod usb-storage——v1.5.15/16/17 加项或干扰控制器初始化），保留 usb-storage/uas；v1.5.18 重打包`

## 报告

写 `task-18-report.md`：改动 diff、构建关键行（initrd 含 usb-storage.ko/uas.ko 证据）、
A/B/C+tests 断言输出、commit hash。返回：状态、commit hash、一行测试摘要、concerns。