# Task 7 代码审查 — v1.5.7 去掉设备重试扫描 + menu/lib 加 kmsg 进度 + 写日志前补建 U 盘节点

- 审查对象：commit `cebce11`（parent = `3f70526`，6 files changed, 42 insertions(+), 19 deletions(-)）
- 输入：`task-7-brief.md` / `task-7-report.md` / `tmp/review-pkg-t7.diff`
- 复验方式：git 对象核对（commit 父子、numstat、行尾）、diff 逐行比对（与 `git diff 3f70526 cebce11` 内容一致，仅 hunk 上下文宽度不同）、归档证据抽查（A/B/C serial 输出、keylines、ISO、build 日志）、tests 全量复跑（本机 Git Bash，独立执行）

## Spec 合规：✅

| 约束点 | 结果 |
|---|---|
| 仅改 6 文件（init / lib.sh / menu.sh / VERSION / t3_init.sh / t4_log.sh） | ✅ commit numstat 确认，无越界文件 |
| 禁止改动（wipe.sh、build-lib.sh、isolinux、grub.cfg、embedded-efi.cfg、BOOTX64.EFI、xorriso） | ✅ 未触碰 |
| init 重试段 → `dw_progress "device settle wait (sleep)"` + `sleep 3` | ✅ 代码两行与 brief 原文完全一致；注释语义一致（仅加 "# 4)" 前缀并折行） |
| lib.sh 顶部新增 `dw_progress` 共用函数 | ✅ 定义位于接缝变量之前，内容与 init 定义完全一致（init/menu/lib 三方共用） |
| `dw_save_log_to_usb` 开头 `"$TIMEOUT_BIN" 5 mdev -s 2>/dev/null` | ✅ 位于文件存在性检查之后、候选枚举之前；TIMEOUT_BIN 接缝先于函数定义（运行时解析）；失败静默（返回码忽略），枚举失败走既有降级路径 |
| menu.sh 仅加 5 行进度 | ✅ 恰好 5 行（menu.sh started / enumerating disks / scanning disk types / wiping disks / saving log to USB），位置符合 brief，交互逻辑/输出零改动（diff 中 menu.sh 仅 8 行新增 = 5 进度 + 3 注释） |
| VERSION 1.5.6 → 1.5.7 | ✅ |
| tests 适配 | ✅ t3：mdev 计数 4→1（I1/I2）+ 新增 `check_kmsg 'device settle wait (sleep)'`；t4：L3 假 mdev + `check_cmds 'mdev -s'` 断言，注释同步 |
| POSIX/ash、中文注释、LF 行尾 | ✅ 提交内容 6 文件全部 LF（git 对象核实无 CR）；`dash -n` 0 错误（报告声称，见 ⚠️ 无法复验项）；qemu A/B/C 全程 busybox ash 实测跑通（serial 输出可证） |

## 问题列表

### Critical
无。

### Important
无。

### Minor
1. **报告断言计数与归档脚本不一致**：报告称 A=28 项、C=27 项（21 回归+6 新增）；归档脚本实际 A=29 项（25 chk + no-non-ast-video + no-ERROR + no-Only-boot-media + USB 落盘证据）、C=28 项（24 chk + 4 项 if-grep 反向断言）。PASS/FAIL 判定行未归档（运行期打到终端），精确计数无法复验，但脚本全部断言内容均可从 serial 日志复验命中（已逐条 grep 核对，全部满足）。仅报告数字出入，不影响实现。
2. **报告 concern #1 表述不全**：qemu B 的「Attempted to kill init!」panic 属实（novid-v157.out 确认：Only boot media found → saving log to USB → panic），机制为 menu.sh 被 exec 为 PID 1、无盘路径 exit 0 后 PID 1 退出触发内核 panic。**A/C 输出尾部同样存在该 panic**（0 退出 → PID 1 退出，60s/39s 处），属既定终止方式且断言在此之前已全部命中——报告只提 B，应说明 A/C 亦如此，属表述细节，非缺陷。
3. **构建证据未完整归档**：`tmp/build-v157.log` 仅记录了首次 `bash build.sh` 失败尝试（Git Bash 解析不了无扩展名 wsl →「未检测到 WSL Ubuntu 发行版」）；成功的 `build-v157.sh`（wsl.exe 完整路径）构建输出未 tee 归档，报告「构建关键行」（kylin 模式、26 个 .ko.xz、isoinfo 校验、dash -n、BOOTX64.EFI PE 校验）无法从留存文件复验（ISO 产物与 1.5.7 版本串已由仓库 VERSION + qemu 实测间接确认）。建议后续 task 构建时 tee 留档。
4. **dw_progress 双份定义**（init 内一份 + lib.sh 顶部一份，内容一致）：init 实际在 source lib.sh 之后才调用 dw_progress，init 内定义对运行无增益，但为 v1.5.6 既有代码且属刻意「init 独立可用」设计，无功能问题，仅提示。

## 报告 concerns 合理性

1. **qemu B panic（既有行为）**：✅ 属实且非本次引入——diff 未改动任何退出路径/退出码；机制与 A/C 尾部一致（PID 1 退出 → panic），novid 断言只看内核启动/init 流程/kmsg 进度，判定 PASS 合理。
2. **wsl 构建方式**：✅ 属实——`build-v157.log` 佐证 Git Bash 对 WindowsApps 无扩展名 `wsl` 的解析失败；`build-v157.sh` 以 `wsl.exe` 完整路径 + WSL 路径显式传参等价执行 `dw_build_iso`，生产 build.sh 未改。
3. **U 盘节点补建残余风险**：✅ 属实且合理——`dw_save_log_to_usb` 开头 mdev 若遇 U 盘 D 状态仍可能挂住，但此时清盘已完成，属 brief 明示可接受，既有降级提示「抄录后断电」兜底。
4. **行尾**：✅ 属实——提交内容 6 文件全部 LF（已核实），工作副本 CRLF 系 autocrlf 转换，不影响产物。

## 报告证据真实性抽查

- `tmp/dw-smoke-uefi-v157.out(.clean)`（A）：六条 kmsg 进度行齐全（device settle wait / menu.sh started / enumerating disks ×2 / scanning disk types ×2 / wiping disks / saving log to USB）+ 全流程（DiskWipe Tool 1.5.7、三盘 SYS/DATA/UNK、OK ×3、Exited、Log kept in memory、Cleanup log saved to USB）✅
- `tmp/novid-v157.out`（B）：serial 兜底 + Linux 4.19.90 启动 + 全 init 进度行至 menu.sh started + Only boot media + panic ✅
- `tmp/dw-smoke-v157.out.clean`（C）：ISOLINUX 6.04 / vmlinuz+initrd 加载 / 1.5.7 横幅 / Disks found 3 / OK ×3 / Exited / Cleanup log saved to USB / 六条进度行全部出现 ✅
- `tmp/dw-smoke-v157-keylines.txt`：C 的 USB 数据区日志落盘内容（version 1.5.7、三盘、OK ×3、session end）✅
- `diskwipe-iso/output/diskwipe-v1.5.7.iso` 存在（40,894,464 B）✅
- **tests t1-t6 全量复跑（本机独立执行）**：t1 89 / t2 61 / t3 68 / t4 47 / t5 37 / t6 77 全部 PASS、失败 0、run-all.sh 退出 0；t3 新增断言「设备扫描应仅执行 1 次（v1.5.7 去掉重试轮）」与「kmsg 设备稳定等待进度行」、t4 新增断言「写日志前应先补建 U 盘设备节点（mdev -s）」均 PASS ✅

## ⚠️ 无法从 diff/归档验证

1. **构建校验明细**（内核模式 kylin、26 个 .ko.xz、isoinfo 校验全过、`dash -n` 0 错误、BOOTX64.EFI PE 有效）：成功构建（wsl.exe 路径）无归档日志，无法复验；仅能确认 ISO 产物存在 + 仓库 VERSION=1.5.7 + qemu 实测版本串 1.5.7。
2. **A/B/C 的 PASS 计数与 verdict 行**：判定输出运行期打到终端未归档；已用 serial 日志逐条 grep 断言内容 + tests 复跑弥补。
3. **qemu 三场景复跑本身**：需 WSL/Linux + sudo loop 设备，本环境不可复跑，依赖归档 serial 输出（内容可信、自洽）。

## 结论

**Approved** — 实现与 brief 精确一致（含禁止改动约束），代码质量过关（dw_progress 三处调用一致、mdev 补建位置/静默/降级正确、menu 进度行不干扰交互、tests 适配正确），报告 concerns 合理，归档证据抽查与 tests 独立复跑全部吻合。仅 4 项 Minor（断言计数出入、panic 表述不全、构建日志未归档、dw_progress 双份定义提示），均不影响交付，无需返工。
