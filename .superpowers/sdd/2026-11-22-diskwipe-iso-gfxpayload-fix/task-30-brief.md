# Task 30 brief — v1.6.0 恢复 megaraid_sas + 去掉 pci=realloc,nocrs（确定性根因修复）

## 背景（ISO 解包客观对比，非猜测）

对 v1.5.6（唯一成功识别 SAS 盘的版本）与 v1.5.27（失败）的 ISO 做客观解包对比
（`isoinfo -f | grep '\.ko'`），initrd 模块清单**唯一差异**是：

| 模块 | v1.5.6 成功 | v1.5.27 失败 |
|------|:---:|:---:|
| mpt3sas | ✅ | ✅ |
| raid_class（mpt3sas 依赖） | ✅ | ✅ |
| scsi_transport_sas（mpt3sas 依赖） | ✅ | ✅ |
| **megaraid_sas** | **✅** | **❌** |

结论：
- 排除「mpt3sas 依赖缺失」假设（依赖链两边都完整）。
- 推翻「megaraid_sas 与 mpt3sas 竞争」假设（v1.5.6 正是**同时有**两者才成功；
  v1.5.19 基于错误假设去掉 megaraid_sas 后 SAS 盘再未识别）。
- 「回退 v1.5.6」从未真正回退——每次都漏掉 megaraid_sas 这一环。

**根因**：v1.5.19 错误去掉 megaraid_sas。**修复 = 加回 megaraid_sas + 去掉同样基于
错误 BAR13 假设加的 pci=realloc,nocrs**（v1.5.6 内核命令行无此参数）。

## 任务（精确，基于 HEAD=7ed5f40 + 工作树 v1.5.29 未提交改动）

### 1. `diskwipe-iso/src/init`：Kylin 白名单加回 megaraid_sas

第 82 行 Kylin 分支 DRIVE_MODULES，在 `mpt3sas` 后、`virtio_blk` 前加 `megaraid_sas`：
```
DRIVE_MODULES="ahci libahci libata nvme nvme-core mpt3sas megaraid_sas virtio_blk sd_mod usb-storage uas nls_iso8859-1 vfat fat"
```
（**仅加这一个词**；同 v1.5.6 顺序。ubuntu 分支第 58 行的 `uhci/ehci` 等不涉及——
Kylin 模式用第 82 行。注释更新：v1.5.6 成功正是因为同时有 megaraid_sas；v1.5.19
的「竞争」假设被 ISO 解包对比证伪。）

### 2. `diskwipe-iso/build-lib.sh`：DW_KYLIN_MODULES 加回 megaraid_sas

第 79 行，在 `mpt3sas` 后、`virtio_blk` 前加 `megaraid_sas`：
```
DW_KYLIN_MODULES="ahci libahci libata nvme nvme-core mpt3sas megaraid_sas virtio_blk sd_mod usb-storage uas nls_iso8859-1 vfat fat ast"
```
（注释同步更新。）

### 3. `diskwipe-iso/build-lib.sh`：去掉内核参数 pci=realloc,nocrs

- 第 423 行 grub.cfg linux 行：`console=tty0 console=ttyS0,115200n8 pci=realloc,nocrs rdinit=/init`
  → `console=tty0 console=ttyS0,115200n8 rdinit=/init`（回到 v1.5.6）。
- 第 446 行 isolinux.cfg APPEND 行：`console=tty0 console=ttyS0,115200n8 pci=realloc,nocrs initrd=/boot/initrd.img`
  → `console=tty0 console=ttyS0,115200n8 initrd=/boot/initrd.img`。
- 相关注释（409-412、417-418、434-436 行关于 pci=realloc,nocrs 的说明）删除或改为
  简短「v1.6.0：去掉 pci=realloc,nocrs——回 v1.5.6 成功配置（BAR13 为 HPE 无害警告，
  非根因；根因是误删 megaraid_sas）」。
- **校验断言翻转**：grep 搜索 `pci=realloc` 的所有校验（dw_verify_iso 里 ~549/557 行）
  改为「校验内核命令行**不含** pci=realloc」（或删除该断言并说明 v1.6.0 不需该参数）。

### 4. `diskwipe-iso/tests/t2_menu.sh`：M13 断言翻转

grep 搜索 `pci=realloc` 的测试断言（M13 段 ~671 行），改为断言**不含** pci=realloc
（grub.cfg linux 行 / isolinux.cfg APPEND 行为 `console=tty0 console=ttyS0,115200n8`
+ rdinit/initrd，无 pci=realloc）。

### 5. `diskwipe-iso/VERSION`：改为 `1.6.0`。

### 6. 重新构建（WSL Kylin 模式）：`output/diskwipe-v1.6.0.iso`。

## 禁止改动

- 白名单其余模块、src/menu.sh（DIAG/U 盘日志等保留）、src/lib.sh、src/wipe.sh、
  init 其余逻辑（usbhid、mdev、settle wait、exec menu 保留）、引导结构（isolinux/grub/
  embedded/BOOTX64.EFI）、xorriso 打包参数。**只做「加回 megaraid_sas + 去 pci=realloc,nocrs」两件事**。

## 验证（必须全部通过）

- **isoinfo 客观校验**：megaraid_sas.ko 在 initrd（`isoinfo -f | grep -i megaraid` 命中）、
  pci=realloc 不在 grub.cfg/isolinux.cfg 内核命令行。
- **qemu A**（UEFI -vga std 有盘）：全流程（DiskWipe Tool 1.6.0、三盘、OK x3、Exited、
  日志降级）不变。
- **qemu B**（-vga none 无盘）：无限重试无 reboot/关机。
- **qemu C**（BIOS isolinux 有盘）：21 项回归（VERSION 1.6.0）。
- **tests t1-t6**（WSL 跑）：全 PASS（含 M13 翻转断言）。
- 验证脚本留档 tmp/dw-smoke-uefi-v160.sh / tmp/novid-v160.sh / tmp/dw-smoke-v160.sh。

## 提交

commit：`fix(diskwipe-iso): 恢复 megaraid_sas + 去 pci=realloc,nocrs——ISO 解包对比
证明 v1.5.6（成功）vs v1.5.27（失败）唯一模块差异是 megaraid_sas（依赖链完整），
v1.5.19「竞争」假设证伪；一波回到 v1.5.6 成功内核启动配置；v1.6.0 重打包`

## 报告

写 `task-30-report.md`：改动 diff、isoinfo 客观校验证据（megaraid_sas.ko 在 initrd +
无 pci=realloc）、A/B/C+tests 断言输出、commit hash。返回：状态、commit hash、一行测试摘要、concerns。