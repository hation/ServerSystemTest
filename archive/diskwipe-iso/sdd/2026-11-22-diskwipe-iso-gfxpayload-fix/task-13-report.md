# Task 13 报告 — v1.5.13 去掉无盘自动关机/重启（安全第一）+ 缩短等待

- 状态：**DONE**
- commit：`8d6a538`（`fix(diskwipe-iso): 去掉无盘自动 reboot（真机 reboot -f 变关机，用户未及操作即断电）+ 缩短等待至 10s；v1.5.13 重打包`，基于 HEAD=4c22a7f，一次 commit，5 文件 +137/-73）
- 产物：`diskwipe-iso/output/diskwipe-v1.5.13.iso`（40894464 字节，WSL Kylin 模式）

## 1. 改动（diff 摘要）

### `diskwipe-iso/src/menu.sh`（只改无盘路径，交互逻辑其余零改动）
删除 v1.5.12 无盘路径的 `sleep 10` + `reboot -f` + `sleep 2` + fallthrough（`reboot ineffective, re-enumerating`），改为无限重试：

```sh
if [ -z "$ml" ]; then
    # v1.5.13：无盘无限重试——每 5 秒重枚举，盘就绪即正常；绝不自动关机/重启
    # （安全第一：真机 reboot -f 执行成关机，用户还没看到菜单就被断电；宁可一直
    # 等待、用户可随时断电）。dwnoretry 仅作日志计数（...v1.5.13 起废弃
    # reboot/sleep 10/fallthrough）。重试消息经 dw_log/dw_progress 双通道。
    dwnoretry=$((dwnoretry + 1))
    dw_log "No wipable disks found yet (retry $dwnoretry). Retrying every 5s... (you may power off anytime)"
    dw_progress "no disks, retry $dwnoretry (sleep 5, never auto poweroff/reboot)"
    sleep 5
    continue
fi
```

同步更新头部硬约束注释、`dwnoretry` 初始化注释、while 循环注释（v1.5.13 语义）。POSIX/ash、LF 行尾、中文注释。

### `diskwipe-iso/src/init`
settle wait `sleep 25` → `sleep 10`（v1.5.13：等待缩短——SAS 盘扫描数秒即可，盘是否就绪由 menu 持续重试兜底）；注释更新。

### `diskwipe-iso/VERSION`
`1.5.12` → `1.5.13`。

### `diskwipe-iso/tests/t2_menu.sh`（适配无盘重试）
- M6 用例重写：假 lsblk 计数切换（前 3 次枚举返回无盘表、之后返回就绪盘表 → 盘出现即正常列盘）；断言：`No wipable disks found yet (retry 1/3)` 出现、`sleep 5` 恰 3 次、**绝不 `sleep 10`/`sleep 2`/`reboot`**（假 reboot 保留但断言未调用）、盘就绪后正常列盘、0 退出、无 wipe/umount。
- 头部注释同步 v1.5.13 语义。

### `diskwipe-iso/tests/t3_init.sh`（适配 settle wait 10）
I1 断言 `sleep 25` → `sleep 10`；注释同步。

### 未改动
lib.sh / wipe.sh / build-lib.sh / isolinux / grub.cfg / embedded / BOOTX64.EFI / xorriso——零触碰。枚举失败（ERROR）路径保持原样。

## 2. 构建关键行（WSL Kylin 模式）

`tmp/build-v1513.sh`（等价 `build.sh kylin`）→ `export DW_KERNEL_MODE=kylin; . build-lib.sh; dw_build_iso`：
- 产物 `output/diskwipe-v1.5.13.iso`（40894464 B，与 v1.5.12 相同体积）
- iso 内 init 中 `sleep 10` 生效、menu.sh 无盘无限重试段生效（qemu 实证见下）

## 3. 验证

### qemu A（UEFI -vga std 有盘全流程）— PASS
`tmp/dw-smoke-uefi-v1513.sh`：三盘 `Disks found: 3 (vda vdb vdc)`、`/dev/vda .*SYS` `/dev/vdb .*DATA` `/dev/vdc .*UNK`、`OK /dev/vda|vdb|vdc reset to uninitialized` ×3、`Exited. You may power off or reboot after done.`、`Log kept in memory:`、`WARN: could not write log to USB`（v1.5.9 降级）、`DiskWipe Tool 1.5.13`、kmsg 双通道全断言 PASS、`no Cleanup log saved to USB`、`no ERROR line`、`no Only boot media`。
注：v1.5.13 修正——usb-kbd 偶发 `usb usb1-port2: couldn't allocate usb_device`（v1.5.12 C 注释记载的同类 xhci 资源问题）致 sendkey 丢失，A 脚本去掉 usb-kbd 改 i8042 PS/2 注入（UEFI 模式 PS/2 存在，v1.5.12 C 已验证）。

### qemu B（-vga none 无盘：无限重试 + 无 reboot/关机）— PASS
`tmp/novid-v1513.sh`：
- `No wipable disks found yet (retry N)` 循环出现（150s 内 **retry 1→170**，无限重试）
- kmsg 进度行 `no disks, retry N (sleep 5, never auto poweroff/reboot)` 出现（明确标注永不自动关机/重启）
- **不出现**：`rebooting in 10s` / `reboot -f` / `reboot ineffective` / `no disks after retries` / `No wipable disks found after 6 retries`（全部 PASS）
- `RAW enum ml=[]`（无盘轮次枚举原文为空，v1.5.12 诊断保留）
- **qemu exit=124**（timeout 150 收尾）——menu 无盘永不退出；若 v1.5.12 行为残留（reboot -f 生效 → qemu 重启 → -no-reboot 提前退出）会非 124，现为 124 = 无自动重启铁证
- `you may power off anytime` 用户可随时断电提示出现

### qemu C（BIOS isolinux 有盘）— PASS
`tmp/dw-smoke-v1513.sh`：ISOLINUX 6.04 横幅、`Loading /boot/vmlinuz... ok`、`initrd.img...ok`、`Linux version 4.19.90`、`RAMDISK:`、`DiskWipe Tool 1.5.13`、三盘 SYS/DATA/UNK、OK ×3、Exited、日志降级 WARN、kmsg 双通道、HID 进度行、`no GNU GRUB`、`no ERROR`、`no Only boot media`、U 盘数据区无日志——21 项关键行全 PASS。

### tests t1-t6（WSL 跑，非 Git Bash）— ALL PASS
`wsl -e bash -c 'cd .../diskwipe-iso && bash tests/run-all.sh'`：**通过 77 项，失败 0 项，全部 ALL PASS**。
- M6 新断言：`无限重试 3 轮（每轮 sleep 5；盘第 4 轮枚举就绪）`、`绝不 sleep 10`、`绝无 fallthrough 的 sleep 2`、`绝不 reboot / reboot -f` 全 PASS
- I1 新断言：`settle wait 应等待 10s（v1.5.13 缩短）` PASS

## 4. 留档
`tmp/dw-smoke-uefi-v1513.sh`、`tmp/novid-v1513.sh`、`tmp/dw-smoke-v1513.sh`、`tmp/build-v1513.sh`（tmp 不提交，与 v1.5.12 惯例一致）。

## 5. Concerns
- qemu 环境 `sleep 5` 实际每轮约 1.5s（v1.5.12 的 B 输出同此现象，非 v1.5.13 引入，疑 qemu/Kylin 虚拟时钟特性）；真机 busybox sleep 为标准 5 秒，不影响行为正确性。
- README.md 148/179 行仍描述旧文案 `Only boot media found`（v1.5.10 起行为已变，属既有过时文档，超出本任务范围未改）。
- 无盘时 menu 无限重试、PID1（menu）永不退出——这是任务明确要求的安全行为（用户可随时断电）；qemu 验证用 timeout 收尾。
