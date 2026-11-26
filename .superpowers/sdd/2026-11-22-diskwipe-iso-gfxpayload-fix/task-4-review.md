# Task 4 审查报告 — v1.5.4 initrd 加载显卡 DRM 驱动（commit 0829353，BASE 7a2bbc2）

审查方式：只读 + 独立复验。复核了 diff（3 文件 +15/-2，与 commit 0829353 完全一致）、kylin-src 实际模块文件、modules.dep 依赖链、initrd 产物内容、A/B/C 验证输出文件、并重跑 tests（WSL 实测 77 项 ALL PASS）。

## Spec 合规：✅

| brief 改动项 | 结果 |
|---|---|
| build-lib.sh DW_KYLIN_MODULES 追加 `ast mgag200 smifb bochs-drm cirrus virtio-gpu` | ✅ 精确匹配，另加注释说明用途（v1.5.4 UEFI 显示） |
| src/init 在 DRIVE_MODULES 循环（约 69-71 行）之后、mdev -s 之前加显卡循环 | ✅ 实测位于 74-79 行，位置精确 |
| 循环 POSIX/ash 兼容、失败静默不 rescue | ✅ `for gv in ...; do modprobe "$gv" 2>/dev/null; done`，无 `|| init_rescue` |
| VERSION 1.5.3 → 1.5.4 | ✅ |
| 产物 diskwipe-v1.5.4.iso | ✅ 存在于 diskwipe-iso/output/（40M，41943040 字节） |
| 禁止改动清单（menu.sh/lib.sh/wipe.sh/isolinux.cfg/grub.cfg 直启/embedded/BOOTX64.EFI/xorriso） | ✅ commit 仅 3 文件，未触碰任何禁止项 |

## 问题列表

### Critical
无。

### Important
无。

### Minor
1. **报告构建关键行算式表述有歧义**（非实现缺陷）：报告写「白名单 + 依赖链共 31 个 .ko.xz ← 25(磁盘) + 6(显卡种子) + drm/ttm/... 等依赖自动解析」。独立模拟 dw_modules_kylin 的 awk DFS（用同款算法 + 同 kylin-src modules.dep）实测：20/20 种子命中，总数 **31** 与报告一致；但构成是磁盘 17（14 种子 + nvme-common/raid_class/scsi_transport_sas 3 依赖）+ 显卡 14（6 种子 + drm/drm_kms_helper/ttm/i2c-algo-bit/fb_sys_fops/syscopyarea/sysfillrect/sysimgblt 8 依赖）。“25(磁盘)”无出处，属报告笔误，不影响实现与产物。
2. **t3 假件测试未正向断言显卡循环**（brief 允许，非缺陷）：I1 的 `for m in $DRIVE_MODULES; check_cmds "modprobe $m"` 仅覆盖 14 个磁盘模块；显卡 6 次 modprobe 调用进入 cmds.txt 但无断言（也不破坏「mdev 在全部 modprobe 之后」顺序断言，实测通过）。可选改进：未来为显卡循环加 6 条正向断言。

## 报告证据复核（全部真实存在）

- **A 组**（tmp/dw-smoke-uefi-v154.out.clean）：`fbcon: bochsdrmfb (fb0) is primary device`（46s）、`Console: switching to colour frame buffer device 128x48`（46s）、`bochs-drm 0000:00:02.0: fb0: bochsdrmfb frame buffer device`、`Linux version 4.19.90`、`RAMDISK:`、`DiskWipe Tool 1.5.4`、三盘 SYS/DATA/UNK、`OK x3`、`Exited.`、`Cleanup log saved to USB` 全部在列；efifb 未出现（符合预期）。尾部 `Kernel panic`（menu 退出→PID1 退出）+ 脚本 `timeout 180` 杀 qemu——concern 3 属实，且 v1.5.3 输出（dw-smoke-uefi-v153.out）同款 panic + `terminating on signal 15 (timeout)`，确认是既有行为；v153 A 输出 fb0/colour/efifb 均无，对比成立。
- **B 组**（tmp/novid-v154.out）：`no suitable video mode found` + `Booting in blind mode`（INFO）、`Linux version 4.19.90`、`RAMDISK:`、`Run /init as init process`、`Only boot media found` 全部在列，内核照常启动不卡；尾部 `Kernel panic - not syncing: Attempted to kill init!` 属实（无盘场景既有行为，concern 2 合理）。
- **C 组**（tmp/dw-smoke-v154-keylines.txt）：version 1.5.4、三盘、OK x3 完整。
- **tests**：WSL 实测 `bash diskwipe-iso/tests/run-all.sh` →「通过 77 项，失败 0 项 / 全部测试: ALL PASS」，与报告一致。
- **产物独立复验**（xorriso 提取 /boot/initrd.img 解包）：`diskwipe.version = 1.5.4`；lib/modules 下 **31 个 .ko、0 个 .ko.xz/.ko.zst 残留**；显卡 6 种子（ast/mgag200/smifb/bochs-drm/cirrus/virtio-gpu）+ 8 依赖（drm/drm_kms_helper/ttm/i2c-algo-bit/fb_sys_fops/syscopyarea/sysfillrect/sysimgblt）全在；modules.dep 已 sed 改 .ko 后缀且无 `.ko.xz` 残留引用（busybox modprobe 可按路径加载）。

## 代码质量要点（独立验证）

- **模块名正确性**：与 kylin-src 实际 .ko.xz 逐一比对——`ast.ko.xz`、`mgag200.ko.xz`、`smidrm/smifb.ko.xz`、`bochs/bochs-drm.ko.xz`、`cirrus.ko.xz`、`virtio/virtio-gpu.ko.xz` 全部存在（Kylin 对 bochs/virtio-gpu 采用非标准连字符命名，种子名与之精确匹配，find 全命中 20/20）。
- **依赖链自动解析**：modules.dep 中 6 个显卡种子均声明 ttm/drm_kms_helper/drm + fb_sys_fops/syscopyarea/sysfillrect/sysimgblt，i2c-algo-bit 为 ast/mgag200 额外依赖；dw_modules_kylin 的 awk DFS 正确提取（模拟 + initrd 实测双重确认）。
- **busybox modprobe 实载**：A 组 fb0 出现证明 `modprobe bochs-drm` + modules.dep 依赖自动加载整条链路真实生效。
- **注释准确性**：build-lib.sh 与 src/init 注释准确描述根因（efifb 依赖 GRUB framebuffer → 真机 GRUB 视频初始化失败 → 无 framebuffer → 显卡驱动自探测重建显示）与失败无害语义。

## 报告 concerns 评估（均合理）

1. blind mode 打印：属实（A/B 输出均含，v1.5.3 同），brief 明确允许打印，断言已按 INFO 处理。✅
2. B 组尾部 panic：属实（novid-v154.out 实证），无盘场景 menu stdin EOF 退出→PID1 退出→panic，qemu 测试环境既有行为，非本次引入。✅
3. A 组 timeout 杀 qemu：属实（v153/v154 输出均实证），非新问题。✅
4. ubuntu 模式 6 模块可能缺失：合理；显卡循环对两模式无条件执行（brief 允许），缺失时 `2>/dev/null` 静默跳过，无害。✅

## ⚠️ 无法从 diff 验证（均已用替代方式确认）

1. A 组 USB 日志实际落盘文件内容（/mnt/dwlogxuefi154/...，qemu 镜像已删）——但 A 组输出含 `Log kept in memory` + `Cleanup log saved to USB`，且报告引用文件名与 .out.clean 一致，判定可信。
2. 报告「构建关键行」原始构建日志无 v154 留档——已通过独立模拟依赖解析 + initrd 解包实测双重验证等价结论。
3. novid-v154.sh 脚本断言细节未逐行读——其输出文件已直接确认 brief B 组全部关键行为（内核启动、init 流程到达、显卡循环无碍）。

## 结论：**Approved**

实现精确符合 brief（3 文件 +15/-2，无越界），模块名/依赖链/产物内容经独立复验全部正确，A/B/C + tests 证据真实，concerns 均有实证支撑。Minor 项仅为报告表述瑕疵与可选测试覆盖增强，不阻塞合入。
