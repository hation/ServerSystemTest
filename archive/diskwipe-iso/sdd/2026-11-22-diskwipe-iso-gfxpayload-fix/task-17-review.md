# Task 17 review — v1.5.17 恢复 usb-storage/uas + 就绪后卸载

审查基准：Spec `task-17-brief.md`（HEAD=ec74487）↔ 实现 commit `468a737`（diff 5 files, +74/-31）。只读审查，未改代码。抽查证据：`git diff ec74487 468a737`、`git show ec74487:diskwipe-iso/build-lib.sh`、`git show 3f70526`（v1.5.6 白名单）、`tmp/run-a/b/c-v1517.log`、`tmp/dw-smoke-uefi-v1517.sh` [3b]、`output/diskwipe-v1.5.17.iso`、独立复跑 tests。

## Spec 合规：✅（build-lib.sh 断言翻转已核实为必要修正，见下）

| 项目 | 结论 | 说明 |
|---|---|---|
| src/init Kylin 白名单加回 usb-storage + uas | ✅ | ky10 分支 `DRIVE_MODULES="… sd_mod usb-storage uas nls_iso8859-1 vfat fat"`，与 v1.5.6（3f70526）逐字一致（git 已核实） |
| src/init 就绪后卸载 | ✅ | `rmmod usb-storage uas 2>/dev/null \|\| true` 位于 sleep 10（settle wait）之后、exec menu.sh 之前（init 第 143→150→154 行），位置符合 brief；卸载失败静默容忍（`\|\| true`） |
| mpt3sas max_queue_depth 分支 | ✅ | init 第 97-98 行 `timeout 5 modprobe mpt3sas max_queue_depth=10000` 保持；t3/t4 断言保留 |
| VERSION | ✅ | 1.5.17 |
| tests 适配（t3/t4） | ✅ | 白名单循环加回 usb-storage/uas、卸载分支断言（含顺序断言）、t4 L5 源码级断言翻转，全部正确 |
| menu.sh/lib.sh/wipe.sh 零改动 | ✅ | `git diff --name-only` 仅 5 文件：VERSION、build-lib.sh、src/init、t3、t4 |
| build-lib.sh | ⚠️→✅ | 白名单加回（符合 brief 一处）+ **dw_verify_iso 6.6 反向断言翻转（超出一处）——已核实为构建必需**，见下 |

### build-lib.sh 断言翻转：核实为合理必要修正（brief 内部矛盾）

brief 同时要求（内部矛盾）：
- 禁止改动条款：「build-lib.sh 仅允许白名单数组加回 usb-storage uas（一处），其余零改动」
- 任务 §4 关键 + 验证条款：「构建产物 initrd **必须含** usb-storage.ko + uas.ko（isoinfo 解包校验）」

而 ec74487 的 dw_verify_iso 6.6 存在 v1.5.9 反向断言（`git show ec74487` 已核实原文）：
`if find … -name 'usb-storage.ko' | grep -q .; then dw_fail "initrd 内不应再含 usb-storage.ko"; return 1`

白名单加回后 usb-storage.ko 必被提取进 initrd → 旧断言必 `dw_fail` → iso 无法产出，与 brief 自身的「initrd 必须含 usb-storage.ko/uas.ko」要求直接冲突。因此 6.6 翻转（正向断言 usb-storage.ko + uas.ko 必须打包）是构建通过的**必要修正**；翻转实现完整（fail 分支与 pass 回显行均翻、补 uas 检查）。报告 Concerns #1 已透明披露。**结论：属合理必要修正，非越权改动**；建议后续修订 brief 明确允许该处，消除字面歧义。

## 代码质量

- **Kylin 形态正确**：`usb-storage`（文件名形态）与 v1.5.6 完全一致；注释说明 busybox modprobe 按 modules.dep 解析、`usb_storage`/`usb-storage` 均能命中，合理。
- **卸载语义自洽**：无 U 盘（qemu A）→ rmmod 成功 → 退出写日志本就走内存降级；有 U 盘绑定（真机/qemu C）→ rmmod EBUSY 静默失败 → 模块保留 → 退出写 U 盘日志仍可用。qemu C「Cleanup log saved to USB」PASS 佐证该路径闭环。
- **POSIX/ash 合规**：`cmd 2>/dev/null || true` 无 bash 专属语法；中文注释、LF 行尾（diff 干净）。
- **rmmod 选择合理**：busybox-static 1.36.1 含 rmmod applet、`filename2modname` '-'→'_'、多模块参数——与 brief「rmmod 若无则 modprobe -r」备选方案一致；即便 initrd 内 busybox 缺 rmmod，`|| true` 使其 no-op 无害。
- **t3 断言有效性实测**：`bash -x` 在 Git Bash 与 WSL（Ubuntu 24.04，均 bash 5.2.21）下 xtrace 行形态均为 `+ rmmod usb-storage uas`（不含重定向），两条顺序断言（sleep 10 之后、exec menu.sh 之前）的 awk 逻辑正确且实际通过。

## 报告证据真实性抽查

- `tmp/run-a/b/c-v1517.log` 存在且与报告一致：A 含 `PASS diskwipe-init: loading module usb-storage` / `uas` + [3b] isoinfo 解包断言（initrd/init 卸载分支、Kylin 白名单、usb-storage.ko/uas.ko 存在）全 PASS；B 无盘无限重试 4 条 + `N%10==1` + 无 reboot + `qemu exit=124` 全 PASS；C 21 项关键行 + `PASS Cleanup log saved to USB` + `PASS no WARN: could not write log to USB` + [5] U 盘数据区日志文件存在 PASS。
- 冒烟脚本 [3b] 确为 isoinfo 解包实检（`isoinfo -R -i "$ISO" -x /boot/initrd.img` + zcat|cpio），非纸面断言。
- **独立复跑 tests 全 PASS**：t1 89 / t2 93 / t3 105 / t4 50 / t5 37 / t6 77，与报告逐项一致。
- 产物：`diskwipe-iso/output/diskwipe-v1.5.17.iso` 存在（40894464 字节 = 39M）。
- commit `468a737` 与报告一致（5 files, +74/-31）。

## 问题列表

- **Critical**：无
- **Important**：无
- **Minor**：
  1. build-lib.sh 改动实为两处（白名单 + 6.6 断言翻转），超出 brief 字面「一处」——已核实为必要修正（brief 内部矛盾），报告已披露；建议修订 brief 明确允许，避免被误读为越权。
  2. 报告 Concerns #4 称留档「运行日志 tmp/build-v1517.log」，但该文件实际不存在（仅 build-v1517.sh）。「Kylin 模块 26 个（v1.5.16 为 24 个）」与构建侧 isoinfo 校验新断言行无法从留档直接复核——等效证据已由冒烟脚本 [3b] 的 isoinfo 解包断言覆盖（全 PASS），不影响结论，属证据留档小缺口。

## ⚠️ 无法从 diff/留档验证（须真机/外部验证）

- **usb-storage 加载触发 mpt3sas 完成初始化并带出 SAS 盘（真机疗效）**——qemu 为 virtio 盘，无法覆盖；与 brief「注」一致，只能由用户真机验证（v1.5.6 真机铁证支持该假设，v1.5.9 去掉后 sda 再未出现的反证亦支持）。
- 产物 initrd 内 busybox 二进制的 rmmod applet 存在性（报告以本机 busybox-static 1.36.1 `--list` 佐证，非产物内同一二进制）——但 qemu A/B/C 全流程已端到端证明 rmmod 行在真实 initramfs 启动中无副作用（无卡死、无报错、menu 正常进入）。
- 卸载后「退出写日志 U 盘」路径的**真机绑定态**行为（EBUSY 静默失败）——qemu C 已模拟绑定态并验证写日志成功；真机 ASolid U 盘行为仍以真机验证为准。

## 结论：**Approved**
