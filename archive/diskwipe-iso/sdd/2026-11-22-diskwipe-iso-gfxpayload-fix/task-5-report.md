# Task 5 report — v1.5.5 init 进度诊断 + timeout 兜底

**状态**：DONE
**commit**：`d14b9b7`
**测试摘要**：tests t1-t6 全部 ALL PASS（t1:89 / t2:61 / t3:60 / t4:46 / t5:37 / t6:77）；qemu A（UEFI -vga std）22 项断言 PASS、B（-vga none serial）7 项断言 PASS、C（BIOS isolinux）22 项断言 PASS，三个 verdict 均 PASS。

## 1. 改动 diff（核心）

### `diskwipe-iso/VERSION`
```
-1.5.4
+1.5.5
```

### `diskwipe-iso/src/init`（仅此三处逻辑 + 注释，LF 行尾）
- 头部注释改为 v1.5.5 语义：每步打印进度 + timeout 5 兜底；仅挂载失败 rescue；模块/mdev 失败 WARN 继续；内核 D 状态用户态 timeout 无效，靠进度行定位卡点。
- 磁盘模块循环（原 69-71 行）：
```sh
for im in $DRIVE_MODULES; do
    echo "loading module $im"
    timeout 5 modprobe "$im" 2>/dev/null || echo "WARN: module $im load failed/timed out"
done
echo "Disk driver modules loaded"
```
- 显卡循环（v1.5.4 新增）：
```sh
for gv in ast mgag200 smifb bochs-drm cirrus virtio-gpu; do
    echo "loading video module $gv"
    timeout 5 modprobe "$gv" 2>/dev/null
done
```
- mdev 首扫：
```sh
echo "device scan (mdev -s)"
timeout 5 mdev -s || echo "WARN: mdev scan failed/timed out"
echo "Device nodes scanned"
```
- 保留：mount 三处 init_rescue；sleep 2 + 3 轮 mdev 重试（内部 mdev 同样包 `timeout 5 mdev -s`）；exec menu.sh。`init_rescue` 函数保留（仅 mount 用）。

### `diskwipe-iso/tests/t3_init.sh`（适配新语义）
- setup_stub 新增 fake `timeout` 假件（`shift; "$@"`，不真等 5s）与 fake `mdev` 失败注入（`$ROOT/mdev.fail`）。
- I1 新增进度行断言：`loading module ahci/mpt3sas`、`Disk driver modules loaded`、`loading video module bochs-drm`、`device scan (mdev -s)`、`Device nodes scanned`。
- I2 重写：mpt3sas 失败 → `WARN: module mpt3sas load failed/timed out` + 继续加载 `virtio_blk` + mdev 4 次 + 最终 `MENU_EXEC_MARKER`；断言不再有 ERROR/rescue shell。
- I3（挂载失败 rescue）保持不变。
- 新增 I4：mdev -s 失败 → WARN 继续 + `Device nodes scanned` + 最终 exec menu.sh。

## 2. 构建关键行（WSL Kylin 模式，build.sh kylin）

```
==> 内核模式：kylin（kylin = 使用 kylin-src 提取的 Kylin 4.19 内核...）
==> 使用内核：4.19.90-89.11.v2401.ky10.x86_64
iso：40M
校验通过：initrd 内 /diskwipe.version = 1.5.5
校验通过：src 四脚本 dash -n 语法 0 错误
校验通过：initrd 内模块全部为未压缩 .ko（共 31 个，无 .ko.zst/.ko.xz 残留）
✓ 构建成功：.../diskwipe-iso/output/diskwipe-v1.5.5.iso（大小 40M）
```

## 3. 验证结果

### tests（Git Bash，`tests/run-all.sh`）
```
t1_wipe  ALL PASS（89 项）
t2_menu  ALL PASS（61 项）
t3_init  ALL PASS（60 项，含 I1/I2/I3/I4）
t4_log   ALL PASS（46 项）
t5_ascii ALL PASS（37 项）
t6_scan  ALL PASS（77 项）
==== 全部测试: ALL PASS ====
```

### qemu A（UEFI -vga std，`tmp/dw-smoke-uefi-v155.sh`）—— verdict PASS，22 项 PASS
关键行：
```
bochs-drm 0000:00:02.0: fb0: bochsdrmfb frame buffer device
Console: switching to colour frame buffer device 128x48
loading module ahci ... loading module uas / loading module nls_iso8859-1
Disk driver modules loaded / Device nodes scanned
DiskWipe Tool 1.5.5 ... / Disks found: 3 (vda vdb vdc) / SYS DATA UNK
OK /dev/vda|vdb|vdc reset to uninitialized / Exited. / Log kept in memory:
Cleanup log saved to USB（USB 数据分区日志 diskwipe-20261123-014456.log，version: 1.5.5）
```
（INFO：efifb 未出现、Booting in blind mode 出现——均既有行为，brief A 允许不判失败）

### qemu B（-vga none serial，`tmp/novid-v155.sh`）—— verdict PASS，7 项 PASS
```
PASS: kernel started (serial)  — Linux version 4.19.90
PASS: initrd received          — RAMDISK:
PASS: Run /init
PASS: init 进度行 loading module 出现
PASS: Disk driver modules loaded 出现
PASS: Device nodes scanned 出现
```
（尾部 kernel panic "Attempted to kill init! exitcode=0x00000000" 与 v154 完全一致——无盘+stdin EOF 下 menu.sh 退出触发 PID1 终止，既有行为非回归）

### qemu C（BIOS isolinux，`tmp/dw-smoke-v155.sh`）—— verdict PASS，22 项 PASS
```
ISOLINUX 6.04 / Loading /boot/vmlinuz... ok / Loading /boot/initrd.img...ok
Linux version 4.19.90 / RAMDISK: / loading module
DiskWipe Tool 1.5.5 / Scanning disks... / Disks found: 3 / SYS DATA UNK
OK x3 / Exited. / Log kept in memory: / Cleanup log saved to USB
no GNU GRUB / no ERROR line / no Only boot media / no No writable log media
```

## 4. 验证脚本留档
- `tmp/dw-smoke-uefi-v155.sh`（A）
- `tmp/novid-v155.sh`（B）
- `tmp/dw-smoke-v155.sh`（C）

## 5. concerns
- 真机卡点若为内核 D 状态（不可中断 I/O，如 mpt3sas/UAS 控制器枚举），用户态 `timeout 5` 无效——此时进度行（最后一行停留在哪个模块/哪个步骤）即为定位证据，与 brief 预期一致；若卡在 `loading module uas` 之后，D 状态定位成立。
- `mdev -s` 及重试均包 timeout 5，理论最坏额外耗时约 5s（首扫）+ 每轮 5s；真机正常路径无影响（qemu 实测通过）。
- 构建产物 `output/diskwipe-v1.5.5.iso` 被 .gitignore 忽略（与 v1.5.4 一致，不提交二进制）。
