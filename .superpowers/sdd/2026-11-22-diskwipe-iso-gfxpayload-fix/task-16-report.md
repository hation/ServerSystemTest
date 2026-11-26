# Task 16 report — v1.5.16 mpt3sas max_queue_depth=10000

- 状态：**DONE**
- commit：`ec74487`（main，一次 commit，3 files changed, 29 insertions(+), 7 deletions(-)）
- 测试摘要：tests t1-t6 全 PASS（t3 99 项含新 mpt3sas 分支断言）+ qemu A/B/C 全 PASS（含 mpt3sas 分支产物/内核日志断言）

## 改动 diff

仅改 3 个文件（src/init mpt3sas 加载分支 + VERSION + tests/t3_init.sh 适配；menu.sh/lib.sh/wipe.sh/build-lib.sh 等均未动）：

### diskwipe-iso/src/init（白名单驱动加载循环，mpt3sas 单独分支）

```diff
 for im in $DRIVE_MODULES; do
     dw_progress "loading module $im"
-    timeout 5 modprobe "$im" 2>/dev/null || echo "WARN: module $im load failed/timed out"
+    # v1.5.16 修复：mpt3sas 默认 max_queue_depth=32455，高核数服务器（海光）+ initramfs
+    # 内存受限时内核无法分配大队列内存 → scsih_probe 失败 → 控制器不初始化、盘不识别
+    # （Fedora/Broadcom 已知问题）。传 max_queue_depth=10000 降低内存需求（官方方案）。
+    if [ "$im" = "mpt3sas" ]; then
+        timeout 5 modprobe mpt3sas max_queue_depth=10000 2>/dev/null || echo "WARN: module mpt3sas load failed/timed out"
+    else
+        timeout 5 modprobe "$im" 2>/dev/null || echo "WARN: module $im load failed/timed out"
+    fi
 done
```

循环结构保持（timeout 5 + WARN 继续语义不变），仅 mpt3sas 传 `max_queue_depth=10000`；POSIX/ash 兼容、中文注释。

### diskwipe-iso/VERSION

`1.5.15` → `1.5.16`

### diskwipe-iso/tests/t3_init.sh（适配 mpt3sas 分支断言）

- 假 modprobe 改为记录完整参数（`$1` → `$*`）——断言 mpt3sas 分支参数形态需要；
- I1：DRIVE_MODULES 循环中 mpt3sas 特殊断言 `modprobe mpt3sas max_queue_depth=10000`（整行）+ 新增 xtrace 载荷断言（`bash -x` 分流 xtrace.txt 显示参数）；
- I2（mpt3sas 加载失败）：`check_cmds 'modprobe mpt3sas'` → `'modprobe mpt3sas max_queue_depth=10000'`（失败形态同样带参数；假 modprobe 仍按 $1 判失败命中）；
- I5（ky10）：ky10 白名单循环中 mpt3sas 同断言（分支在 ky10 清单同样生效）；
- 头部注释补 v1.5.16 适配说明。

## 构建关键行（WSL Kylin 模式）

脚本 `tmp/build-v1516.sh`（等价 `build.sh kylin`，DW_KERNEL_MODE=kylin）→ `dw_build_iso`：

- ISO：`diskwipe-iso/output/diskwipe-v1.5.16.iso`（39M）
- isoinfo 校验全部通过：`initrd 内 /diskwipe.version = 1.5.16`、vmlinuz 为 Kylin 4.19（strings 检出 4.19.90）、src 四脚本 dash -n 语法 0 错误、initrd 内 24 个模块全部未压缩 .ko、无 usb-storage.ko、双 console 参数、BOOTX64.EFI 精简 GRUB 无 gfxterm/video 模块

## 验证断言输出

### tests t1-t6（WSL bash 运行，未用 Git Bash）

`tests/run-all.sh` → **全部 ALL PASS**：t1 89 项、t2 93 项、t3 99 项（含新增：
`PASS mpt3sas 应带 max_queue_depth=10000 加载（v1.5.16 修复…）`、`PASS xtrace 载荷显示 mpt3sas 分支带 max_queue_depth=10000`、
I2 `PASS 应尝试加载失败模块（mpt3sas 分支带 max_queue_depth=10000…）`、I5 ky10 `PASS ky10 模式 mpt3sas 应带 max_queue_depth=10000 加载`）、
t4 50 项、t5 37 项、t6 77 项。

### qemu A（UEFI -vga std 有盘全流程，`tmp/dw-smoke-uefi-v1516.sh`）→ **PASS**

- 全流程不变：DiskWipe Tool 1.5.16、Disks found: 3 (vda vdb vdc)、/dev/vda SYS / vdb DATA / vdc UNK、OK x3、Exited、Log kept in memory、WARN: could not write log to USB、无 Cleanup log saved to USB、无 ERROR、无 Only boot media、rescan 静默（无 scsi_host 输出）、显卡循环只留 ast；
- **mpt3sas 分支断言（[3b]）**：
  - `PASS initrd/init 含 mpt3sas 分支（modprobe mpt3sas max_queue_depth=10000）`——isoinfo 解包 initrd + cpio，grep 显示分支上下文（xtrace 显示参数形态）：
    ```
    92-    if [ "$im" = "mpt3sas" ]; then
    93:        timeout 5 modprobe mpt3sas max_queue_depth=10000 2>/dev/null || echo "WARN: module mpt3sas load failed/timed out"
    ```
  - `PASS init 循环结构保持（mpt3sas 独立分支 + 其余模块正常 modprobe）`
  - `PASS 内核日志 mpt3sas version ... loaded`（`mpt3sas version 27.100.00.00 loaded`——分支实际执行、驱动加载成功；qemu 无 mpt3sas 硬件，virtio 盘流程不变）

### qemu B（-vga none 无盘，`tmp/novid-v1516.sh`）→ **PASS**

- 无盘无限重试：`No wipable disks found yet (retry 1/11…)` 4 条（≤6，read -t 5 真实等待降噪生效）、retry 编号 N%10==1、kmsg `no disks, retry N (never auto poweroff/reboot)`；
- 无旧自动重启字符串（rebooting in 10s / reboot -f / reboot ineffective / no disks after retries 均无）；
- qemu exit=124（timeout 收尾，menu 永不退出）；RAW lsblk/RAW enum 诊断行出现；rescan 静默；
- [3c] mpt3sas 分支断言：`PASS initrd/init 含 mpt3sas 分支` + `PASS 内核日志 mpt3sas version ... loaded`（无盘场景分支同样执行）。

### qemu C（BIOS ISOLINUX 有盘 21 项回归，`tmp/dw-smoke-v1516.sh`）→ **PASS**

- 21 项关键行全 PASS（ISOLINUX 6.04 → Loading vmlinuz/initrd → Linux 4.19.90 → RAMDISK → diskwipe-init 进度链 → DiskWipe Tool 1.5.16 → 三盘 SYS/DATA/UNK → OK x3 → Exited → 日志降级）+ 无 GNU GRUB、无 ERROR、无 Only boot media、无 No writable log media、rescan 静默；
- [3b] mpt3sas 分支断言：`PASS initrd/init 含 mpt3sas 分支` + `PASS 内核日志 mpt3sas version ... loaded`（BIOS 路径分支同样执行）。

## 提交

- `git log -1`：`ec74487 fix(diskwipe-iso): mpt3sas 加载传 max_queue_depth=10000（Fedora/Broadcom 已知问题：默认 32455 高核数服务器内存分配失败致 scsih_probe 失败、盘不识别）；v1.5.16 重打包`
- 仅含 diskwipe-iso/src/init、diskwipe-iso/VERSION、diskwipe-iso/tests/t3_init.sh（3 files, +29/-7）

## Concerns

- qemu 三盘为 virtio、无 mpt3sas 硬件：分支断言基于构建产物（initrd/init 解包 grep 参数形态）+ 内核日志 `mpt3sas version loaded`（证明分支执行、驱动加载成功）；**max_queue_depth 对 scsih_probe 的实际疗效只能由真机（海光高核数服务器）验证**——与 brief 注一致，真机验证由用户执行。
- `modprobe mpt3sas max_queue_depth=10000` 是模块参数，busybox modprobe 支持透传；Kylin 4.19 mpt3sas 27.100.00.00 模块参数名与 Fedora/Broadcom 方案一致（该参数为 mpt3sas 驱动标准 module_param）。
- 验证脚本留档：`tmp/dw-smoke-uefi-v1516.sh`（A）、`tmp/novid-v1516.sh`（B）、`tmp/dw-smoke-v1516.sh`（C）、`tmp/build-v1516.sh`、运行日志 `tmp/run-a/b/c-v1516.log`、构建日志 `tmp/build-v1516.log`。
