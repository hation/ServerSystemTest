# Task 9 report — v1.5.9 去掉 usb-storage（U 盘不绑定，根治设备枚举系统级卡死）

## 状态：DONE

commit：`d7da880`（main，5 files changed, 40 insertions(+), 11 deletions(-)）
```
fix(diskwipe-iso): 去掉 usb-storage（U 盘绑定读盘触发内核 I/O 阻塞致系统整体停滞，USB 键盘走内建 usbhid 不受影响）；v1.5.9 重打包
```

## 改动 diff

### 1. `diskwipe-iso/src/init`（POSIX/ash、中文注释）

- Kylin `case *ky10*` 分支 `DRIVE_MODULES` 去掉 `usb-storage`（新增 v1.5.9 注释：真机 U 盘
  绑定后读盘触发内核 I/O 阻塞致系统整体停滞（>30s 无调度）；U 盘不绑定则内核不读盘、
  系统正常启动；USB 键盘走内建 usbhid 不受影响；退出写日志 U 盘降级留内存（既有 WARN
  提示））。Ubuntu 分支（`usb_storage uas` 保留）与 top 注释不变。
- 新白名单：`ahci libahci libata nvme nvme-core mpt3sas megaraid_sas virtio_blk sd_mod
  nls_iso8859-1 vfat fat`（vfat/fat 保留——与构建侧白名单一致，加载无害）。

### 2. `diskwipe-iso/build-lib.sh`

- `DW_KYLIN_MODULES` 去掉 `usb-storage`（注释同上；initrd 不再打包）；新白名单：
  `ahci libahci libata nvme nvme-core mpt3sas megaraid_sas virtio_blk sd_mod
  nls_iso8859-1 vfat fat ast`。
- `dw_verify_iso` 6.6 Kylin 校验适配：关键模块检查 `ahci usb-storage nvme` → `ahci nvme`，
  新增反向断言「initrd 内无 usb-storage.ko（v1.5.9 去掉，U 盘不绑定）」（回归防护）。

### 3. `diskwipe-iso/VERSION`：`1.5.8` → `1.5.9`

### 4. tests 适配（禁止改 menu.sh/lib.sh/wipe.sh 未动）

- `t3_init.sh`：I5 用例 ky10 白名单循环去掉 `usb-storage`、新增
  `check_not_cmds 'modprobe usb-storage'`（v1.5.9 负断言）；用例名/注释同步。
- `t4_log.sh`：L5 新增源码级断言「src/init Kylin 白名单无 usb-storage（grep 锚定
  DRIVE_MODULES 赋值行，注释提及不算）」；L1 注释标注无 U 盘降级路径即 v1.5.9 常态
  （Log kept in memory + WARN: could not write log to USB）。

## 构建关键行（WSL Kylin 模式）

产物：`diskwipe-iso/output/diskwipe-v1.5.9.iso`（39M，output/ 已 gitignore 不入库）
- `内核模式：kylin`；`使用内核：4.19.90-89.11.v2401.ky10.x86_64`
- `Kylin 模块提取：白名单 + 依赖链共 24 个 .ko.xz`（v1.5.8 为 25——**usb-storage 去掉后
  少 1 个**）
- `VERSION → /diskwipe.version（1.5.9）`；initrd.img 5.0M
- isoinfo 校验全部通过：`initrd 内 /diskwipe.version = 1.5.9`、`src 四脚本 dash -n 语法
  0 错误`、24 个未压缩 .ko、Kylin 4.19 版本串、双 console、BOOTX64.EFI PE 有效、
  **`initrd 内无 usb-storage.ko（v1.5.9 去掉，U 盘不绑定）`**
- 构建入口：Git Bash 的 `wsl`（无扩展名）PATH 解析失败，用 `tmp/build-v159.sh`
  （wsl.exe 完整路径 + `DW_KERNEL_MODE=kylin`）等价执行 build.sh 内逻辑。

## 验证断言输出

### A（qemu UEFI -vga std，tmp/dw-smoke-uefi-v159.sh）→ PASS（34 断言全过）
- **运行期模块清单已无 usb-storage**：`loading module` 序列 = ahci libahci libata nvme
  nvme-core mpt3sas megaraid_sas virtio_blk sd_mod nls_iso8859-1 vfat fat（ky10 白名单）
- 全流程：Linux version 4.19.90 / RAMDISK: / DiskWipe Tool 1.5.9 / 三盘 SYS-DATA-UNK /
  OK x3 / Exited. / **Log kept in memory** / **WARN: could not write log to USB** /
  **无 Cleanup log saved to USB**（降级断言）
- v1.5.8 诊断/镜像回归：exec menu.sh / menu.sh argv0 / menu.sh started / 横幅/盘列表行/
  Exited. kmsg 镜像全出现；无 ERROR / 无 Only boot media
- **[5] 降级实证**：U 盘数据区（DWLOGTEST vfat）**无 diskwipe-*.log**（usb-storage 未加载
  → U 盘未绑定 → 日志留内存 `Log kept in memory: /tmp/diskwipe-log/diskwipe-*.log`）

### B（qemu UEFI -vga none，tmp/novid-v159.sh）→ PASS
- serial 兜底：Booting in blind mode 打印（允许）但内核照常启动（Linux version 4.19.90 /
  RAMDISK: / Run /init）
- kmsg 进度行：loading module / Disk driver modules loaded / Device nodes scanned /
  device settle wait (sleep) / menu.sh started / exec menu.sh / menu.sh argv0 全出现
- **无 usb-storage 加载（v1.5.9）**断言 PASS；界面 kmsg 镜像（Only boot media found +
  横幅行）经 serial 可见
- 尾部「Attempted to kill init」panic 为无盘路径既有无盘退出语义（同 v1.5.8，非本次引入）

### C（qemu BIOS isolinux，tmp/dw-smoke-v159.sh）→ 34 断言全 PASS（21 项回归 + 13 项新增/降级）
- ISOLINUX 6.04 / Loading /boot/vmlinuz... ok / Loading /boot/initrd.img...ok /
  Linux version 4.19.90 / RAMDISK: / 1.5.9 横幅 / Scanning / Disks found 3 /
  SYS×DATA×UNK / OK x3 / Exited / Log kept in memory / **WARN: could not write log to USB**
  / **无 Cleanup log saved to USB** / no GNU GRUB / no ERROR / no Only boot media /
  no No writable log media
- v1.5.8 镜像回归全出现（exec menu.sh / menu.sh argv0 / Default: all selected / 表头 /
  Exited.）；**[5] 降级实证**：U 盘数据区无日志文件

### tests t1-t6 回归（Git Bash，bash diskwipe-iso/tests/run-all.sh）→ 全部 ALL PASS
- t1 89 项、t2 68 项、t3 92 项（I5 新增 usb-storage 负断言）、t4 50 项（L5 新增 Kylin
  白名单断言）、t5 37 项、t6 77 项 —— 全量 413 项，0 失败。

验证脚本留档：`tmp/dw-smoke-uefi-v159.sh`、`tmp/novid-v159.sh`、`tmp/dw-smoke-v159.sh`
（输出：`tmp/dw-smoke-uefi-v159.out(.clean)`、`tmp/novid-v159.out`、`tmp/dw-smoke-v159.out(.clean)`、
`tmp/build-v159.sh`）。

## 一行测试摘要

qemu A（UEFI -vga std 34 项）、B（-vga none serial 全诊断）、C（BIOS 34 项）+ tests t1-t6（413 项）全部 PASS；iso 已重打包 v1.5.9（模块 25→24，运行期无 usb-storage，日志降级留内存）。

## concerns

1. **真机验证前提**：本改动为根治方案，qemu 无法复现真机「U 盘绑定读盘 → 内核 I/O 阻塞 →
   系统整体停滞」现象（qemu 的虚拟 U 盘无此问题），qemu A/B/C 仅能证明 U 盘不再被绑定
   （运行期无 usb-storage、盘数 3、降级路径生效）。真机最终确认仍需现场用 Ventoy U 盘
   （ASolid USB 59GB）验证启动不再停滞。
2. **日志无法落 U 盘**：v1.5.9 起 U 盘不绑定为存储设备，退出写日志恒走降级路径（WARN +
   Log kept in memory，提示抄录后断电）——清盘功能完整、日志留内存可抄录，属 brief 明确
   接受的代价；menu.sh/lib.sh 的 dw_save_log_to_usb 逻辑未改（若未来恢复加载 usb-storage，
   写日志能力自动回来）。
3. **vfat/fat 仍打包**：Kylin 白名单保留 vfat/fat（与 init 白名单一致，加载无害；
   modules.builtin 中 usbhid/hid 为内建，USB 键盘不受影响）。
4. **行尾**：与 task-6/7/8 一致——仓库 core.autocrlf=true，工作副本 CRLF/提交内容 LF，
   保持基线风格；busybox ash（A/B/C 全流程）与 Git Bash 测试均正常。
