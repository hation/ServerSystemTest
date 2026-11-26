# Task 10 brief — v1.5.10 等设备就绪加长 + 无盘自动重试/reboot

## 背景（v1.5.9 真机突破 + 新问题）

v1.5.9 真机日志：**系统不再卡死，menu 完整启动**（exec menu.sh → menu.sh started →
cleanup log 横幅 → enumerating disks → **Only boot media found** → session end）。
U 盘（usb-storage）去掉后系统正常，但暴露两个新问题：

1. **内部盘（sda，mpt3sas SAS 447GiB）未就绪**：mpt3sas 14.47s 才加载，SAS 盘扫描
   需数秒；menu 15.45s 就枚举（init settle wait 仅 sleep 3）→ lsblk 空 →
   "Only boot media found"。**修复：init settle wait 加长（sleep 3 → 10）**。
2. **menu 无盘退出 → PID 1 退出 → 内核 panic**（用户看到 panic 误判"卡住"）。
   **修复：无盘时自动重试枚举（3 轮）→ 仍无则自动 reboot（回 Ventoy），不 panic**。

## 任务（精确）

### 1. `diskwipe-iso/src/init`：`device settle wait (sleep)` 的 `sleep 3` → `sleep 10`
（注释：v1.5.10 加长等待——mpt3sas SAS 盘扫描需数秒，menu 枚举前需就绪；U 盘已不
绑定，等待期间无 I/O 阻塞风险）。

### 2. `diskwipe-iso/src/menu.sh`：无盘路径（现约 91-97 行）改为重试 + reboot
（保持 POSIX/ash；`dwnoretry` 计数在 `while :` 前初始化为 0）：
```
    if [ -z "$ml" ]; then
        dwnoretry=$((dwnoretry + 1))
        if [ "$dwnoretry" -le 3 ]; then
            dw_log "Only boot media found (no wipable disks yet; retrying in 5s...)"
            dw_progress "no disks, retry $dwnoretry/3 (sleep 5)"
            sleep 5
            continue
        fi
        dw_log "No wipable disks found after 3 retries."
        dw_log "You may power off or reboot safely."
        dw_progress "no disks after retries, rebooting in 10s"
        sleep 10
        reboot
    fi
```
（`reboot` 用 busybox reboot；注释说明 v1.5.10：无盘重试避免 sda 迟就绪误判，最终
reboot 回 Ventoy 而非 exit 导致 PID1 panic。交互逻辑其余不变。）

### 3. `diskwipe-iso/VERSION`：`1.5.9` → `1.5.10`。

### 4. 重新构建（WSL Kylin 模式）：`output/diskwipe-v1.5.10.iso`。

## 禁止改动

- src/lib.sh、src/wipe.sh、build-lib.sh、isolinux、grub.cfg、embedded、BOOTX64.EFI、
  xorriso。

## 验证（必须全部通过）

- **qemu A**（UEFI -vga std，参考 tmp/dw-smoke-uefi-v159.sh 改 VERSION 1.5.10）：有盘
  全流程（DiskWipe Tool 1.5.10、三盘、OK x3、Exited、日志降级）不变。
- **qemu B**（-vga none，参考 tmp/novid-v159.sh）：无盘场景——断言改为：`Only boot
  media found` + `no disks, retry`（重试）+ 最终 `rebooting in 10s`（不再断言
  "You may power off" 后 panic；qemu 内 reboot 会触发重启，timeout 收尾可接受）。
- **qemu C**（BIOS isolinux，参考 tmp/dw-smoke-v159.sh）：有盘全流程回归（VERSION
  1.5.10）。
- **tests t1-t6 回归**：适配（t3_init：settle wait sleep 10；t2_menu：无盘路径改为
  重试/reboot 断言）。全部 PASS（在 WSL 跑，勿用 Git Bash——chmod 语义差异）。
- 验证脚本留档 tmp/dw-smoke-uefi-v1510.sh / tmp/novid-v1510.sh / tmp/dw-smoke-v1510.sh。

## 提交

commit：`fix(diskwipe-iso): 等设备就绪加长（SAS 盘扫描数秒）+ 无盘自动重试/reboot（避免 PID1 退出 panic）；v1.5.10 重打包`

## 报告

写 `task-10-report.md`：改动 diff、构建关键行、A/B/C+tests 断言输出、commit hash。
返回：状态、commit hash、一行测试摘要、concerns。