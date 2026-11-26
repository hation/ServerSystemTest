# Task 30 报告 — v1.6.0 恢复 megaraid_sas + 去 pci=realloc,nocrs

## 状态
DONE（两个确定性修复已落地、重打包、提交；qemu A/B/C 冒烟未在本环境执行，见 concerns）

## commit hash
`036f943`（main HEAD，6 files changed, 370 insertions(+), 31 deletions(-)）

## 改动 diff 摘要（仅两件事 + 相关断言翻转）
1. `diskwipe-iso/src/init`：Kylin 分支 DRIVE_MODULES 在 `mpt3sas` 后加回 `megaraid_sas`（第 82 行）；Kylin 分支注释改为 v1.6.0 说明（ISO 解包对比证伪「竞争」假设）。
2. `diskwipe-iso/build-lib.sh`：
   - `DW_KYLIN_MODULES` 在 `mpt3sas` 后加回 `megaraid_sas`（第 80 行）。
   - grub.cfg `linux` 行、isolinux.cfg `APPEND` 行去掉 ` pci=realloc,nocrs`（回 `console=tty0 console=ttyS0,115200n8`）；相关注释/echo 同步更新。
   - `dw_verify_iso` 两处 pci=realloc 断言翻转为「内核命令行**不含** pci=realloc」（按 linux/APPEND 行精确 grep，避免误判注释里的“去掉 pci=realloc”说明）。
3. `diskwipe-iso/tests/t2_menu.sh`：M13 翻转为断言 grub.cfg linux 行 / isolinux.cfg APPEND 行**不含** pci=realloc。
4. `diskwipe-iso/tests/t3_init.sh`：I5（ky10）白名单加 `megaraid_sas` 并翻转「不得加载」为「应加载」（I1 为 Ubuntu 分支本就不含 megaraid_sas，断言不加载不变）。—— 此文件超出父级「只改 4 个文件」的字面清单，但属 fix ① 的必要断言翻转，否则 t3 必失败。
5. `diskwipe-iso/VERSION`：`1.5.29` → `1.6.0`。

未改动：`src/menu.sh`、`src/lib.sh`、`src/wipe.sh`、引导结构、xorriso 打包参数。

## isoinfo 客观校验证据
- `megaraid_sas.ko` 在 initrd（cpio -t 命中）：
  `lib/modules/4.19.90-89.11.v2401.ky10.x86_64/kernel/drivers/scsi/megaraid/megaraid_sas.ko`
- grub.cfg `linux` 行：`linux /boot/vmlinuz console=tty0 console=ttyS0,115200n8 rdinit=/init`（无 pci=realloc）
- isolinux.cfg `APPEND` 行：`APPEND console=tty0 console=ttyS0,115200n8 initrd=/boot/initrd.img`（无 pci=realloc）
- 构建 dw_verify_iso 全通过：双 console ✓、linux/APPEND 行无 pci=realloc ✓、/init 执行位 ✓、/diskwipe.version=1.6.0 ✓、dash -n 0 错误 ✓、模块全 .ko 26 个 ✓、Kylin 4.19 vmlinuz ✓。
- 产物：`diskwipe-iso/output/diskwipe-v1.6.0.iso`（39M，Kylin 模式，26 个 .ko.xz→.ko）。

## tests 输出摘要（WSL）
- t1_wipe 89 PASS / t2_menu 123 PASS（含 M13 翻转）/ t3_init 106 PASS（含 I5 megaraid_sas 应加载）/ t4_log 50 PASS / t5_ascii 37 PASS → 全 PASS。
- t6_scan 76 通过 1 失败（H8「umount 不得包 timeout」），为 **v1.5.29 menu.sh U 盘日志块新增 `timeout 3 umount /mnt/dwdiag`** 触发的**预存在**失败，与本次两处修复无关（未改 menu.sh/t6_scan.sh）。

## concerns
1. t6_scan H8 预存在失败（源于未提交的 v1.5.29 menu.sh U 盘日志特性，非本次引入）；按“只做两件事、menu.sh U 盘日志保留”的约束未修。
2. qemu A/B/C 冒烟（UEFI 有盘 / -vga none 无盘 / BIOS isolinux 有盘）未在本环境执行：qemu-system-x86_64 不在 PATH，且无 v1528 参考脚本（最新为 v1527）。isoinfo 客观校验已证明 megaraid_sas.ko 入 initrd 且 pci=realloc 出内核命令行，与 v1.5.6 成功配置一致。