# Task 2 brief — UEFI 直启版 v1.5.2（grub.cfg 去菜单直启，根治盲模式卡死）

## 背景

v1.5.1（删 gfxpayload=text）已修复「内核无 efifb 显示」问题（qemu 仿真验证 efifb+fbcon）。
但真机（UEFI + Ventoy + KVM VGA）仍报 `no suitable video mode found. Booting in blind
mode` 后**黑屏卡死**——根因升级为：**GRUB 盲模式（无可用终端）渲染菜单（menuentry +
timeout=3）时卡死，内核未启动**。qemu 无法复现真盲模式（OVMF 无 VGA 时回退 serial 终端），
需靠配置消除盲模式下的卡死点。

## 任务（精确）

1. `diskwipe-iso/build-lib.sh` 4.1 段（`cat > "$rootfs/boot/grub/grub.cfg"` here-doc）：
   将 grub.cfg 改为**无菜单直启**（不渲染菜单、无 timeout 倒计时，盲模式下 GRUB 加载后
   直接执行 linux/initrd/boot）：

   ```
   # v1.5.2 UEFI 精简 GRUB 直启（无菜单渲染，盲模式安全：不等待终端、不渲染 menuentry）
   linux /boot/vmlinuz console=tty0 console=ttyS0,115200n8 rdinit=/init
   initrd /boot/initrd.img
   boot
   ```

   - 删除 `set timeout=3`、`set default=0`、`set gfxmode=text`、`menuentry ... {...}` 块。
   - **不得引入 gfxpayload=text**（当前工作树 build-lib.sh 已是删后状态，保留）。
   - 注释更新为 v1.5.2 直启语义（保留「BIOS 走 ISOLINUX」说明）。
2. `diskwipe-iso/VERSION`：`1.5.1` → `1.5.2`。
3. 重新构建（WSL Kylin 模式）：`output/diskwipe-v1.5.2.iso`。

## 禁止改动

- `src/{init,menu.sh,lib.sh,wipe.sh}`、isolinux.cfg、BOOTX64.EFI 打包逻辑、embedded-efi.cfg
  （embedded 的 terminal_output console 保留）。

## qemu 验证（必须全部通过）

### A. UEFI 有视频（-vga std）：直启 + 显示 + 全流程

参考 `tmp/dw-smoke-uefi-v150.sh`（FIFO 喂键：盘列表→回车全选→YES→0 退出）：
- serial 断言：`efifb:`、`Console: switching to colour frame buffer`、
  `Linux version 4.19.90`、`RAMDISK:`、`DiskWipe Tool 1.5.2`、三盘 SYS/DATA/UNK、
  `OK /dev/vd* reset` x3、`Exited.`、`Cleanup log saved to USB`。
- 注意直启后无 GRUB 菜单：流程直接进入 initrd 的 menu.sh（盘列表立即出现）。

### B. UEFI 无视频（-vga none）：盲模式不卡死（核心新断言）

参考 `tmp/novid-repro.sh`（-vga none + OVMF + serial）：
- GRUB 可能打印 `no suitable video mode`/`Booting in blind mode`（允许）。
- **必须** serial 出现 `Linux version 4.19.90` + `RAMDISK:` + init 流程（`Run /init`、
  `Only boot media found` 或菜单横幅）→ 证明盲模式下直启不卡、内核照常启动。
  （无盘场景即可，不用挂盘/喂键。）

### C. BIOS isolinux 回归

参考 `tmp/dw-smoke-v150.sh`（VERSION 断言改 1.5.2）。必须全部通过。

## 提交

完成验证后 commit（一次 commit 同时包含 Task 1 的 gfxpayload 改动与本次直启改动）：
`git add diskwipe-iso/build-lib.sh diskwipe-iso/VERSION && git commit`
message 风格：`fix(diskwipe-iso): grub.cfg 改无菜单直启（盲模式不渲染菜单致真机 UEFI 卡死）+ 删 gfxpayload=text（内核跳过 efifb）；v1.5.2 重打包`

## 报告

写 `task-2-report.md`（与 brief 同目录）：改动 diff、构建关键行、A/B/C 验证断言输出、
commit hash。返回：状态、commit hash、一行测试摘要、concerns。
