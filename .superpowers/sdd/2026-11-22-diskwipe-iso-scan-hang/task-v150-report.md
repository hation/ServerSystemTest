# diskwipe-iso v1.5.0 任务报告：引导方式重构——BIOS 改 ISOLINUX + UEFI 精简 GRUB

日期：2026-11-22　实现：subagent（自执行，未派生子代理）

## 目标与方案（已确认）

根治两个真机问题：①GRUB 视频模式盲模式卡死（grub-mkrescue GRUB 2.12 core 内嵌 gfxterm，该海光服务器无合适视频模式 → `no suitable video mode found. Booting in blind mode` 卡死）；②Ventoy grub2 mode 下 initrd 传递丢失（GRUB 打印 loading initrd 但内核未收到 initramfs）。方案：BIOS 改 ISOLINUX（syslinux 纯文本）+ UEFI 改精简 GRUB（grub-mkimage 剔除 gfxterm/video 模块）+ xorriso 手动打包。

## 实施内容（commit 0c824e4 + d10147e）

- **build-lib.sh**：
  - 第 4 步重写：rootfs 增 `isolinux/isolinux.bin` + `ldlinux.c32` + `isolinux.cfg`（DEFAULT linux / KERNEL /boot/vmlinuz / APPEND console=tty0 console=ttyS0,115200n8 initrd=/boot/initrd.img / TIMEOUT 30 / PROMPT 1）；`EFI/BOOT/BOOTX64.EFI`（grub-mkimage 精简版，模块列表 iso9660 linux normal search search_fs_file configfile part_gpt part_msdos fat ext2 boot fshelp memdisk，embedded.cfg 含 search -f /boot/grub/grub.cfg + terminal_output console）；`EFI/BOOT/efi.img`（FAT 卷封入 BOOTX64.EFI，mtools mmd/mcopy）；grub.cfg 清理诊断（去掉 echo/debug loglevel=7，保留 terminal_output console / gfxmode=text / gfxpayload=text / rdinit=/init）。
  - 第 5 步 `dw_mkrescue` → `dw_mkiso`：xorriso 手动打包（-isohybrid-mbr isohdpfx.bin + -b isolinux/isolinux.bin -c isolinux/boot.cat -no-emul-boot -boot-load-size 4 -boot-info-table + -eltorito-alt-boot -e EFI/BOOT/efi.img -no-emul-boot + -isohybrid-gpt-basdat + -R）。
  - 第 6 步 `dw_verify_iso` 适配：校验 isolinux.bin/ldlinux.c32/isolinux.cfg、BOOTX64.EFI、efi.img、grub.cfg、vmlinuz、initrd.img（-l + -x 双检）；isolinux.cfg 含 KERNEL/initrd= 双 console；grub.cfg 双 console 且无诊断残留；BOOTX64.EFI 为 PE（MZ 头）且 gfxterm 出现次数 ≤1（>1 即模块被内嵌，回归防护；video 模块随 linux.mod 依赖内嵌属预期不判失败）；initrd /init 执行位 + 版本文件校验保留。
  - apt 依赖新增 isolinux、dosfstools（ldlinux.c32 来自 syslinux-common 依赖包）。
- **build.sh**：注释更新；**VERSION**：1.5.0-diag2 → 1.5.0；**kylin-kernel-export.sh**：保留 initramfs 拷贝改动；**README.md**：v1.5.0（§1 更新日志、§2/§3 构建说明、§4/§5/§7 版本与引导说明、§10 重测指引改为 Ventoy + dd 双路径）。

## 构建与校验

- 产物：`diskwipe-iso/output/diskwipe-v1.5.0.iso`（Kylin 内核模式，37M；xorriso 报告 El Torito：BIOS→isolinux.bin（boot-info-table isohybrid-suitable）、UEFI→efi.img；MBR 为 isohdpfx 33ed 头）。
- isoinfo 校验 11 项全过（含 vmlinuz strings 4.19.90、17 个 .ko 无压缩残留）。

## 测试与冒烟

- **qemu BIOS 冒烟（必做，PASS 21/21）**：`ISOLINUX 6.04` 横幅 → `boot:` 提示 → `Loading /boot/vmlinuz... ok` → `Loading /boot/initrd.img...ok` → `Linux version 4.19.90-89.11.v2401.ky10...`（Kylin 内核）+ `RAMDISK:`（**initrd 传递确认**）→ 菜单 1.5.0 → 三盘 SYS/DATA/UNK → OK vda/vdb/vdc → Exited → Log kept in memory → Cleanup log saved to USB；无 GNU GRUB、无 ERROR、无 Only boot media；**输出零视频模式相关消息**。
- **qemu UEFI 冒烟（尽力项，OVMF 存在已测，PASS 17/17）**：`-bios /usr/share/qemu/OVMF.fd` + 精简 GRUB → 内核 + RAMDISK: + 菜单全流程 + USB 日志。**关键发现**：裸 PE 作 El Torito EFI 条目 OVMF 报 `failed to load Boot0001 ... Not Found`（不引导）→ 已改为 FAT efi.img（grub-mkrescue 标准做法），OVMF 引导成功。UEFI 路径 linux 加载器仍打印一次 `no suitable video mode found. Booting in blind mode`（video 模块随 linux.mod 依赖内嵌、gfxpayload 设置失败）——**非致命**，内核照常启动、菜单正常（与真机 v1.4.x 卡死的根因 gfxterm 模块内嵌不同）。
- **回归 t1-t6**：全部 ALL PASS（355 用例，含 t6 77 项）。

## 关键发现 / concerns

1. syslinux 6.x 需 `ldlinux.c32` 与 isolinux.bin 同目录，否则 `Failed to load ldlinux.c32`（已解决，构建校验覆盖）。
2. GRUB 2.12 无 initrd.mod（initrd 命令内建）——grub-mkimage 模块列表已不含 initrd。
3. UEFI 路径的 `no suitable video mode found` 消息无法彻底消除（linux 模块依赖 video 模块），但非致命；已写入 README §10 预期提示。
4. 真机 Ventoy 路径（问题 2 原路径）无法在 qemu 复现（qemu 无 Ventoy），§10 已列真机从 Ventoy 测（BIOS/UEFI 各一次）+ dd 直写测；**BIOS 模式经 Ventoy legacy 链最终执行 iso 内 ISOLINUX，initrd 走 syslinux 成熟路径**。
5. 遗留未提交：docs/压测报告/README.md（另一任务 test-mission-6 中途分析归档改动，与本任务无关，未纳入提交）。

## 产物

- `diskwipe-iso/output/diskwipe-v1.5.0.iso`（37M）
- 冒烟脚本与结果：`tmp/dw-smoke-v150.sh` / `tmp/dw-smoke-v150-result.txt`（BIOS）、`tmp/dw-smoke-uefi-v150.sh` / `tmp/dw-smoke-uefi-v150-result.txt`（UEFI）、`tmp/regression-v150.log`（t1-t6 全过）

## Commits

- `0c824e4` feat(diskwipe-iso): 引导方式重构——BIOS 改 ISOLINUX + UEFI 精简 GRUB，根治视频模式盲模式卡死与 initrd 传递
- `d10147e` release(diskwipe-iso): v1.5.0 重打包
