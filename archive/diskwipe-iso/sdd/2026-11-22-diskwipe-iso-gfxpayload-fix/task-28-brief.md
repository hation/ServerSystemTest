# Task 28 brief — v1.5.28 PCI 重新扫描（echo 1 > /sys/bus/pci/rescan 带出未枚举的 SAS 控制器）

## 背景（DIAG SAS 决定性证据）

v1.5.27 真机 `DIAG SAS=` **完全为空** → **系统里无任何 LSI/Broadcom（vendor 0x1000）
SAS 控制器** → SAS 控制器**不在内核 PCI 总线枚举里**（v1.5.6 时在、mpt3sas 找到并
初始化；现在不在）→ mpt3sas 加载但无设备可绑定（无 scsi_host）→ 盘不识别。
**不是驱动问题、不是 BAR13（HPE 无害）**。**修复：软件重新枚举 PCI**——
`echo 1 > /sys/bus/pci/rescan`（触发内核重新扫描 PCI 总线，带出未枚举设备）→
mpt3sas 重载绑定新出现的 SAS 控制器 → 盘带出。这是针对「设备未枚举」的确定性动作
（非概率重试）。

## 任务（精确，基于工作树——含 v1.5.20-27 未提交改动；pci=realloc,nocrs 已加）

### 1. `diskwipe-iso/src/init`：mpt3sas 加载后触发 PCI 重新扫描 + 重载 mpt3sas

在模块加载段（mpt3sas 加载后、ast 显卡前）加：
```
# v1.5.28：SAS 控制器（vendor 0x1000）未被内核 PCI 枚举（DIAG SAS 空）——触发 PCI
# 重新扫描（echo 1 > /sys/bus/pci/rescan）重新枚举总线带出设备，再重载 mpt3sas 绑定
# （initramfs 无 udev，PCI hotplug 事件不自动触发驱动 probe，需重载驱动）。
dw_progress "v1.5.28 pci rescan (re-enumerate SAS controller)"
echo 1 > /sys/bus/pci/rescan 2>/dev/null || true
rmmod mpt3sas 2>/dev/null || true
timeout 5 modprobe mpt3sas 2>/dev/null
```

### 2. `diskwipe-iso/src/menu.sh`：枚举前若 DIAG SAS 仍空则再次 PCI rescan + 重载（兜底）

在枚举前 rescan 处（现有 mpt3sas 重试兜底若存在则替换/保留）加：
```
# v1.5.28：SAS 控制器仍未枚举时（/sys/bus/pci/devices 无 vendor 0x1000）再触发一次
# PCI rescan + 重载 mpt3sas（枚举前兜底，盘就绪后下次枚举即出现）。
if ! grep -ql '^0x1000$' /sys/bus/pci/devices/*/vendor 2>/dev/null; then
    echo 1 > /sys/bus/pci/rescan 2>/dev/null || true
    rmmod mpt3sas 2>/dev/null || true
    timeout 5 modprobe mpt3sas 2>/dev/null
fi
```
（`grep -ql` 检查 vendor 0x1000 是否存在；避免卸载已正常工作的 mpt3sas）

### 3. `diskwipe-iso/VERSION`：改为 `1.5.28`。

### 4. 重新构建（WSL Kylin 模式）：`output/diskwipe-v1.5.28.iso`。

## 禁止改动

- src/lib.sh、src/wipe.sh、build-lib.sh（pci=realloc,nocrs 保留）、isolinux、grub.cfg、
  embedded、BOOTX64.EFI、xorriso、白名单。DIAG 行保留。

## 验证（必须全部通过）

- **qemu A**（UEFI -vga std 有盘）：全流程（DiskWipe Tool 1.5.28、三盘、OK x3、Exited、
  日志降级）——qemu 无 0x1000 设备 → menu 兜底触发 rescan（无副作用）；断言 rescan
  逻辑存在（kmsg/xtrace）。
- **qemu B**（-vga none 无盘）：无限重试 + rescan 兜底 + DIAG；无 reboot/关机。
- **qemu C**（BIOS isolinux 有盘）：21 项回归（VERSION 1.5.28）。
- **tests t1-t6**（WSL 跑，勿用 Git Bash）：适配（pci rescan 断言、vendor 0x1000
  检查断言）。全 PASS。
- 验证脚本留档 tmp/dw-smoke-uefi-v1528.sh / tmp/novid-v1528.sh / tmp/dw-smoke-v1528.sh。
- **注**：真机验证由用户执行——预期 PCI rescan 后 DIAG SAS 非空（SAS 控制器出现）、
  mpt3sas 绑定、盘（447GiB）带出。

## 提交

commit：`fix(diskwipe-iso): PCI 重新扫描（echo 1 > /sys/bus/pci/rescan + mpt3sas 重载）——
真机 DIAG SAS 空证明 SAS 控制器未被内核 PCI 枚举（非驱动/非 BAR13 问题），rescan 重新
枚举带出设备后 mpt3sas 绑定；init + menu 枚举前双兜底；v1.5.28 重打包`

## 报告

写 `task-28-report.md`：改动 diff、构建关键行、A/B/C+tests 断言输出、commit hash。
返回：状态、commit hash、一行测试摘要、concerns。