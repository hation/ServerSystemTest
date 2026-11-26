# Task 23 brief — v1.5.23 内核参数 pci=realloc（修复 BAR13 failed to assign io）

## 背景（真机 DIAG pci 决定性证据——真正根因）

v1.5.22 真机 DIAG pci 决定性错误：
```
0000:80:05.2: BAR13: failed to assign io size 0x1000
0000:83:01.0: BAR13: failed to assign io size 0x1000
0000:85:01.0: BAR13: failed to assign io size 0x1000
```
**SAS 控制器的 PCI I/O BAR 分配失败**（BAR13 failed to assign io）→ 设备无法正常
初始化 → mpt3sas probe 失败（无 scsi_host）→ SAS 盘不识别。**根因 = PCI I/O 资源
分配失败**（解释：v1.5.6 碰巧分配成功、后续碰巧失败；rescan/max_queue_depth/去
megaraid_sas 均非根因）。**Linux 标准修复 = 内核参数 `pci=realloc`**（允许内核重新
分配 PCI 资源，解决 BAR 分配失败）。

## 任务（精确，基于 HEAD=7ed5f40；工作树可能含 v1.5.20-22 未提交 DIAG 改动）

### 1. 内核命令行加 `pci=realloc`
- `diskwipe-iso/` 引导配置：**isolinux.cfg** 的 APPEND 行 + **grub.cfg**（UEFI）的
  linux 行，各加 `pci=realloc`（保留现有 console=tty0 console=ttyS0,115200n8 参数）。
- 若引导配置在 build-lib.sh 内动态生成（dw_write_bootloader 等），在该处加；
  先 grep 确认 pci=realloc 无重复、参数拼接到 APPEND/linux 行。

### 2. `diskwipe-iso/VERSION`：改为 `1.5.23`（若工作树为 1.5.20-22 则直接 1.5.23）。

### 3. 重新构建（WSL Kylin 模式）：`output/diskwipe-v1.5.23.iso`。
**关键**：isoinfo 校验 isolinux.cfg 与 grub.cfg 的 linux/APPEND 行含 `pci=realloc`。

## 禁止改动

- src/menu.sh（DIAG 行保留，不改）、src/init、src/lib.sh、src/wipe.sh、embedded、
  BOOTX64.EFI、xorriso 打包参数、白名单（去 megaraid_sas 保留）。

## 验证（必须全部通过）

- **qemu A**（UEFI -vga std 有盘）：全流程（DiskWipe Tool 1.5.23、三盘、OK x3、Exited、
  日志降级）——pci=realloc 对 qemu 无副作用；断言 grub.cfg linux 行含 pci=realloc。
- **qemu B**（-vga none 无盘）：无限重试 + DIAG 行；无 reboot/关机。
- **qemu C**（BIOS isolinux 有盘）：21 项回归（VERSION 1.5.23）+ 断言 isolinux.cfg
  APPEND 行含 pci=realloc。
- **tests t1-t6**（WSL 跑，勿用 Git Bash）：适配（pci=realloc 断言）。全 PASS。
- 验证脚本留档 tmp/dw-smoke-uefi-v1523.sh / tmp/novid-v1523.sh / tmp/dw-smoke-v1523.sh。
- **注**：真机验证由用户执行——预期 BAR13 failed to assign io 消失、mpt3sas 创建
  scsi_host、SAS 盘（447GiB）带出。

## 提交

commit：`fix(diskwipe-iso): 内核参数 pci=realloc（真机 DIAG pci 证实 BAR13 failed to
assign io——SAS 控制器 I/O 资源分配失败致 mpt3sas probe 失败、盘不识别；Linux 标准
修复允许内核重分配 PCI 资源）；v1.5.23 重打包`

## 报告

写 `task-23-report.md`：改动 diff、构建关键行（isolinux.cfg/grub.cfg 含 pci=realloc
证据）、A/B/C+tests 断言输出、commit hash。返回：状态、commit hash、一行测试摘要、
concerns。