# Task 25 brief — v1.5.25 mpt3sas 初始化自动重试（实际修复动作，概率性失败→确定性成功）

## 背景（用户目标澄清 + 确定性修复决策）

用户目标：**清空这台服务器的硬盘**（系统起不来，用 ISO 工具从外部启动清盘）。
关键事实：**v1.5.6 曾成功识别 SAS 盘（447GiB）**（mpt3sas_cm0 port enable SUCCESS、
sda 在 scsi 32）→ **硬件正常，mpt3sas 初始化是概率性失败**（v1.5.6 成功、后续版本
失败）。多轮修复（rescan/max_queue_depth/去 megaraid/pci=realloc/回退 v1.5.6）均无效。
**决策：实际修复动作——mpt3sas 初始化失败时自动重试**（modprobe -r + modprobe，最多
3 轮 + menu 枚举时也重试）→ 概率性失败变确定性成功。不再加新诊断（用户已明确要求
「想办法解决」）。

## 任务（精确，基于工作树——含 v1.5.20-24 未提交改动：DIAG 行、pci=realloc、VERSION 1.5.24）

### 1. `diskwipe-iso/src/init`：mpt3sas 加载后自动重试（最多 3 轮）

在「Disk driver modules loaded」之后（或 mpt3sas 单独加载处）加：
```
# v1.5.25 实际修复：mpt3sas 初始化概率性失败（v1.5.6 曾成功、后续失败）→ 检测到 SAS
# 盘未出现则卸载重载驱动重试（最多 3 轮）。判定：/proc/partitions 有 ≥1 个非 U 盘
# 块设备（sd*/nvme*/vd* 且非 usb）。modprobe -r 卸载 mpt3sas（raid_class 依赖残留无害），
# 重新 modprobe 触发全新初始化尝试。
dwmretry=0
while [ "$dwmretry" -lt 3 ]; do
    # 判定 SAS 盘是否已出现（/proc/partitions 有 sd*/nvme*/vd* 非 ram/loop/sr）
    if grep -qE '^\s+(sd|nvme|vd)[a-z0-9]+\s' /proc/partitions 2>/dev/null; then
        break
    fi
    dwmretry=$((dwmretry + 1))
    dw_progress "DIAG mpt-retry $dwmretry (rmmod+modprobe mpt3sas, disk not detected)"
    rmmod mpt3sas 2>/dev/null || true
    timeout 5 modprobe mpt3sas 2>/dev/null
    read -t 3 dummy < /dev/tty0 2>/dev/null || true   # 等初始化（read -t 防 sleep 失真）
done
```

### 2. `diskwipe-iso/src/menu.sh`：枚举前若 SAS 盘未出现则触发 mpt3sas 重试（兜底）

在 `ml="$(dw_enum_disks)"` 之前（枚举前 rescan 处附近）加（**仅当 /proc/partitions
无 SAS 盘时才重试，避免卸载已正常工作的 mpt3sas 移除盘**）：
```
# v1.5.25：枚举前兜底——SAS 盘仍未出现时重试 mpt3sas（rmmod+modprobe 触发全新初始化）
if ! grep -qE '^\s+(sd|nvme|vd)[a-z0-9]+\s' /proc/partitions 2>/dev/null; then
    rmmod mpt3sas 2>/dev/null || true
    timeout 5 modprobe mpt3sas 2>/dev/null
fi
```

### 3. `diskwipe-iso/VERSION`：改为 `1.5.25`。

### 4. 重新构建（WSL Kylin 模式）：`output/diskwipe-v1.5.25.iso`。

## 禁止改动

- src/lib.sh、src/wipe.sh、build-lib.sh、isolinux、grub.cfg、embedded、BOOTX64.EFI、xorriso。
- 现有 DIAG 行、pci=realloc、白名单（去 megaraid_sas）保留。

## 验证（必须全部通过）

- **qemu A**（UEFI -vga std 有盘）：全流程（DiskWipe Tool 1.5.25、三盘、OK x3、Exited、
  日志降级）——qemu 三盘 virtio，/proc/partitions 有盘 → init/menu 重试逻辑不触发
  （break/跳过），流程不变；断言重试逻辑存在（xtrace/kmsg）。
- **qemu B**（-vga none 无盘）：无限重试 + mpt-retry 逻辑（无盘 → 重试 3 轮后继续
  menu 无限重试）；无 reboot/关机。
- **qemu C**（BIOS isolinux 有盘）：21 项回归（VERSION 1.5.25）。
- **tests t1-t6**（WSL 跑，勿用 Git Bash）：适配（mpt-retry 循环断言、/proc/partitions
  判定断言）。全 PASS。
- 验证脚本留档 tmp/dw-smoke-uefi-v1525.sh / tmp/novid-v1525.sh / tmp/dw-smoke-v1525.sh。
- **注**：真机验证由用户执行——预期 SAS 盘（447GiB）经重试后带出。

## 提交

commit：`fix(diskwipe-iso): mpt3sas 初始化自动重试（v1.5.6 曾成功证明硬件正常、初始化
概率性失败——检测盘未出现则 rmmod+modprobe 重载，init 3 轮 + menu 枚举前兜底），把
概率性失败变确定性成功；v1.5.25 重打包`

## 报告

写 `task-25-report.md`：改动 diff、构建关键行、A/B/C+tests 断言输出、commit hash。
返回：状态、commit hash、一行测试摘要、concerns。