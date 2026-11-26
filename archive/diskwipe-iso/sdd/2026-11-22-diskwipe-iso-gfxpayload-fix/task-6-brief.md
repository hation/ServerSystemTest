# Task 6 brief — v1.5.6 显卡循环只留 ast + 进度改 kmsg（解决真机 sdb 后卡死）

## 背景（根因已分析）

真机 v1.5.5（Kylin 内核 + AST2500）日志分析：
- 显示正常（AST2500 fbcon 切换）、磁盘枚举正常（sda/sdb），驱动全部注册成功（18.5-19.66s）。
- **屏幕最后定格在 sdb Attached（19.66s）**，之后无任何新输出（用户只能看到屏幕最后几行，
  卡点前的 `loading module` 进度行被 sdb 等后续内核日志滚动覆盖）。
- **结论**：卡点发生在 sdb（19.66s）**之前**，即 init 的**显卡驱动循环**——ast 加载成功后
  （18.6s），继续 modprobe mgag200/smifb/bochs-drm/cirrus/virtio-gpu。真机只有 AST2500，
  其余 5 个显卡驱动探测时挂起（内核 D 状态，用户态 `timeout 5` 无法杀死）→ init 卡死。

**修复**：
1. **显卡循环只加载 ast**（真机确认 AST2500；其余显卡驱动从循环移除，需要时按机器
   单独配置）——消除 D 状态卡点。
2. **进度行改走 `/dev/kmsg`**（内核 printk 通道，与内核日志混排，屏幕最后几行可见）
   ——若仍卡在别处（磁盘循环/mdev），kmsg 进度行会留在屏幕供定位。

## 任务（精确）

### 1. `diskwipe-iso/src/init` 改造（POSIX/ash、LF 行尾、中文注释）

a) **新增 kmsg 进度辅助**（文件头部，PATH 设置后）：
   ```
   # v1.5.6：进度走 /dev/kmsg（内核 printk 通道）——与内核日志混排，真机 KVM 屏幕
   # 最后几行可见（普通 echo 到 /dev/console 在 fbcon 切换前的输出被丢弃/滚动覆盖）。
   dw_progress() { echo "diskwipe-init: $*" > /dev/kmsg 2>/dev/null; }
   ```
b) **磁盘模块循环**（现 v1.5.5 版）：`echo "loading module $im"` 改为
   `dw_progress "loading module $im"`；其余（timeout 5 + WARN 继续）不变。
   `echo "Disk driver modules loaded"` 改 `dw_progress "Disk driver modules loaded"`。
c) **显卡循环**（现 v1.5.5 版，`for gv in ast mgag200 ...`）：**只保留 ast**：
   ```
   # v1.5.6：显卡循环只加载 ast（真机 AST2500）。mgag200/smifb/bochs-drm/cirrus/
   # virtio-gpu 在无对应硬件时 modprobe 可能内核 D 状态挂起（用户态 timeout 无效），
   # 导致 init 卡死（真机实证 sdb 枚举后无输出）；需要时按机器单独加入白名单。
   dw_progress "loading video module ast"
   timeout 5 modprobe ast 2>/dev/null
   ```
d) **mdev**：`echo "device scan (mdev -s)"` 改 `dw_progress "device scan (mdev -s)"`；
   `echo "Device nodes scanned"` 改 `dw_progress "Device nodes scanned"`。其余不变。

### 2. `diskwipe-iso/build-lib.sh`：`DW_KYLIN_MODULES` 白名单中的显卡种子
   只保留 `ast`（移除 mgag200 smifb bochs-drm cirrus virtio-gpu）——initrd 不再打包
   这些模块（构建体积减小、init 无法加载它们）。注释说明原因（同 init 注释）。

### 3. `diskwipe-iso/VERSION`：`1.5.5` → `1.5.6`。

### 4. 重新构建（WSL Kylin 模式）：`output/diskwipe-v1.5.6.iso`。

## 禁止改动

- `src/menu.sh`、`src/lib.sh`、`src/wipe.sh`、isolinux、grub.cfg 直启、embedded-efi.cfg、
  BOOTX64.EFI、xorriso。

## 验证（必须全部通过）

- **qemu A**（UEFI -vga std，参考 tmp/dw-smoke-uefi-v155.sh 改 VERSION 1.5.6）：fb0 +
  Console switching + 全流程（DiskWipe Tool 1.5.6、三盘、OK x3、Exited、Cleanup log）；
  kmsg 进度行（diskwipe-init: loading module ...）应出现。
- **qemu B**（-vga none，参考 tmp/novid-v155.sh）：serial 兜底 + 内核启动 + kmsg 进度行。
- **qemu C**（BIOS isolinux，参考 tmp/dw-smoke-v155.sh）：21 项回归（VERSION 1.5.6）。
- **tests t1-t6 回归**（diskwipe-iso/tests/）：适配 kmsg 进度（假件需覆盖 /dev/kmsg 写
  或断言 dw_progress 调用）与显卡循环只留 ast。全部 PASS。
- 验证脚本留档 tmp/dw-smoke-uefi-v156.sh / tmp/novid-v156.sh / tmp/dw-smoke-v156.sh。

## 提交

commit：`fix(diskwipe-iso): 显卡循环只留 ast（真机 AST2500，其余显卡驱动无硬件时 D 状态挂起致卡死）+ 进度改 /dev/kmsg；v1.5.6 重打包`

## 报告

写 `task-6-report.md`：改动 diff、构建关键行、A/B/C+tests 断言输出、commit hash。
返回：状态、commit hash、一行测试摘要、concerns。