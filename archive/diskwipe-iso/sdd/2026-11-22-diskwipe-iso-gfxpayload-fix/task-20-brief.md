# Task 20 brief — v1.5.20 全面诊断版（每个可疑点都加日志，一次定位根因）

## 背景（用户明确要求全面诊断）

v1.5.19（去 megaraid_sas）真机仍失败：SAS 盘（447GiB）未出现，lsblk 只有 U 盘
（sda 59G USB）。19 轮未定位。**用户明确要求：每一个可能出问题的点都搞上日志**。
本任务做**全面诊断版**：mpt3sas 加载退出码、scsi_host 列表、/proc/partitions 块设备表、
PCI 控制器驱动绑定（SAS 控制器被谁绑定——mpt3sas/megaraid_sas/未绑定，**关键证据**）、
dmesg mpt3sas/SCSI/sd 关键日志、模块加载结果。用户只能看到屏幕最后几行（KVM 无滚动），
诊断必须压缩成少数行、每次枚举时刷新（保证最后几行是最新诊断）。

## 任务（精确，基于 HEAD=7ed5f40）

### 1. `diskwipe-iso/src/menu.sh`：枚举处加压缩诊断行（每次枚举输出）

在 `RAW lsblk`/`RAW enum` 诊断附近加（v1.5.20，全部 kmsg/dw_progress）：
```
# v1.5.20 全面诊断：每个可疑点一行——SCSI 控制器列表、内核块设备表、
# mpt3sas/megaraid/SCSI/sd 关键日志、PCI 控制器驱动绑定（SAS 控制器被谁绑）。
dw_progress "DIAG hosts=$(ls /sys/class/scsi_host 2>/dev/null | tr '\n' '|')"
dw_progress "DIAG parts=$(cat /proc/partitions 2>/dev/null | tr '\n' '|')"
dw_progress "DIAG mpt=$(dmesg 2>/dev/null | grep -E 'mpt3sas|megaraid|megasas|scsih|fault|error|fail' | tail -n 8 | tr '\n' '|')"
dw_progress "DIAG sd=$(dmesg 2>/dev/null | grep -E 'sd [0-9]|Attached SCSI|Adding|Discovered' | tail -n 8 | tr '\n' '|')"
dw_progress "DIAG pci=$(for d in /sys/bus/pci/devices/*; do drv=$(readlink "$d/driver" 2>/dev/null); [ -n "$drv" ] && printf '%s:%s|' "${d##*/}" "$(basename "$drv")"; done)"
```
（`DIAG pci` 逐设备打印 `PCI地址:驱动名`——看 SAS 控制器被 mpt3sas/megaraid_sas/
未绑定；`dmesg` grep 用 tail 限制行数防刷屏）

### 2. `diskwipe-iso/src/init`：模块加载记录退出码

模块加载循环每条后加退出码记录（kmsg）：
```
timeout 5 modprobe "$im" 2>/dev/null
dwmrc=$?
[ "$dwmrc" -ne 0 ] && dw_progress "DIAG mod $im rc=$dwmrc FAILED"
```
（仅失败时输出退出码；成功不刷屏）

### 3. `diskwipe-iso/src/menu.sh`：无盘重试时每 10 轮输出一次 dmesg 尾部

在重试消息（每 10 轮一次）处追加 dmesg 尾部（tail -40 全量，防过滤丢关键）：
```
[ $((dwnoretry % 10)) -eq 1 ] && dw_progress "DIAG dmesg-tail=$(dmesg 2>/dev/null | tail -n 40 | tr '\n' '|')"
```

### 4. `diskwipe-iso/VERSION`：`1.5.19` → `1.5.20`。

### 5. 重新构建（WSL Kylin 模式）：`output/diskwipe-v1.5.20.iso`。

## 禁止改动

- src/lib.sh、src/wipe.sh、build-lib.sh、isolinux、grub.cfg、embedded、BOOTX64.EFI、xorriso。
- **保留** v1.5.19 的去 megaraid_sas（白名单不动）。

## 验证（必须全部通过）

- **qemu A**（UEFI -vga std 有盘）：全流程（DiskWipe Tool 1.5.20、三盘、OK x3、Exited、
  日志降级）+ DIAG 诊断行（hosts/parts/mpt/sd/pci 出现且非空/合理）。
- **qemu B**（-vga none 无盘）：无限重试 + DIAG 行 + dmesg-tail 每 10 轮；无 reboot/关机。
- **qemu C**（BIOS isolinux 有盘）：21 项回归（VERSION 1.5.20）。
- **tests t1-t6**（WSL 跑，勿用 Git Bash）：适配（DIAG 行断言、模块 rc 断言）。
  全 PASS。
- 验证脚本留档 tmp/dw-smoke-uefi-v1520.sh / tmp/novid-v1520.sh / tmp/dw-smoke-v1520.sh。
- **注**：真机验证由用户执行——重点看 `DIAG hosts`（有无 mpt3sas 的 scsi_host）、
  `DIAG parts`（SAS 盘在不在内核块设备表）、`DIAG pci`（SAS 控制器被哪个驱动绑定）。

## 提交

commit：`feat(diskwipe-iso): 全面诊断（scsi_host 列表/内核块设备表/PCI 驱动绑定/
dmesg mpt3sas+SCSI+sd 日志/模块加载退出码）——用户要求每个可疑点都加日志，一次定位
真机 SAS 盘未识别根因；v1.5.20 重打包`

## 报告

写 `task-20-report.md`：改动 diff、构建关键行、A/B/C+tests 断言输出、commit hash。
返回：状态、commit hash、一行测试摘要、concerns。