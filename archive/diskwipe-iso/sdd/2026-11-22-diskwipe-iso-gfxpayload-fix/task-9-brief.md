# Task 9 brief — v1.5.9 去掉 usb-storage（U 盘不绑定，根治设备枚举系统级卡死）

## 背景（根因最终确认）

真机 v1.5.8（已去 uas）：驱动/显卡/mdev 全部正常推进到 `device settle wait (sleep)`，
**此后 >30 秒屏幕无任何输出（连 exec menu.sh 诊断行都没出现）** → **sleep 3 都无法完成
→ 系统整体停滞**（非 init 逻辑问题）。用户确认无法换 U 盘（ASolid USB 59GB，Ventoy 盘）。

**根因**：usb-storage 驱动绑定 U 盘后，内核 SCSI 扫描读 U 盘（分区表/容量）→ I/O 阻塞
（D 状态/停滞）→ **整个系统调度停滞**（用户态 sleep 无法返回）。v1.5.6 日志实证 sdb
枚举耗时 2.6s 且其后任何 U 盘 I/O 都触发卡死。

**修复（根治）**：**init 不再加载 usb-storage 模块** → U 盘不被绑定为存储设备 → 内核
不读 U 盘 → 系统正常启动。
- **USB 键盘/鼠标不受影响**：Kylin 内核 usbhid/hid 为**内建**（modules.builtin 确认：
  kernel/drivers/hid/hid.ko + usbhid/usbhid.ko + hid-generic.ko）→ 自动工作、无需加载。
- **代价**：U 盘不可用于写日志 → dw_save_log_to_usb 降级（既有 WARN 提示：日志留内存，
  抄录后断电）——清盘功能完整。

## 任务（精确）

### 1. `diskwipe-iso/src/init`：Kylin 模式 `DRIVE_MODULES`（case *ky10* 分支）去掉 `usb-storage`
（注释：v1.5.9 去掉 usb-storage——真机 U 盘绑定后读盘触发内核 I/O 阻塞致系统整体
停滞（>30s 无调度）；U 盘不绑定则内核不读盘、系统正常启动；USB 键盘走内建 usbhid
不受影响；退出写日志 U 盘降级留内存（既有 WARN 提示））。

### 2. `diskwipe-iso/build-lib.sh`：`DW_KYLIN_MODULES` 白名单去掉 `usb-storage`
（initrd 不再打包；注释同上）。

### 3. `diskwipe-iso/VERSION`：`1.5.8` → `1.5.9`。

### 4. 重新构建（WSL Kylin 模式）：`output/diskwipe-v1.5.9.iso`。

## 禁止改动

- src/menu.sh、src/lib.sh、src/wipe.sh、isolinux、grub.cfg、embedded、BOOTX64.EFI、
  xorriso。

## 验证（必须全部通过）

- **qemu A**（UEFI -vga std，参考 tmp/dw-smoke-uefi-v158.sh 改 VERSION 1.5.9）：全流程
  断言调整——U 盘不再识别，**"Cleanup log saved to USB" 改为降级断言**
  （`Log kept in memory` 或 `WARN: could not write log to USB`）；其余（DiskWipe Tool
  1.5.9、三盘、OK x3、Exited）不变。
- **qemu B**（-vga none，参考 tmp/novid-v158.sh）：serial 兜底 + 内核启动 + 诊断行。
- **qemu C**（BIOS isolinux，参考 tmp/dw-smoke-v158.sh）：21 项回归（VERSION 1.5.9，
  日志断言同 A 调整）。
- **tests t1-t6 回归**：适配 usb-storage 去掉（t3_init：Kylin 白名单无 usb-storage；
  t4_log：U 盘写日志降级路径断言）。全部 PASS。
- 验证脚本留档 tmp/dw-smoke-uefi-v159.sh / tmp/novid-v159.sh / tmp/dw-smoke-v159.sh。

## 提交

commit：`fix(diskwipe-iso): 去掉 usb-storage（U 盘绑定读盘触发内核 I/O 阻塞致系统整体停滞，USB 键盘走内建 usbhid 不受影响）；v1.5.9 重打包`

## 报告

写 `task-9-report.md`：改动 diff、构建关键行、A/B/C+tests 断言输出、commit hash。
返回：状态、commit hash、一行测试摘要、concerns。