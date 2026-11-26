# Task 4 brief — v1.5.4 initrd 加载显卡 DRM 驱动（解决 UEFI VGA 显示，不依赖 GRUB framebuffer）

## 背景

真机（UEFI + Ventoy + KVM VGA）问题链：
1. v1.5.3 已用 serial 终端兜底解决「盲模式卡死」（qemu -vga none 实证：报错后内核照常
   启动、init 流程跑完）——但**显示问题未解**。
2. 根因：Linux 内核 efifb **依赖 GRUB 通过 boot 协议传递 framebuffer**（screen_info）。
   我们精简 BOOTX64.EFI 无 efi_gop 驱动 → GRUB 视频初始化失败 → 无 framebuffer →
   qemu A 组（-vga std 有 GOP）serial 日志**无 efifb/fb0**（已实证）→ VGA 黑屏。
   真机 Ventoy grub 路径同理（视频初始化失败 → 无 framebuffer）。
3. **正解**：initrd 加载**显卡 DRM 驱动**（内核自探测显卡硬件，不依赖 GRUB/EFI framebuffer）
   → fbcon（CONFIG_FRAMEBUFFER_CONSOLE=y 内建）→ tty0 显示。Kylin 内核已确认
   CONFIG_DRM_AST=m / DRM_MGAG200=m / DRM_BOCHS=m；kylin-src 模块齐全。

## 任务（精确）

1. `diskwipe-iso/build-lib.sh` `DW_KYLIN_MODULES` 白名单（Kylin 模式，文件头部定义处）
   追加显卡种子模块：`ast mgag200 smifb bochs-drm cirrus virtio-gpu`
   （依赖链——ttm、i2c-algo-bit、drm_kms_helper、drm、fb_sys_fops、syscopyarea、
   sysfillrect、sysimgblt——由 dw_modules_kylin 按 modules.dep 自动解析提取）。
   注释说明用途（v1.5.4 UEFI 显示）。
2. `diskwipe-iso/src/init`：在 DRIVE_MODULES 加载循环（约 69-71 行）之后、mdev -s 之前，
   加显卡驱动加载循环（**失败不触发 init_rescue**——无对应显卡时无害）：
   ```
   # v1.5.4 显卡驱动：内核自探测显卡硬件 → DRM → fbcon → tty0 显示（不依赖 GRUB framebuffer；
   # 真机 UEFI 下 GRUB 视频初始化失败无 framebuffer，靠显卡驱动重建显示）。
   # 加载失败无害（该机无对应显卡），仅静默跳过，不进入救援 shell。
   for gv in ast mgag200 smifb bochs-drm cirrus virtio-gpu; do
       modprobe "$gv" 2>/dev/null
   done
   ```
   （POSIX/ash 兼容；Kylin 模式已由 case 选择白名单，显卡加载对 ubuntu/kylin 两模式
   都执行亦可，但本任务只保证 Kylin 模式材料齐全）
3. `diskwipe-iso/VERSION`：`1.5.3` → `1.5.4`。
4. 重新构建（WSL Kylin 模式）：`output/diskwipe-v1.5.4.iso`。

## 禁止改动

- `src/menu.sh`、`src/lib.sh`、`src/wipe.sh`、isolinux.cfg、grub.cfg 直启内容、
  embedded-efi.cfg、BOOTX64.EFI 打包逻辑、xorriso 打包逻辑。

## 验证（必须全部通过）

### A. qemu UEFI -vga std（bochs 显卡）：显卡驱动显示 + 全流程（核心断言）

参考 `tmp/dw-smoke-uefi-v153.sh` 改 VERSION 1.5.4（FIFO 喂键全流程）：
- serial 断言：**`Console: switching to colour frame buffer`**（fbcon 激活）+ **`fb0:`**
  （fbdev 设备，来自 bochs-drm）——**这是 v1.5.4 的核心**（efifb 可能仍不出现，
  不判失败；显示由 bochs-drm 提供）。
- 全流程：`Linux version 4.19.90`、`RAMDISK:`、`DiskWipe Tool 1.5.4`、三盘
  SYS/DATA/UNK、OK x3、`Exited.`、`Cleanup log saved to USB`。

### B. qemu UEFI -vga none：serial 兜底 + 显卡驱动不影响（回归）

参考 `tmp/novid-v153.sh`（-vga none）：`no suitable video mode`/`Booting in blind
mode` 允许打印；**必须** `Linux version 4.19.90` + `RAMDISK:` + init 流程
（`Run /init`、`Only boot media found`）→ 内核照常启动、不卡。

### C. BIOS isolinux 回归 + tests 回归

- `tmp/dw-smoke-v150.sh` 改 VERSION 1.5.4 断言，21 项全过。
- 跑 `diskwipe-iso/tests/`（t1-t6，355 PASS 基线）——init 假件测试需兼容新增显卡
  modprobe 调用（若断言了 modprobe 调用清单则更新）。

## 提交

commit：`feat(diskwipe-iso): initrd 加载显卡 DRM 驱动（ast/mgag200/smifb/bochs-drm/cirrus/virtio-gpu）→ fbcon 显示，不依赖 GRUB framebuffer；v1.5.4 重打包`

## 报告

写 `task-4-report.md`：改动 diff、构建关键行、A/B/C+tests 验证断言输出、commit hash。
返回：状态、commit hash、一行测试摘要、concerns。
