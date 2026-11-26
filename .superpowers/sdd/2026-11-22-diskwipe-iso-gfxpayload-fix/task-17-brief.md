# Task 17 brief — v1.5.17 恢复 usb-storage/uas（触发 SCSI 扫描带出 SAS 盘）+ 就绪后卸载防卡死

## 背景（基于证据的复盘，v1.5.16 max_queue_depth 无效）

真机全历程铁证：
- **v1.5.6（唯一 sda 识别成功的版本）**：加载了 usb-storage + uas → `mpt3sas_cm0:
  port enable: SUCCESS` → `sd 32:0:0:0: [sda] 447GiB` 带出（scsi host 32 = mpt3sas）。
- v1.5.9 起去掉 usb-storage/uas → **sda 再未出现过**（lsblk 空、mpt3sas_cm0 未出现）。
- v1.5.15 rescan（无 scsi_host 可扫，无效）、v1.5.16 max_queue_depth=10000（无效）——
  都未解决。**唯一成功配置是 v1.5.6（有 usb-storage/uas）**。

**结论**：usb-storage 加载触发 SCSI 总线扫描/事件，使 mpt3sas 控制器完成初始化并把
SAS 盘带出（v1.5.6 证据：usb-storage 加载后 sda 出现）。**修复 = 恢复 usb-storage/uas
加载 + 设备就绪后卸载（防 v1.5.7/1.5.8 的 U 盘卡死）**。

## 任务（精确，基于 HEAD=ec74487）

### 1. `diskwipe-iso/src/init`：白名单加回 usb-storage + uas

DW_MODULES 或 Kylin 白名单对应模块加回：**usb-storage（文件名形态 usb-storage.ko）
+ uas**（Kylin 4.19 白名单——与 v1.5.6 一致，含 uas 依赖链 usb-storage）。
**注意**：Kylin 模式白名单（DW_KYLIN_MODULES）加回 `usb-storage uas`；构建层
build-lib.sh 的 Kylin 提取白名单同步加回（**这是本任务唯一允许动的 build-lib.sh
位置：白名单数组加回 usb-storage uas，其他一律不动**）。

### 2. `diskwipe-iso/src/init`：设备就绪后卸载 usb-storage/uas（防卡死）

在「Disk driver modules loaded」与 device scan（mdev -s）之间、或 settle wait 之后、
exec menu 之前，加：
```
# v1.5.17：U 盘设备已绑定（触发 SCSI 扫描带出 SAS 盘）。退出写日志 U 盘不再需要
# （日志降级内存+屏幕），卸载 usb-storage/uas 消除 U 盘 I/O 阻塞（v1.5.7/1.5.8 卡死
# 根源）。卸载失败不阻断（无 U 盘时 usb-storage 仍加载、卸载亦无害）。
rmmod usb-storage uas 2>/dev/null || true
```
（**位置**：settle wait（sleep）之后、exec menu.sh 之前——确保 SAS 盘已带出再卸载；
busybox 无 rmmod applet 时该行 no-op 无害，init 已有 modprobe 故必有 modprobe，
rmmod 若缺失则注释说明。**核实 init 当前是否有 rmmod 可用**——busybox 静态含
modprobe applet；rmmod 若无，用 `modprobe -r usb-storage uas`（busybox modprobe 支持 -r）。）

### 3. `diskwipe-iso/VERSION`：`1.5.16` → `1.5.17`。

### 4. 重新构建（WSL Kylin 模式）：`output/diskwipe-v1.5.17.iso`。
**关键**：构建产物 initrd 必须含 usb-storage.ko + uas.ko（isoinfo 解包校验）。

## 禁止改动

- src/menu.sh、src/lib.sh、src/wipe.sh、isolinux、grub.cfg、embedded、BOOTX64.EFI、
  xorriso。**build-lib.sh 仅允许白名单数组加回 usb-storage uas（一处），其余零改动**。

## 验证（必须全部通过）

- **qemu A**（UEFI -vga std 有盘）：全流程（DiskWipe Tool 1.5.17、三盘、OK x3、Exited、
  日志降级）——qemu 三盘 virtio，usb-storage 加载无 U 盘绑定 → 卸载正常；断言 initrd
  含 usb-storage.ko/uas.ko + rmmod/modprobe -r 分支。
- **qemu B**（-vga none 无盘）：无限重试 + read -t + rescan；无 reboot/关机。
- **qemu C**（BIOS isolinux 有盘）：21 项回归（VERSION 1.5.17）。
- **tests t1-t6**（WSL 跑，勿用 Git Bash）：适配（白名单含 usb-storage/uas、卸载分支
  断言）。全 PASS。
- **isoinfo 校验**：initrd 内 usb-storage.ko/uas.ko 存在。
- 验证脚本留档 tmp/dw-smoke-uefi-v1517.sh / tmp/novid-v1517.sh / tmp/dw-smoke-v1517.sh。
- **注**：qemu 无法覆盖 usb-storage 触发 mpt3sas 的真机疗效（virtio 盘），真机验证由用户执行。

## 提交

commit：`fix(diskwipe-iso): 恢复 usb-storage/uas（v1.5.6 唯一 sda 识别成功配置：usb-storage 加载触发 SCSI 扫描带出 SAS 盘）+ 就绪后卸载防 U 盘卡死；v1.5.17 重打包`

## 报告

写 `task-17-report.md`：改动 diff、构建关键行（initrd 含 usb-storage.ko/uas.ko 证据）、
A/B/C+tests 断言输出、commit hash。返回：状态、commit hash、一行测试摘要、concerns。