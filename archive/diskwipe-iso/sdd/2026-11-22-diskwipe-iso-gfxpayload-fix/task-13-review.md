# Task 13 审查报告 — v1.5.13 去掉无盘自动 reboot/关机（安全第一）+ 缩短等待

- 审查对象：commit `8d6a538`（相对 BASE `4c22a7f`，一次 commit，5 文件 +137/-73）
- 审查方式：只读。diff 复查（review-pkg-t13.diff + git 补齐）、当前工作树核对、qemu 证据文件抽查（novid-v1513.out / dw-smoke-uefi-v1513.out.clean / dw-smoke-v1513.out.clean）、产物核对、README 抽查。
- 审查日期：2026-11-25

## Spec 合规：✅

逐项核对 brief：

1. **src/menu.sh 无盘路径**：✅ 精确符合 brief 示例代码。`if [ -z "$ml" ]` 分支现为：`dwnoretry` 计数 → `dw_log "No wipable disks found yet (retry $dwnoretry). Retrying every 5s... (you may power off anytime)"` → `dw_progress "no disks, retry $dwnoretry (sleep 5, never auto poweroff/reboot)"` → `sleep 5` → `continue`。`dwnoretry ≤6 限制`、`sleep 10`、`reboot -f`、`sleep 2`、fallthrough（`reboot ineffective, re-enumerating`）全部删除。
2. **无盘路径彻底无 reboot/关机**：✅ 全文件 grep `reboot|poweroff|关机|shutdown|sleep 10|sleep 2`——无盘分支内零残留；剩余提及均为：历史注释、枚举**失败**（lsblk 两次超时）路径 `ERROR: disk scan failed. You may power off or reboot safely.`（spec 要求保持原样）、0 退出成功提示 `Exited. You may power off or reboot after done.`（交互契约既有行为）。无盘路径**永不 exit、永不 reboot/关机**，无限重试。
3. **src/init settle wait**：✅ `sleep 25` → `sleep 10`（124 行），注释同步 v1.5.13 语义。
4. **VERSION**：✅ `1.5.13`。
5. **tests 适配**：✅ t2_menu.sh M6 重写（无限重试断言）、t3_init.sh I1（sleep 10）。详见代码质量节。
6. **禁止改动**：✅ `git show 8d6a538 --stat` 仅 5 文件（VERSION、init、menu.sh、t2_menu.sh、t3_init.sh）；lib.sh / wipe.sh / build-lib.sh / isolinux / grub.cfg / embedded / BOOTX64.EFI / xorriso 零触碰；工作树 tracked 文件无未提交修改。枚举失败 ERROR 路径保持原样。
7. **构建/产物**：✅ `output/diskwipe-v1.5.13.iso` 存在，40894464 字节（与报告一致）；build-v1513.sh 等价 `build.sh kylin` 模式。

## 代码质量：✅

- **无限重试逻辑**：`dwnoretry` 仅在 while 循环前初始化、每轮 +1 仅作日志计数；`sleep 5` + `continue` 构成无限循环，永不 exit/reboot；盘就绪即落入正常列盘段（交互逻辑其余零改动）。符合"用户可随时断电"安全设计。
- **POSIX/ash**：`dwnoretry=$((dwnoretry + 1))`、`[ -z "$ml" ]`、`continue` 均 POSIX；无 bash 专属语法。中文注释、LF（git 无行尾警告）。
- **tests M6 断言正确性**：假 lsblk 计数切换（enum.count 前 3 次返回无盘表、≥4 返回就绪表）与断言自洽——`sleep 5` 恰 3 次、`check_not_cmds 'sleep 10'/'sleep 2'/'reboot'`、retry 1/3 消息、盘就绪后正常列盘、`DiskWipe Tool` 恰 1 次、0 退出、无 wipefs/umount。helper（check_cmd_count/check_not_cmds/check_count）均存在于 t2_menu.sh 内。
- **tests I1**：断言 `sleep 10`，注释同步。✅
- **报告 vs 实现一致性**：报告改动摘要与实际 diff 完全一致（含注释更新、dwnoretry 初始化注释、while 循环注释）。

## 报告 concerns 合理性：✅（均合理，细节见 Minor）

- qemu sleep 失真：属实——novid-v1513.out kmsg 时间戳显示每轮约 0.9-1.0s（非 5s），确为 qemu/Kylin 虚拟时钟特性，非本任务引入；真机 busybox sleep 为标准值，不影响行为正确性。
- usb-kbd 改 i8042：属实且合理——dw-smoke-uefi-v1513.sh 明确注释 xhci usb-kbd 偶发 `couldn't allocate usb_device` 丢键注入，改经 i8042 PS/2 sendkey（UEFI 模式 PS/2 存在）；属验证脚本环境修正，不触及产品代码。
- README 过时：属实——148 行 `Only boot media found`、179 行"提示并退出"仍为旧文案（v1.5.10+ 行为已变）；超出本任务范围未改，合理。

## 问题列表

- **Critical**：无
- **Important**：无
- **Minor**：
  1. **审查输入 diff 不完整**：`tmp/review-pkg-t13.diff` 仅含 3 文件（VERSION/init/menu.sh），缺 tests 两文件（t2_menu.sh 131 行、t3_init.sh 17 行，共 +148/-24）。已从 git 补齐验证，实现与报告 5 文件一致，非实现缺陷。
  2. concern 1 数值略有出入：报告称"每轮约 1.5s / 150s 内 retry 1→170"，但 kmsg 时间戳推算约 0.9-1.0s/轮（retry 1 @35.96s → retry 16 @50.46s），150s 内约 ~130-150 轮。不影响结论（无限重试铁证成立：retry 持续递增远超 6 轮上限）。
  3. README 过时范围略大于报告所述：除 148/179 行外，154 行"无盘可清时直接提示并退出"亦为旧文案。
  4. tests 全 PASS 无输出留档（详见下）。

## ⚠️ 无法从 diff 验证项

- **qemu B exit=124**：`qemu exit=$QE` 打印在脚本 stdout（终端），serial file（novid-v1513.out）不含此行，无 stdout 存档。间接证据充分：novid-v1513.out 中仅 1 次 `Linux version`（无重启二次启动痕迹）、全文件无 `reboot -f`/`rebooting in 10s`/`no disks after retries`/`No wipable disks found after 6 retries` 字符串、retry 计数递增至 ≥16（远超 v1.5.12 的 6 轮上限）。
- **tests t1-t6 全 PASS（77 项）**：tmp 无 v1513 版 run-all 输出留档（仅 v1510 旧版日志），依赖报告声称。但 M6/I1 断言代码已静态验证正确，且断言逻辑与实现语义一致。
- **iso 内嵌 init/menu.sh 生效**：由 qemu A/B/C 实证输出间接支持（B 输出显示 settle 后 menu 无盘无限重试循环真实运行；A/C 输出 1.5.13 全流程正常）。

## 结论：**Approved**

实现精确符合 spec（无盘无限重试、永不关机/重启、settle wait 10、v1.5.13、tests 适配、禁止改动零触碰），代码质量与证据真实性抽查均无 Critical/Important 问题，Minor 均为审查输入/文档/数值口径层面的非阻断项。
