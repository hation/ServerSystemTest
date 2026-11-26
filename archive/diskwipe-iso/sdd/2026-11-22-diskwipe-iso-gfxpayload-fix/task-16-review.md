# Task 16 Review — v1.5.16 mpt3sas max_queue_depth=10000

- 审查对象：commit `ec74487`（父提交 `9cd973b`，单 commit 线性，无 merge）
- 审查方式：只读；`git diff 9cd973b ec74487` + 源码/测试细读 + 证据产物抽查 + WSL 实跑 tests 复验
- 审查日期：2026-11-25

## Spec 合规：✅

- 改动文件恰为 3 个：`diskwipe-iso/src/init`、`diskwipe-iso/VERSION`、`diskwipe-iso/tests/t3_init.sh`（+29/-7），与 brief「只改 src/init 的 mpt3sas 加载分支 + VERSION + tests 适配」精确一致；**menu.sh/lib.sh/wipe.sh/build-lib.sh/isolinux/grub.cfg/embedded/BOOTX64.EFI 均未动**（git diff --name-status 实证）。
- mpt3sas 分支位于白名单加载循环**内**（`for im in $DRIVE_MODULES`，init 87-97 行）——正确位置；其余模块 `timeout 5 modprobe "$im"` 形态与 v1.5.15 完全不变。
- VERSION `1.5.15` → `1.5.16` ✅；commit message 与 brief 指定文案逐字一致 ✅。
- 分支语义：错误静默（`2>/dev/null`）+ WARN 继续 + `timeout 5` 兜底全部保留（brief 的裸 snippet 省略了 timeout/WARN，但 brief 明确「保持现有循环结构」，实现按真实循环语义保留——符合意图）。
- 验证：t3 99 项（含 3 处 mpt3sas 分支断言）+ t1-t6 全 PASS（WSL 实跑复验，见下）；qemu A/B/C 日志（run-a/b/c-v1516.log）与报告描述一致。

## 代码质量：✅

- `timeout 5 modprobe mpt3sas max_queue_depth=10000 2>/dev/null || echo "WARN: module mpt3sas load failed/timed out"`：POSIX/ash 兼容；`if/else` 分支无嵌套破坏；WARN 文案与 generic 形态一致。
- busybox modprobe 参数透传：busybox `modprobe MODULE [OPTIONS]` 标准语法支持模块参数透传；qemu 内核日志 `mpt3sas version 27.100.00.00 loaded`（run-a [35.714827]，时间戳位于 mpt3sas 加载步骤 35.56 与 megaraid_sas 35.82 之间，时序吻合）且无 `unknown parameter` 告警——参数被模块接受。
- tests 适配正确性（t3_init.sh）：
  - 假 modprobe `$1` → `$*`：非 mpt3sas 模块记录行仍为 `modprobe <name>`（无参数），不影响既有 `check_cmds "modprobe $m"` 整行断言；mpt3sas 分支记录 `modprobe mpt3sas max_queue_depth=10000`。
  - I1：`check_cmds` 用 `grep -Fxq` 整行匹配，`modprobe mpt3sas` 不会误配带参整行 → 分支断言唯一且精确；新增 xtrace 载荷断言（`check_kmsg` → `check_file` grep -Fq 子串，可命中 `+ timeout 5 modprobe mpt3sas max_queue_depth=10000 ...`）。
  - I2（mpt3sas 加载失败）：`modprobe.fail` 按 `$1` 判失败，mpt3sas 分支 `$1` 仍为 mpt3sas → 失败命中正确；失败形态断言同样带参数。
  - I5（ky10）：分支在 ky10 清单同样生效（uname 假件分支）。
- **实跑复验**（WSL bash，非 Git Bash）：t3 单独跑 99 PASS；`run-all.sh` t1 89 / t2 93 / t3 99 / t4 50 / t5 37 / t6 77，全部 ALL PASS——与报告数字完全一致。

## 报告 Concerns 合理性：✅

- 「qemu 无法覆盖 mpt3sas 真机疗效」：成立且表述准确——qemu 三盘为 virtio、无 mpt3sas 硬件，分支断言退化为「构建产物（initrd/init 解包 grep 参数形态）+ 内核日志 mpt3sas version loaded（证明分支执行、驱动加载成功）」；与 brief 注「真机验证由用户执行」一致。
- 「max_queue_depth 为 mpt3sas 标准 module_param」：属实（Linux 内核 mpt3sas 驱动标准参数，默认 32455，可调），Kylin 4.19 mpt3sas 27.100.00.00 参数名一致。

## 证据真实性抽查：✅

- `tmp/run-a-v1516.log`：全流程 PASS 行（DiskWipe Tool 1.5.16、三盘、OK x3、Exited、日志降级）+ [3b] init 分支上下文（87-95 行源码 + 内核日志 `mpt3sas version 27.100.00.00 loaded`）——真实且时序自洽。
- `tmp/run-b-v1516.log`：无盘 retry 1/11 共 4 条、qemu exit=124、无 reboot 字符串、[3c] 分支断言——真实。
- `tmp/run-c-v1516.log`：BIOS ISOLINUX 21 项 + 1.5.16 + [3b] 断言——真实。
- `tmp/build-v1516.log`：WSL Kylin 构建，`/diskwipe.version = 1.5.16`、dash -n 0 错误、24 个未压缩 .ko、无 usb-storage.ko——真实。
- 留档脚本齐全：`tmp/dw-smoke-uefi-v1516.sh`（A）、`tmp/novid-v1516.sh`（B）、`tmp/dw-smoke-v1516.sh`（C）、`tmp/build-v1516.sh`；产物 `output/diskwipe-v1.5.16.iso` 存在（40,894,464 B ≈ 39M）。

## 问题列表

- **Critical**：无。
- **Important**：无。
- **Minor**（brief 侧表述不一致，非实现缺陷）：
  1. brief 代码 snippet 用 `$m` 作循环变量名，实际 init 循环变量为 `im`——实现正确使用 `$im`，无影响。
  2. brief snippet 省略 `timeout 5 / 2>/dev/null / WARN` 后缀，实现按「保持现有循环结构」保留——符合意图，反而更稳妥。

## ⚠️ 无法从 diff/产物验证项

- **max_queue_depth=10000 对真机（海光高核数服务器）scsih_probe 的实际疗效**——只能真机验证（与 brief/report 一致，用户执行）。
- qemu 中参数「确实生效」仅有间接证据（无 unknown parameter 告警 + 参数为标准 module_param）；无 mpt3sas 硬件故无法观测控制器行为。
- WSL tests 与 qemu 均未覆盖 busybox modprobe 在真实 initramfs 环境的参数透传行为本身（qemu 内核日志已是最强可得证据）。

## 结论：Approved

实现精确符合 brief，无越界改动，代码质量良好，tests 适配正确且实跑全 PASS，报告证据真实可信。真机疗效验证留待用户执行。
