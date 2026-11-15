# 一键压测（oneclick.sh）· 交付记录

- 日期：2026-11-15
- 计划：`docs/superpowers/plans/2026-11-15-oneclick-stress.md`
- 设计：`docs/superpowers/specs/2026-11-15-oneclick-stress-design.md`
- 执行方式：Subagent-driven development（每任务独立实现 + 独立评审；结尾整支复查）
- 提交状态：按用户要求**未提交**，改动留在工作区（分支 `fix/stress-memory-guard`）

## 1. 做了什么

在离线包内新增一键压测入口 `oneclick.sh`：一条命令完成「前置检查 → 自动挂载 → 每块数据盘一个窗口 → 系统盘 → CPU → 内存 → 失败即停 → 等待结束 → 自动逐个复盘 → 汇总」。`disk-mount.sh` 增加 `--yes` 以支持无交互自动挂载。

### 改动的文件

- `offline-stress-pkg/oneclick.sh`（新增）：菜单 / 子命令、前置检查、自动挂载、任务计划、每任务图形终端窗口（`gnome-terminal` / `mate-terminal` / `xterm`）或后台降级、内部子命令 `__task`、就绪握手、失败即停、等待结束、逐任务 review 与 `summary.txt` 汇总。
- `offline-stress-pkg/disk-mount.sh`：`mount` 新增 `--yes`（跳过 y/N 确认，仍需 `--disks`；系统盘校验不绕过）。
- `offline-stress-pkg/README.md`：包结构加入 `oneclick.sh`；新增 `### 4.1 一键压测（推荐）`（位于“4. 安装”之后、“5. 验证”之前，5 以后编号未变）。
- `offline-stress-pkg/operation-manual.md`：第 2 节标注“分步执行时使用”；新增 `## 2.1 一键全测（oneclick.sh）`（前置、菜单/子命令、全测顺序、窗口标题与关窗不影响压测、SSH 降级与 `ONECLICK_GUI=0` 强制、失败即停、结果位置与批次目录文件），后续章节编号未动。
- `offline-stress-pkg.zip`：按目录内容重打（正斜杠条目、保留顶层 `offline-stress-pkg/`）。
- `.superpowers/sdd/2026-11-15-oneclick-stress/tests/`：`lib.sh`、`t1_disk_yes.sh`、`t2_menu.sh`、`t3_window.sh`、`t4_fallback.sh`、`t5_failfast.sh`、`t6_finish.sh`、`run-all.sh`（离线假件驱动真实脚本；`run-all.sh` 依次运行 t1–t6，任一失败整体非 0）。

> `offline-stress-pkg/cmd.txt` 是用户现场命令笔记，随包带出，**不属交付内容**；README 包结构不列它。

> 工作区还包含更早计划/规格（如 `docs/superpowers/plans/2026-11-13-*`、`docs/superpowers/specs/2026-11-14-*` 等）的历史未提交改动，本次未触碰。

## 2. 用法

菜单（推荐）：

```bash
sudo bash oneclick.sh
```

菜单项：`1` 全测 / `2` 只测硬盘 / `3` 只测系统盘 / `4` 只测 CPU / `5` 只测内存 / `6` 查看状态 / `7` 生成复盘 / `0` 退出。

子命令（等价，便于脚本化；默认超时 10h）：

```bash
sudo bash oneclick.sh all --timeout 10h
sudo bash oneclick.sh hdd --timeout 8h
sudo bash oneclick.sh sysdisk
sudo bash oneclick.sh cpu
sudo bash oneclick.sh mem
sudo bash oneclick.sh status      # 最近批次逐任务状态 + stress-test.sh status
sudo bash oneclick.sh review      # 最近批次重新逐个复盘并生成 summary.txt
sudo bash oneclick.sh --help
```

环境变量：`STRESS_TEST_ROOT`（默认 `/root/stress-test`）、`ONECLICK_GUI`（`auto`/`1`/`0`，默认 `auto`）、`ONECLICK_POLL_INTERVAL`（默认 30 秒）、`ONECLICK_READY_TIMEOUT`（默认 180 秒）、`ONECLICK_STRESS_TEST_SH` / `ONECLICK_DISK_MOUNT_SH`（替身脚本注入，测试用）。

全测顺序：自动执行 `disk-mount.sh mount --disks all --yes` → 每块 `/mnt/HDD*` 一个任务（窗口标题 `压测-HDDxx`）→ 系统盘（`压测-系统盘`）→ CPU（`压测-CPU`）→ 内存（`压测-内存`）→ 等待全部结束 → 逐个 `review` → 汇总。

强制后台执行（不弹窗）：

```bash
ONECLICK_GUI=0 sudo -E bash oneclick.sh all
```

窗口只是查看入口：压测与监控由 `stress-test.sh` 以 nohup 后台运行，关窗或 Ctrl-C 不影响压测。

## 3. 批次目录文件说明

每次运行在 `/root/stress-test/oneclick-<YYYYmmdd-HHMMSS>/` 建批次目录（同秒冲突顺延 `-1`、`-2`）：

| 文件 | 说明 |
|---|---|
| `start.time` / `timeout.txt` | 批次开始时间、统一超时 |
| `plan.txt` | 任务计划：`id\|类型\|附加参数` |
| `tasks.txt` | 已就绪任务：`id\|类型\|结果目录` |
| `mount.log` | 自动挂载输出（仅 all/hdd） |
| `<任务>.start.log` / `<任务>.startrc` | 单任务启动输出与退出码 |
| `<任务>.dir` | 就绪标记，内容为该任务结果目录 |
| `<任务>.fail` | 启动失败标记（有则停止启动后续任务） |
| `aborted` | 启动阶段中止标记 |
| `<任务>.out` | 无图形环境降级时该任务的后台输出 |
| `<任务>.review.txt` | 该任务 `review` 的完整输出 |
| `summary.txt` | 一键汇总：逐任务结论 + 结果目录清单；存在异常结论时进程退出码 1 |

各任务完整结果仍在 `/root/stress-test/<时间戳>-<类型>/`（`run-config.txt`、`monitor.csv`、`stress*.log`、`summary.txt` 等，见操作手册第 4.4 节）。

## 4. 测试结果

新测试（`timeout 180` 包裹，全部实测通过）：

| 测试 | 断言数 | 结果 |
|---|---|---|
| `t1_disk_yes.sh` | 8 | ALL PASS |
| `t2_menu.sh` | 10 | ALL PASS |
| `t3_window.sh` | 6 | ALL PASS |
| `t4_fallback.sh` | 5 | ALL PASS |
| `t5_failfast.sh` | 6 | ALL PASS |
| `t6_finish.sh` | 41 | ALL PASS |
| 合计 | 76 | 0 失败 |

上述六个测试也由总入口 `bash .superpowers/sdd/2026-11-15-oneclick-stress/tests/run-all.sh` 一次跑完：`t1–t6 ALL PASS`，末尾 `==== 全部测试: ALL PASS ====`，rc=0（任一失败时整体退出 1）。

旧回归 `.superpowers/sdd/2026-11-15-spec-driven-stress-params/tests/run-all.sh`：t1 19 项、t2 89 项、t3 27 项，合计 135 项 ALL PASS（`全部测试: ALL PASS`）。

语法检查：`bash -n offline-stress-pkg/oneclick.sh offline-stress-pkg/stress-test.sh offline-stress-pkg/disk-mount.sh` 无输出，退出码 0。

覆盖要点：`--yes` 非交互挂载与系统盘拒绝；菜单项/非法输入/`--help` 文案/非法 `--timeout`；xterm 与 gnome-terminal 的标题与 `--dirs` 单参数拼装；无 GUI 降级与 `tasks.txt` 写入；第二个任务启动失败时不启动后续任务且退出码 1；全部完成汇总退出 0、存在异常结论退出 1、status 四种状态、`review` 重新生成、等待轮询、结果目录缺失不卡住等待。

## 5. 打包校验结果

执行 `python3 .superpowers/sdd/2026-11-15-spec-driven-stress-params/pack_zip.py`（WSL 下 python3 3.12.3）：

```
条目数: 15 反斜杠条目: []
OK    offline-stress-pkg/stress-test.sh
      sha256 MATCH 9508eff8fd55a9aa
OK    offline-stress-pkg/operation-manual.md
      sha256 MATCH 2cac239095711669
OK    offline-stress-pkg/rpms/stress-1.0.4-24.el8.x86_64.rpm
      sha256 MATCH 0090571fd05c307d
```

- `oneclick.sh` 虽不在脚本固定校验清单内，但已确认在包内：`offline-stress-pkg/oneclick.sh`（18861 字节）。
- 包内 `oneclick.sh` 与工作区 SHA256 一致：`c57ee3faf6b5be31fe8675ca7c66a5253fa9b68d01a8c5c2b31223ed0a9f2694`。
- 修正手册 2.1 后已重打一次并复核：包内 `operation-manual.md` 与工作区一致（`2cac2390…`）；`run-all.sh` 位于 `.superpowers/`，不打包。

## 6. 遗留事项

1. **root 桌面下终端拉起需现场验证一次**：测试用假终端验证了 argv 拼装（`-T`/`-e`、`--title`），真实图形环境（root 桌面、`DISPLAY`、`gnome-terminal`/`xterm` 可用性）需在服务器上人工确认一次「每块盘一个窗口、窗口内有实时监控」。
2. 自动挂载返回非 0 属设计豁免：全测继续执行系统盘/CPU/内存，仅打印警告；现场需留意该警告并核对 `mount.log`。
3. 启动阶段失败采用「失败即停」，被中止后未启动的任务在 `status` 中显示“未启动”；属预期行为。
4. 菜单项 `6`（查看状态）/ `7`（生成复盘）执行后原地结束，不再回到菜单；属设计行为，重看需重新运行 `oneclick.sh`。
