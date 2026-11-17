# 服务器 CPU/内存压测：参数配置与验收指南

- 日期：2026-11-17
- 适用对象：2P 海光 7380（32C/64T ×2）及同类 x86 服务器；其他机型按本文公式换算
- 用途：解释现有压测参数（`--cpu 100`、`--vm N`、`--vm-bytes`）的来历，给出可复用的参数推导方法、到位判据与排查手册
- 结论先行：改造前的配法是"按内存条覆盖"的经验参数，能做出负载，但不能作为 CPU/内存验收；应按本文公式重新定标并补齐判据

> **当前实现（v3，2026-11-17 起）**：本仓库 `offline-stress-pkg/stress-test.sh` 已按 `2026-11-17-cpu-mem-general-allocation-design.md`（v3）实施，实际参数以 v3 为准：
>
> - CPU worker = `round(物理核数 × 1.5625)`（64 物理核 → 100；物理核识别失败回退 `round(nproc × 78%)`）；
> - VM worker = DIMM 根数；单 worker = `单条容量 − max(6G, 单条容量/8)`（32G→26G、64G→56G、128G→112G）；
> - 内存分配上限 = `min(模块总容量 × 88%, MemTotal × 92%, MemTotal − (盘数 × hdd-bytes × 1.2 + 8G))`，超限逐 GiB 下调；
> - `mem` / `combo` 固定追加 `--vm-keep`；显式 `--cpu` / `--vm` / `--vm-bytes` 优先。
>
> 下文第 1 节是改造前的四组历史参数拆解；第 3、4、7 节的通用建议（如 CPU = 逻辑线程 T、内存目标 = M×90%）与 v3 冲突处**一律以 v3 为准**，仅作方法论参考。

## 1. 现有四组参数拆解

### 1.1 原始数据

| | 内存 | 条数×容量 | CPU worker | VM worker | 单 worker | 压力合计 | 占物理内存 |
|---|---|---|---|---|---|---|---|
| 配置1 | 512G | 16×32G | 100 | 16 | 26G | 416G | 81.3% |
| 配置2 | 1024G | 16×64G | 100 | 16 | 56G | 896G | 87.5% |
| 配置3 | 1152G | 18×64G | 100 | 18 | 56G | 1008G | 87.5% |
| 配置4 | 768G | 24×32G | 100 | 24 | 26G | 624G | 81.3% |

### 1.2 三条规律

1. **CPU worker 恒为 100，与内存无关。**
   2×海光 7380 = 64 物理核 / 128 逻辑线程（SMT 开启）。
   - 100 ≈ 64 × 1.56，接近"物理核数 × 1.5 再凑整"，不是从"打满逻辑线程"推导的；
   - 纯 CPU worker 只覆盖 78% 的逻辑线程；
   - 若 BIOS 关闭 SMT（64 逻辑），100 又是 1.56 倍超订。
   同一个数字在两种 BIOS 设置下含义完全不同，**不可跨机型/跨 BIOS 直接复用**。

2. **VM worker 数 = 内存条数。**
   16/16/18/24 与 DIMM 数完全一致，设计意图是"一根内存条配一个进程"，让每条 DIMM 都被写到。但 Linux 无法把进程绑定到某根 DIMM，实际由内核在通道/NUMA 间交错，"一条一进程"只是覆盖概率，不是精确覆盖。

3. **`--vm-bytes` 按单条容量缩放，留 6~8G 余量。**
   32G → 26G（81.25%），64G → 56G（87.5%）。本质是"单条容量 − 6~8GB（内核、页缓存、进程自身）"。两个百分比不一致，说明是逐机型手调的经验值。

### 1.3 命令层面的问题

- `--vm-bytes 56 G`（配置2，中间有空格）、`--vm 24--vm-bytes`（配置4，缺空格）会被解析失败或忽略，需核对现场脚本；
- 未加 `--vm-keep`：stress 默认 malloc → 写一遍 → free → 再 malloc，RSS 周期性回落，内存压力是脉冲式的，峰值可能明显低于名义值；
- 未加 `--timeout`：默认无限运行，无法定义验收时长；
- CPU 与内存混合跑：CPU 总利用率看起来很高，但部分是缺页/内存写，出问题无法归因到 CPU 或内存。

### 1.4 能否达到目的

| 场景 | 结论 | 原因 |
|---|---|---|
| 整机通电/散热/供电冒烟 | 基本可以 | 有持续 CPU 负载，内存推到 80%+，无 OOM |
| CPU 性能/满载验收 | 不够 | worker 未按 `nproc` 定标，SMT 开/关结果不可比 |
| 内存容量/带宽验收 | 不够 | 压力不持续、无带宽指标、无数据校验 |
| 稳定性/RAS 老化 | 不够 | 无时长、无监控、无 ECC/MCE/温度判据 |

## 2. 服务器压测到底测什么

压测目标决定参数与判据，不能只看"CPU 和内存有没有跑满"。

1. **CPU**：全部逻辑线程持续满载、频率维持、SMT 调度、缓存与内存子系统、功耗与温度墙；
2. **内存**：容量覆盖（每条 DIMM/每个通道）、带宽（STREAM）、延迟、NUMA 本地性、ECC/RAS；
3. **存储**：NVMe 顺序/随机 IOPS、延迟、温度降速、掉盘；
4. **网络**：25G 双向线速、丢包/重传、链路 flap、PCIe AER；
5. **整机**：双电源冗余（满载拔一路）、风扇/风道、长时间稳定性、重启后自检。

单靠 `stress --cpu/--vm` 只覆盖第 1、2 项的一小部分，磁盘、网络、电源冗余必须单独测。

## 3. 通用参数配置方法

### 3.1 前置采集（每台机器先做一次）

```bash
lscpu                      # 物理核 C、逻辑线程 T、NUMA 节点 N
nproc                      # 逻辑线程数（T）
free -g                    # MemTotal（M）
dmidecode -t memory        # DIMM 数量 D、单条容量、Configured Speed
lsblk -d -o NAME,SIZE,ROTA # 数据盘清单
numactl -H                 # 每节点 CPU/内存
```

判断 SMT 是否开启：`nproc == 2 × 物理核` 即开启；相等即关闭。后文以"开启（T=128）"为例。

### 3.2 参数公式

> ⚠️ **与 v3 冲突处以 v3 为准**：现场脚本已按 v3 实施（CPU = 物理核 × 1.5625、内存按单条容量规则 + 三道上限、`mem`/`combo` 固定 `--vm-keep`），**不采用**本节的"CPU = 逻辑线程 T"与"内存目标 = M×90%"。以下公式仅作通用方法论参考。

```
C = 物理核数，T = 逻辑线程数，M = MemTotal(GiB)，D = DIMM 数，N = NUMA 节点数

CPU worker = T                 # 打满；要调度压力可 T×1.1~1.2（收益有限）
              SMT 关闭时用 C×1.1

内存目标   = M × 0.90          # 无 swap；预留 8~10%，且不少于 8GB/路
VM worker  = clamp(D, 2×N, T/4)   # 覆盖所有条/节点，又不过度抢 CPU
每 worker  = floor(内存目标 / VM worker)  # GiB，向下取整，单 worker ≥ 4G

必加：--vm-keep --timeout <时长>
```

原则说明：

- **CPU 以"逻辑线程"为准**：`$(nproc)` 是最稳妥的写法，SMT 开/关都不会拍错；
- **内存以"总容量百分比"为准**，不要以"单条百分比"为准；按条分配只是为了让 D 个 worker 均匀铺开；
- **留余量是为了避免 OOM 与抖动**：`stress` 默认 free/再 malloc，同一时刻可能出现瞬时双倍占用；
- **`--vm-keep` 让压力持续**：常驻并反复重写，才能测出持续带宽与发热；
- **`--vm-stride` 默认 4096**（每 4KB 写 1 字节）。要更接近真实访问，可用 stress-ng 的 `--vm-method` 或 memtester 做数据校验。

### 3.3 四组配置的推荐值（SMT 开启，T=128）

> ⚠️ 本表按"CPU = 逻辑线程 T、内存约 87.5%~90%"给出，**与 v3 冲突，现场以 v3 为准**（v3 四组案例为 CPU 100、单 worker 26G/56G、总量 416G/896G/1008G/624G）。

| | CPU worker | VM worker | `--vm-bytes`（稳妥） | 合计 | 激进值 | 备注 |
|---|---|---|---|---|---|---|
| 配置1 | 128 | 16 | 28G | 448G / 87.5% | 29G（464G，90.6%） | 16 条均衡，带宽最好 |
| 配置2 | 128 | 16 | 57G | 912G / 89% | 58G（928G，90.6%） | 同上 |
| 配置3 | 128 | 18 | 57G | 1026G / 89% | 58G（1044G，90.6%） | 18 条非均衡，建议补齐 16/32 条再测 |
| 配置4 | 128 | 24 | 28G | 672G / 87.5% | 29G（696G，90.6%） | 24 条非均衡，注意 2DPC 降频 |

SMT 关闭时，CPU worker 取 72（64×1.125），其余不变。

### 3.4 命令模板

```bash
# 阶段一：纯 CPU（先单独压，便于归因）
stress-ng --cpu "$(nproc)" --cpu-method all --timeout 24h --metrics-brief

# 阶段二：纯内存（容量 + 持续带宽）
stress-ng --vm 16 --vm-bytes 57G --vm-keep --timeout 24h --metrics-brief

# 阶段三：整机混合（最后再做）
stress-ng --cpu "$(nproc)" --cpu-method all \
          --vm 16 --vm-bytes 57G --vm-keep \
          --timeout 24h --metrics-brief
```

只有 `stress`（无 stress-ng）时的等价写法：

```bash
stress --cpu "$(nproc)" --vm 16 --vm-bytes 57G --vm-keep --timeout 24h
```

严谨做法：NUMA 绑定，每节点各起一组，内存不跨节点。

```bash
for n in $(seq 0 $((N-1))); do
  numactl --cpunodebind=$n --membind=$n \
    stress-ng --cpu $((T/N)) --vm $((D/N)) --vm-bytes $((per_node))G \
              --vm-keep --timeout 24h &
done; wait
```

### 3.5 分阶段执行（推荐顺序）

1. **纯 CPU** 30min：确认全核满载、频率/温度正常、无降频；
2. **纯内存容量** 30min：确认目标占用、无 OOM、`si/so=0`；
3. **内存带宽**：STREAM Triad，≥ 理论值 70%~80%；
4. **混合** 24h（验收）/72h（老化）：全程采集指标与 RAS 日志；
5. **存储/网络**：fio、iperf3 各 30min；
6. **电源冗余**：满载下按厂商流程断开一路 PSU，确认不断电、SEL 有记录；
7. **结论**：任一项不达标或出现 UE/MCE/OOM/重启即判失败。

## 4. 如何评估"压测到位"

先明确目的：老化看"零错误 + 时长"；性能看"吞吐/带宽/延迟"；散热供电看"频率/温度/功耗"。

| 维度 | 判据 | 采集命令 |
|---|---|---|
| CPU 占用 | 所有逻辑 CPU `%idle ≤ 5`（纯 CPU 阶段） | `mpstat -P ALL 1` |
| CPU 频率 | 全核负载下不低于基频，无持续降频 | `grep MHz /proc/cpuinfo`、`ipmitool sdr` |
| 温度/功耗 | 低于 Tjmax−10℃，功耗接近额定，无 throttle 日志 | `ipmitool sdr type temperature`、`dmesg \| grep -i throttl` |
| 内存占用 | `MemAvailable` 达到目标值 ±5%，`si/so = 0` | `free -g`、`vmstat 1` |
| 内存带宽 | STREAM Triad ≥ 理论值 70%~80% | `numactl -H`、STREAM |
| 数据/ECC | UE=0；CE 不新增；无 MCE | `edac-util -v`、`journalctl -k \| grep -iE 'mce\|edac'` |
| 内核 | 无 I/O error、AER、OOM、link down | `journalctl -k -p err` |
| 稳定性 | 24h/72h 无重启、无告警 | `uptime`、`ipmitool sel list` |

理论内存带宽参考：2P × 8 通道 DDR4-2666 ≈ **341 GB/s**；2DPC 或非均衡插法会降频，实际以 `dmidecode -t memory` 的 Configured Speed 为准。STREAM 数组需远大于 L3（建议 ≥ 8GB）。

## 5. 出问题怎么排查

| 现象 | 第一步 | 判定/处理 |
|---|---|---|
| 进程被杀、机器卡死 | `dmesg -T \| grep -i oom` | 目标过高/无 `--vm-keep` 导致重复分配；降 per-worker 或加 keep |
| CPU 利用率上不去 | `nproc`、`lscpu`、`mpstat -P ALL` | SMT 是否开启、cgroup/CPU 配额、worker 数是否 < 逻辑线程 |
| 频率掉、性能衰减 | `ipmitool sdr`、`sensors`、`dmesg \| grep throttl` | 温度墙/功耗墙/风扇策略，检查风道与 PSU |
| 随机重启/宕机 | `ipmitool sel list`、`mcelog`/`rasdaemon`、kdump | 保留 SEL 与 vmcore，按 MCE/内存/PSU 分类 |
| ECC 报错 | `edac-util -v`、`/sys/devices/system/edac/mc/*/{ce,ue}_count` | CE 持续增长需记录定位；UE 直接失败并更换 DIMM |
| NVMe 掉盘/降速 | `nvme smart-log /dev/nvmeXn1`、`dmesg \| grep nvme` | 温度、media errors、PCIe 降速 |
| 网络异常 | `ethtool -S`、`ip -s link`、iperf3 重传 | 光模块、链路 flap、AER |
| 无法归因 | 分阶段单独跑 CPU-only / 内存-only | 不要一开始就混合压测 |

## 6. 平台差异与注意事项

1. **SMT 状态决定 CPU worker 含义**：先用 `nproc` 确认，不要写死 100。
2. **DIMM 均衡性影响带宽**：16 条（每路 8 条，1DPC）最均衡；18/24 条在常见 32 槽平台上属于非均衡插法（每路 9/12 条），可能触发 2DPC 降频，结果不能与均衡配置直接比较。
3. **海光 7380 频率**：基频 2.2GHz，满载全核频率以 `ipmitool`/`/proc/cpuinfo` 实测为准，不能按标称值判定。
4. **电源冗余**：2×800W 冗余，满载整机功耗可能接近单模块上限，必须做"满载拔一路"验证（按厂商流程）。
5. **stress 的局限**：CPU 压力以 sqrt 循环为主，不含 AVX 类高热负载；内存只按页写 1 字节、不校验数据。需要更严格时用 `stress-ng`（`--cpu-method matrixprod/fft/all`、`--vm-method`）与 `memtester`。
6. **Swappiness/overcommit**：内存验收前建议 `swapoff -a`，并确认 `vm.overcommit_memory` 策略，避免把 swap 抖动误判为内存故障。

## 7. 验收清单（可直接勾）

- [ ] 已采集 `lscpu`/`nproc`/`free`/`dmidecode -t memory`/`numactl -H` 并记录 C/T/M/D/N
- [ ] CPU worker = T（或 C×1.1，SMT 关闭），纯 CPU 阶段 `%idle ≤ 5`（**现场 v3 为 C×1.5625，以 v3 为准**）
- [ ] 内存目标 = M×90%，VM worker 按公式，全部加 `--vm-keep`（**现场 v3 按单条容量规则 + 三道上限，以 v3 为准**）
- [ ] `--timeout` 明确（30min 冒烟 / 24h 验收 / 72h 老化）
- [ ] 全程采集 `mpstat`/`vmstat`/`free`/STREAM/`edac`/`ipmitool sdr`/`journalctl -k`
- [ ] UE=0、无 MCE、无 AER、无 OOM、无重启、无持续降频
- [ ] 内存带宽达到理论值 70% 以上
- [ ] 磁盘 fio、网络 iperf3、电源冗余各自单独通过
- [ ] 报告记录机型、BIOS SMT、内存插法、参数、时长、判据与原始日志路径

## 8. 参考

- 联想 ThinkServer SR658H V2（海光 7380：32 核 64 线程、DDR4、32 DIMM 槽）参数页
- stress(1) manpage：`--vm`、`--vm-bytes`、`--vm-keep`、`--vm-stride` 语义
- stress-ng(1) manpage：`--vm`、`--page-in` 等内存压力选项
