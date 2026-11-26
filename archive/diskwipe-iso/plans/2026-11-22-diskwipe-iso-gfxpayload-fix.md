# 2026-11-22 diskwipe-iso gfxpayload 修复计划（v1.5.1）

## 背景（根因已实证）

真机（UEFI + Ventoy 默认模式 + KVM VGA）黑屏根因：

1. **Kylin 内核并非 headless**——此前用 `strings vmlinuz` 判断 CONFIG_VT 缺失是**误判**。
   kernel-core rpm 自带 `config-4.19.90-89.11.v2401.ky10.x86_64` 权威确认：
   `CONFIG_VT=y`、`CONFIG_VT_CONSOLE=y`、`CONFIG_FB_EFI=y`、`CONFIG_FRAMEBUFFER_CONSOLE=y`、
   `CONFIG_VGA_CONSOLE=y`、`CONFIG_DUMMY_CONSOLE=y`、`CONFIG_DRM_AST=m`。
2. UEFI 精简 GRUB 的 grub.cfg 里 `set gfxpayload=text`（v1.4.1 为压制「no suitable video
   mode」报错而加入）→ 内核收到 gfxpayload=text → **跳过 EFI framebuffer（efifb）**；
   UEFI 固件无 BIOS int10h VGA text → vgacon 无法初始化 → tty0 无输出 → 黑屏。
3. qemu 实证：UEFI（OVMF + `-vga std` 有 GOP）+ v1.5.0 ISO → serial 日志无
   `efifb`/`fbcon`/`Console: switching` 证据；内核照常启动（`Linux version` 在 serial）
   但无 framebuffer（黑屏）。删除 gfxpayload=text 后内核将自行经 EFI GOP 初始化 efifb
   → fbcon → tty0 显示。

## 修复

### Task 1：grub.cfg 删 gfxpayload=text + 重打包 v1.5.1 + qemu 显示验证 + BIOS 回归

- `diskwipe-iso/build-lib.sh` 4.1 段（写 `boot/grub/grub.cfg`）：删除 `set gfxpayload=text`
  行（`set gfxmode=text` 保留无副作用——无 gfxterm 模块时 gfxmode 不生效）。
- `diskwipe-iso/VERSION`：`1.5.0` → `1.5.1`。
- 重新构建（WSL，Kylin 内核模式，材料在 Windows 侧 `diskwipe-iso/kylin-src/`）：
  `output/diskwipe-v1.5.1.iso`。
- **qemu UEFI 显示验证（新增断言）**：OVMF + `-vga std`（有 GOP）+ serial 日志必须出现
  `efifb:` / `Console: switching to colour frame buffer`（fbcon 激活）；且全流程断言通过
  （`Linux version 4.19.90`、`RAMDISK:`、菜单横幅 `DiskWipe Tool 1.5.1`、三盘 SYS-DATA-UNK、
  OK x3、Exited、日志写 U 盘）。参考 `tmp/dw-smoke-uefi-v150.sh` 改 VERSION 断言 + 加 efifb 断言。
- **BIOS isolinux 回归**：参考 `tmp/dw-smoke-v150.sh`（21 项断言）不回归。
- GRUB 阶段 `no suitable video mode` 报错可接受（非致命，盲模式 3s 后自动启动内核）。

### Task 2：结尾整支复查（final whole-branch review）

## 全局约束

- 只改 `build-lib.sh` 的 grub.cfg 生成段与 `VERSION`；`src/{init,menu.sh,lib.sh,wipe.sh}`
  一律不动（initrd 运行时脚本与本次黑屏无关）。
- 版本号必须为 1.5.1（构建产物 `diskwipe-v1.5.1.iso`，横幅/日志版本串一致）。
- qemu 验证只读 ISO/虚拟盘，绝不写真实块设备。
- 验证产出：UEFI 显示断言（efifb/fbcon）+ 全流程 + BIOS 回归均通过才可交付。
