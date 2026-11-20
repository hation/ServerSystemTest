# 修复 oneclick full/--high 模式 CPU/内存参数默认值

- 日期：2026-11-20
- 状态：已确认
- 计划文件：docs/superpowers/plans/2026-11-20-oneclick-full-auto-params.md
- 分支：main（叠加现有未提交改动，不强制 commit）

## 背景与根因

`oneclick.sh` 的 `full`（中高强度整机压测，等价 `--high`）模式把 **"朋友方案"** 写死为：

```bash
FULL_CPU="${FULL_CPU:-45}"
FULL_VM="${FULL_VM:-12}"
FULL_VMBYTES="${FULL_VMBYTES:-24G}"
```

并在 `oneclick-lib-run.sh` 的 `write_plan` 的 `full` 分支（第 207 行）直接写入计划：

```bash
printf 'COMBO|combo|--peer-disks|%s|--cpu|%s|--vm|%s|--vm-bytes|%s\n' ... "$FULL_CPU" "$FULL_VM" "$FULL_VMBYTES"
```

结果：`--cpu 45 --vm 12 --vm-bytes 24G` 作为**显式参数**传给 `stress-test.sh start combo`，绕过了自动推导与上限裁剪。

事故：test-mission-5 的 7380（128 线程 / 16×64G / 1121G）因此只压了 CPU 45（应 100）、内存 288G（应 16×56G≈896G），实测 CPU 仅 ~50%，内存压力不足。

对照：`all` 模式（第 181 行）只写 `--peer-disks`，CPU/内存完全由 `stress-test.sh` 自动推导，从未出错。因此修复方向是让 `full` 默认也走自动推导，仅当用户显式设置 `FULL_*` 时使用显式值（保留换机覆盖能力）。

## 目标（修订 2026-11-20，用户确认）

- `full` / `--high` 模式在未显式设置 `FULL_CPU` / `FULL_VM` / `FULL_VMBYTES` 时，按**朋友规则推导**生成中高强度参数（区别于 all 的自动推导）：
  - `CPU = round(逻辑线程 × 70%)`（逻辑线程 = 物理核 × SMT 每核线程数，SMT 未知默认 2；物理核识别失败回退 nproc）
  - `VM = DIMM 根数`（dmidecode/EDAC 探测）
  - `vm-bytes = 脚本单根推导：单条容量 − max(单条/8, 6G)`（**不写死 8G**，复用脚本推导公式；用户确认）
  - 这些推导值作为**显式参数**写入 COMBO 计划（走显式路径：`--vm-bytes` 只告警不裁剪，同朋友方案）。
- 用户显式设置环境变量时，行为不变（显式值优先）。
- 验证基准：用户提供配置 2×5380（32 物理核 / 64 逻辑线程 / 384G / 12×32G）→ CPU 应推导出 45（round(64×70%)=45）、VM 12、vm-bytes 26G（32−max(4,6)=26G，脚本口径，区别于朋友写死的 24G）。
- 文档同步：README、operation-manual、oneclick-lib-basic、docs 四篇，以及"full 默认参数"口径改为"按朋友规则推导（CPU≈逻辑线程70%、VM=DIMM根数、vm-bytes=脚本单根推导）"。

## 任务

### Task 3：按朋友规则实现 full 默认推导（覆盖/修订 Task 1 的"默认空"实现）

1. `oneclick.sh` 或 `oneclick-lib-run.sh`：新增/复用推导函数，按上述朋友规则计算 FULL_CPU/FULL_VM/FULL_VMBYTES 的默认值（复用 stress-lib-common.sh 的探测函数：physical_cores/logical_cpus/smt_tpc/dimm_count_auto/dimm_cap_gib_uniform，若 oneclick 未加载该 lib 则 source 它）。
2. `oneclick-lib-run.sh` `write_plan` 的 `full` 分支：COMBO 行始终带 `--peer-disks`；FULL_CPU/FULL_VM/FULL_VMBYTES 使用推导默认值（非空），写入 `--cpu/--vm/--vm-bytes`；显式设置时用显式值。
3. 更新 Task 1 改的文档（README/operation-manual/oneclick-lib-basic）与 docs 四篇：full 默认口径从"未设置=自动推导同 all"改为"未设置=按朋友规则推导（CPU≈逻辑线程×70%、内存单条−8G，不裁剪）"；命令执行逻辑.md 相应段落与行号同步。
4. 验证：
   - `bash -n` 三个脚本；
   - 模拟：64 逻辑线程/12×32G → plan 行 `COMBO|combo|--peer-disks|N|--cpu|45|--vm|12|--vm-bytes|24G`；
   - 模拟：128 逻辑线程/16×64G → `--cpu|90|--vm|16|--vm-bytes|56G`（round(128×0.7)=90）；
   - 显式 `FULL_CPU=100` 时 → `--cpu|100|--vm|16|--vm-bytes|56G`（显式优先，其余推导）。
   - 注意 bash 整数运算取整：`round(x×70/100)` 用 `(x*70+50)/100` 形式。

## 全局约束

- 不修改 plan 格式约定（`|` 分隔）。
- 不破坏 `all` 模式与其它模式。
- 显式 FULL_* 覆盖能力保留。
- 不执行 git commit；改动留在工作区，以 `git diff` 追踪。
- 只改必需文件，不做额外重构。
