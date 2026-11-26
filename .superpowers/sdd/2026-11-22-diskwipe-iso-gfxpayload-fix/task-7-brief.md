# Task 7 brief — v1.5.7 去掉设备重试扫描（U 盘 D 状态卡点）+ 菜单阶段全进度

## 背景（卡点已锁定）

真机 v1.5.6 日志（kmsg 进度可见）确认：
- 磁盘驱动、显卡（只留 ast）、mdev 首扫全部正常（`Device nodes scanned` 20.28s）。
- sdb（U 盘，ASolid USB 59GB）枚举完成（21.13s）。
- **之后无任何输出**（无菜单横幅）→ 卡在 init 的**设备重试扫描**（`sleep 2 + 3 轮
  mdev -s`，v1.5.5 起每轮 mdev 包 timeout 5，但**U 盘 I/O 阻塞为内核 D 状态，用户态
  timeout 无法杀死**）→ init 卡死，menu 永不启动。

**修复**：
1. **去掉设备重试扫描**（首扫后仅 sleep 等待设备稳定，不做 mdev）——消除 U 盘 D 状态
   卡点。U 盘设备节点（/dev/sdb*）缺失 → 退出写日志由 lib.sh 的 dw_save_log_to_usb
   内补 mdev -s（见下），失败降级（已有 WARN 提示）。
2. **menu 阶段全进度（/dev/kmsg）**——万一仍卡（menu 内部），屏幕会显示 menu 内
   卡点（menu started / enumerating / scanning / saving log）。
3. **dw_save_log_to_usb 补 mdev -s**——清盘完成后写 U 盘日志前补建设备节点（此时若
   mdev 卡属可接受：清盘已完成，WARN 提示抄录后断电）。

## 任务（精确）

### 1. `diskwipe-iso/src/init`（POSIX/ash、LF 行尾、中文注释）

**设备重试扫描段**（现 v1.5.6 版，约 84-88 行：`sleep 2` + `for dwtry in 1 2 3; do
mdev -s; sleep 2; done`）改为：
```
# v1.5.7：去掉设备重试扫描（mdev -s 轮询）——真机 U 盘枚举后重试 mdev 触发 U 盘 I/O
# 阻塞（内核 D 状态，用户态 timeout 无效）致 init 卡死。改为仅 sleep 等待设备稳定；
# U 盘设备节点由 menu 退出写日志前 dw_save_log_to_usb 内 mdev -s 补建（失败降级）。
dw_progress "device settle wait (sleep)"
sleep 3
```
（`dw_progress` 与 v1.5.6 相同：`echo "diskwipe-init: $*" > /dev/kmsg 2>/dev/null`）

### 2. `diskwipe-iso/src/lib.sh` 的 `dw_save_log_to_usb`（POSIX/ash）

在函数**开头**（枚举候选分区前）加：
```
# v1.5.7：清盘完成后写日志前补建 U 盘设备节点（init 已不再重试 mdev；此时若 mdev
# 卡住属可接受——清盘已完成，下方降级提示抄录后断电）
"$TIMEOUT_BIN" 5 mdev -s 2>/dev/null
```
（`TIMEOUT_BIN` 接缝已存在；mdev 失败静默，后续候选分区枚举失败则走既有降级路径）

### 3. `diskwipe-iso/src/menu.sh`：入口 + 关键阶段加 kmsg 进度（定位 menu 内卡点）

在 menu.sh 入口（`. lib.sh` 之后、横幅之前）与各关键阶段加：
```
dw_progress "menu.sh started"
...
dw_progress "enumerating disks (lsblk)"
...
dw_progress "scanning disk types (blkid)"
...
dw_progress "wiping disks"
...
dw_progress "saving log to USB"
```
（`dw_progress` 定义在 lib.sh 中新增——lib.sh 顶部加与 init 相同的函数：
`dw_progress() { echo "diskwipe-init: $*" > /dev/kmsg 2>/dev/null; }`，供 init/menu/lib 共用）

### 4. `diskwipe-iso/VERSION`：`1.5.6` → `1.5.7`。

### 5. 重新构建（WSL Kylin 模式）：`output/diskwipe-v1.5.7.iso`。

## 禁止改动

- src/wipe.sh、isolinux、grub.cfg 直启、embedded-efi.cfg、BOOTX64.EFI、xorriso、
  build-lib.sh（本次不改）。
- menu.sh 仅**加进度行**，不改交互逻辑/输出内容。

## 验证（必须全部通过）

- **qemu A**（UEFI -vga std，参考 tmp/dw-smoke-uefi-v156.sh 改 VERSION 1.5.7）：全流程
  （DiskWipe Tool 1.5.7、三盘、OK x3、Exited、Cleanup log saved to USB）+ kmsg 进度行
  （device settle wait / menu.sh started / saving log to USB）。
- **qemu B**（-vga none，参考 tmp/novid-v156.sh）：serial 兜底 + 内核启动 + init 流程。
- **qemu C**（BIOS isolinux，参考 tmp/dw-smoke-v156.sh）：21 项回归（VERSION 1.5.7）。
- **tests t1-t6 回归**：适配重试轮去掉（t3_init 断言更新：无 mdev 重试轮，改为
  device settle wait）+ lib.sh 写日志 mdev（t4_log 适配）。全部 PASS。
- 验证脚本留档 tmp/dw-smoke-uefi-v157.sh / tmp/novid-v157.sh / tmp/dw-smoke-v157.sh。

## 提交

commit：`fix(diskwipe-iso): 去掉设备重试扫描（U 盘枚举后重试 mdev 触发 D 状态 I/O 阻塞致卡死）+ menu/lib 加 kmsg 进度 + 写日志前补建 U 盘节点；v1.5.7 重打包`

## 报告

写 `task-7-report.md`：改动 diff、构建关键行、A/B/C+tests 断言输出、commit hash。
返回：状态、commit hash、一行测试摘要、concerns。