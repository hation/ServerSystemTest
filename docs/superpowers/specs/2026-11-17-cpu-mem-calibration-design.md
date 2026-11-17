> ⛔ **已被 v3 取代，仅存档（勿据此实现）**
>
> 现行方案见 [`2026-11-17-cpu-mem-general-allocation-design.md`](2026-11-17-cpu-mem-general-allocation-design.md)（v3 通用分配：物理核 ×1.5625、单条容量规则、三道上限）。本文件正文（机型预设 100/75/50 + 双上限）不再作为实现依据。

# CPU/内存参数标定：基础逻辑改造设计（已确认）

- 日期：2026-11-17
- 状态：用户已确认（“按这个方案修改基础逻辑”）
- 标定样本：用户提供的四组 2×海光 7380（64C/128T）案例
- 目标：给定同样的机器，脚本自动推导出的参数必须复现案例；未知机型按兜底公式；不改 CLI 语义、不改结论判定

## 1. 标定样本

| 案例 | 内存（模块） | DIMM | 案例 CPU | 案例 VM | 案例单 worker | 合计 | 占模块总容量 |
|---|---|---|---|---|---|---|---|
| 1 | 16×32G | 16 | 100 | 16 | 26G | 416G | 81.25% |
| 2 | 16×64G | 16 | 100 | 16 | 56G | 896G | 87.5% |
| 3 | 18×64G | 18 | 100 | 18 | 56G | 1008G | 87.5% |
| 4 | 24×32G | 24 | 100 | 24 | 26G | 624G | 81.25% |

## 2. CPU 推导（新）

```text
显式 --cpu                       → 原值
model ∈ {5380,7360,7380}         → 预设 50 / 75 / 100
其他（含 auto/未知）             → round(nproc × 78%)，最小 1
```

- `CPU_MAX_PCT` 默认值 86 → **78**；
- `cpu_workers_auto()` 由 floor 改为四舍五入：`(n*PCT + 50)/100`；
- 128→100、96→75、64→50；
- 注释/usage/run-config 的推导说明同步改为“nproc × 78%（四舍五入）”或“机型预设”；
- 机型交叉校验（`check_model_threads`）保留，不改参数。

## 3. 内存推导（新）

### 3.1 单根容量规则（案例口径）

当 DIMM 容量可探测且全部一致，且 worker 数等于 DIMM 根数：

```text
单根 GiB = 模块容量
预留     = clamp(单根/8, 6, 8) GiB      # 32→6, 64→8
单 worker = 单根 − 预留                  # 32→26, 64→56
总量     = 单 worker × 根数
```

### 3.2 双上限（用户已选）

```text
cap_module = 模块总容量(GiB) × 88%
cap_total  = MemTotal(MB) × 92%
cap        = min(cap_module, cap_total)
若总量 > cap：逐 GiB 下调单 worker，直到 ≤ cap；仍不足 1G 则报错/裁剪
```

- 常量：`MEM_MAX_PCT` 85 → **88**（模块总容量口径）；新增 `MEM_TOTAL_MAX_PCT=92`（MemTotal 口径）；
- `MEM_TARGET_PCT=82` 保留，仅用于“容量不可探测/混合容量”的兜底目标。

### 3.3 兜底路径

| 情况 | 目标 | 上限 |
|---|---|---|
| dmidecode 容量已知且一致，vm=DIMM 数 | 单根规则 | min(模块×88%, MemTotal×92%) |
| EDAC 只能给根数、无容量 | MemTotal×82% 均分 | MemTotal×92% |
| 混合容量 | MemTotal×82% 均分 | MemTotal×92% |
| 显式 `--vm-bytes` | 原样保留 | 只告警，不裁剪（沿用现状） |
| 显式 `--vm` 且 ≠ DIMM 数 | MemTotal×82% 均分 | MemTotal×92% |

### 3.4 四组案例的期望输出

| 案例 | 单 worker | 总量 | 模块上限（88%） | MemTotal 上限（92%，按正常可用内存） | 结果 |
|---|---|---|---|---|---|
| 1 | 26G | 416G | 450G | ≥470G | 复现 |
| 2 | 56G | 896G | 901G | ≥940G | 复现 |
| 3 | 56G | 1008G | 1013G | ≥1052G | 复现 |
| 4 | 26G | 624G | 675G | ≥705G | 复现 |

## 4. `--vm-keep`

- `mem` 与 `combo` 的 stress 参数固定追加 `--vm-keep`；
- `cpu` / `hdd` 不加；
- usage、启动命令回显、`run-config.txt`、`operations.log` 同步可见；
- 不改 timeout、不改判定、不改监控。

## 5. 显示与落盘（用于测试断言）

- CPU 说明：`（nproc 128 × 78%，四舍五入）` 或 `（机型 7380 预设）`；
- 内存说明至少包含：根数、单 worker、总量、单根容量、预留值、模块占比、双上限；
- `run-config.txt` 的命令行必须包含 `--vm-keep`；
- `operations.log` 的 `mem-plan` 行记录：`dimms`、`per`、`total`、`module_cap`、`total_cap`、`cpu`、`nproc`。

## 6. 实施任务（Subagent-driven）

1. **Task 1**：CPU 推导（预设 + 78% 四舍五入）+ 文案 + `t1_cpu.sh` 更新；reviewer 复查。
2. **Task 2**：内存推导（单根规则、双上限、兜底）+ 文案 + `t2_dimm_mem.sh`、memory-guard 用例更新；reviewer 复查。
3. **Task 3**：`--vm-keep` 命令组装 + 新用例 + 文案；reviewer 复查。
4. **Task 4**：更新 README/操作手册/指南/本设计关联文档，重打 zip，跑全部旧测试套件；整支最终复查。

## 7. 非目标

- 不改 `--model/--timeout/--cpu/--vm/--vm-bytes/--dirs/--sysdisk` 的 CLI 语义；
- 不改结论判定、监控项、dmesg 检测；
- 不引入新二进制（stress-ng/memtester/STREAM）；
- 不改 hdd 的 10G/worker 与每盘一进程模型。
