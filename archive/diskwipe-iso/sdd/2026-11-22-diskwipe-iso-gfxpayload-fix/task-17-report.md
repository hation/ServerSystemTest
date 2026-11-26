# Task 17 report — v1.5.17 恢复 usb-storage/uas（触发 SCSI 扫描带出 SAS 盘）+ 就绪后卸载防 U 盘卡死

- 状态：**DONE**
- commit：`468a737`（main，一次 commit，5 files changed, 74 insertions(+), 31 deletions(-)）
- 测试摘要：tests t1-t6 全 PASS（t3 105 项含新卸载分支断言、t4 50 项含白名单翻转断言）+ qemu A/B/C 全 PASS（含 usb-storage/uas 加载 + initrd 产物断言 + U 盘写日志成功证据）

## 改动 diff

改 5 个文件：`src/init`（白名单加回 usb-storage/uas + settle wait 后 rmmod 卸载）、`build-lib.sh`（DW_KYLIN_MODULES 白名单加回 usb-storage uas + 校验断言翻转）、`VERSION`、`tests/t3_init.sh`、`tests/t4_log.sh`。menu.sh/lib.sh/wipe.sh 未动。

### diskwipe-iso/src/init

1. **Kylin（ky10）白名单加回 usb-storage + uas**（v1.5.8/1.5.9 历史注释更新为 v1.5.17 恢复语义）：

```diff
 *ky10*)
-    # v1.5.8 去掉 uas：UAS 驱动绑定 U 盘（ASolid USB 盘）若协议响应异常会内核 D 状态
-    # 卡死（真机实证：uas 注册后 sleep 结束前的 exec 未发生）；usb-storage 已足够枚举 U 盘
-    # v1.5.9 去掉 usb-storage——真机 U 盘绑定后读盘触发内核 I/O 阻塞致系统整体停滞
-    # （>30s 无调度）；U 盘不绑定则内核不读盘、系统正常启动；USB 键盘走内建 usbhid
-    # 不受影响；退出写日志 U 盘降级留内存（既有 WARN 提示）
-    DRIVE_MODULES="ahci libahci libata nvme nvme-core mpt3sas megaraid_sas virtio_blk sd_mod nls_iso8859-1 vfat fat"
+    # v1.5.17 恢复 usb-storage + uas（文件名形态 usb-storage.ko——busybox modprobe 按
+    # modules.dep 解析，usb_storage 与 usb-storage 均能命中）——v1.5.6 唯一 sda 识别成功
+    # 的配置：usb-storage 加载触发 SCSI 总线扫描/事件带出 SAS 盘（v1.5.9 去掉后 sda 再未
+    # 出现）。v1.5.8 曾去掉 uas（UAS 绑定 ASolid U 盘协议异常 D 状态卡死）、v1.5.9 曾去掉
+    # usb-storage（U 盘绑定读盘触发内核 I/O 阻塞）——v1.5.17 以「就绪后卸载」化解
+    # （SAS 盘带出后 rmmod usb-storage uas，见 settle wait 之后；卸载失败不阻断）。
+    DRIVE_MODULES="ahci libahci libata nvme nvme-core mpt3sas megaraid_sas virtio_blk sd_mod usb-storage uas nls_iso8859-1 vfat fat"
     ;;
 esac
```

2. **settle wait（sleep 10）之后、exec menu.sh 之前加卸载分支**（busybox 核实：Ubuntu busybox-static 1.36.1 `busybox --list` 含 rmmod applet；rmmod 内部经 `filename2modname` 把 `-` 转 `_`、支持多模块参数——`rmmod usb-storage uas` 正确解析为 usb_storage/uas，故按 brief 首选 rmmod 而非 modprobe -r）：

```diff
 dw_progress "device settle wait (sleep)"
 sleep 10
 
+# v1.5.17：SAS 盘已带出（usb-storage 加载触发 SCSI 扫描），卸载 usb-storage/uas——
+# U 盘设备已绑定，退出写日志 U 盘不再需要（日志降级内存+屏幕），卸载消除 U 盘 I/O 阻塞
+# （v1.5.7/1.5.8 卡死根源；busybox rmmod 支持多模块与 '-'→'_' 模块名转换——Kylin
+# usb-storage.ko 运行时模块名为 usb_storage）。卸载失败不阻断（无 U 盘时 usb-storage
+# 仍加载、卸载亦无害）。
+rmmod usb-storage uas 2>/dev/null || true
+
 # 5) 进入交互菜单（exec 替换自身；v1.5.8 加诊断：exec 前后进度，失败兜底救援 shell）
```

mpt3sas max_queue_depth=10000 分支保持不动。POSIX/ash 兼容、中文注释、LF 行尾。

### diskwipe-iso/build-lib.sh

1. **DW_KYLIN_MODULES 白名单数组加回 usb-storage uas**（brief 要求的一处）：

```diff
-DW_KYLIN_MODULES="ahci libahci libata nvme nvme-core mpt3sas megaraid_sas virtio_blk sd_mod nls_iso8859-1 vfat fat ast"
+DW_KYLIN_MODULES="ahci libahci libata nvme nvme-core mpt3sas megaraid_sas virtio_blk sd_mod usb-storage uas nls_iso8859-1 vfat fat ast"
```

2. **dw_verify_iso 6.6 校验断言翻转（必需修正，见 Concerns #1）**：v1.5.9 的「initrd 内不应再含 usb-storage.ko」反向断言改为 v1.5.17 正向断言（usb-storage.ko + uas.ko 必须打包，否则构建校验失败、iso 无法产出）：

```diff
-        if find "$build_dir/initrdx/lib/modules" -name 'usb-storage.ko' 2>/dev/null | grep -q .; then
-            dw_fail "initrd 内不应再含 usb-storage.ko（v1.5.9 去掉，U 盘不绑定）"; return 1
-        fi
-        echo "     校验通过：initrd 内无 usb-storage.ko（v1.5.9 去掉，U 盘不绑定）"
+        for m in usb-storage uas; do
+            if ! find "$build_dir/initrdx/lib/modules" -name "$m.ko" 2>/dev/null | grep -q .; then
+                dw_fail "initrd 内缺少 Kylin 模块 $m.ko（v1.5.17 恢复 usb-storage/uas 触发 SCSI 扫描带出 SAS 盘，必须打包）"; return 1
+            fi
+        done
+        echo "     校验通过：initrd 内关键模块 usb-storage/uas 均为未压缩 .ko（v1.5.17 恢复）"
```

### diskwipe-iso/VERSION

`1.5.16` → `1.5.17`

### tests（t3_init.sh / t4_log.sh 适配）

- t3：stub 加假 rmmod（记录 `rmmod usb-storage uas`）；I1 新增 3 项断言（卸载命令出现 + 在 sleep 10 之后 + 在 exec menu.sh 之前）；I5 翻转（ky10 白名单循环加 usb-storage uas + `check_cmds modprobe usb-storage/uas` + 卸载断言，删除 v1.5.8/1.5.9 的不得加载断言）；头部注释补 v1.5.17 适配说明；
- t4：L5 源码级断言翻转——init Kylin 白名单「不得含 usb-storage」→「必须含 usb-storage」（grep 锚定 DRIVE_MODULES 赋值行）。

## 构建关键行（WSL Kylin 模式，脚本 `tmp/build-v1517.sh` = `build.sh kylin`）

- ISO：`diskwipe-iso/output/diskwipe-v1.5.17.iso`（39M）；
- Kylin 模块提取：**白名单 + 依赖链共 26 个 .ko.xz**（v1.5.16 为 24 个——新增 usb-storage/uas），全部 xz 解压为 .ko；
- isoinfo 校验全部通过，含新断言行：**`校验通过：initrd 内关键模块 usb-storage/uas 均为未压缩 .ko（v1.5.17 恢复）`**；`initrd 内 /diskwipe.version = 1.5.17`；vmlinuz 为 Kylin 4.19（strings 检出 4.19.90）；src 四脚本 dash -n 语法 0 错误；26 个模块无 .ko.zst/.ko.xz 残留；BOOTX64.EFI 精简 GRUB 无 gfxterm/video 模块。

## 验证断言输出

### tests t1-t6（WSL bash 运行，未用 Git Bash；脚本 `tmp/run-tests-v1517.sh`）

全部 **ALL PASS**：t1 89 项、t2 93 项、t3 **105 项**（+6：I1 `PASS settle wait 后应卸载 usb-storage/uas`、`PASS rmmod 卸载在 settle wait（sleep 10）之后`、`PASS rmmod 卸载在 exec menu.sh 之前`、I5 `PASS ky10 模式应加载 usb-storage`、`PASS ky10 模式应加载 uas`、`PASS ky10 模式 settle 后应卸载 usb-storage/uas`）、t4 50 项（L5 翻转断言 PASS）、t5 37 项、t6 77 项。

### qemu A（UEFI -vga std 有盘全流程，`tmp/dw-smoke-uefi-v1517.sh`，3 virtio 盘、无 USB）→ **PASS**

- 全流程不变：DiskWipe Tool 1.5.17、Disks found: 3 (vda vdb vdc)、SYS/DATA/UNK、OK x3、Exited、Log kept in memory、WARN: could not write log to USB（**A 无 USB → 日志降级留内存**）、无 Cleanup log saved to USB、无 ERROR、无 Only boot media、rescan 静默、显卡循环只留 ast；
- **v1.5.17 恢复断言**：`PASS diskwipe-init: loading module usb-storage` + `PASS diskwipe-init: loading module uas`（v1.5.9-16 反向断言翻转）；
- **[3b] 产物断言**：`PASS initrd/init 含卸载分支（rmmod usb-storage uas 2>/dev/null || true）`（grep 显示上下文行）、`PASS initrd/init Kylin 白名单含 usb-storage uas`、`PASS initrd/init mpt3sas 分支保持（max_queue_depth=10000，v1.5.16 保留）`、`PASS initrd 含 usb-storage.ko（Kylin 文件名形态，未压缩）`、`PASS initrd 含 uas.ko（未压缩）`。

### qemu B（-vga none 无盘，`tmp/novid-v1517.sh`）→ **PASS**

- 无盘无限重试：`No wipable disks found yet (retry 1/11…)` 4 条（≤6，read -t 5 真实等待降噪生效）、retry 编号 N%10==1、kmsg `no disks, retry N (never auto poweroff/reboot)`、无任何旧自动重启字符串、qemu exit=124（timeout 收尾，menu 永不退出）、RAW lsblk/RAW enum 诊断行、rescan 静默；
- **翻转断言**：`PASS usb-storage 加载（v1.5.17 恢复…）` + `PASS uas 加载（v1.5.17 恢复）`；
- [3c] 产物断言同 A：rmmod 卸载分支 + 白名单 + usb-storage.ko/uas.ko 均 PASS。

### qemu C（BIOS ISOLINUX 有盘 21 项回归 + USB stick，`tmp/dw-smoke-v1517.sh`）→ **PASS**

- 21 项关键行全 PASS（ISOLINUX 6.04 → Loading vmlinuz/initrd → Linux 4.19.90 → RAMDISK → diskwipe-init 进度链 → **DiskWipe Tool 1.5.17** → 三盘 SYS/DATA/UNK → OK x3 → Exited）+ `loading module usb-storage`/`uas` PASS + 无 GNU GRUB、无 ERROR、无 Only boot media、无 No writable log media、rescan 静默；
- **U 盘写日志成功（v1.5.17 恢复的端到端证据）**：`PASS Cleanup log saved to USB` + `PASS no WARN: could not write log to USB`（qemu USB stick 经 usb-storage 绑定为 sda（TRAN=usb，menu 枚举排除、仍 3 盘），退出时 dw_save_log_to_usb 写日志到 DWLOGTEST 数据分区成功）+ **[5] 节**：`PASS U 盘数据区日志文件存在（v1.5.17 usb-storage 恢复 → 退出写日志成功）`（losetup 挂载 USB 镜像实测 diskwipe-*.log 存在）；
- [3b] 产物断言同 A/B 全 PASS。

## 提交

- `git log -1`：`468a737 fix(diskwipe-iso): 恢复 usb-storage/uas（v1.5.6 唯一 sda 识别成功配置：usb-storage 加载触发 SCSI 扫描带出 SAS 盘）+ 就绪后卸载防 U 盘卡死；v1.5.17 重打包`
- 仅含 diskwipe-iso/src/init、diskwipe-iso/build-lib.sh、diskwipe-iso/VERSION、diskwipe-iso/tests/t3_init.sh、diskwipe-iso/tests/t4_log.sh（5 files, +74/-31）；output/（iso）与 kylin-src/ 均 gitignore 不入库，与历史一致。

## Concerns

1. **build-lib.sh 改动超出「白名单一处」**：brief 的 dw_verify_iso 6.6 仍保留 v1.5.9 的「initrd 不应含 usb-storage.ko」反向断言——若只改白名单，构建校验必失败（usb-storage.ko 已打包）、iso 无法产出，与「initrd 必须含 usb-storage.ko/uas.ko」的新要求直接冲突。已将 6.6 反向断言改为正向断言（这是构建通过的必需修正，属本任务唯一追加的 build-lib.sh 改动，其余零改动）。
2. **卸载方式核实**：busybox-static 1.36.1 `--list` 含 rmmod；rmmod 源码（modutils/rmmod.c）用 `filename2modname` 把 `-`→`_` 并支持多模块参数——`rmmod usb-storage uas` 正确命中 usb_storage/uas（Kylin usb-storage.ko 运行时模块名 usb_storage），故按 brief 首选 rmmod；`|| true` 兜底卸载失败不阻断。
3. **真机 U 盘绑定场景**：U 盘（启动介质）绑定后 rmmod usb-storage 会因模块被设备占用（EBUSY）卸载失败（静默容忍）——qemu A（无 USB）已验证卸载路径，qemu C（带 USB）验证的是 U 盘绑定 + 退出写日志成功的恢复路径；**usb-storage 触发 mpt3sas 带出 SAS 盘的真机疗效只能由真机验证**（与 brief 注一致，用户执行）。
4. **验证脚本留档**：`tmp/dw-smoke-uefi-v1517.sh`（A）、`tmp/novid-v1517.sh`（B）、`tmp/dw-smoke-v1517.sh`（C）、`tmp/build-v1517.sh`、`tmp/run-tests-v1517.sh`、`tmp/chk-v1517-kylin-src.sh`；运行日志 `tmp/run-a/b/c-v1517.log`、`tmp/build-v1517.log`（tmp/ 未跟踪，与 v1516 一致不入库）。
