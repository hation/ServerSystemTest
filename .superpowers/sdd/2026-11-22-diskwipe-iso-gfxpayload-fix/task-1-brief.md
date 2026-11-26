# Task 1 brief — 修复 gfxpayload 黑屏 + 构建 v1.5.1 + 双路径验证

## 任务目标

修复真机（UEFI + Ventoy 默认模式 + KVM VGA）黑屏：UEFI 精简 GRUB 的 grub.cfg 中
`set gfxpayload=text` 使内核跳过 EFI framebuffer（efifb），UEFI 下无 int10h VGA text
→ tty0 无输出 → 黑屏。删除该行后内核将自行经 EFI GOP 初始化 efifb → fbcon → 显示。

## 必改文件（精确）

1. `diskwipe-iso/build-lib.sh` 4.1 段（`cat > "$rootfs/boot/grub/grub.cfg"` 的 here-doc，
   约 386-399 行）：删除 `set gfxpayload=text` 一行。
   - 保留 `set gfxmode=text`（无 gfxterm 模块时不生效，无副作用）。
   - 保留 `set timeout=3`/`set default=0`/menuentry/linux 行（linux 行的
     `console=tty0 console=ttyS0,115200n8 rdinit=/init` 不动）。
2. `diskwipe-iso/VERSION`：`1.5.0` → `1.5.1`。

## 禁止改动

- `diskwipe-iso/src/{init,menu.sh,lib.sh,wipe.sh}` 一律不动。
- grub.cfg 其余内容、isolinux.cfg、BOOTX64.EFI 打包逻辑不动。

## 构建（WSL，Kylin 内核模式）

- 构建脚本 `diskwipe-iso/build.sh`（WSL bash 执行；内核材料在 Windows 侧
  `diskwipe-iso/kylin-src/`，build-lib.sh 自动检测 kylin-src/boot/vmlinuz-4.19* 走 Kylin 模式）。
- 参考命令形态：`wsl -e bash -c 'cd /mnt/c/Users/ganxin01/Documents/trae-work/ServerSystemTest/diskwipe-iso && ./build.sh'`
  （build.sh 具体用法/参数先读 build.sh 开头确认）。
- 产物必须为 `output/diskwipe-v1.5.1.iso`。

## qemu 验证（必须全部通过）

### A. UEFI 显示验证（本次修复的核心断言，新增）

参考 `tmp/verify-gfxpayload.sh`（当前无 efifb 证据的基线）与 `tmp/dw-smoke-uefi-v150.sh`（全流程冒烟模板）：
- qemu：`-bios /usr/share/qemu/OVMF.fd -cdrom diskwipe-v1.5.1.iso -boot d -vga std
  -display none -serial file:<log>`（**必须 -vga std**，OVMF 才有 GOP）。
- serial 日志断言（修复后必须出现）：
  - `efifb:`（内核初始化 EFI framebuffer）
  - `Console: switching to colour frame buffer`（fbcon 激活）
  - 全流程（参考 uefi-v150 冒烟）：`Linux version 4.19.90`、`RAMDISK:`、
    `DiskWipe Tool 1.5.1`、三盘 SYS/DATA/UNK、OK x3、`Exited.`、`Cleanup log saved to USB`
    （带盘 + 喂键流程参考 dw-smoke-uefi-v150.sh 的 FIFO feeder）。
- GRUB 阶段 `no suitable video mode found. Booting in blind mode` 允许出现（非致命）。

### B. BIOS isolinux 回归

参考 `tmp/dw-smoke-v150.sh`（v1.5.0 BIOS 冒烟，21 项断言；VERSION 断言改为 1.5.1）。
必须全部通过（isolinux 路径不受本次改动影响，回归确认）。

## 报告

完成后写 `task-1-report.md`（与 brief 同目录）：改动 diff、构建输出关键行、A/B 验证的关键
断言输出（含 efifb/fbcon 证据行 + 全流程行 + BIOS 回归 PASS 行）、git commit（message
风格参考：`fix(diskwipe-iso): grub.cfg 删除 gfxpayload=text（内核跳过 efifb 致 UEFI 真机黑屏）；v1.5.1 重打包`）。
返回：状态（DONE/BLOCKED/NEEDS_CONTEXT）、commit hash、一行测试摘要、concerns（若有）。
