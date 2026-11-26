# Task 14 审查报告 — v1.5.14 lsblk 原始输出诊断 + read -t 等待 + 重试消息降噪

- 审查对象：commit `873f09c`（HEAD），diff `8d6a538..873f09c`（3 文件，+52/-12）
- 审查方式：只读（diff 逐行 + 源码上下文 + 证据抽查 + WSL 独立重跑 tests 全量验证）
- 审查结论：**Approved**

## 1. Spec 合规性：✅ 精确符合

| 要求 | 结果 | 说明 |
|---|---|---|
| ① RAW lsblk 诊断（在 RAW enum 之前） | ✅ | 文本与 brief 逐字一致：`dw_progress "RAW lsblk: $(lsblk -o NAME,SIZE,TYPE,MODEL,TRAN,MOUNTPOINT 2>&1 \| tr '\n' '\|')"`，位于 `RAW enum ml=[$ml]` 之前（menu.sh:118-119） |
| ② read -t 5 替代 sleep 5 | ✅ | 文本与 brief 逐字一致：`read -t 5 dummy < /dev/tty0 2>/dev/null \|\| true` + 指定注释（menu.sh:135） |
| ③ 消息每 10 轮 | ✅ | `dwnoretry=$((dwnoretry + 1))` + `if [ $((dwnoretry % 10)) -eq 1 ]`，与 brief 逐字一致（menu.sh:127-132） |
| ④ VERSION 1.5.14 | ✅ | 已改（VERSION:1 `1.5.14`） |
| ⑤ 重新构建 | ✅ | `output/diskwipe-v1.5.14.iso` 39M；build-v1514.log：kylin 模式、内核 4.19.90-89.11.v2401.ky10、initrd 5.0M、isoinfo/dash -n 0 错误/无 usb-storage.ko 全过 |
| 禁止改动 | ✅ | diff 仅 3 文件：VERSION / src/menu.sh / tests/t2_menu.sh；lib.sh、wipe.sh、build-lib.sh、isolinux、grub.cfg、embedded、BOOTX64.EFI 均未触碰 |
| 交互逻辑未被改动 | ✅ | menu.sh 变更仅限：头部注释、循环注释、RAW 诊断行、read -t 等待段、消息降噪段；列盘/勾选/确认/清除/0 退出流程零改动 |

## 2. 代码质量审查

- **RAW lsblk 诊断**：命令静态无注入面；`2>&1` 捕获 lsblk 错误（含 PATH 缺失场景）；`tr '\n' '|'` 压行进 kmsg 正确。走 dw_progress（kmsg 双通道）不刷屏幕，符合设计。
- **read -t 5 dummy < /dev/tty0 2>/dev/null || true**：超时语义正确（无输入 → select 超时 → read 返回非 0 → `|| true` → continue 重枚举）；tty0 不存在时重定向立即失败也走 `|| true`（测试环境已利用此特性）；`dummy` 变量名、POSIX 语法合规。**注意**：`read -t` 是 shell 扩展非严格 POSIX（POSIX 仅定义 `read` 无 `-t`），但目标运行时 busybox ash / dash 均支持，真机 initramfs 为 busybox ash → 实际无风险（见 Minor 1）。
- **消息频率**：`% 10 -eq 1` 逻辑正确（retry 1/11/21… 打印，其余轮静默计数），与 brief 一致；消息文案同步去掉了 `Retrying every 5s`/`sleep 5`（配合 read -t 事实，降噪意图自洽）。
- **tests 适配（t2_menu.sh）**：
  - M6 阈值 4→5：数学正确——无盘每轮 2 次 lsblk 调用（dw_enum_disks 枚举 + RAW 诊断各 1），前 4 次调用 = 2 轮重试，第 5 次起就绪 → 重试 2 轮仅 1 条消息。✅
  - `check_not_cmds 'sleep'` 正确（read -t 为内建，sleep 假件不可拦截，故改断言"无 sleep 命令调用" + xtrace 正向断言 `read -t 5 dummy`）。✅
  - xtrace 重跑场景：`/dev/tty0` 在假 tmpfs /dev 中不存在 → read 立即失败不真等 5s，测试快速确定。✅
  - M10 新增 `diskwipe-init: RAW lsblk:` kmsg 载荷断言正确（dw_progress 前缀 + 命令替换载荷）。✅
  - t1/t3/t4/t5/t6 无需改动的论证成立：RAW 诊断仅 kmsg 不进 stdout（t5 ASCII 断言不受影响）；裸 lsblk 无 timeout 前缀（t6 H1 `timeout 3 lsblk` 计数 4 不变，已核对 t6_scan.sh:91 及假件不记录裸 lsblk）。

## 3. 报告 concerns 合理性：✅ 全部成立

1. **RAW lsblk 无 timeout**——合理。brief 指定原文，裸调用仅在枚举成功轮执行；若真机 U 盘 I/O 阻塞 lsblk 挂起会拖慢该轮，但诊断价值优先，属可接受权衡。
2. **read -t 依赖 select 时钟**——合理且已被 qemu B 证据证实时钟正常（retry 1 @37.2s → retry 11 @99.3s，10 轮 62.1s ≈ 5s×10 + 枚举开销）；真机待现场确认的声明恰当；消息降噪与轮速解耦独立生效的论断正确。
3. **M6 阈值与每轮 lsblk 调用数耦合**——成立，已按当前实现精确计算（每轮枚举+RAW 恰好 2 次）并通过；耦合点已在测试注释中显式声明。

## 4. 报告证据真实性：✅ 抽查全部属实

- `tmp/novid-v1514.out`：retry 1 @37.2s、retry 11 @99.3s（62.1s/10 轮，read -t 真实 5s 等待确认）；RAW lsblk 行存在（无盘载荷为空——busybox lsblk 无块设备时空输出）；retry 消息仅 1/11（%10==1），150s 窗口内 4 条（kmsg+console 双通道）；qemu exit=124 timeout 收尾。
- `tmp/dw-smoke-uefi-v1514.out.clean`：RAW lsblk 载荷含真实行（vda/vdb/vdc 含树形前缀）、RAW enum、DiskWipe Tool 1.5.14、OK x3、Exited、WARN + Log kept in memory、无 ERROR。
- `tmp/dw-smoke-v1514.out.clean`：ISOLINUX 6.04、Linux 4.19.90、RAW lsblk、1.5.14、OK x3、Exited、无 GNU GRUB/ERROR。
- `tmp/build-v1514.log`：构建关键行与报告一致。
- **独立重跑验证**：本审查在 WSL 重跑 `tests/run-all.sh` → **通过 77 项，失败 0 项，全部测试: ALL PASS**；t2 新增断言（read -t 5 dummy / 重试 2 轮仅 1 条消息 / retry 2 不打消息 / 无 sleep 调用 / RAW lsblk kmsg 载荷）逐条 PASS。

## 5. 问题列表

- **Critical**：无。
- **Important**：无。
- **Minor**：
  1. `read -t` 非严格 POSIX（shell 扩展）——但 busybox ash（真机 initramfs 运行时）与 dash 均支持，实际无风险；仅提示 brief 中"POSIX 兼容"表述略强。
  2. RAW lsblk 行经 kmsg 有单条长度上限（多盘大表可能截断）——诊断可接受；qemu A 证据显示 3 盘载荷完整。
  3. `read -t` 会消费等待期间用户输入（按回车提前跳过即吞掉该行）——与 brief"按键可提前跳过"设计意图一致，非缺陷。
  4. 报告措辞两处轻微不精确（不影响结论）：(a) "retry 编号全为 1/11/21"——150s 窗口内实际仅出现 1/11（retry 21 在 ~161s 超出 timeout）；(b) qemu C "21 项" 实为脚本 [3] 段关键行断言子集，run.log 共 37 行 PASS（含 boot 阶段行）。

## 6. ⚠️ 无法从 diff/证据验证项

- **真机现场行为**（read -t 在真机 select 时钟是否同样失真、sda 迟就绪根因定位）——qemu 证据仅能证明时钟正常路径有效，真机待现场确认（报告 concerns 已如实声明，属预期外延）。
- tests 在 Git Bash（非 WSL）环境的兼容性——brief 明确要求 WSL 跑，未另行验证。

## 结论

**Approved**。实现与 brief 逐字合规、无越界改动；代码质量与测试适配经独立重跑验证（77/77 PASS）；报告证据抽查属实，concerns 合理且已如实披露真机待确认项。
