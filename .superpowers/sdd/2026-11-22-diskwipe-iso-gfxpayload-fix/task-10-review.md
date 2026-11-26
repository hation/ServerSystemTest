# Task 10 代码审查 — v1.5.10（settle wait sleep 10 + 无盘重试/reboot）

审查对象：commit `f3e100e`（BASE `d7da880`），diff 见 `tmp/review-pkg-t10.diff`
审查方式：只读；比对 brief/报告/diff、抽查代码现状、git 提交、tests 日志与 tmp 证据、重跑产物自检。

## Spec 合规：✅

- **init**：`sleep 3 → 10` + brief 指定注释（mpt3sas 14.47s 才加载、SAS 盘扫描需数秒、U 盘不绑定无 I/O 阻塞风险）——已精确落地（init 109-113 行），头注释同步。✅
- **menu.sh**：无盘路径与 brief 精确代码逐行一致（`dwnoretry=0` 在 `while :` 前、`+1`、`-le 3`、`sleep 5`+`continue`、3 轮后 `sleep 10`+`reboot`）；`reboot` 用 busybox reboot（产物自检 `bin/reboot -> busybox` + `--list` 含 reboot，已重跑确认）。交互逻辑其余零改动——`git diff d7da880 f3e100e` 确认 menu.sh 仅动无盘 if 块与注释。✅
- **VERSION** `1.5.9 → 1.5.10` ✅。
- **禁止改动清单零触碰**：diff 仅 5 文件（VERSION、src/init、src/menu.sh、tests/t2_menu.sh、tests/t3_init.sh；65+/17-，与报告一致）；lib.sh/wipe.sh/build-lib.sh/isolinux/grub.cfg/embedded/BOOTX64.EFI/xorriso 零改动。✅
- **验证**：A/B/C + tests t1-t6（418 项）全 PASS，三个验证脚本与产物留档齐全；commit message 与 brief 一致。✅

## 问题列表

- **Critical**：无
- **Important**：无
- **Minor**：
  1. **reboot 失败后的 fallthrough 语义**：`reboot` 为无盘块末语句，失败返回后 menu 落入正常列盘流程；此时 `dwnoretry` 已 >3，后续每轮循环不再回 ≤3 重试而直接 sleep 10+reboot（直至用户输入）。真机 reboot 成功即终止，仅极端失败路径——与 brief 精确代码一致（非实现偏差），report concern 3 已声明可接受。
  2. **M6 测试的隐性流程依赖**：`run_menu` 无超时兜底，M6 靠「假 reboot 返回 → 落入列盘流程 → 读入 '0' 退出」收尾（`check_rc 0`、`check_cmd_count 'sleep 10' 1` 均依赖此流程）。当前断言经推演与实测（t2 73 项 0 失败、M6 8 断言全 PASS）自洽；但若未来无盘路径在 reboot 后改为 exit 或死循环，M6 会挂起。建议在用例注释中显式说明该依赖（可选改进，不阻塞）。
  3. **brief 预期与实测小出入**：brief 预测「qemu 内 reboot 会触发重启」，实测 TCG 下未真正重启（timeout 收尾）——report 已如实披露并附受控实验证据（dbg2-sleep-pid1.sh），满足 brief 兜底条款「timeout 收尾可接受」。

## 报告 concerns 合理性

- **concern 1（qemu TCG 两工件）**：实锤证据吻合。`novid-v1510.out` 中 retry 间隔仅 ~0.25-0.35s（32.099→32.356→32.804→33.107→33.656→33.919→34.806），印证 TCG 时钟工件；428 行 rebooting in 10s 后 437/443 行出现幻影盘 `Disks found: 1 ()` / `1 /dev/ UNK`（lsblk 读损坏 /sys），452 行 timeout 收尾——与「reboot 返回后部分关机路径」描述完全一致。✅
- **concern 2（真机验证前提）**：合理且必要——qemu 无法复现 SAS 扫描延迟，sleep 10+重试 3 轮的设计收益只能在现场确认。✅
- **concern 3（fallthrough 兜底）**：合理；该行为恰在 B 的 qemu 工件中被验证（reboot 返回后 menu 健康继续列盘、无 panic）。✅
- **concern 4（LF 行尾）**：抽查 `git show f3e100e:.../menu.sh|grep -c $'\r'`=0、init=0；dash -n 对两文件通过。✅

## 证据真实性（抽查）

- **产物自检重跑**（`tmp/chk-v1510-initrd.sh`，WSL 实跑）：isoinfo rc=0、`bin/reboot -> busybox`、init 113 行 `sleep 10`、menu 78/101-104/110 行无盘路径、`diskwipe.version=1.5.10`、busybox `--list` 含 reboot——全部通过。✅
- **A 输出**（dw-smoke-uefi-v1510.out.clean）：1.5.10 横幅、三盘 OK x3、Exited.、WARN log 降级、无 ERROR/无 Only boot media。✅
- **B 输出**（novid-v1510.out）：retry 1/3..3/3、rebooting in 10s、无 `Kernel panic`。✅
- **C 输出**（dw-smoke-v1510.out.clean）：ISOLINUX 6.04、三盘 OK x3、Exited.。✅
- **tests 日志**（tests-v1510-runall.log）：t1 89 / t2 73（M6 7 项可见 + rc 项）/ t3 92（I1「settle wait 应等待 10s」PASS）/ t4 50 / t5 37 / t6 77，结尾「全部测试: ALL PASS」；M6 断言行与推演逐一对应。✅
- **构建日志**（build-v1510.log）：kylin 模式、内核 4.19.90-89.11.v2401.ky10、busybox applet 272、isoinfo 校验通过（含 initrd 无 usb-storage.ko）。✅
- commit 统计与报告「5 files, 65+, 17-」一致；`diskwipe-iso/output/diskwipe-v1.5.10.iso` 存在。✅

## ⚠️ 无法从 diff 验证

1. **qemu A/B/C 完整执行过程**：仅核对了留档输出产物与日志，未在本环境重跑 qemu（耗时且依赖 WSL/TCG 环境）；断言脚本本身（dw-smoke-uefi-v1510.sh / novid-v1510.sh / dw-smoke-v1510.sh）未逐行复核。
2. **真机行为**（海光服务器 + Ventoy）：SAS 盘首轮枚举即就绪、无盘自动 reboot 回 Ventoy 不 panic——report concern 2 已明确为现场验证前提。
3. **tests 全量重跑**：依赖留档的 tests-v1510-runall.log（已抽查全部关键断言行与汇总行），未在本次审查中重跑。

## 结论

**Approved**

代码与 brief 精确一致、禁止清单零越界、无盘重试/reboot 计数逻辑正确（while 前初始化、≤3、continue 回枚举）、busybox reboot 可用（自检重跑证实）、POSIX/ash 语法通过（dash -n）、tests 适配正确（M6 推演自洽 + 实测全过）、报告 concerns 全部有证据支撑。仅 3 条 Minor 观察，均不阻塞合并。
