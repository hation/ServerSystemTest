# Task 15 报告 — v1.5.15 强制 SCSI 重扫描（直接修复真机 SAS 盘未被内核带出）

## 状态
**DONE**

## 根因与修复方案
真机 v1.5.14：lsblk 完全空（连表头都没有）→ sda（SAS/mpt3sas）从未被内核创建。
直接修复（非诊断）：mpt3sas/megaraid_sas 加载后**强制对全部 scsi_host 写 rescan**
（`echo "- - -" > /sys/class/scsi_host/host*/scan`）——即使自动 SCSI 扫描未完成/被抢占，
强制重扫描也会把 SAS 盘带出。init 与 menu 枚举前各做一次。

## 改动 diff（commit 9cd973b，5 files changed, 49 insertions(+), 1 deletion(-)）

### 1. src/init — 「Disk driver modules loaded」之后、video(ast) 之前
```sh
# v1.5.15 修复：SCSI 驱动（mpt3sas/megaraid_sas）加载后强制重扫描全部 scsi_host——
# 真机 SAS 盘未被自动扫描带出（lsblk 空）；echo "- - -" 触发一次完整 rescan，
# 确保盘被内核创建。逐个写、失败跳过（部分 host 非 SCSI 扫描型）。
for sh in /sys/class/scsi_host/host*/scan; do
    [ -w "$sh" ] && echo "- - -" > "$sh" 2>/dev/null || true
done
```

### 2. src/menu.sh — `ml="$(dw_enum_disks)"` 之前（enumerating disks 打印后，枚举前兜底）
```sh
# v1.5.15：枚举前强制 SCSI 重扫描兜底——盘可能晚就绪，每次枚举前 rescan 一次，
# 就绪的盘下次枚举即出现（与无限重试配合）。
for sh in /sys/class/scsi_host/host*/scan; do
    [ -w "$sh" ] && echo "- - -" > "$sh" 2>/dev/null || true
done
```

### 3. VERSION：1.5.14 → 1.5.15

### 4. tests 适配
- `tests/t3_init.sh`：I1 新增 xtrace 断言——`[ -w /sys/class/scsi_host/host0/scan ]` 出现
  （循环执行；WSL host0/scan 存在但不可写 → [ -w ] 为假、echo 不执行、零副作用）+
  顺序断言（Disk driver modules loaded 之后、loading video module ast 之前）。
- `tests/t2_menu.sh`：M10 新增 xtrace 断言——枚举前 rescan 循环执行 + 顺序断言
  （enumerating disks (lsblk) 之后、枚举 lsblk 调用之前）。

禁止改动项（lib.sh/wipe.sh/build-lib.sh/isolinux/grub.cfg/embedded/BOOTX64.EFI）未动。

## 构建关键行（WSL Kylin 模式，build-v1515.sh = DW_KERNEL_MODE=kylin）
```
output/diskwipe-v1.5.15.iso  (40894464 B, Nov 25 13:25)
CD-ROM is in ISO 9660 format / Volume id: DISKWIPE / XORRISO-1.5.6 打包
```

## 验证结果（全部通过）

### tests t1-t6（WSL 跑，bash diskwipe-iso/tests/run-all.sh）
```
t1_wipe ALL PASS（77 项）
t2_menu ALL PASS（含 M10 枚举前 rescan 循环断言 + 顺序断言）
t3_init ALL PASS（97 项，含 I1 init rescan 循环断言 + 顺序断言）
t4_log ALL PASS / t5_ascii ALL PASS / t6_scan ALL PASS
==== 全部测试: ALL PASS ====
```

### qemu A（UEFI -vga std 有盘，tmp/dw-smoke-uefi-v1515.sh 留档）— PASS
- DiskWipe Tool 1.5.15 - Reset disks to uninitialized
- Disks found: 3 (vda vdb vdc)；第一轮列盘 /dev/vda SYS、/dev/vdb DATA、/dev/vdc UNK
- OK /dev/vda|vdb|vdc reset to uninitialized x3；Exited. You may power off or reboot after done.
- 日志降级 WARN: could not write log to USB（v1.5.9 语义保持）
- 无 scsi_host 输出（v1.5.15 rescan 静默）、无 ERROR、无 Only boot media
- 全流程与 v1.5.14 完全一致（rescan 不影响 virtio 盘）

### qemu B（-vga none 无盘，tmp/novid-v1515.sh 留档）— PASS
- init 流程到达（Disk driver modules loaded → Device nodes scanned → settle wait → exec menu.sh）
- 无盘无限重试：retry 消息 4 条（retry 1/11/21/31，全部 N%10==1，每 10 轮一次降噪）
- **read -t 真实间隔**：RAW lsblk 轮次时间戳间隔 6.12–6.75s/轮（sleep 失真 ~0.17s 未复现）
- **rescan 循环不报错**：输出无 scsi_host 错误行（[ -w ] 防不可写 + 2>/dev/null 静默）
- 无旧自动重启字符串（rebooting in 10s / reboot -f / reboot ineffective 等全无）
- qemu 由 timeout 收尾（exit=124 等价：进程被 timeout 150 结束，无盘永不退出、无 reboot/关机）

### qemu C（BIOS isolinux 有盘，tmp/dw-smoke-v1515.sh 留档）— PASS
- 21 项关键行全过（ISOLINUX 6.04 → Loading vmlinuz → Linux version 4.19.90 → RAMDISK →
  init 流程 → DiskWipe Tool 1.5.15 → 三盘 → OK x3 → Exited → Log kept in memory →
  WARN could not write log to USB）
- 无 GNU GRUB / 无 ERROR / 无 Only boot media / 无 No writable log media
- 无 scsi_host 输出（rescan 静默）

## 验证脚本留档
- tmp/dw-smoke-uefi-v1515.sh（验证 A）
- tmp/novid-v1515.sh（验证 B）
- tmp/dw-smoke-v1515.sh（验证 C）
- tmp/build-v1515.sh（构建）

## commit
`9cd973b` — fix(diskwipe-iso): 强制 SCSI 重扫描（init 加载后 + menu 枚举前，echo - - - > scsi_host/scan）直接修复真机 SAS 盘未被内核带出；v1.5.15 重打包

## concerns
- 真机效果最终以现场 KVM 观察为准：若 mpt3sas 本身加载过慢（此前 v1.5.10 观察 14.47s），
  init 的 rescan 发生在模块加载循环之后（循环含 timeout 5/模块），SAS 盘若在 rescan 之后才
  出现在 SCSI 总线上，则由 menu 每轮枚举前的 rescan + 无限重试兜底带出（与既有设计配合）。
- WSL 下 /sys/class/scsi_host/host0/scan 存在但不可写，tests 的 rescan 断言以 xtrace 断言
  循环代码路径执行（[ -w ] 为假不写入），未覆盖真实写入路径；真实写入路径由 qemu A/B/C
  隐式覆盖（qemu initramfs 中 scsi_host 的 scan 可写，rescan 实际执行且无副作用）。
