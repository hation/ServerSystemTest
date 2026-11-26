# Task 6 report — v1.5.6 显卡循环只留 ast + 进度改 /dev/kmsg

## 状态：DONE

commit：`3f70526`（main，4 files changed, 71 insertions(+), 41 deletions(-)）
```
fix(diskwipe-iso): 显卡循环只留 ast（真机 AST2500，其余显卡驱动无硬件时 D 状态挂起致卡死）+ 进度改 /dev/kmsg；v1.5.6 重打包
```

## 改动 diff

### 1. `diskwipe-iso/src/init`（POSIX/ash、行尾与基线一致、中文注释）

- 头部（PATH 设置后）新增：
  ```sh
  # v1.5.6：进度走 /dev/kmsg（内核 printk 通道）——与内核日志混排，真机 KVM 屏幕
  # 最后几行可见（普通 echo 到 /dev/console 在 fbcon 切换前的输出被丢弃/滚动覆盖）。
  dw_progress() { echo "diskwipe-init: $*" > /dev/kmsg 2>/dev/null; }
  ```
- 磁盘模块循环：`echo "loading module $im"` → `dw_progress "loading module $im"`；
  `echo "Disk driver modules loaded"` → `dw_progress "Disk driver modules loaded"`（timeout 5 + WARN 继续不变）。
- 显卡循环：`for gv in ast mgag200 ...` 删除，只保留：
  ```sh
  # v1.5.6：显卡循环只加载 ast（真机 AST2500）。mgag200/smifb/bochs-drm/cirrus/
  # virtio-gpu 在无对应硬件时 modprobe 可能内核 D 状态挂起（用户态 timeout 无效），
  # 导致 init 卡死（真机实证 sdb 枚举后无输出）；需要时按机器单独加入白名单。
  dw_progress "loading video module ast"
  timeout 5 modprobe ast 2>/dev/null
  ```
- mdev：`echo "device scan (mdev -s)"` / `echo "Device nodes scanned"` → 对应 `dw_progress` 行。
- 头注释 v1.5.5 语义 → v1.5.6 语义（kmsg 进度 + timeout 兜底）。

### 2. `diskwipe-iso/build-lib.sh`

- `DW_KYLIN_MODULES` 移除 mgag200 smifb bochs-drm cirrus virtio-gpu，只留 `ast`；注释改为
  v1.5.6 原因说明（与 init 注释一致）。initrd 不再打包这 5 个显卡驱动（构建体积减小、init 无法加载它们）。

### 3. `diskwipe-iso/VERSION`

- `1.5.5` → `1.5.6`。

### 4. `diskwipe-iso/tests/t3_init.sh`（t1-t6 中唯一涉及 init 的测试）

- kmsg 进度断言方式：Git Bash 的 /dev 为 MSYS 虚拟只读目录，无法创建 /dev/kmsg 假件
  （写失败静默——恰是生产「写失败不中断启动」语义）；改用 `bash -x` + `BASH_XTRACEFD=3`
  把 xtrace 分流到 `$ROOT/xtrace.txt`，正向断言 dw_progress 调用与 kmsg 载荷
  （`+ echo 'diskwipe-init: ...'` / `+ dw_progress '...'`）；stdout 保持纯 console 输出
  （断言进度不再打 console、WARN/ERROR 语义不变）。
- 新增断言：kmsg 载荷 6 类（loading module / Disk driver modules loaded / loading video
  module ast / device scan / Device nodes scanned）；显卡循环 `modprobe ast` 在、
  mgag200/smifb/bochs-drm/cirrus/virtio-gpu 不在（check_not_cmds）；stdout 不含
  `diskwipe-init:`。
- 运行：`bash diskwipe-iso/tests/run-all.sh`（Git Bash）→ t1-t6 全部 ALL PASS（t3 67 项）。

## 构建关键行（WSL Kylin 模式，`bash diskwipe-iso/build.sh kylin`）

产物：`diskwipe-iso/output/diskwipe-v1.5.6.iso`（39M）
- `内核模式：kylin`；`使用内核：4.19.90-89.11.v2401.ky10.x86_64`
- `Kylin 模块提取：白名单 + 依赖链共 26 个 .ko.xz`（v1.5.5 为 31 个——5 个显卡驱动及其依赖链已剔除）
- `VERSION → /diskwipe.version（1.5.6）`；`initrd.img：5.0M`
- isoinfo 校验全部通过（含 initrd 内 `/diskwipe.version = 1.5.6`、dash -n 语法 0 错误、
  26 个未压缩 .ko、Kylin 4.19 版本串）
- 解包实检：`lib/modules/*/kernel/drivers/gpu/drm/` 只剩 `ast`（+ 依赖链 drm/drm_kms_helper/ttm），
  无 mgag200/bochs/cirrus/virtio-gpu；init 含 6 处 dw_progress。

## 验证断言输出

### A（qemu UEFI -vga std，tmp/dw-smoke-uefi-v156.sh）→ PASS
- kmsg 进度行全部出现（serial 输出带内核时间戳）：
  `[37.28s] diskwipe-init: loading module ahci` … `diskwipe-init: loading video module ast`
  … `diskwipe-init: Disk driver modules loaded` / `Device nodes scanned`
- 显卡循环无 mgag200/smifb/bochs-drm/cirrus/virtio-gpu（PASS no non-ast video module）
- 全流程：Linux version 4.19.90 / RAMDISK: / DiskWipe Tool 1.5.6 / 三盘 SYS-DATA-UNK /
  OK x3 / Exited. / Log kept in memory / Cleanup log saved to USB（USB 日志 version 1.5.6）
- 无 ERROR / 无 Only boot media

### B（qemu UEFI -vga none，tmp/novid-v156.sh）→ PASS
- serial 兜底：Booting in blind mode 打印（允许）但内核照常启动
- Linux version 4.19.90 / RAMDISK: / Run /init / 菜单横幅
- kmsg 进度行：diskwipe-init: loading module / Disk driver modules loaded / Device nodes scanned 全出现

### C（qemu BIOS isolinux，tmp/dw-smoke-v156.sh）→ 21 项全 PASS
- ISOLINUX 6.04 / Loading /boot/vmlinuz... ok / Loading /boot/initrd.img...ok /
  Linux version 4.19.90 / RAMDISK: / diskwipe-init: loading module / 1.5.6 横幅 /
  Scanning / Disks found 3 / SYS×DATA×UNK / OK x3 / Exited / Log kept in memory /
  Cleanup log saved to USB / no GNU GRUB / no ERROR / no Only boot media / no No writable log media

### tests t1-t6 回归（Git Bash）→ 全部 ALL PASS（t3 67 项、其余同基线）

验证脚本留档：`tmp/dw-smoke-uefi-v156.sh`、`tmp/novid-v156.sh`、`tmp/dw-smoke-v156.sh`
（输出：`tmp/dw-smoke-uefi-v156.out(.clean)`、`tmp/novid-v156.out`、`tmp/dw-smoke-v156.out(.clean)`、
`tmp/dw-smoke-v156-keylines.txt`、`tmp/build-v156.log`、`tmp/runall-v156.log`）。

## concerns

1. **qemu A 不再出现 fb0 / Console: switching**（brief 原文列了这两项断言，已适配为 INFO 不判失败）：
   v1.5.5 的 fb0 来自 bochs-drm（qemu std VGA 是 bochs 兼容）；v1.5.6 显卡种子只留 ast，
   qemu 无 ast 硬件 → 无 fbcon（dummy console 保持），efifb 亦未出现（既有行为）。
   真机 AST2500 由 ast 提供 fbcon（v1.5.5 真机实证显示正常），不受影响。已把 A 脚本中
   fb0/Console switching 改为 INFO 记录并在报告中说明——如需 qemu 显示断言，可后续单独
   `-vga std` + 按机型加 bochs-drm 白名单，但违背「只留 ast」的修复本意，不建议。
2. **行尾**：仓库基线（HEAD d14b9b7）各文件即为 CRLF（core.autocrlf=true），本次保持与
   基线一致未改行尾；busybox ash（initramfs 实测 A/B/C 全流程）与 Git Bash 测试均正常。
   若要求严格 LF，需另开任务统一转行尾（会引入全文件 diff）。
3. **t3 的 kmsg 断言方式**：Git Bash 无法创建 /dev/kmsg 假件，用 `bash -x`+BASH_XTRACEFD
   断言 dw_progress 调用与载荷（等价满足 brief「断言 dw_progress 调用」选项）；真实
   /dev/kmsg 写路径由 qemu A/B/C 端到端验证（kmsg → printk → serial console 出现）。
