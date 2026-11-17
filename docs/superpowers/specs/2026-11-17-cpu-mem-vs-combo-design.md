> ⛔ **已被 v3 取代，仅存档（勿据此实现）**
>
> 现行方案见 [`2026-11-17-cpu-mem-general-allocation-design.md`](2026-11-17-cpu-mem-general-allocation-design.md)（v3 通用分配：物理核 ×1.5625、单条容量规则、三道上限）。本文件正文仍写 86%/85%/110 且未含 `--vm-keep`，不再作为实现依据。

# CPU/内存单独压测 vs CPU/内存/硬盘同时压测：两套方案

- 日期：2026-11-17
- 状态：待用户核对（核对通过后再进入实现/执行）
- 依据：`docs/superpowers/notes/2026-11-17-cpu-mem-stress-parameter-guide.md`、`offline-stress-pkg/stress-test.sh` 现行实现、独立只读核查结果
- 前提：已认可的“最小改动”——`mem`/`combo` 的 stress 命令追加 `--vm-keep`，其余默认值不变
- 核实范围：代码行为按现行脚本逐行核对；参数计算为本机复算；stress 语义依据 manpage；未在真实 Kylin 机器上执行（当前为 Windows 环境）

## 1. 两套方案一句话

| | 方案A：只压 CPU+内存 | 方案B：CPU+内存+硬盘同时压 |
|---|---|---|
| 命令 | `start combo`（不带 `--dirs`/`--sysdisk`） | `start combo --dirs "/mnt/HDD01 ..."` |
| 进程 | 1 个 stress：CPU worker + VM worker | 1 个 CPU/内存 stress + 每盘 1 个 hdd stress |
| 内存目标 | MemTotal × 82%（上限 85%） | 默认 82%；12 盘小内存机需下调（见 4.2） |
| 适合 | CPU/内存验收、性能与 RAS 观察 | 整机老化、供电/散热稳定性 |
| 不适合 | 无法发现盘、网卡、电源问题 | 盘吞吐/延迟不作为性能数字；写入寿命消耗大 |

## 2. 方案A：只跑 CPU+内存

### 2.1 命令

```bash
# 128 逻辑线程、DIMM 自动探测、默认 10h
bash stress-test.sh start combo --model 7380 --timeout 10h
```

不带 `--dirs` 时，combo 会提示“无数据盘（仅 CPU/内存）”后继续，不启动任何 hdd 进程。

需要把 CPU 与内存分开归因时，改为两次独立运行：

```bash
bash stress-test.sh start cpu --model 7380 --timeout 10h
bash stress-test.sh start mem --model 7380 --timeout 10h
```

### 2.2 参数（四组硬件，SMT 开启）

| | 逻辑线程 | CPU worker（86%） | DIMM 根数 | 单 worker | 内存合计 | 占 MemTotal | 余量 |
|---|---|---|---|---|---|---|---|
| 配置1（512G） | 128 | 110 | 16 | 26G | 416G | 81.25% | 96G |
| 配置2（1024G） | 128 | 110 | 16 | 52G | 832G | 81.25% | 192G |
| 配置3（1152G） | 128 | 110 | 18 | 52G | 936G | 81.25% | 216G |
| 配置4（768G） | 128 | 110 | 24 | 26G | 624G | 81.25% | 144G |

计算口径：`CPU worker = floor(nproc×86%)`；`单 worker = round(MemTotal×82% / DIMM数)`，结果不超过 `MemTotal×85%`。以现行 `mem_plan()` 为准，实际下发值可能因四舍五入比 82% 低 1~2 个百分点。

### 2.3 实际命令形态

```text
stress --cpu 110 --vm 16 --vm-bytes 52G --vm-keep --timeout 10h
```

### 2.4 预期与判据

- CPU：110 个纯 CPU worker + 16 个 VM worker，共约 126 个可运行进程，接近但不超过 128 逻辑线程；`mpstat` 看 `%usr+%sys`，不要只看 `%idle`。
- 内存：`--vm-keep` 让 81% 常驻，`MemAvailable` 稳定在 18%~19%，`si/so=0`。
- 若出现 OOM：说明现场有其他进程占用，或显式 `--vm-bytes` 超限；按现有逻辑，预设值会被裁到 85% 以内。
- 本方案不覆盖磁盘、网络、电源冗余。

## 3. 方案B：CPU+内存+硬盘同时压

### 3.1 命令

```bash
# 自动发现 /mnt/HDD*；也可显式 --dirs
bash stress-test.sh start combo --model 7380 --timeout 10h \
  --dirs "/mnt/HDD01 /mnt/HDD02 /mnt/HDD03"

# 需要系统盘一起压时追加（谨慎，见 3.4）
bash stress-test.sh start combo --model 7380 --timeout 10h \
  --dirs "/mnt/HDD01 /mnt/HDD02 /mnt/HDD03" --sysdisk
```

### 3.2 进程模型（已核实）

- 主进程：`stress --cpu 110 --vm N --vm-bytes X --vm-keep --timeout 10h`；
- 每块数据盘：单独一个 `stress --hdd 1 --hdd-bytes 10G --timeout 10h`，工作目录为该盘挂载点；
- `--sysdisk`：再起一个 hdd 进程，工作目录 `/stresstest-hdd`；
- 所有任务共用同一 `--timeout`，没有独立的盘测试时长。

### 3.3 内存与页缓存余量（本方案的核心约束）

每块盘每轮写 10G 再删除，循环到超时；页缓存/脏页需要空间。按“预留 = 盘数 × 10G × 1.2 + 8G”估算：

| 配置 | 数据盘数 | 需要预留 | 当前余量（82% 方案） | 结论 |
|---|---|---|---|---|
| 配置1（512G） | 1 | 20G | 96G | 充足 |
| 配置2（1024G） | 2 | 32G | 192G | 充足 |
| 配置3（1152G） | 6 | 80G | 216G | 充足 |
| 配置4（768G） | 2 | 32G | 144G | 充足 |
| 512G + 12 盘（现场常见） | 12 | 152G | 96G | **不足，需降到约 70%** |
| 768G + 12 盘 | 12 | 152G | 144G | 偏紧，建议 25G/worker（约 78%） |
| 1TB 及以上 + 12 盘 | 12 | 152G | ≥192G | 82% 可保持 |

余量不足时不会 OOM（页缓存可回收），但会出现 dirty throttling：盘写入被阻塞、`wa` 升高、吞吐下降，看起来像盘故障。

### 3.4 已知的额外问题

1. **盘测试结果失真**：CPU/内存满载下，盘吞吐/延迟没有性能参考价值，只能用于“是否报错、是否稳定”。
2. **错误归因是 combo 级**：`devices.txt` 汇总了所有数据盘（及 `--sysdisk` 的 `/`），dmesg I/O 错误只写入 combo 目录的 `error.log`，不会拆分到每块盘的 `error-HDDxx.log`；要靠错误行里的设备名（如 `sdb1`）反查。
3. **写入寿命**：hdd worker 是 write/unlink 循环。按 fsync 落盘、500MB/s 估算，单盘 10h 约 18TB；6 盘约 108TB。跑前确认盘的 DWPD/TBW 预算。
4. **CPU 争抢**：110 + VM + 盘数 个可运行进程，6 盘时约 132、12 盘时约 138，超过 128 逻辑线程；盘进程会被调度出去，吞吐进一步下降。
5. **功耗/温度**：CPU+内存+多块 NVMe 是整机最大功耗场景；2×800W 冗余的余量、NVMe 温度降速、CPU 降频都要现场观察。
6. **swap**：必须在压测前 `swapoff -a`，否则换页会污染盘测试并加速磨损。
7. **系统盘**：480G SATA SSD 连续写 10h 磨损明显，且根文件系统延迟升高会影响日志/ssh；长跑建议不带 `--sysdisk`。
8. **超时残留**：任务被 timeout 终止时，hdd 临时文件可能残留，结束后检查各盘空间。

## 4. 联合核实表

| # | 事实 | 证据 | 对方案A | 对方案B |
|---|---|---|---|---|
| 1 | CPU worker = `nproc × 86%`，显式 `--cpu` 绕过 | `stress-test.sh:36-40`、`:90-97`、`:391-405` | 110 个 | 同左 |
| 2 | 内存目标 82%、上限 85%，单 worker 四舍五入，worker=DIMM 数 | `stress-test.sh:188-206`、`:475-537` | 81.25% 常驻 | 同左，余量按 3.3 校核 |
| 3 | 当前 mem/combo **没有** `--vm-keep` | `stress-test.sh:637-644` | 本次改动点 | 同左 |
| 4 | combo 主进程不含 `--hdd`，每盘单独起 hdd 进程，共用 timeout | `stress-test.sh:706-724` | 无盘进程 | 关键差异 |
| 5 | 目录校验先于内存计划（可按盘数调整目标） | `stress-test.sh:411-459` 早于 `:475` | 不涉及 | 支持自动下调 |
| 6 | `devices.txt` 汇总数据盘 + 系统盘，dmesg 错误写 combo 级 `error.log` | `stress-test.sh:672-678`、`:1211-1214` | 不涉及 | 归因粒度限制 |
| 7 | 默认 timeout 10h | `stress-test.sh:329` | 可覆盖 | 所有任务同值 |
| 8 | 系统盘 hdd 工作目录 `/stresstest-hdd` | `stress-test.sh:721-723` | 不涉及 | 可选，建议长跑关闭 |

## 5. 建议的执行顺序

1. 先跑方案A（CPU+内存），确认 CPU/内存/RAS 无异常；
2. 再单独跑每块盘的 hdd（不叠加 CPU/内存），确认盘本身无问题；
3. 最后跑方案B做整机老化，只用于稳定性判定；
4. 任何阶段出现 UE/MCE/AER/OOM/重启/持续降频，立即停止并保留日志。

## 6. 待确认项

1. 方案B 是否按盘数自动下调内存目标（仅当 3.3 余量不足时触发），还是保持 82% 只在文档提示风险？
2. 方案B 是否默认包含 `--sysdisk`（本文建议不包含）。
3. 默认时长保持 10h，现场用 `--timeout 24h`，是否认可？
