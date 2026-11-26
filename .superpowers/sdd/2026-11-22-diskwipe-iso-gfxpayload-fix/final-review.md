# 结尾整支复查（final whole-branch review）— diskwipe-iso v1.5.1→v1.5.4（commits 7a2bbc2 + 0829353）

复查方式：只读。复核整支 diff（tmp/review-pkg-final.diff = git diff fc586cf..0829353，3 文件 +43/-22，与两个 commit 逐条核对一致）、当前工作树文件（build-lib.sh / src/init / VERSION）、验证证据输出文件抽查、并独立重跑 tests。

## 整支结论：**Approve**

无 Critical、无 Important。问题均为 Minor/提示，不阻塞合入。

## 问题清单

### Critical
无。

### Important
无。

### Minor（全部不阻塞）
1. （task-4-review 遗留）task-4-report.md 构建关键行算式「25(磁盘)」笔误——实际构成为磁盘 17（14 种子 + nvme-common/raid_class/scsi_transport_sas 3 依赖）+ 显卡 14（6 种子 + drm/drm_kms_helper/ttm/i2c-algo-bit/fb_sys_fops/syscopyarea/sysfillrect/sysimgblt 8 依赖）= 31。仅报告表述问题，实现与产物不受影响。
2. （task-4-review 遗留）tests/t3 未对显卡循环 6 次 modprobe 做正向断言（I1 仅覆盖 DRIVE_MODULES 14 模块）；「mdev 在全部 modprobe 之后」顺序断言仍成立（awk 取最后一个 modprobe 行号，显卡循环在 mdev -s 之前），实测 77 项全过。可选未来增强。
3. （本次新发现，纯 cosmetic）build-lib.sh L466 构建日志 echo 文案过时：「grub.cfg（UEFI）：文本终端 terminal_output console」——实际配置已是 `terminal_output serial console`。仅构建期打印，不影响产物，可顺手更新。
4. （已知风险提示，非缺陷）Ventoy 路径依赖 Ventoy grub core 内含 serial 模块（build-lib.sh 注释已声明该假设）。最坏情况（Ventoy core 无 serial）：`insmod serial` 失败 → 退化为 console-only（等价 v1.5.0 行为），不劣化、不引入新回归；预期情况（Ventoy 含 serial，其 grub2 为标准全量模块集）即修复生效。v1.5.4 无真机（UEFI+Ventoy+KVM VGA）复验记录，qemu OVMF 直启证据充分（同一 BOOTX64.EFI + grub.cfg 路径），建议用户发布前真机确认。

## 整支改动正确性核验（逐项）

1. **serial 兜底**（commit 7a2bbc2）：
   - grub.cfg：`insmod serial` → `serial --unit=0 --speed=115200 --word=8 --parity=no --stop=1`（GRUB 语法正确，unit 0=COM1，与内核 `console=ttyS0,115200n8` 一致）→ `terminal_output/input serial console`（serial 列前，输出双终端、输入 serial 优先）→ linux/initrd/boot 直启。Ventoy 路径（不走 embedded cfg）由 grub.cfg 自身 insmod serial 覆盖，幂等。
   - embedded-efi.cfg：insmod serial 置于 search 之前；grub-mkimage core 模块列表追加 `serial terminal`（iso 内无 serial.mod 也不依赖，core 内嵌）。
   - 语义：serial 至少提供一个可用终端 → GRUB 不再无终端卡死（盲模式打印仍出现但内核照常 boot，符合 brief「允许打印，不卡死即可」）。
2. **显卡加载循环**（commit 0829353）：`for gv in ast mgag200 smifb bochs-drm cirrus virtio-gpu; do modprobe "$gv" 2>/dev/null; done`——纯 POSIX/ash，失败静默跳过、无 `|| init_rescue`（无对应显卡无害）；位置在 DRIVE_MODULES 循环（L69-71）之后、mdev -s（L82）之前，精确符合 brief。
3. **白名单与依赖链**：DW_KYLIN_MODULES 追加 6 种子，与 kylin-src 实际模块文件逐一命中（ast/mgag200/smidrm→smifb/bochs→bochs-drm/cirrus/virtio→virtio-gpu 均为非标准命名，种子名精确匹配）；依赖由 dw_modules_kylin 按 modules.dep DFS 解析（共 31 个 .ko，task-4-review 独立模拟 + initrd 解包双重复验）。
4. **版本一致性**：VERSION=1.5.4；A 组横幅 `DiskWipe Tool 1.5.4`、C 组日志头 `version: 1.5.4`、构建自检 initrd `/diskwipe.version=1.5.4`；产物 `diskwipe-iso/output/diskwipe-v1.5.4.iso` 存在（41943040 字节 = 40M，时间戳晚于构建、先于 commit）。
5. **禁止改动清单**：git diff --stat 仅 3 文件（VERSION/build-lib.sh/src/init）；menu.sh/lib.sh/wipe.sh/isolinux.cfg 未动；isolinux.cfg 内容在 diff 中为纯上下文（无 +/-）。BIOS isolinux 路径零改动。

## 回归确认

- BIOS isolinux：无改动，C 组 21 项断言输出（dw-smoke-v154-keylines.txt）version 1.5.4 + 三盘 OK x3 完整。
- src/menu.sh / lib.sh / wipe.sh：未触碰（git diff 确认）。
- tests：本次复查独立重跑（WSL `bash diskwipe-iso/tests/run-all.sh`）→ **通过 77 项，失败 0 项，ALL PASS**，与报告/前审一致。

## 验证证据真实性抽查（全部属实）

- **A 组**（tmp/dw-smoke-uefi-v154.out.clean）：`Console: switching to colour frame buffer device 128x48`（46.7s）、`bochs-drm 0000:00:02.0: fb0: bochsdrmfb frame buffer device`（47.5s）、`[drm] Initialized bochs-drm`、`Linux version 4.19.90`、`RAMDISK:`、`Run /init`、横幅 1.5.4、三盘 SYS/DATA/UNK、`OK /dev/vda/vdb/vdc reset to uninitialized`（OK x3）、`Exited.`、`Log kept in memory: /tmp/diskwipe-log/diskwipe-20261122-153813.log`、`Cleanup log saved to USB`——全在列；`efifb` 0 命中（符合预期：显示由 bochs-drm 提供）。尾部 panic + `terminating on signal 15 (timeout)` 为既有行为（v1.5.3 同款）。
- **B 组**（tmp/novid-v154.out）：`no suitable video mode found` x2 + `Booting in blind mode`（允许打印）→ `Linux version 4.19.90`、`RAMDISK:`、`Run /init as init process`、`Only boot media found (no wipable disks...)`——内核照常启动不卡；尾部 panic 为无盘场景既有行为。显卡循环无显卡时静默失败无碍。
- **C 组**（tmp/dw-smoke-v154-keylines.txt）：version 1.5.4、3 盘、OK x3、session end 完整。

## 对 deferred minors 的 triage

- Minor #1（报告算式笔误）：**不阻塞**。纯报告表述，产物/实现经双重独立验证正确。
- Minor #2（t3 未正向断言显卡循环）：**不阻塞**。可选测试增强；现 77 项全过、顺序断言不破坏。
- 本次新增 Minor #3（构建 echo 文案过时）：**不阻塞**，cosmetic，可顺手改。
- 已知可接受行为（盲模式打印 / B 组尾部 panic / ubuntu 模式模块缺失静默）：全部有实证支撑（v1.5.3 输出同款），确认非本次引入，不阻塞。

## 结论

整支改动（v1.5.1→v1.5.4，7a2bbc2 + 0829353）正确、无越界、证据真实：serial 兜底消除盲模式卡死、initrd 显卡 DRM 驱动重建显示（A 组 fb0+Console switching 实证核心修复生效）、版本全链一致 1.5.4、BIOS/脚本/tests 无回归（77 项 ALL PASS 独立复验）。**Approve**——可合入。
