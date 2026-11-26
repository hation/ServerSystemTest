# Task 8 review — v1.5.8 去掉 uas + exec/menu 启动 kmsg 诊断 + 菜单界面输出 kmsg 双通道

审查对象：commit `7b66568`（8 files changed, 122 insertions(+), 19 deletions(-)，与报告一致）；
diff 文件 `tmp/review-pkg-t8.diff`（cebce11..7b66568）。经核实 7b66568 父提交为 9b24d9b，
cebce11..9b24d9b 之间无 diskwipe-iso 改动（`git diff cebce11 9b24d9b -- diskwipe-iso` 为空），
故 review-pkg-t8.diff 精确反映 Task 8 全部变更，无缺漏、无混入。

## 1. Spec 合规性 — ✅ 完全合规

| brief 条目 | 结果 | 说明 |
|---|---|---|
| 1. build-lib.sh `DW_KYLIN_MODULES` 去 uas | ✅ | 白名单与依赖链注释（两处 `uas→usb-storage`）同步移除；新增 v1.5.8 中文注释（D 状态卡死、usb-storage 足够）；`DW_MODULES`（Ubuntu）不动 |
| 2a. init Kylin `DRIVE_MODULES` 去 uas | ✅ | `case *ky10*` 分支去除，注释与 build-lib 同口径；Ubuntu 分支不动 |
| 2b. init exec 段诊断 + 兜底 | ✅ | 按 brief 原文逐字实现（dw_progress "exec menu.sh" + `exec ... \|\| { FAILED/argv0/exec sh }`） |
| 3a. menu.sh 头部 argv0 打点 | ✅ | 位于 `. lib.sh` **之前**，`echo ... > /dev/kmsg 2>/dev/null`，不依赖 lib.sh |
| 3b. menu.sh 界面 kmsg 镜像 | ✅ | 横幅 `====`（两处）、盘列表表头/分隔线/行、`Default: all selected`、`0 = exit`、`> ` 提示（两处）、`Exited.` 行均已镜像；wipe 结果行经 `fi \| while read` 逐行镜像；dw_log 已覆盖行保持原样（由 lib.sh 自动镜像） |
| 4. lib.sh `dw_log` kmsg 镜像 | ✅ | 函数首行加 `echo "diskwipe-init: $1" > /dev/kmsg 2>/dev/null`；LOG_DEGRADED 分支、`timeout 2 tee`、WARN 兜底**全部保留**；接口注释同步 |
| 5. VERSION 1.5.8 | ✅ | `1.5.7 → 1.5.8` |
| 6. 重打包 v1.5.8 iso | ✅ | build-v158.log：Kylin 模式、模块 26→25（uas 去掉少 1）、VERSION→1.5.8、isoinfo 校验全过、src 四脚本 dash -n 0 错误 |
| 禁止改动 | ✅ | wipe.sh / isolinux / grub.cfg / embedded-efi.cfg / BOOTX64.EFI / xorriso 均未出现在 diff 中；`git status` 确认无已跟踪文件未提交改动（仅一个未跟踪的 Kylin iso 构建原料，非本次变更） |

**menu.sh 交互逻辑零改动确认**：diff 中交互行（`IFS= read -r mex`、`IFS= read -r myn`、`case "$mex"`、
`if [ "$myn" = "YES" ]`、循环结构）全部为**上下文行**（无 +/- 前缀）；新增行仅诊断/镜像输出及
`fi | while IFS= read -r wline; do ... done`（读的是 wipe.sh 输出管道，非用户输入，不改变任何
交互语义；输出经 `printf '%s\n'` 逐行重写，顺序不变）。`fi | while` 为 POSIX 合法语法
（pipeline 允许 if 复合命令），busybox ash / dash / bash 均支持。

## 2. 代码质量

- **uas 去掉一致性**：build-lib 白名单、init ky10 分支、依赖链注释、tests（I5 用例）四处一致；
  运行期实证无 uas（qemu A/B 的 loading module 序列 = ahci libahci libata nvme nvme-core mpt3sas
  megaraid_sas virtio_blk sd_mod usb-storage nls_iso8859-1 vfat fat，usb-storage 在列）。
- **exec 诊断（concern 1）**：`exec ... || {}` 在 POSIX 下不可达（exec 失败 → shell 立即以
  126/127 退出）。评估：**不影响诊断目的**——真正生效的诊断是 exec **前**的
  `dw_progress "exec menu.sh"`（真机卡在 exec 前或启动时即由该行定位，qemu A/B 均证实该行
  在 argv0 打点之前出现）；源码按 brief 原文保留兜底为防御性、无副作用（exec 失败仅 126 退出，
  无额外错误输出）；t3 I6 用例已按真实语义改写（断言 126 退出 + 诊断行先打 + 未进菜单）并
  注释说明。合理。
- **menu.sh 界面镜像**：镜像载荷与屏幕 printf 格式逐字符一致（已核对 `  %d    /dev/%s  %s   %s  %s`
  与 dw_progress 串）；`printf '> '` 无换行、镜像独立写 kmsg，屏幕提示不受影响。
- **dw_log kmsg 镜像**：位于函数最前（LOG_DEGRADED 检查之前）——日志文件降级时 kmsg 镜像仍生效，
  符合双通道意图；`$1` 与原函数签名一致（brief 示意图 `$msg` 为伪码）。
- **POSIX/ash**：新增代码全部为 POSIX 构造（`||`、`{ }`、`$()`、管道）；dash -n 0 错误
  （build-v158.log 实证）；中文注释合规。
- **tests 适配**：M10（bash -x + BASH_XTRACEFD=3 分流 xtrace，正向断言 argv0/提示/盘列表/Exited
  的 kmsg 载荷）、I5（假 uname ky10：uas 不得加载 + 13 模块加载断言）、I6（exec 失败 126）、
  L6（dw_log kmsg 镜像两行）——全部 PASS（runall-v158.log 实证）。

## 3. 报告 concerns 合理性 — 全部成立

1. `||` 兜底不可达：成立。有实证（I6 用例 + WSL dash/busybox ash 1.36.1/bash 一致），源码保留
   符合 brief 原文，I6 断言真实语义而非兜底分支，处理得当。
2. qemu B 尾部 panic：成立。`tmp/novid-v157.out` 对比实证——v1.5.7 无盘路径同样
   `Attempted to kill init! exitcode=0x00000000`，非本次引入。
3. 构建入口（wsl.exe 完整路径 + dpkg 锁）：成立，build-v158.log 实证（unattended-upgrade 锁为
   WSL 环境外部干扰，非构建脚本缺陷）。
4. 行尾 CRLF/LF：与 task-6/7 基线一致，A/B/C 全流程 + Git Bash 测试均正常，成立。
5. kmsg 镜像行量噪音：属 brief 要求的双通道设计权衡；kmsg 行带内核时间戳可对应阶段，成立。

## 4. 报告证据真实性 — 抽查属实（非凭空声明）

- `tmp/dw-smoke-uefi-v158.out.clean`：无 uas 模块序列；`exec menu.sh`(32.5s) → `menu.sh argv0=//menu.sh` →
  `menu.sh started` 三行齐全；界面镜像（横幅/OK 行/Exited）带时间戳；OK x3、Exited.、Cleanup log
  saved to USB；无 ERROR / 无 Only boot media。
- `tmp/novid-v158.out`：Booting in blind mode → Linux 4.19.90 → RAMDISK → Run /init → 无 uas 序列 →
  exec/argv0/menu.sh started → `Only boot media found`（kmsg 镜像经 serial 可见，行出现两次）→
  尾部 panic 与 v157 一致。
- `tmp/dw-smoke-v158.out.clean`（BIOS C）：ISOLINUX 6.04 → Loading vmlinuz/initrd → 1.5.8 横幅 →
  Disks found 3 → 盘列表行 + 镜像 → OK x3 → Exited → Log kept in memory → Cleanup log saved to USB；
  第二轮列表类型 SYS→DATA 变化正常；无 GNU GRUB / ERROR / Only boot media。
- `tmp/runall-v158.log`：t1 89 / t2 68（M10 全过）/ t3 91（I5 19 项、I6 3 项全过）/ t4 49（L6
  含 kmsg 镜像两行全过）/ t5 37 / t6 77 = **411 项 0 失败，全部 ALL PASS**，与报告数字一致。
- `tmp/build-v158.log`：Kylin 模块 25 个（v1.5.7 26 → 少 1）、VERSION→1.5.8、dash -n 0 错误、
  isoinfo 校验全过、BOOTX64.EFI PE 有效。
- `tmp/chk-v158-initrd.sh` 复核脚本存在（find uas 无匹配、usb-storage 在、argv0 行、dw_log kmsg 行）。

## 问题列表

- **Critical**：无
- **Important**：无
- **Minor**：
  1. `exec ... || {}` 兜底不可达（concern 1）——源码保留符合 brief 原文，仅认知层面；建议后续
     版本如需真兜底改用 `if ! exec ...; then` 前检查方式（本次不必改）。
  2. wipe 结果行 `fi | while` 管道：若下游 stdout 提前关闭，`printf` 收 SIGPIPE → while 退出 →
     上游 wipe.sh 收 SIGPIPE。与基线 tee 的风险一致（报告声明"同基线"属实），非新增风险，无需处理。
  3. dw_log 镜像消息与 dw_progress 前缀同为 `diskwipe-init: `，kmsg 中两者无法按前缀区分——但均带
     内核时间戳可对应阶段，concern 5 已说明，属可接受噪音。

## 结论

**Approved** — commit 7b66568 精确实现 brief 全部 6 项任务，零越界（wipe.sh/isolinux/grub.cfg/
embedded/BOOTX64.EFI/xorriso 均未动），menu.sh 交互逻辑零改动；uas 去掉四处一致；报告 5 项
concerns 全部成立且有实证；验证证据（qemu A/B/C 输出 + tests 411 项 ALL PASS + build 日志）抽查
属实。3 项 Minor 均不阻塞。

## ⚠️ 无法从 diff 验证的项

1. **真机（海光服务器 + ASolid U 盘）上去掉 uas 是否真正消除 D 状态卡死**——qemu 无法复现 UAS
  协议异常场景，仅能验证 uas 不在加载清单/不在 initrd（模块 26→25、运行期序列无 uas）。修复的
  核心假设需真机复测确认。
2. **qemu A 的"33 断言"脚本逐条核对**——`tmp/dw-smoke-uefi-v158.sh` 存在，但本次仅抽查其输出
  文件关键行（全部命中）；断言计数未逐条跑脚本比对。
3. **iso 产物本身**（39M，gitignore 未入库）——经 build-v158.log isoinfo 校验行 +
  chk-v158-initrd.sh 复核脚本间接可信，未直接解包核对。
