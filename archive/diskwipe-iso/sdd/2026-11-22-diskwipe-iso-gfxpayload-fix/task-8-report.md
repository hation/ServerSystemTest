# Task 8 report — v1.5.8 去掉 uas + exec/menu 启动 kmsg 诊断 + 菜单界面输出 kmsg 双通道

## 状态：DONE

commit：`7b66568`（main，8 files changed, 122 insertions(+), 19 deletions(-)）
```
fix(diskwipe-iso): 去掉 uas（UAS 绑定 U 盘可能 D 状态卡死）+ exec/menu 启动 kmsg 诊断 + 菜单界面输出 kmsg 双通道；v1.5.8 重打包
```

## 改动 diff

### 1. `diskwipe-iso/build-lib.sh`（POSIX/ash、中文注释）

- `DW_KYLIN_MODULES` 去掉 `uas`（新增 v1.5.8 注释：UAS 绑定 U 盘（ASolid USB 盘）若协议
  响应异常会内核 D 状态卡死；usb-storage 已足够枚举 U 盘）；`DW_MODULES`（Ubuntu 模式）不变。
- 依赖链注释同步去掉 `uas→usb-storage`（白名单与 dw_modules_kylin 两处）。

### 2. `diskwipe-iso/src/init`

- Kylin `case *ky10*` 分支 `DRIVE_MODULES` 去掉 `uas`（注释同上）；Ubuntu 分支不变。
- exec 段（原 105-106 行）按 brief 原文改为带诊断 + 失败兜底：
  ```sh
  # 5) 进入交互菜单（exec 替换自身；v1.5.8 加诊断：exec 前后进度，失败兜底救援 shell）
  dw_progress "exec menu.sh"
  exec "$(dirname "$0")/menu.sh" || {
      dw_progress "exec menu.sh FAILED"
      dw_progress "argv0=$0 dirname=$(dirname "$0")"
      exec sh
  }
  ```

### 3. `diskwipe-iso/src/menu.sh`（只加诊断/镜像，交互逻辑零改动）

- 头部（`. lib.sh` **之前**）新增 argv0 诊断（不依赖 lib.sh）：
  `echo "diskwipe-init: menu.sh argv0=$0" > /dev/kmsg 2>/dev/null`
- 界面关键输出加 kmsg 镜像（`echo` 到 console + `dw_progress` 镜像到 kmsg）：
  横幅 `====` 行、盘列表表头/分隔线、盘列表行（`printf` 后镜像同行内容）、
  `Default: all selected` / `0 = exit` 提示、`> ` 输入提示（两处）、`Exited.` 行。
- 每盘结果行（OK/FAIL，来自 wipe.sh，wipe.sh 禁改）经「`if/else` 块整体管道进
  `while IFS= read` 逐行读改写」镜像到 kmsg（屏幕顺序不变，SIGPIPE 风险同基线）。
- dw_log 已覆盖的行（DiskWipe Tool 横幅、Type YES 提示、确认清单、Only boot media、
  日志文件头/尾等）保持原样——lib.sh 改造后 dw_log 自动镜像 kmsg。

### 4. `diskwipe-iso/src/lib.sh`

- `dw_log` 首行加 kmsg 镜像：`echo "diskwipe-init: $1" > /dev/kmsg 2>/dev/null`
  （LOG_DEGRADED 兜底、timeout 2 tee 逻辑全部保留；接口注释同步）。

### 5. `diskwipe-iso/VERSION`：`1.5.7` → `1.5.8`

### 6. tests 适配

- `t3_init.sh`：新增 I5（假 uname 走 *ky10* 分支：uas 不得加载、usb-storage/vfat/fat 等
  ky10 清单加载、exec 正常）；I1 新增 `check_kmsg 'diskwipe-init: exec menu.sh'`；
  I6 改为断言 POSIX exec 语义真实行为（exec 失败 shell 以 126 退出、exec 前诊断行已先打、
  未进菜单）。
- `t2_menu.sh`：新增 M10（`bash -x`+BASH_XTRACEFD 分流 xtrace，正向断言 argv0 诊断 +
  提示/盘列表行/Exited 的 kmsg 镜像载荷）。
- `t4_log.sh`：L6 改 `bash -x` 捕获 xtrace，新增 `dw_log 应镜像到 kmsg（第一/二行）` 断言。

## 构建关键行（WSL Kylin 模式）

产物：`diskwipe-iso/output/diskwipe-v1.5.8.iso`（39M，output/ 已 gitignore 不入库）
- `内核模式：kylin`；`使用内核：4.19.90-89.11.v2401.ky10.x86_64`
- `Kylin 模块提取：白名单 + 依赖链共 25 个 .ko.xz`（v1.5.7 为 26——**uas 去掉后少 1 个**）
- `VERSION → /diskwipe.version（1.5.8）`；`initrd.img` 解包复核：`uas` 无匹配文件、
  `usb-storage.ko` 在、`menu.sh` argv0 行（25 行）与 `lib.sh` dw_log kmsg 行（406 行）在。
- isoinfo 校验全部通过：`initrd 内 /diskwipe.version = 1.5.8`、`src 四脚本 dash -n 语法
  0 错误`、25 个未压缩 .ko、Kylin 4.19 版本串、双 console、BOOTX64.EFI PE 有效。
- 首次构建被 WSL `unattended-upgrade` 持 dpkg 锁中断 → kill 该进程 + 清锁后重跑成功。

## 验证断言输出

### A（qemu UEFI -vga std，tmp/dw-smoke-uefi-v158.sh）→ PASS（33 断言全过）
- **运行期模块清单已无 uas**：`loading module` 序列 = ahci libahci libata nvme nvme-core
  mpt3sas megaraid_sas virtio_blk sd_mod **usb-storage** nls_iso8859-1 vfat fat（ky10 白名单）
- v1.5.8 新增 kmsg 诊断行全部出现：`exec menu.sh`（32.5s）→ `menu.sh argv0=//menu.sh` →
  `menu.sh started`；界面 kmsg 镜像：横幅（`DiskWipe Tool 1.5.8` / `====`）、盘列表表头/行、
  `Default: all selected`、`Exited. You may power off`
- 全流程：Linux version 4.19.90 / RAMDISK: / DiskWipe Tool 1.5.8 / 三盘 SYS-DATA-UNK /
  OK x3 / Exited. / Log kept in memory / Cleanup log saved to USB（USB 日志 version 1.5.8）
- 无 ERROR / 无 Only boot media；显卡循环无非 ast 驱动

### B（qemu UEFI -vga none，tmp/novid-v158.sh）→ PASS
- serial 兜底：Booting in blind mode 打印（允许）但内核照常启动（Linux version 4.19.90 /
  RAMDISK: / Run /init）
- kmsg 进度行：loading module / Disk driver modules loaded / Device nodes scanned /
  device settle wait (sleep) / menu.sh started / **exec menu.sh** / **menu.sh argv0** 全出现
- **界面 kmsg 镜像经 serial 可见**：`Only boot media found` + 横幅行（dw_log→kmsg→printk→serial）
- 尾部「Attempted to kill init」panic 为无盘路径既有无盘退出语义（同 v1.5.7，非本次引入）

### C（qemu BIOS isolinux，tmp/dw-smoke-v158.sh）→ 33 断言全 PASS（21 项回归 + 12 项新增）
- ISOLINUX 6.04 / Loading /boot/vmlinuz... ok / Loading /boot/initrd.img...ok /
  Linux version 4.19.90 / RAMDISK: / 1.5.8 横幅 / Scanning / Disks found 3 /
  SYS×DATA×UNK / OK x3 / Exited / Log kept in memory / Cleanup log saved to USB /
  no GNU GRUB / no ERROR / no Only boot media / no No writable log media
- v1.5.8 新增：exec menu.sh / menu.sh argv0 / `Default: all selected` / 盘列表表头 /
  Exited. 镜像全出现；USB 数据区日志落盘成功（version 1.5.8）

### tests t1-t6 回归（Git Bash，bash diskwipe-iso/tests/run-all.sh）→ 全部 ALL PASS
- t1 89 项、t2 68 项（含 M10 kmsg 双通道）、t3 91 项（含 I5 ky10 去 uas、I6 exec 失败）、
  t4 49 项（含 L6 dw_log kmsg 镜像）、t5 37 项、t6 77 项 —— 全量 411 项，0 失败。

验证脚本留档：`tmp/dw-smoke-uefi-v158.sh`、`tmp/novid-v158.sh`、`tmp/dw-smoke-v158.sh`
（输出：`tmp/dw-smoke-uefi-v158.out(.clean)`、`tmp/novid-v158.out`、`tmp/dw-smoke-v158.out(.clean)`、
`tmp/dw-smoke-v158-keylines.txt`、`tmp/build-v158.sh`、`tmp/build-v158.log`、`tmp/runall-v158.log`、
`tmp/chk-v158-initrd.sh`）。

## 一行测试摘要

qemu A（UEFI -vga std 33 项）、B（-vga none serial 全诊断）、C（BIOS 33 项）+ tests t1-t6（411 项）全部 PASS；iso 已重打包 v1.5.8（模块 26→25，运行期无 uas）。

## concerns

1. **brief 的 `exec ... || {}` 失败兜底在 POSIX shell 中不可达**：实证（WSL dash / busybox ash
   1.36.1 / bash 一致）exec 失败 → shell 立即以 126/127 退出，`|| {}` 分支永不执行
   （busybox ash 与 initramfs 的 busybox-static 同版本）。源码按 brief 原文保留该兜底
   （防御性，无副作用）；真正生效的诊断是 exec **前**的 `dw_progress "exec menu.sh"` 行
   （真机卡在 exec 前或启动时即由该行定位）。t3 I6 用例已按真实语义改写并注释说明。
2. **qemu B 尾部内核 panic「Attempted to kill init!」**：无盘场景 menu 退出 → PID 1 退出 →
   panic，与 v1.5.7 既有无盘路径语义一致（非本次引入），novid 断言只看内核启动/init 流程/
   kmsg 诊断，判定 PASS。
3. **构建入口**：Git Bash 的 `wsl`（无扩展名）PATH 解析失败，用 `tmp/build-v158.sh`
   （wsl.exe 完整路径 + WSL 路径显式传参）等价执行 build.sh 内逻辑；首次构建被 WSL
   `unattended-upgrade` 持 dpkg 锁中断，kill 该进程 + 清锁后重跑成功（不影响构建脚本本身）。
4. **行尾**：与 task-6/7 一致——仓库 core.autocrlf=true，工作副本 CRLF/提交内容 LF，本次
   保持基线风格未改；busybox ash（A/B/C 全流程）与 Git Bash 测试均正常。
5. **界面镜像的行量与噪音**：menu 每轮循环镜像 ~10 行到 kmsg（横幅/表头/行/提示/Exited），
   与内核日志混排、serial 可见；真机定位时 kmsg 行带时间戳可对应阶段，属 brief 要求的
   「双通道保证可读可操作」，非过度输出。
