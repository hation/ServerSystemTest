# Task 13 brief — v1.5.13 去掉无盘自动关机/重启（安全第一）+ 缩短等待

## 背景（紧急修复）

v1.5.12 真机：`reboot -f` 在该机器**执行成关机**（qemu 里是重启，真机变关机）→ 用户
还没看到清盘菜单就被自动断电。**必须彻底去掉无盘路径的自动 reboot/关机**——无盘时
只提示并持续重试枚举，绝不绝不自动关机/重启。同时 v1.5.11 起的 settle wait 25 秒
+ 重试 6 次太长（用户等待煎熬），缩短。

## 任务（精确，基于 HEAD=4c22a7f）

### 1. `diskwipe-iso/src/menu.sh`：无盘路径去掉 reboot（约 91-97 行 + reboot 段）

**现状**（v1.5.12）：`dwnoretry` 重试 ≤6 → 仍无盘 → `sleep 10` → `reboot -f`（真机变
关机）+ fallthrough 保护（reboot ineffective → continue）。

**改为**：**去掉 reboot/sleep 10/fallthrough**，无盘时**无限重试**（每 5 秒重枚举，
永不关机/重启，用户可随时断电）：
```
    if [ -z "$ml" ]; then
        dwnoretry=$((dwnoretry + 1))
        dw_log "No wipable disks found yet (retry $dwnoretry). Retrying every 5s... (you may power off anytime)"
        dw_progress "no disks, retry $dwnoretry (sleep 5, never auto poweroff/reboot)"
        sleep 5
        continue
    fi
```
（**删除** dwnoretry ≤3/≤6 限制与 reboot 段——无盘永远重试，盘出现即正常；注释说明
v1.5.13：绝不自动关机/重启，安全第一。交互逻辑其余不变。）

### 2. `diskwipe-iso/src/init`：settle wait `sleep 25` → `sleep 10`
（v1.5.13：等待缩短——SAS 盘扫描数秒即可，盘是否就绪由 menu 持续重试兜底）。

### 3. `diskwipe-iso/VERSION`：`1.5.12` → `1.5.13`。

### 4. 重新构建（WSL Kylin 模式）：`output/diskwipe-v1.5.13.iso`。

## 禁止改动

- src/lib.sh、src/wipe.sh、build-lib.sh、isolinux、grub.cfg、embedded、BOOTX64.EFI、xorriso。

## 验证（必须全部通过）

- **qemu A**（UEFI -vga std 有盘）：全流程（DiskWipe Tool 1.5.13、三盘、OK x3、Exited、
  日志降级）不变。
- **qemu B**（-vga none 无盘）：**改为断言无限重试**——`No wipable disks found yet
  (retry N)` 循环出现、**不出现** `rebooting`/`reboot`/`poweroff`/关机行为（qemu 收尾
  timeout 可接受）。
- **qemu C**（BIOS isolinux 有盘）：21 项回归（VERSION 1.5.13）。
- **tests t1-t6**（WSL 跑）：适配（无盘重试循环无 reboot 断言、settle wait 10）。全 PASS。
- 验证脚本留档 tmp/dw-smoke-uefi-v1513.sh / tmp/novid-v1513.sh / tmp/dw-smoke-v1513.sh。

## 提交

commit：`fix(diskwipe-iso): 去掉无盘自动 reboot（真机 reboot -f 变关机，用户未及操作即断电）+ 缩短等待至 10s；v1.5.13 重打包`

## 报告

写 `task-13-report.md`：改动 diff、构建关键行、A/B/C+tests 断言输出、commit hash。
返回：状态、commit hash、一行测试摘要、concerns。