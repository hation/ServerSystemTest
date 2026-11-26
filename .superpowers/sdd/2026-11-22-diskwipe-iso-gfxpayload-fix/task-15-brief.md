# Task 15 brief — v1.5.15 强制 SCSI 重扫描（直接修复 sda 未被内核带出，非诊断）

## 背景（真机根因 + 用户诉求）

v1.5.14 真机：lsblk 完全空（连表头都没有）→ sda（SAS/mpt3sas）从未被内核创建。
v1.5.6 时 sda 正常出现（当时有 usb-storage/uas）。**用户明确要求：修复问题，不是
加日志排查**。**直接修复方案**：mpt3sas/megaraid_sas 加载后**强制对全部 scsi_host
写 rescan**（`echo "- - -" > /sys/class/scsi_host/host*/scan`）——即使自动 SCSI 扫描
未完成/被抢占，强制重扫描也会把 SAS 盘带出。init 与 menu 枚举前各做一次。

## 任务（精确，基于 HEAD=873f09c）

### 1. `diskwipe-iso/src/init`：磁盘驱动加载完成后强制 SCSI 重扫描

在「Disk driver modules loaded」打印之后、video 模块加载之前，加：
```
# v1.5.15 修复：SCSI 驱动（mpt3sas/megaraid_sas）加载后强制重扫描全部 scsi_host——
# 真机 SAS 盘未被自动扫描带出（lsblk 空）；echo "- - -" 触发一次完整 rescan，
# 确保盘被内核创建。逐个写、失败跳过（部分 host 非 SCSI 扫描型）。
for sh in /sys/class/scsi_host/host*/scan; do
    [ -w "$sh" ] && echo "- - -" > "$sh" 2>/dev/null || true
done
```
（**注意**：`-w` 检查可写；`2>/dev/null` 静默非 SCSI 型 host 的写入错误）

### 2. `diskwipe-iso/src/menu.sh`：枚举前强制 SCSI 重扫描（兜底）

在 `ml="$(dw_enum_disks)"` 之前（`enumerating disks` 打印后）加同样循环：
```
# v1.5.15：枚举前强制 SCSI 重扫描兜底——盘可能晚就绪，每次枚举前 rescan 一次，
# 就绪的盘下次枚举即出现（与无限重试配合）。
for sh in /sys/class/scsi_host/host*/scan; do
    [ -w "$sh" ] && echo "- - -" > "$sh" 2>/dev/null || true
done
```

### 3. `diskwipe-iso/VERSION`：`1.5.14` → `1.5.15`。

### 4. 重新构建（WSL Kylin 模式）：`output/diskwipe-v1.5.15.iso`。

## 禁止改动

- src/lib.sh、src/wipe.sh、build-lib.sh、isolinux、grub.cfg、embedded、BOOTX64.EFI、xorriso。

## 验证（必须全部通过）

- **qemu A**（UEFI -vga std 有盘）：全流程（DiskWipe Tool 1.5.15、三盘、OK x3、Exited、
  日志降级）——三盘为 virtio，rescan 不影响，流程须不变。
- **qemu B**（-vga none 无盘）：无限重试 + rescan 循环不报错 + read -t 真实间隔；无 reboot/关机。
- **qemu C**（BIOS isolinux 有盘）：21 项回归（VERSION 1.5.15）。
- **tests t1-t6**（WSL 跑，勿用 Git Bash）：适配（init rescan 循环断言、menu rescan
  循环断言）。全 PASS。
- 验证脚本留档 tmp/dw-smoke-uefi-v1515.sh / tmp/novid-v1515.sh / tmp/dw-smoke-v1515.sh。

## 提交

commit：`fix(diskwipe-iso): 强制 SCSI 重扫描（init 加载后 + menu 枚举前，echo - - - > scsi_host/scan）直接修复真机 SAS 盘未被内核带出；v1.5.15 重打包`

## 报告

写 `task-15-report.md`：改动 diff、构建关键行、A/B/C+tests 断言输出、commit hash。
返回：状态、commit hash、一行测试摘要、concerns。