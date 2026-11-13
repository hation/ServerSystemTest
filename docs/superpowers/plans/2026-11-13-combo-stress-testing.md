# 组合压测模式（combo + --sysdisk）Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 在既有压测体系中新增 `stress-test.sh start combo`（CPU/内存/硬盘同时压，全盘覆盖）+ `--sysdisk`（系统盘显式压测），并更新实操手册、重打 zip。

**Architecture:** 复用既有 stress-test.sh 架构（结果目录、监控循环、status/stop/review、两阶段前置校验）。combo 双轨：CPU/内存一个 stress 进程 + 每个已挂载测试盘一个 --hdd 进程（全盘覆盖）；`--sysdisk` 在 `/stresstest-hdd` 加一个系统盘 hdd 进程（空间预检 + 默认关闭显式开启）。全部 WSL stub 测试。

**Tech Stack:** bash（既有 stress-test.sh 扩展）、WSL stub 测试、git。

**Spec:** [2026-11-13-combo-stress-testing-design.md](file:///c:/Users/ganxin01/Documents/trae-work/ServerSystemTest/docs/superpowers/specs/2026-11-13-combo-stress-testing-design.md)

## Global Constraints

- 修改对象仅限：`offline-stress-pkg/stress-test.sh`（Task 1）、`offline-stress-pkg/压测实操手册.md`（Task 2）、`offline-stress-pkg.zip`（Task 3 重打）。**install.sh / verify.sh / disk-mount.sh / README.md / RPM 一律不动**
- 机型预设逐字复用：5380→cpu 110/vm 12/26G；7380→cpu 110/vm 16/54G；7360→cpu 80/vm 16/26G；hdd 每盘 `--hdd 1 --hdd-bytes 10G`；timeout 默认 `12h`
- combo 结果目录：`$STRESS_TEST_ROOT/<YYYYmmdd-HHMMSS>-combo/`，产物：run-config.txt / info-before.txt / stress.log+stress.exitcode（CPU/内存进程）/ stress-HDDxx.log+.exitcode（每盘）/ stress-SYSDISK.log+.exitcode（--sysdisk 时）/ monitor.csv / summary.txt；根级 operations.log
- `--sysdisk`：hdd 与 combo 模式可用（cpu/mem 忽略并提示）；默认关闭；`mkdir -p /stresstest-hdd` 后 cd 运行；前置 `df -P /` 可用空间 ≥ `--hdd-bytes × 1.2` 不足整体退出
- 无数据盘时 `combo --sysdisk` 允许（hdd 目录集合为空仅跑 CPU/内存+系统盘）；combo 无 hdd 盘且无 --sysdisk 时警告后仅跑 CPU/内存
- summary 输出"监控采样行数"（非异常行数）
- `--dirs` 与 `--sysdisk` 重叠由操作员负责，不强制去重
- 既有测试接缝不变：STRESS_TEST_ROOT / MONITOR_INTERVAL / PATH stub；脚本不 set -e、LF、中文
- 本机 WSL：`c:\...` ↔ `/mnt/c/...`；PowerShell 5 禁 `&&`；git 身份每次提交注入 env（`ganxin01 <ganxin01@local>`，勿改 config）
- 提交消息：`type(scope): 一句话` + body 原因/改动/影响

## Review Focus

1. **combo 的 CPU/内存进程与每盘 hdd 进程生命周期统一** → 全部 PID 进 stress.pids，监控随全部消失退出，stop 全杀 → Task 1 测试（短 stub 后 monitor 退出、stop 无残留）。
2. **--sysdisk 空间预检** → `df -P /` 可用不足必须整体退出、零启动 → Task 1 测试（stub df 模拟不足）。
3. **系统盘 hdd 专用目录** → `/stresstest-hdd` 不存在则 mkdir 后启动，不污染 `/` 根 → Task 1 测试（目录创建 + 日志）。
4. **无数据盘场景** → combo 无挂载盘无 --sysdisk 仍启动 CPU/内存（警告）；有 --sysdisk 加系统盘 → Task 1 测试。
5. **既有单测回归** → cpu/mem/hdd 默认行为不变，hdd 新增 --sysdisk 不破坏原流程 → Task 1 回归测试。
6. **summary 事实输出** → 采样行数/退出码齐全，无阈值判定 → Task 1 测试（review 输出字段）。

---

### Task 1: stress-test.sh 扩展 combo + --sysdisk

**Files:**
- Modify: `offline-stress-pkg/stress-test.sh`

**Interfaces:**
- Consumes: 既有 start/status/stop/review 结构、结果目录/监控/PID 机制、机型预设
- Produces（后续任务依赖）：`start combo [--sysdisk]` 完整可用；`--sysdisk` 在 hdd 模式也可用；日志文件命名规范（stress.log / stress-HDDxx.log / stress-SYSDISK.log + 各自 .exitcode）

- [ ] **Step 1: 修改 stress-test.sh 增加 combo 与 --sysdisk**

关键改动（在既有结构上最小扩展）：
1. 参数解析：新增 `--sysdisk` 标志（combo/hdd 生效，cpu/mem 忽略并提示）
2. start type 增加 `combo`：走 combo 流程
3. combo 启动流程（顺序即既有语义）：
   - 前置校验（先全量后启动）：hdd 目录集合（默认 /mnt/HDD* 挂载点校验 / --dirs 存在性）——**集合为空不报错**（澄清 2）；存在但校验失败才整体退出
   - `--sysdisk`：`mkdir -p /stresstest-hdd`；`df -P /` 可用空间（kB）≥ `hdd-bytes×1.2`（hdd-bytes 按 G 换算，stub 可注入 DF_BIN 测试接缝），不足整体退出
   - 建 `<ts>-combo/` 结果目录 → run-config.txt / info-before.txt
   - 启动 CPU/内存组合进程：`nohup stress --cpu N --vm M --vm-bytes X --timeout T` → stress.log + `echo $? > stress.exitcode`，记 PID
   - 逐盘启动：`(cd 盘目录 && stress --hdd 1 --hdd-bytes Y --timeout T)` → stress-HDDxx.log + .exitcode，记 PID
   - `--sysdisk`：`(cd /stresstest-hdd && stress --hdd 1 --hdd-bytes Y --timeout T)` → stress-SYSDISK.log + .exitcode，记 PID
   - 全部 PID 写 stress.pids → 启动监控循环 → 打印启动信息
4. hdd 单测模式增加 `--sysdisk`（复用同一系统盘启动逻辑）
5. review：summary 增加"监控采样行数"；退出码扫描覆盖 stress.exitcode + stress-HDDxx.exitcode + stress-SYSDISK.exitcode
6. 不 set -e；其余既有行为不变

- [ ] **Step 2: 语法检查（WSL）**

Run: `bash -n /mnt/c/Users/ganxin01/Documents/trae-work/ServerSystemTest/offline-stress-pkg/stress-test.sh`
Expected: 无输出，退出码 0

- [ ] **Step 3: combo stub 冒烟（WSL）**

构造：PATH 前置假 stress（--version 输出 `stress 1.0.4`；其余参数忽略；sleep 3；打印 successful run completed）、假挂载目录 A/B、`STRESS_TEST_ROOT=$tmp MONITOR_INTERVAL=1`。执行：
```bash
cd /mnt/c/Users/ganxin01/Documents/trae-work/ServerSystemTest/offline-stress-pkg
bash stress-test.sh start combo --dirs "$A $B" --timeout 3
bash stress-test.sh status
# 等 stub 退出后：
bash stress-test.sh review
```
Expected: 结果目录 `<ts>-combo/` 含 run-config/info-before/stress.log/stress.exitcode/stress-HDD01.log+exitcode/stress-HDD02.log+exitcode/monitor.csv（≥2 行、表头正确、无 BOM）；status 运行中 → 空闲；review 生成 summary（含 CPU/内存退出码、两盘 hdd 退出码、监控采样行数）

- [ ] **Step 4: --sysdisk 与边界 stub 测试（WSL）**

Run（同一 stub 环境，DF_BIN 注入假 df 用于空间预检）：
```bash
# a) combo --sysdisk → 额外生成 stress-SYSDISK.log + .exitcode，/stresstest-hdd 已创建
bash stress-test.sh start combo --dirs "$A" --sysdisk --timeout 3
# b) 假 df 报可用空间不足 → 整体退出 1，不建结果目录、无进程
# c) 无数据盘：start combo（无 --dirs、无 /mnt/HDD*、无 --sysdisk）→ 警告后仅 CPU/内存启动，exit 0
# d) 默认路径含未挂载目录 → 整体退出 1（回归既有两阶段语义）
# e) hdd 单测 --sysdisk → 生成 stress-SYSDISK.log（hdd 模式系统盘可用）
```
Expected: a-e 与上述一致；全程无孤儿进程（校验失败场景）

- [ ] **Step 5: 既有单测回归（WSL）**

Run: cpu / mem / hdd（--dirs）三种单测 stub 冒烟（复现既有测试路径）。
Expected: 与既有行为一致（目录/日志/status/review 正常），无回归

- [ ] **Step 6: Commit**

```bash
git add offline-stress-pkg/stress-test.sh
git commit -m "feat(offline-stress): stress-test.sh 新增 combo 组合模式与 --sysdisk

- 原因：需同时压 CPU/内存/硬盘并支持系统盘压测
- 改动：start combo 双轨（CPU/内存一进程+每盘 hdd 一进程）、--sysdisk 系统盘 hdd、空间预检
- 影响：WSL stub 全链路+回归通过；真实组合 12h 留服务器侧验收"
```

---

### Task 2: 压测实操手册.md 增加组合与系统盘两节

**Files:**
- Modify: `offline-stress-pkg/压测实操手册.md`

**Interfaces:**
- Consumes: Task 1 的 combo/--sysdisk 实际用法
- Produces: 操作人员可照着跑组合测试与系统盘测试

- [ ] **Step 1: 手册新增两节**

在既有章节后新增：
1. **组合测试**：`bash stress-test.sh start combo`（默认 12h，按机型预设）；结果目录说明（stress.log + stress-HDDxx.log + monitor.csv + summary.txt）；查看日志方法（status / tail -f monitor.csv / 各日志文件）；复盘（review）
2. **系统盘测试（--sysdisk）**：说明默认关闭、显式开启；运行位置 /stresstest-hdd 与清理提示；空间预检行为；`--dirs` 勿与系统盘重复的提示；服务器侧 60s 冒烟建议
3. 在快速上手/参数表格等处同步补充 combo 与 --sysdisk 一行
- 全部命令与 Task 1 实际 CLI 逐字一致

- [ ] **Step 2: 自查**

核对：新增命令与脚本实际用法一致；既有章节无破坏。

- [ ] **Step 3: Commit**

```bash
git add offline-stress-pkg/压测实操手册.md
git commit -m "docs(offline-stress): 手册新增组合测试与系统盘测试两节"
```

---

### Task 3: 整包质检 + zip 重打

**Files:**
- Modify: `offline-stress-pkg.zip`（重打）
- 质检对象：整个 `offline-stress-pkg/`

**Interfaces:**
- Consumes: Task 1-2 全部产物
- Produces: 最终交付物

- [ ] **Step 1: 既有文件零改动校验**

Run: `git diff --stat HEAD -- offline-stress-pkg/install.sh offline-stress-pkg/verify.sh offline-stress-pkg/disk-mount.sh offline-stress-pkg/README.md offline-stress-pkg/rpms/`
Expected: 空（本计划只动 stress-test.sh、压测实操手册.md、zip）

- [ ] **Step 2: 语法与 LF 复检（WSL）**

Run: `bash -n` 全部 4 脚本；`git ls-files --eol offline-stress-pkg/` 新增/改动脚本 i/lf。
Expected: 全过、全 LF

- [ ] **Step 3: 重打 zip 并校验**

```powershell
Compress-Archive -Path "c:\Users\ganxin01\Documents\trae-work\ServerSystemTest\offline-stress-pkg" -DestinationPath "c:\Users\ganxin01\Documents\trae-work\ServerSystemTest\offline-stress-pkg.zip" -Force
# 解压到临时目录，逐文件 SHA256 与原目录一致（7 条目）
```
Expected: 全部 MATCH

- [ ] **Step 4: Commit**

```bash
git add offline-stress-pkg.zip
git commit -m "chore(offline-stress): 重打离线包 zip（含 combo/--sysdisk 与手册更新）"
```

---

### 终检（整支复查）

按 superpowers:subagent-driven-development 流程，全部任务完成后由**新 reviewer subagent** 整支复查：combo/--sysdisk 与设计一致、既有文件零改动、单测回归、zip 完整性、CRLF 防护。通过即交付。
