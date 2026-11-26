# Task 3 brief — v1.5.3 serial 终端兜底（消除 GRUB 盲模式卡死）

## 背景

真机（UEFI + Ventoy + KVM VGA）用 v1.5.1/v1.5.2 均报 `error: no suitable video mode
found. Booting in blind mode` 后黑屏卡死。根因：GRUB video 框架模块（linux.mod 依赖
自动带入，无法剔除）在 normal init 时必然初始化失败 → 报错 → **盲模式**（真机 ConOut
无可用文本终端，Ventoy 路径下 GRUB 无任何终端）→ 盲模式下执行停住，内核未启动。
直启版（v1.5.2，已删 menuentry）仍卡死 → 卡死点不是菜单渲染。

**正解**：给 GRUB 加 **serial 终端兜底**。盲模式 = 无任何可用终端；GRUB 有 serial
模块（UEFI SerialIO / COM1），真机服务器一般有 COM 口。加 serial 后 GRUB 至少有一个
可用终端 → 不进入盲模式 → 正常执行 grub.cfg → 内核启动（内核 efifb 经 GOP 显示，
Kylin 内核 CONFIG_FB_EFI=y；真机 Ubuntu 内核时代显示正常证明 GOP 可用）。

## 任务（精确，基于当前工作树——build-lib.sh 已是 v1.5.2 直启版、VERSION 待改）

1. `diskwipe-iso/build-lib.sh` 4.3 段 `embedded-efi.cfg`（grub-mkimage 的 -c 参数）：
   在现有 `search/prefix/terminal_output console/terminal_input console/configfile`
   基础上增加 serial 终端（顺序：先 insmod serial，再初始化，再设双终端）：
   ```
   insmod serial
   search --no-floppy --set=root -f /boot/grub/grub.cfg
   set prefix=(\$root)/boot/grub
   serial --unit=0 --speed=115200 --word=8 --parity=no --stop=1
   terminal_output serial console
   terminal_input serial console
   configfile /boot/grub/grub.cfg
   ```
2. `diskwipe-iso/build-lib.sh` 4.1 段 `grub.cfg`：在直启版（v1.5.2 现状）基础上，
   顶部同样加 serial 终端（兼容 Ventoy grub 执行本 cfg 的场景——Ventoy grub 也有
   serial 模块），保留直启 `linux/initrd/boot`：
   ```
   # v1.5.3 UEFI 直启 + serial 终端兜底（消除盲模式卡死；无 gfxterm/video/gfxpayload）
   insmod serial
   serial --unit=0 --speed=115200 --word=8 --parity=no --stop=1
   terminal_output serial console
   terminal_input serial console
   linux /boot/vmlinuz console=tty0 console=ttyS0,115200n8 rdinit=/init
   initrd /boot/initrd.img
   boot
   ```
3. `diskwipe-iso/build-lib.sh` 4.3 段 `grub-mkimage` 模块列表：追加 `serial terminal`
   （BOOTX64.EFI 需要 serial 模块；terminal 模块一般随 normal 依赖已有，缺则加）。
4. `diskwipe-iso/VERSION`：`1.5.2`（若当前为 1.5.1 则先改 1.5.2 再改 1.5.3）→ 最终 `1.5.3`。
5. 重新构建（WSL Kylin 模式）：`output/diskwipe-v1.5.3.iso`。

## 禁止改动

- `src/{init,menu.sh,lib.sh,wipe.sh}`、isolinux.cfg、isolinux 引导项、xorriso 打包逻辑。

## qemu 验证（必须全部通过）

### A. UEFI 有视频（-vga std）：显示 + 全流程
参考 `tmp/dw-smoke-uefi-v150.sh`（FIFO 喂键）。serial 断言：`efifb:`、
`Console: switching to colour frame buffer`、`Linux version 4.19.90`、`RAMDISK:`、
`DiskWipe Tool 1.5.3`、三盘 SYS/DATA/UNK、OK x3、`Exited.`、`Cleanup log saved to USB`。

### B. UEFI 无视频（-vga none）：serial 终端兜底生效（核心新断言）
参考 `tmp/novid-repro.sh`（-vga none + OVMF + serial）：
- **不应出现** `Booting in blind mode`（serial 终端存在 → 不盲模式）；`no suitable
  video mode found` 允许出现（video 框架初始化失败的 error 本身无法消除）。
- **必须** serial 出现 `Linux version 4.19.90` + `RAMDISK:` + init 流程
  （`Run /init`、`Only boot media found` 或菜单横幅）→ 盲模式卡死被消除、内核照常启动。

### C. BIOS isolinux 回归
参考 `tmp/dw-smoke-v150.sh`（VERSION 断言改 1.5.3）。必须全部通过。

## 提交

commit（一次，包含 Task 1 gfxpayload + Task 2 直启 + 本次 serial 的全部改动）：
`fix(diskwipe-iso): UEFI 加 serial 终端兜底消除盲模式卡死 + grub.cfg 直启 + 删 gfxpayload=text（内核跳过 efifb）；v1.5.3 重打包`

## 报告

写 `task-3-report.md`：改动 diff、构建关键行、A/B/C 验证断言输出、commit hash。
返回：状态、commit hash、一行测试摘要、concerns。
