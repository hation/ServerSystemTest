# Task 9 review — v1.5.9 去掉 usb-storage（U 盘不绑定根治真机设备枚举停滞）

审查对象：commit `d7da880`（相对 BASE `7b66568`，5 files changed, 40 insertions(+), 11 deletions(-)）
审查方式：只读 + 证据抽查（commit 校验、A/B/C 输出、iso/initrd 实测、tests 重跑）

---

## Spec 合规：✅

| brief 要求 | diff 实现 | 结论 |
|---|---|---|
| src/init ky10 分支 DRIVE_MODULES 去 usb-storage（注释文案指定） | ✅ 只改 `case *ky10*` 分支赋值行 + 注释（注释与 brief 指定文案一致）；Ubuntu 分支 `usb_storage uas` 与 top 注释未动 | 精确 |
| build-lib.sh DW_KYLIN_MODULES 去 usb-storage | ✅ 白名单去掉，注释一致 | 精确 |
| VERSION 1.5.8 → 1.5.9 | ✅ | 精确 |
| 禁止改动（menu.sh/lib.sh/wipe.sh/isolinux/grub.cfg/embedded/BOOTX64.EFI/xorriso） | ✅ `git show --stat` 仅 5 文件：VERSION、build-lib.sh、src/init、tests/t3_init.sh、tests/t4_log.sh | 无越界 |
| tests 适配（t3 负断言 / t4 降级断言） | ✅ t3 I5 循环去 usb-storage + `check_not_cmds 'modprobe usb-storage'`；t4 L5 源码级断言（grep 锚定 DRIVE_MODULES 赋值行，连字符形态，Ubuntu 下划线形态不误匹配，注释提及不算） | 正确 |

附加改动（brief 未明列但合理，不构成越界）：`build-lib.sh` 的 `dw_verify_iso` 6.6 Kylin 校验适配——关键模块检查 `ahci usb-storage nvme` → `ahci nvme`，并新增「initrd 内无 usb-storage.ko」反向断言（回归防护）。属 build-lib.sh 允许改动范围，报告如实说明。

## 问题列表

### Critical
- 无。

### Important
- **R1（报告证据准确性）**：报告声称「tests t1-t6 全部 ALL PASS（413 项）」与本环境重跑不符。重跑（MSYS Git Bash）结果：t1 89 ✅、t2 68 ✅、t4 50 ✅、t5 37 ✅、t6 77 ✅，**t3 89 PASS + 2 FAIL（I6 用例）**。
  - 根因（已实测确认）：MSYS Git Bash 下 `chmod -x` 对 Windows 文件无效——`chmod -x` 后 `ls -l` 仍为 `-rwxr-xr-x`，脚本照常执行、`exec` 退出码 0（Linux/WSL 语义才生效）。I6 期望 `exec` 失败退出 126 因此在 Git Bash 必失败。
  - **与本次 commit 无关**：I6 用例代码（t3_init.sh）与 init 的 exec 逻辑均未被本次 diff 改动，属预先存在的环境敏感用例。本次变更新增/修改的断言（I5 usb-storage 负断言、t4 L5）重跑全部 PASS。
  - 建议：报告注明 t3 I6 的环境依赖（或在 Linux/WSL 语义环境运行），勿将「全 ALL PASS」作为无条件声称。

### Minor
- **M1**：t3 头部注释「POSIX 语义实证（WSL dash/busybox ash/bash 一致）」成立范围仅限 WSL/Linux；MSYS Git Bash 下 chmod 语义不同（非本次改动，仅提示）。
- **M2**：报告断言计数 413 项与重跑口径 412 项差 1（差异来自 I6 环境失败路径），数字需与运行环境绑定说明。

## 代码质量（抽查确认）
- **init/build-lib 白名单一致性**：init ky10 = `ahci libahci libata nvme nvme-core mpt3sas megaraid_sas virtio_blk sd_mod nls_iso8859-1 vfat fat`；build-lib = 同上 + `ast`（v1.5.6 显卡种子）✅ 完全一致。
- **注释准确性（usbhid 内建依据）**：A/B/C 内核启动日志均有 `usbcore: registered new interface driver usbhid` + `usbhid: USB HID core driver`（无需 modprobe 即自动注册）——usbhid 内建的说法有运行时证据支持 ✅。
- **POSIX/ash**：src/init 仅改赋值字符串与注释，无语法变更；build-lib 为 bash 构建脚本，语法无误。
- **dw_verify_iso 反向断言**：`find "$build_dir/initrdx/lib/modules" -name 'usb-storage.ko' | grep -q .` → dw_fail，逻辑正确 ✅。
- **vfat/fat 保留**：与 init 白名单一致、加载无害（报告 concern 3 属实）。

## 报告 concerns 合理性：✅
1. qemu 无法复现真机 U 盘缺陷——属实且合理（qemu 虚拟 U 盘无真实 I/O 阻塞；A/B/C 已证 U 盘不被绑定：USB 层可见 `QEMU USB HARDDRIVE` 但 `Disks found: 3` 仅 virtio 盘）。真机现场验证为必须项。
2. 日志降级代价——brief 明确接受的代价；menu.sh/lib.sh 的 dw_save_log_to_usb 未改，未来恢复加载 usb-storage 则写日志能力自动回来 ✅。
3. vfat/fat 仍打包——无害 ✅。
4. 行尾 CRLF 与 task 6/7/8 一致 ✅。

## 报告证据真实性（抽查）
- commit `d7da880` 存在，stat 与报告一致（5 files / 40+/11-）✅
- `tmp/dw-smoke-uefi-v159.out.clean`：模块序列无 usb-storage、DiskWipe Tool 1.5.9、三盘 SYS-DATA-UNK、OK x3、Exited、`Log kept in memory`、`WARN: could not write log to USB`、无 Cleanup log saved to USB ✅
- `tmp/novid-v159.out`：blind mode + serial 全诊断行 + 无 usb-storage ✅（尾部 panic 为无盘既有语义）
- `tmp/dw-smoke-v159.out.clean`：BIOS isolinux 21 项回归 + 降级断言 + `Disks found: 3` ✅
- iso 实测：`output/diskwipe-v1.5.9.iso` 存在（40894464 B≈39M）；解 initrd 实测 **24 个 .ko、usb-storage 匹配 0**（v1.5.8 为 25，少 1 个）✅
- 构建方式 `tmp/build-v159.sh`（wsl.exe 完整路径 + DW_KERNEL_MODE=kylin 等价 build.sh）如实 ✅
- A 脚本 `[5]` 降级实证（U 盘数据区无日志文件）断言存在且合理 ✅

## ⚠️ 无法从 diff 验证
1. **真机根治效果**：Ventoy U 盘（ASolid USB 59GB）现场启动不再停滞——qemu 无法复现，报告 concern 1 已如实声明，需现场确认（唯一真正闭环验证项）。
2. **modules.builtin 内建原文**（hid/usbhid/hid-generic）：diff 中不可见；以运行时注册证据（内核日志）佐证，强度足够但非源码级。

## 结论

**Approved**（1 条 Important 为报告准确性注明，不阻塞合入；I6 环境失败与本次变更无关，本次变更新增断言全部 PASS，initrd 实测无 usb-storage、模块 24、A/B/C 证据属实）
