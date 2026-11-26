# Task 4 报告 — v1.5.4 initrd 加载显卡 DRM 驱动

## 状态：DONE　commit：`0829353`　一行测试摘要：A 组 fb0/Console switching 核心断言 + 全流程 PASS、B 组 serial 兜底内核照常启动 PASS、C 组 BIOS 21 项 PASS、tests t1-t6 ALL PASS（77 项）

## 改动 diff（3 文件，+15/-2）

### 1) `diskwipe-iso/build-lib.sh`（DW_KYLIN_MODULES 白名单追加显卡种子）
```diff
-DW_KYLIN_MODULES="ahci libahci libata nvme nvme-core mpt3sas megaraid_sas virtio_blk sd_mod usb-storage uas nls_iso8859-1 vfat fat"
+DW_KYLIN_MODULES="ahci libahci libata nvme nvme-core mpt3sas megaraid_sas virtio_blk sd_mod usb-storage uas nls_iso8859-1 vfat fat ast mgag200 smifb bochs-drm cirrus virtio-gpu"
```
+ 追加注释说明用途（v1.5.4 UEFI 显示：efifb 依赖 GRUB framebuffer，真机 GRUB 视频初始化失败无 framebuffer，改由 initrd 加载显卡驱动内核自探测 → DRM → fbcon → tty0）。

### 2) `diskwipe-iso/src/init`（DRIVE_MODULES 循环后、mdev -s 前加显卡加载循环）
```sh
# 2.5) v1.5.4 显卡驱动：内核自探测显卡硬件 → DRM → fbcon → tty0 显示（不依赖 GRUB framebuffer；
# 真机 UEFI 下 GRUB 视频初始化失败无 framebuffer，靠显卡驱动重建显示）。
# 加载失败无害（该机无对应显卡），仅静默跳过，不进入救援 shell。
for gv in ast mgag200 smifb bochs-drm cirrus virtio-gpu; do
    modprobe "$gv" 2>/dev/null
done
```
（POSIX/ash 兼容；失败静默跳过不 rescue）

### 3) `diskwipe-iso/VERSION`：`1.5.3` → `1.5.4`

禁止改动项（menu.sh/lib.sh/wipe.sh/isolinux.cfg/grub.cfg/BOOTX64.EFI 打包/xorriso 打包）未触碰。

## 构建关键行（WSL Kylin 模式）

```
内核模式：kylin（Kylin 4.19.90-89.11.v2401.ky10.x86_64）
Kylin 模块提取：白名单 + 依赖链共 31 个 .ko.xz      ← 25(磁盘) + 6(显卡种子) + drm/ttm/i2c-algo-bit/fb_sys_fops 等依赖自动解析
已把 31 个 .ko.xz 模块解压为 .ko（busybox 无 xz 解压能力）
initrd.img：5.2M
iso：40M → output/diskwipe-v1.5.4.iso
校验通过：initrd 内 /diskwipe.version = 1.5.4
校验通过：src 四脚本 dash -n 语法 0 错误
校验通过：initrd 内模块全部为未压缩 .ko（共 31 个，无 .ko.zst/.ko.xz 残留）
```

## 验证 A — qemu UEFI -vga std（bochs 显卡）：**PASS**（smoke verdict: PASS）

`tmp/dw-smoke-uefi-v154.sh`（模板 dw-smoke-uefi-v153.sh 改 1.5.4；efifb 断言改为 INFO 记录不判失败）：

| 断言 | 结果 |
|---|---|
| `fb0:`（fbdev 设备，bochs-drm） | **PASS** — `bochs-drm 0000:00:02.0: fb0: bochsdrmfb frame buffer device` |
| `Console: switching to colour frame buffer` | **PASS** — `Console: switching to colour frame buffer device 128x48`（fbcon 激活） |
| `Linux version 4.19.90` / `RAMDISK:` | PASS |
| `DiskWipe Tool 1.5.4` 全流程（三盘 SYS/DATA/UNK、OK x3、Exited.、Log kept in memory、Cleanup log saved to USB） | 全部 PASS |
| efifb | INFO 未出现（符合预期：显示由 bochs-drm 提供，不依赖 GRUB framebuffer） |
| no ERROR / no Only boot media | PASS |

USB 日志证据：`/mnt/dwlogxuefi154/diskwipe-20261122-153813.log`（version: 1.5.4，OK x3 完整）。

**核心对比**：v1.5.3 的 A 输出（dw-smoke-uefi-v153.out，任务背景"已实证"诊断运行）fb0=0、colour=0、efifb=0；v1.5.4 fb0=1、colour=1 —— 显卡驱动路径真实生效，黑屏问题解决。

## 验证 B — qemu UEFI -vga none（serial 兜底回归）：**PASS**（novid verdict: PASS）

`tmp/novid-v154.sh`（模板 novid-v153.sh 改 1.5.4；blind mode 断言按 brief「允许打印」改为 INFO）：

- `no suitable video mode found` + `Booting in blind mode`：INFO 允许打印（GRUB 视频初始化失败，既有行为）
- `Linux version 4.19.90`（serial）：**PASS** — 内核照常启动、不卡
- `RAMDISK:`：PASS；`Run /init`：PASS（init 流程到达）
- 显卡循环在无显卡场景全部静默失败，不影响启动

## 验证 C — BIOS isolinux 冒烟回归：**PASS**（smoke verdict: PASS，21 项全过）

`tmp/dw-smoke-v154.sh`（模板 dw-smoke-v150.sh 改 1.5.4）：ISOLINUX 6.04 / Loading vmlinuz+initrd ok / Linux version 4.19.90 / RAMDISK: / DiskWipe Tool 1.5.4 / 三盘 SYS-DATA-UNK / OK x3 / Exited. / Log kept in memory / Cleanup log saved to USB / no GNU GRUB / no ERROR / no Only boot media / no No writable log media。USB 日志完整（`dw-smoke-v154-keylines.txt`）。

## tests 回归：**ALL PASS**（77 项）

`bash diskwipe-iso/tests/run-all.sh` → `==== 全部测试: ALL PASS ====`。t3（init 假件测试）兼容新增显卡 modprobe 调用：I1 正向断言仅覆盖 DRIVE_MODULES 白名单各模块、显卡循环在 mdev -s 之前不破坏「mdev 在全部 modprobe 之后」顺序断言；I2/I3 失败路径在 DRIVE_MODULES 循环内即 exec 救援 shell，显卡循环不执行，计数断言不受影响。

## concerns

1. **"Booting in blind mode" 在 A/B 中均打印**——GRUB 阶段既有行为（v1.5.3 输出文件同样各含 1 次），源自精简 GRUB 无 video/efi_gop 模块 → 视频初始化失败；brief B 组明确「允许打印」，关键是不卡死（serial 兜底 + 内核照常启动已证）。脚本断言已按 brief 修正为 INFO 记录。
2. **无视频场景（B）尾部 `Kernel panic - not syncing: Attempted to kill init!`**——menu 在无盘场景无输入（stdin EOF）直接退出 → PID1 退出 → 内核 panic，属 qemu 测试环境既有行为（v1.5.3 novid-v153.out 同样有 2 次 panic），非本次改动引入；真机有交互不触发。
3. **A 组 qemu exit=124（timeout 180s）**——菜单流程跑完（feed 0 退出）后 menu 退出 → PID1 退出 → panic 挂起 → timeout 杀 qemu；v1.5.3 同行为（A-v153 亦 timeout 终止），非新问题。
4. **显卡循环仅 Kylin 模式材料齐全**（brief 允许）：ubuntu 模式下 6 个显卡模块可能无文件，modprobe 失败静默跳过（`2>/dev/null`），无害。
5. 产物 `diskwipe-iso/output/diskwipe-v1.5.4.iso`（40M）；验证脚本 `tmp/dw-smoke-uefi-v154.sh`、`tmp/novid-v154.sh`、`tmp/dw-smoke-v154.sh` 留档（tmp/ 未跟踪不入库）。
