# Task 19 brief — v1.5.19 去掉 megaraid_sas（mpt3sas 独占控制器，消除竞争根因）

## 背景（联网 + 对照确凿根因）

真机全历程 + 联网（Broadcom/Proxmox/Dell）+ v1.5.6 对照，根因确凿：
- **megaraid_sas 与 mpt3sas 竞争同一 LSI SAS 控制器**（已知问题，需禁用其一）。
- v1.5.6（唯一 SAS 盘识别成功）碰巧 mpt3sas 抢先接管（`mpt3sas_cm0: port enable:
  SUCCESS` + sda 447GiB 在 scsi host 32 = mpt3sas）；后续版本 megaraid_sas 碰巧抢先
  → mpt3sas 无法初始化控制器 → SAS 盘从未创建（lsblk 只有 U 盘）。
- v1.5.6 铁证：盘在 mpt3sas（scsi 32），**需要 mpt3sas、不需要 megaraid_sas**。
- 回退 v1.5.6 配置（v1.5.18）仍失败 → 证实 v1.5.6 成功是碰巧（竞争概率），非配置差异。

**修复 = 去掉 megaraid_sas**（只留 mpt3sas 独占控制器 → SAS 盘确定带出）。

## 任务（精确，基于 HEAD=468a737；v1.5.18 已去掉 max_queue_depth/rescan/rmmod）

### 1. `diskwipe-iso/src/init`：白名单去掉 megaraid_sas
Kylin 驱动加载白名单去掉 `megaraid_sas`（其余不变；mpt3sas 保持正常 modprobe，
无 max_queue_depth 分支——v1.5.18 已恢复默认）。

### 2. `diskwipe-iso/build-lib.sh`：DW_KYLIN_MODULES 白名单去掉 megaraid_sas
（与 init 白名单同步；注释说明 v1.5.19：megaraid_sas 与 mpt3sas 竞争同一 LSI 控制器，
只留 mpt3sas 独占——联网确认 Broadcom/Proxmox/Dell 已知问题。）

### 3. `diskwipe-iso/VERSION`：`1.5.18` → `1.5.19`。

### 4. 重新构建（WSL Kylin 模式）：`output/diskwipe-v1.5.19.iso`。
**关键**：isoinfo 解包校验 initrd **含 mpt3sas.ko、不含 megaraid_sas.ko**，含
usb-storage.ko/uas.ko（保留）。

## 禁止改动

- src/menu.sh、src/lib.sh、src/wipe.sh、isolinux、grub.cfg、embedded、BOOTX64.EFI、xorriso。

## 验证（必须全部通过）

- **qemu A**（UEFI -vga std 有盘）：全流程（DiskWipe Tool 1.5.19、三盘、OK x3、Exited、
  日志降级）——三盘 virtio，megaraid_sas 缺席不影响；断言 initrd 含 mpt3sas.ko、
  不含 megaraid_sas.ko、含 usb-storage.ko/uas.ko。
- **qemu B**（-vga none 无盘）：无限重试 + read -t + menu rescan；无 reboot/关机。
- **qemu C**（BIOS isolinux 有盘）：21 项回归（VERSION 1.5.19）。
- **tests t1-t6**（WSL 跑，勿用 Git Bash）：适配（白名单去 megaraid_sas 断言）。
  全 PASS。
- 验证脚本留档 tmp/dw-smoke-uefi-v1519.sh / tmp/novid-v1519.sh / tmp/dw-smoke-v1519.sh。
- **注**：qemu 无法覆盖 mpt3sas 真机疗效（virtio 盘），真机验证由用户执行。

## 提交

commit：`fix(diskwipe-iso): 去掉 megaraid_sas（与 mpt3sas 竞争同一 LSI SAS 控制器——
联网确认 Broadcom/Proxmox/Dell 已知问题；v1.5.6 盘在 mpt3sas 无需 megaraid_sas），
mpt3sas 独占控制器带出 SAS 盘；v1.5.19 重打包`

## 报告

写 `task-19-report.md`：改动 diff、构建关键行（initrd 含 mpt3sas.ko 不含
megaraid_sas.ko 证据）、A/B/C+tests 断言输出、commit hash。
返回：状态、commit hash、一行测试摘要、concerns。