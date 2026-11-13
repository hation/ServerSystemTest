# 服务器压测实操体系（三类机型 CPU/内存/硬盘）Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 在现有 `offline-stress-pkg` 离线包中新增压测实操体系：主控脚本 `stress-test.sh`、挂载辅助 `disk-mount.sh`、实操文档 `压测实操手册.md`，支持三类机型（5380/7380/7360）的 CPU/内存/硬盘压测——测试中实时可见、原始数据全保存、测完可复盘，并更新 README、重打 zip。

**Architecture:** 两个 bash 脚本 + 一份文档，并入既有离线包目录。`stress-test.sh` 内置三机型预设参数，`start cpu|mem|hdd` 后台运行 stress 并启动 30s 监控循环，数据落盘到 `/root/stress-test/<时间戳>-<类型>/`；`status/stop/review` 分别查看、终止、生成复盘总结。`disk-mount.sh` 提供 `list/mount/umount`，强制逐盘确认，空盘自动 mkfs 挂载，全程写 mount.log。全部脚本遵循 `.gitattributes`（LF），本机用 WSL + stub 做逻辑测试，真实 12h 跑服务器侧验收。

**Tech Stack:** bash（服务器侧）、/proc 监控（零额外依赖）、WSL stub 测试（本机）、git。

**Spec:** [2026-11-13-stress-testing-workflow-design.md](file:///c:/Users/ganxin01/Documents/trae-work/ServerSystemTest/docs/superpowers/specs/2026-11-13-stress-testing-workflow-design.md)

## Global Constraints

- 交付目录：`C:\Users\ganxin01\Documents\trae-work\ServerSystemTest\offline-stress-pkg\`（既有 install.sh / verify.sh / rpms / README.md 必须保持字节不变，除 Task 4 对 README 的指定更新）
- 新增文件：`stress-test.sh`、`disk-mount.sh`、`压测实操手册.md`（UTF-8 无 BOM）
- 机型预设（设计文档定值，脚本内逐字使用）：
  - 5380：cpu=110, vm=12, vm-bytes=26G；7380：cpu=110, vm=16, vm-bytes=54G；7360：cpu=80, vm=16, vm-bytes=26G
  - hdd 默认：每盘 `--hdd 1 --hdd-bytes 10G`；timeout 默认 `12h`，显式参数覆盖
- 结果根目录默认 `/root/stress-test`，环境变量 `STRESS_TEST_ROOT` 可覆盖（测试接缝）；监控间隔默认 30s，`MONITOR_INTERVAL` 可覆盖（测试接缝）
- monitor.csv 字段（30s 一行）：`时间,load1,cpu_usage%,mem_total,mem_used,mem_avail,swap_used,disk_read_MBps,disk_write_MBps`
- 挂载点：`/mnt/HDDxx`（xx=01..N 递增）；系统盘按 `df /` 识别，永不处理
- 挂载脚本：逐盘确认强制；无分区空盘 → `mkfs.ext4 -m 0` 后挂载；测试接缝 `DRY_RUN=1`（只打印计划不执行）与 `SKIP_ROOT_CHECK=1`
- 所有脚本：纯 LF（`.gitattributes` 已生效 `*.sh text eol=lf`）；不 `set -e`；中文输出
- 本机 WSL 路径映射：`c:\...\ServerSystemTest` = `/mnt/c/.../ServerSystemTest`；PowerShell 5（禁 `&&`）
- git 身份未配置：每次提交前注入 `$env:GIT_AUTHOR_NAME="ganxin01"; $env:GIT_AUTHOR_EMAIL="ganxin01@local"; $env:GIT_COMMITTER_NAME="ganxin01"; $env:GIT_COMMITTER_EMAIL="ganxin01@local"`
- 提交消息按用户全局格式：`type(scope): 一句话` + body 原因/改动/影响

## Review Focus

1. **ssh 会话断开导致测试中断** → stress 必须 `nohup` 后台 + 全部日志落盘文件，不依赖会话 → Task 1 测试（stub 后台 + 日志文件存在）。
2. **hdd 多盘并发日志串扰** → 每盘独立日志 `stress-HDDxx.log` + 独立 exitcode → Task 1 测试（2 个 stub 盘目录各自日志）。
3. **监控循环与 stress 生命周期不同步** → 监控进程随 stress 全部结束而自动退出 → Task 1 测试（短 stub 跑完监控 csv 有行且进程退出）。
4. **挂载脚本误格式化/误测非测试盘** → 逐盘确认 + 计划打印 + 单个 y 确认 + `DRY_RUN` 先看计划 → Task 2 测试（DRY_RUN 不执行任何写操作）。
5. **系统盘被纳入测试** → `df /` 识别并硬跳过 → Task 2 测试（list 输出标出系统盘；mount 计划不含系统盘）。
6. **多轮测试结果互相覆盖** → 结果目录 `<时间戳>-<类型>` 命名，永不覆盖 → Task 1 测试（两次 start 得到两个目录）。
7. **csv 编码导致 Excel 复盘乱码** → UTF-8 无 BOM，Excel 可直开 → Task 1 测试（检查首行字段与无 BOM）。
8. **status 时无任务在跑** → 清晰提示"无运行中的压测"，退出码 0，不报错 → Task 1 测试。

---

### Task 1: stress-test.sh（压测主控脚本）

**Files:**
- Create: `offline-stress-pkg/stress-test.sh`

**Interfaces:**
- Consumes: 既有安装好的 `stress`（`/usr/bin/stress`）；Task 2 挂载的 `/mnt/HDDxx`（hdd 模式）
- Produces（后续任务依赖）：
  - 子命令 `start cpu|mem|hdd [--model 5380|7380|7360|auto] [--timeout X] [--cpu N] [--vm N] [--vm-bytes X] [--hdd-bytes X] [--dirs "d1 d2"]`、`status`、`stop`、`review [--dir X]`
  - 结果目录：`$STRESS_TEST_ROOT/<YYYYmmdd-HHMMSS>-<type>/`，含 run-config.txt、info-before.txt、stress.log（hdd：每盘 stress-HDDxx.log + stress-HDDxx.exitcode）、monitor.csv、summary.txt
  - PID 记录：结果目录内 stress.pids、monitor.pid（stop 用）
  - 根级 `operations.log` 记录每次 start/stop

- [ ] **Step 1: 编写 stress-test.sh**

按设计文档实现。关键契约：
1. 参数解析（`--model` 缺省 `auto`：mem≥800G→7380；nproc≥120→5380；否则 7360；打印"检测到机型 X，使用预设参数"）；`--timeout` 缺省 `12h`；显式参数覆盖预设
2. `start`：校验 `command -v stress` → 建结果目录（时间戳）→ 写 run-config.txt（机型/参数/开始时间/命令原文）与 info-before.txt（lscpu/free -h/df -h/lsblk/stress --version）→ 逐条 `nohup` 后台启动 stress（日志重定向；hdd 每盘一条，命令内 `echo $? > stress-HDDxx.exitcode`；cpu/mem 单条 `echo $? > stress.exitcode`）→ 记录 PIDs → 后台启动监控循环（每 `MONITOR_INTERVAL` 秒读 /proc 写一行 CSV；当 stress.pids 全部消失即退出）→ 打印结果目录与 `stress-test.sh status` 提示
3. `status`：查 stress.pids 存活数 → 打印运行中任务、结果目录、`tail -5 monitor.csv`、剩余时长估算（run-config 开始时间+timeout 推算）；无任务 → "无运行中的压测" 退出 0
4. `stop`：按 stress.pids 杀进程、杀 monitor.pid、写 operations.log
5. `review [--dir]`：缺省取最新结果目录 → 解析 monitor.csv 统计（行数/时长/CPU 均值峰值/内存峰值/IO 峰值）、各 stress exitcode、run-config 起止 → 生成 summary.txt 并打印
6. 监控实现：CPU% 用 `/proc/stat` 两次采样差值；磁盘 IO 用 `/proc/diskstats` 全部设备 sectors 差值×512 字节；`awk` 计算；CSV 首行表头
7. 不 `set -e`；结果目录不存在时各子命令给出清晰提示

- [ ] **Step 2: 语法检查（WSL）**

Run: `bash -n /mnt/c/Users/ganxin01/Documents/trae-work/ServerSystemTest/offline-stress-pkg/stress-test.sh`
Expected: 无输出，退出码 0

- [ ] **Step 3: stub 冒烟测试（WSL）**

构造：临时目录 `$STUB_BIN` 放假 stress（`#!/bin/bash`；`--version` 打印 `stress 1.0.4`；其余参数忽略；`sleep 3`；打印 `successful run completed`），临时结果根 `$TMP_ROOT`。执行：
```bash
export PATH="$STUB_BIN:$PATH" STRESS_TEST_ROOT="$TMP_ROOT" MONITOR_INTERVAL=1
cd /mnt/c/Users/ganxin01/Documents/trae-work/ServerSystemTest/offline-stress-pkg
bash stress-test.sh start cpu --timeout 3
```
Expected: 结果目录 `<ts>-cpu/` 生成，含 run-config.txt、info-before.txt、stress.log、monitor.csv（≥2 行数据，首行表头，UTF-8 无 BOM 字节检查：`head -c 3` ≠ `EF BB BF`）；`bash stress-test.sh status` 显示运行中；等 stub 退出后 `bash stress-test.sh status` 显示"无运行中的压测"退出 0；`bash stress-test.sh review` 生成 summary.txt（含起止/时长/CPU 统计/退出码）且打印

- [ ] **Step 4: hdd 模式 + 多轮不覆盖测试（WSL）**

构造假挂载点目录 `$TMP_ROOT/fakehdds/HDD01`、`HDD02`，执行 `bash stress-test.sh start hdd --timeout 3 --dirs "$TMP_ROOT/fakehdds/HDD01 $TMP_ROOT/fakehdds/HDD02"`；再对 cpu 跑一次 `start cpu --timeout 3`。
Expected: hdd 模式产生 stress-HDD01.log / stress-HDD02.log / 各自 .exitcode 两份独立文件；两次 start 得到**两个不同**结果目录（时间戳不同，互不覆盖）；hdd 完成后 monitor 进程自动退出（`ps` 中无该 monitor 循环）

- [ ] **Step 5: Commit**

```bash
git add offline-stress-pkg/stress-test.sh
git commit -m "feat(offline-stress): 新增压测主控脚本 stress-test.sh

- 原因：三类机型 CPU/内存/硬盘压测需统一入口与数据落盘
- 改动：start/status/stop/review 子命令、三机型预设、30s /proc 监控、摘要生成
- 影响：WSL stub 冒烟测试通过；真实 12h 留服务器侧验收"
```

---

### Task 2: disk-mount.sh（挂载辅助脚本）

**Files:**
- Create: `offline-stress-pkg/disk-mount.sh`

**Interfaces:**
- Consumes: 服务器块设备（`lsblk`、`/dev/sd*`、`/dev/nvme*`）；`df /` 识别系统盘
- Produces（供 Task 1 hdd 模式使用）：挂载好的 `/mnt/HDDxx` 目录、`mount.log`（挂载全步骤时间/命令/结果）
- 子命令：`list`、`mount [--disks sdb,sdc]`、`umount [--all]`；测试接缝 `DRY_RUN=1`、`SKIP_ROOT_CHECK=1`

- [ ] **Step 1: 编写 disk-mount.sh**

按设计文档实现。关键契约：
1. root 检查（`SKIP_ROOT_CHECK=1` 可跳过，测试用）；不 `set -e`
2. `list`：`lsblk -o NAME,SIZE,TYPE,MOUNTPOINT`；用 `df /` 的底层设备（如 sda）标出系统盘"（系统盘，跳过）"；输出已挂载/未分区状态
3. `mount` 流程：收集非系统块设备（TYPE=disk）→ 交互列出并提示"输入要纳入测试的盘符（逗号分隔，all 全部）："（或 `--disks sdb,sdc` 直接指定）→ 打印完整执行计划（每盘：设备/容量/动作：mkfs.ext4 -m 0 后挂载 或 直接挂载，目标 /mnt/HDDxx）→ 单个 `y` 确认 → 执行（无分区 → `mkfs.ext4 -m 0 <dev>` 后挂载；有分区 → 直接挂载分区）→ 每步 `echo "[$(date)] cmd: ... 结果:$?"` 追加到 mount.log；`DRY_RUN=1` 时只打印计划与"（DRY RUN，未执行）"不执行
4. 系统盘（`df /` 底层设备）在任何分支都硬跳过；选择包含系统盘时拒绝并提示
5. 挂载点编号：按选定盘顺序从 01 递增；已挂载的盘跳过并注明
6. `umount`：列出已挂载测试点 → 确认（`--all` 跳过确认）→ 逐个 umount → 写 mount.log
7. 交互不可用（无 TTY）时要求 `--disks`，否则报错提示

- [ ] **Step 2: 语法检查（WSL）**

Run: `bash -n /mnt/c/Users/ganxin01/Documents/trae-work/ServerSystemTest/offline-stress-pkg/disk-mount.sh`
Expected: 无输出，退出码 0

- [ ] **Step 3: 只读与安全分支测试（WSL）**

Run:
```bash
cd /mnt/c/Users/ganxin01/Documents/trae-work/ServerSystemTest/offline-stress-pkg
bash disk-mount.sh list              # 只读，应正常输出且标出系统盘（WSL 无 /dev/sd* 则输出"未发现非系统盘"）
SKIP_ROOT_CHECK=1 DRY_RUN=1 bash disk-mount.sh mount --disks /dev/nonexist   # 不存在盘 → 报错退出 1，无任何写操作
SKIP_ROOT_CHECK=1 DRY_RUN=1 bash disk-mount.sh mount --disks sda            # 系统盘 → 拒绝退出 1
SKIP_ROOT_CHECK=1 DRY_RUN=1 bash disk-mount.sh mount                         # 无 TTY 且无 --disks → 提示需 --disks 退出 1
```
Expected: 4 个分支行为与上述一致，全程无 mkfs/mount 写操作（DRY_RUN 生效）

- [ ] **Step 4: Commit**

```bash
git add offline-stress-pkg/disk-mount.sh
git commit -m "feat(offline-stress): 新增挂载辅助脚本 disk-mount.sh

- 原因：硬盘压测前需挂载测试盘，且必须逐盘确认防误测
- 改动：list/mount/umount、逐盘确认、DRY_RUN、系统盘硬跳过、mount.log
- 影响：WSL 只读与安全分支测试通过；真实挂载留服务器侧验收"
```

---

### Task 3: 压测实操手册.md（实操文档）

**Files:**
- Create: `offline-stress-pkg/压测实操手册.md`

**Interfaces:**
- Consumes: Task 1-2 脚本用法、三机型参数预设、既有 README/install.sh
- Produces: 服务器操作人员的完整手册

- [ ] **Step 1: 编写 压测实操手册.md**

内容清单（设计文档定，缺一条即不通过）：
1. 适用环境与准备（三机型；先 `sudo bash install.sh` 装 stress、`bash verify.sh` 验证）
2. 快速上手三条命令：CPU（`bash stress-test.sh start cpu`）、内存（`bash stress-test.sh start mem`）、硬盘（挂载后 `bash stress-test.sh start hdd`）
3. 硬盘测试完整流程：`list` → `mount`（含逐盘选择、计划确认、DRY_RUN 说明、空盘自动格式化提示）→ `start hdd` → 完成后 `umount`
4. 查看测试状态：`status`、`tail -f <结果目录>/monitor.csv`、各日志说明
5. 测完复盘：`review`（summary.txt 说明、原始数据文件清单与含义）
6. 数据拷回 U 盘：`cp -r /root/stress-test/* /mnt/usb/`（示例）
7. 常见问题：--timeout 单位（秒/时，`60` 或 `12h`）、进程被杀/中断、目录已存在、盘未挂载、监控进程退出条件、--model 检测规则（mem/nproc 判定）与手动指定
8. 三机型参数预设表（与设计文档一致）与"显式参数可覆盖"说明
9. 安全提示：系统盘永不测试、测试盘为空盘前提、执行前确认计划

- [ ] **Step 2: 按清单自查**

逐项勾选上面 9 条均在文档中，且所有命令与 Task 1-2 脚本实际用法一致。

- [ ] **Step 3: Commit**

```bash
git add offline-stress-pkg/压测实操手册.md
git commit -m "docs(offline-stress): 新增压测实操手册"
```

---

### Task 4: README 更新 + 整包质检 + zip 重打包

**Files:**
- Modify: `offline-stress-pkg/README.md`（仅包结构一节 + 一行指引）
- Modify: `offline-stress-pkg.zip`（重打）
- 质检对象：整个 `offline-stress-pkg/`

**Interfaces:**
- Consumes: Task 1-3 全部产物
- Produces: 最终交付物（目录 + zip）

- [ ] **Step 1: 更新 README 包结构节**

在 README 的"包结构说明"部分追加三行（stress-test.sh、disk-mount.sh、压测实操手册.md），并在安装/验证说明后加一行：`压测实操见同目录 压测实操手册.md`。**除这两处外 README 其余内容一律不动。**

- [ ] **Step 2: 既有文件字节不变校验**

Run: 对比 install.sh / verify.sh / README.md(除指定两处)/ rpms/stress-1.0.4-24.el8.x86_64.rpm 与 Task 1-4 前的状态——校验方式：git 中这 4 个文件的 blob 与 HEAD 相比无意外 diff（`git diff --stat HEAD -- offline-stress-pkg/install.sh offline-stress-pkg/verify.sh offline-stress-pkg/rpms/` 应为空，README 的 diff 仅限指定两处）。
Expected: install.sh/verify.sh/RPM 零改动；README 仅指定两处

- [ ] **Step 3: 全脚本语法与 LF 复检（WSL）**

Run: `bash -n` 四个脚本（install.sh / verify.sh / stress-test.sh / disk-mount.sh）全过；`git ls-files --eol offline-stress-pkg/` 确认新增脚本 `i/lf`。
Expected: 全部退出码 0；新增脚本 blob 为 LF

- [ ] **Step 4: 重打 zip 并校验**

```powershell
Compress-Archive -Path "c:\Users\ganxin01\Documents\trae-work\ServerSystemTest\offline-stress-pkg" -DestinationPath "c:\Users\ganxin01\Documents\trae-work\ServerSystemTest\offline-stress-pkg.zip" -Force
# 解压到临时目录，逐文件 SHA256 与原目录一致（现为 7 个条目：4 旧 + 3 新）
```
Expected: 全部文件哈希 MATCH

- [ ] **Step 5: Commit**

```bash
git add offline-stress-pkg/README.md offline-stress-pkg.zip
git commit -m "chore(offline-stress): 更新 README 结构说明并重打离线包 zip"
```

---

### 终检（整支复查）

按 superpowers:subagent-driven-development 流程，全部任务完成后由**新 reviewer subagent** 对整支交付做复查：新增脚本与设计文档一致性、既有文件字节不变、zip 完整性、CRLF 防护继续生效、Review Focus 各条目。复查通过即交付。
