# Task 10 report — v1.5.10 等设备就绪加长（sleep 10）+ 无盘自动重试/reboot（避免 PID1 退出 panic）

## 状态：DONE

commit：`f3e100e`（main，5 files changed, 65 insertions(+), 17 deletions(-)）
```
fix(diskwipe-iso): 等设备就绪加长（SAS 盘扫描数秒）+ 无盘自动重试/reboot（避免 PID1 退出 panic）；v1.5.10 重打包
```

## 改动 diff

### 1. `diskwipe-iso/src/init`（POSIX/ash、中文注释、LF）

- 步骤 4「设备稳定等待」`sleep 3` → `sleep 10`（新增 v1.5.10 注释：真机 mpt3sas 14.47s
  才加载、SAS 盘扫描需数秒，menu 枚举前需就绪；U 盘已不绑定，等待期间无 I/O 阻塞风险）。
- top 注释同步：`→ sleep 10 等待设备稳定（v1.5.7：去掉重试 mdev 轮询；v1.5.10 加长——…）`。

### 2. `diskwipe-iso/src/menu.sh`（仅无盘路径，交互逻辑其余零改动）

- `while :` 前新增 `dwnoretry=0`（v1.5.10 无盘重试计数）。
- 无盘路径（原 `echo + dw_log + dw_log_finish + exit 0`）改为重试 + reboot（brief 精确代码）：
  - `dwnoretry` ≤ 3：`dw_log "Only boot media found (no wipable disks yet; retrying in 5s...)"`
    + `dw_progress "no disks, retry $dwnoretry/3 (sleep 5)"` + `sleep 5` + `continue`；
  - 3 轮后仍无盘：`dw_log "No wipable disks found after 3 retries."` / `"You may power off
    or reboot safely."` + `dw_progress "no disks after retries, rebooting in 10s"` +
    `sleep 10` + `reboot`（busybox reboot——initrd `bin/reboot -> busybox`）。
  - 注释：重试避免 sda（mpt3sas SAS）迟就绪误判；最终 reboot 回 Ventoy 而非 exit 导致
    PID1 退出内核 panic。头注释/枚举段注释同步（交互契约其余不变）。

### 3. `diskwipe-iso/VERSION`：`1.5.9` → `1.5.10`

### 4. tests 适配（lib.sh/wipe.sh/build-lib.sh/isolinux/grub.cfg/embedded 零改动）

- `t3_init.sh`：stub 加假 `sleep`（记录调用到 cmds.txt 并立即返回——同假 timeout 既有
  模式，不真等 10s）；I1 新增 `check_cmds 'sleep 10'`（settle wait 应等待 10s）；头注释
  与 v1.5.10 适配说明同步。
- `t2_menu.sh`：M6 用例重写——假 `reboot`（记录调用、绝不真重启测试机）+ 假 `sleep`；
  断言：`Only boot media found`（首轮重试消息）/ `No wipable disks found after 3 retries` /
  `sleep 5` ×3 / `sleep 10` ×1 / `reboot` 被调用 / 无 wipefs / 无 umount（原 `check_no_cmds`
  因 sleep/reboot 已记入 cmds.txt 改为定向负断言）；头注释/用例清单同步。

## 构建关键行（WSL Kylin 模式）

产物：`diskwipe-iso/output/diskwipe-v1.5.10.iso`（39M；output/ 已 gitignore 不入库）
- 构建入口：PowerShell 侧 wsl.exe 引号转义易碎，改用 WSL 侧脚本
  `tmp/build-v1510.sh`（wsl.exe 完整路径 + `DW_KERNEL_MODE=kylin`，等价 build.sh kylin）。
- `内核模式：kylin`；`使用内核：4.19.90-89.11.v2401.ky10.x86_64`；`busybox applet 链接数：272`
- isoinfo 校验全部通过（含 v1.5.9 保留项：`initrd 内无 usb-storage.ko`）。
- 产物自检（tmp/chk-v1510-initrd.sh，从 ISO 提取 initrd）：`bin/reboot -> busybox` ✓、
  init `sleep 10`（113 行）✓、menu `dwnoretry`/`rebooting in 10s`/`retrying in 5s` ✓、
  `/diskwipe.version = 1.5.10` ✓、busybox `--list` 含 `reboot` ✓。
- dash -n / busybox ash -n 语法检查通过。

## 验证断言输出

### A（qemu UEFI -vga std，tmp/dw-smoke-uefi-v1510.sh）→ 35 断言全 PASS
- 全流程：Linux version 4.19.90 / RAMDISK: / **DiskWipe Tool 1.5.10** / 三盘 SYS-DATA-UNK
  （vda/vdb/vdc）/ OK x3 / Exited. / Log kept in memory / **WARN: could not write log to
  USB**（降级）/ **无 Cleanup log saved to USB**；kmsg 全诊断（exec menu.sh / menu.sh
  argv0 / menu.sh started / 横幅/盘列表/Exited. 镜像）回归；无 ERROR / 无 Only boot media。
- [5] 降级实证：U 盘数据区无 diskwipe-*.log。

### B（qemu UEFI -vga none，tmp/novid-v1510.sh）→ PASS（brief §B 断言适配）
- serial 兜底：内核照常启动（Linux version / RAMDISK: / kmsg 全进度行）；无 usb-storage 加载。
- **v1.5.10 核心断言全过**：`Only boot media found (no wipable disks yet; retrying in 5s...)`
  + `no disks, retry 1/3..3/3` + 最终 `no disks after retries, rebooting in 10s`；
- **不再出现 v1.5.9 的 `Kernel panic - not syncing: Attempted to kill init!`**（v159 尾部
  panic 实证复现过该问题，v1510 已消除）。

### C（qemu BIOS isolinux，tmp/dw-smoke-v1510.sh）→ 35 断言全 PASS
- ISOLINUX 6.04 / Loading vmlinuz+initrd ok / Linux version 4.19.90 / RAMDISK: /
  1.5.10 横幅 / 三盘 SYS-DATA-UNK / OK x3 / Exited / 日志降级（WARN + Log kept in memory、
  无 Cleanup log saved to USB）/ no GNU GRUB / no ERROR / no Only boot media。

### tests t1-t6 回归（WSL 跑，bash diskwipe-iso/tests/run-all.sh）→ 全部 ALL PASS
- t1 89 项、t2 73 项（M6 重试/reboot 8 断言）、t3 92 项（I1 含 sleep 10 断言）、t4 50 项、
  t5 37 项、t6 77 项 —— 全量 418 项，0 失败。

验证脚本留档：`tmp/dw-smoke-uefi-v1510.sh`、`tmp/novid-v1510.sh`、`tmp/dw-smoke-v1510.sh`
（输出 `tmp/dw-smoke-uefi-v1510.out(.clean)`、`tmp/novid-v1510.out`、`tmp/dw-smoke-v1510.out(.clean)`、
`tmp/build-v1510.sh`、`tmp/chk-v1510-initrd.sh`；另两个受控实验脚本留档
`tmp/dbg-sleep-reboot.sh` / `tmp/dbg2-sleep-pid1.sh`）。

## 一行测试摘要

qemu A（UEFI 35 项）、B（-vga none 无盘→重试→rebooting in 10s、panic 消除）、C（BIOS 35 项）+ tests t1-t6（418 项）全部 PASS；iso 已重打包 v1.5.10（init settle wait sleep 10、无盘重试 3 轮后 reboot）。

## concerns

1. **qemu TCG 环境两处工件（均有受控实验证据，不影响真机）**：
   - `reboot(2)` 在 qemu TCG 下返回 0 但不真正重启（`tmp/dbg2-sleep-pid1.sh` 直启内核实验
     实证），且返回后内核部分关机路径已拆 /sys —— 故 B 尾部 menu 会越过无盘块继续枚举并
     出现幻影盘 `Disks found: 1 ()`（lsblk 读损坏的 /sys 所致）。真机上 busybox reboot 为
     initramfs 标准机制（syscall 成功即重启、失败则 syscall 未启动关机、系统健康，不会出现
     该状态）；brief 已预告「qemu 内 reboot 会触发重启，timeout 收尾可接受」，本环境仅
     timeout 收尾。
   - sleep 在 ISO 全链路引导下 printk 间隔仅 ~0.28s（v1.5.9 的 sleep 3 同样只 0.17s，既有
     现象非本次引入）；但直启内核受控实验证明 busybox sleep 精确生效（sleep 2→+2.02s、
     sleep 5→+5.01s、sleep 10→+10.01s）——TCG 定时器/时钟模拟工件，真机时钟正常。
2. **真机验证前提**：v1.5.10 针对真机 mpt3sas SAS 盘迟就绪设计（sleep 10 + 重试 3 轮），
   qemu 无法复现 SAS 扫描延迟，最终确认仍需现场（海光服务器 + Ventoy U 盘）验证内部盘
   sda 在 menu 首轮枚举即就绪、无盘时自动 reboot 回 Ventoy 不 panic。
3. **无盘 fallthrough 兜底语义**：`reboot` 为无盘块末语句（brief 精确代码，无 exit 兜底）——
   真机 reboot 成功则流程终止；若极端情况下 reboot 失败，menu 会继续到正常列盘流程（健康
   系统，无部分关机），属可接受的降级，不 panic。
4. **行尾**：与 task-6/7/8/9 一致——仓库 core.autocrlf=true，提交内容 LF（已用
   `git show <commit>:src/menu.sh | grep -c $'\r'` = 0 验证）；busybox ash（A/B/C 全流程）
   与 WSL bash 测试均正常。
