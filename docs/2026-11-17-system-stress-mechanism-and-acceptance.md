# 整机压测技术方案：CPU/内存/硬盘混合负载的分配、追踪与验收

- 日期：2026-11-17
- 状态：机制说明与验收口径（不含实测数据）
- 适用：Kylin V10 SP3、系统自带 `stress`、2P 海光平台
- 依据：`stress-test.sh`、`oneclick.sh`、`disk-mount.sh` 当前实现；`2026-11-17-cpu-mem-general-allocation-design.md`；`2026-11-17-oneclick-combo-orchestration-design.md`

## 0. 一页结论

1. **一套算法，两个入口**：单测 `stress-test.sh start ...` 与一键 `oneclick.sh` 共用同一套参数推导；oneclick 不复制公式，只负责挂载、拆分任务和启动终端。
2. **CPU 按逻辑线程分配（SMT 参与）**：`round(逻辑线程 × 25/32)`，逻辑线程 = 物理核 × 每核线程数（SMT 探测）；SMT 开启时 2×32C 的 128 逻辑线程得到 100 个 worker，占逻辑线程 78%，留 22% 给内存 worker、hdd、内核和监控；SMT 关闭时逻辑线程减半，worker 按 78.125% 推导（如 7380 → 50）。
3. **内存按内存条分配**：VM worker 数 = DIMM 根数；单 worker = 单条容量 − `max(6G, 单条/8)`；总量同时受“模块总容量 88%、MemTotal 92%、磁盘页缓存预留”三道上限约束，超限自动下调。
4. **场景 A（CPU+内存）**：一个 `stress` 进程同时跑 `--cpu` 与 `--vm --vm-keep`，一个结果目录，适合 CPU/DRAM 的功耗、发热、RAS 与调度验证。
5. **场景 B（CPU+内存+硬盘）**：一个 COMBO 任务（CPU+内存）+ 每块数据盘一个独立 HDD 任务 + 系统盘任务；各自终端与结果目录，`--peer-disks` 只把并发盘数带入 COMBO 的内存预留，不会二次压盘。
6. **效果追踪是五层证据链**：`run-config.txt`（分配依据）→ `monitor.csv`（运行曲线）→ `runtime-snapshot.txt`/`actual-params.txt`（实际参数、cwd、RSS、worker 数）→ `error.log`/`status.txt`（异常与退出状态）→ `review`/`summary.txt`（结论与执行一致性）。结论优先级为 **内核 I/O 错误 → ENOSPC → error.log → status.txt**；执行一致性 FAIL 只在原结论“正常”时改写。
7. **可靠性来自可复现，不是口号**：四组现场案例可被公式精确复现；9 个测试套件全部通过（核心 7 个套件 826 项断言，另有 spec-driven 142 项与 memory-guard 全套）；系统盘硬跳过、挂载校验、显式 `--rebuild`、blkid 重试、按盘归因等安全边界已落地。
8. **边界必须说清**：`stress` 是负载发生器，不是性能基准；不校验数据位翻转、不测内存带宽；混合场景的盘吞吐不能当性能数字；COMBO 无设备清单时 I/O 错误可能同时落到 COMBO 与对应盘任务（保守，不漏判）。

---

## 1. 组件与数据流

| 组件 | 职责 | 不负责 |
|---|---|---|
| `disk-mount.sh` | 识别非系统盘、挂载到 `/mnt/HDDxx`、按需分区/格式化 | 不启动压测 |
| `stress-test.sh` | **唯一的参数推导与压测执行入口**；监控、错误记录、复盘 | 不做挂载 |
| `oneclick.sh` | 挂载 → 生成任务计划 → 开终端/后台 → 等待 → 汇总 | 不计算 CPU/内存参数 |

数据流：

```text
disk-mount.sh mount
        │  /mnt/HDD01..N
        ▼
stress-test.sh start <cpu|mem|combo|hdd> [--dirs ...] [--peer-disks N]
        │  推导资源 → 写 run-config → 启动 stress → monitor-loop
        ▼
结果目录：run-config.txt / monitor.csv / runtime-snapshot.txt / actual-params.txt / runtime-final.txt / error.log / status.txt / *.exitcode
        │
        ▼
stress-test.sh review --dir <结果目录>  →  summary.txt / 结论 / 执行一致性
```

运行中可用 `stress-test.sh snapshot <结果目录>` 手动补抓一次进程快照（只作展示，不作为一致性证据）。

一键入口只做编排：`oneclick.sh` 的 `all` 计划为 `COMBO → HDD01..N → SYSDISK`，每条计划最终仍调用 `stress-test.sh start ...`（`oneclick-lib-run.sh L280-309`（写计划）、`L384-427`（`__task` 内执行 `bash <ST> start ...`））。

---

## 2. 资源分配机制

### 2.1 CPU：按逻辑线程定标（SMT 参与分配）

```text
物理核 C（lscpu 去重 Core+Socket；失败则 /proc/cpuinfo）
逻辑线程 L = C × 每核线程数（SMT 探测：开=2、关=1、未知默认开）
CPU worker = max(1, round(L × 25 / 32))     # SMT 开启时等价 round(C × 1.5625)
物理核识别失败 → round(nproc × 78%)
显式 --cpu 优先，不做二次调整
```

| 物理核（SMT 开启时） | CPU worker | SMT 开启时占逻辑线程 |
|---|---|---|
| 32C | 50 | 50/64 = 78% |
| 48C | 75 | 75/96 = 78% |
| 64C（2×32C） | **100** | 100/128 = 78% |
| 96C | 150 | 150/192 = 78% |

为什么是 25/32：现场四组案例都是 2×32C + `--cpu 100`（SMT 开启，128 逻辑线程），即“每个逻辑线程 25/32 个 worker”（等价“每个物理核 1.5625 个 worker”）。把它固化为逻辑线程系数后，任何新机型都能按物理核 × 每核线程数直接缩放，不需要机型表。SMT 开启时它等价于逻辑线程的 78%，留出的 22% 是共享池；SMT 关闭时逻辑线程减半，worker 按逻辑线程 78.125% 推导（5380→25、7360→38、7380→50），不再是 1.56 倍超订。

对应实现：`stress-lib-common.sh L97-120`（`cpu_workers_auto`）、`stress-lib-commands.sh L100-120`（`cmd_start` 推导）。

**SMT 状态探测与分配（方案A）**：`smt_tpc`/`smt_status` 函数（`stress-lib-common.sh L52-72` 的 `smt_tpc`、`L77-90` 的 `smt_status`），探测优先级 `lscpu "Thread(s) per core"` → `/sys/devices/system/cpu/smt/active` → `/sys/devices/system/cpu/smt/control` → 未知，输出 开(每核2线程) / 关(每核1线程) / 不支持 / 未知。SMT 状态**参与 CPU worker 分配**：逻辑线程 = 物理核 × 每核线程数（tpc，未知默认按开 tpc=2），worker = `round(逻辑线程 × 25/32)`（`cpu_workers_auto` 整数实现 `w=$(( (logical*25+16)/32 ))`，见 `stress-lib-common.sh L97-120`）；SMT 关闭（每核1线程）时逻辑线程减半，worker 相应减半：5380→25、7360→38、7380→50。探测结果同时用于：① 资源计划标注（run-config.txt 的 `smt=` 字段与 "SMT 状态:" 行）；② 机型交叉校验提示——实测线程 ≈ 标称一半时，若 SMT 关闭则提示 "SMT 关闭（每核1线程），逻辑线程减半属预期；CPU worker 将按逻辑线程 78.125% 推导"，SMT 开启/未知仍提示疑似单路 CPU。

### 2.2 内存：按内存条定标 + 三道上限

```text
VM worker = DIMM 根数
单 worker = 单条容量 − max(6G, 单条容量 / 8)
  32G → 26G（81.25%）
  64G → 56G（87.5%）
  128G → 112G（87.5%）

cap_module = 模块总容量 × 88%
cap_mem    = MemTotal × 92%
cap_disk   = MemTotal − (有效盘流 × hdd-bytes × 1.2 + 8G)
cap        = min(cap_module, cap_mem, cap_disk)
总量 > cap → 逐 GiB 下调单 worker
```

| 案例 | DIMM | 单 worker | 总量 | 占模块容量 | 主要约束 |
|---|---|---|---|---|---|
| 配置1 512G | 16×32G | 26G | 416G | 81.25% | cap_module |
| 配置2 1024G | 16×64G | 56G | 896G | 87.5% | cap_module |
| 配置3 1152G | 18×64G | 56G | 1008G | 87.5% | cap_module |
| 配置4 768G | 24×32G | 26G | 624G | 81.25% | cap_module |

兜底：

| 情况 | 处理 |
|---|---|
| 物理核识别失败 | `nproc × 78%` |
| DIMM 容量混合/EDAC 只有根数 | `MemTotal × 82%` 均分，上限 92% |
| DIMM 根数探测失败 | 中止，给出手动 `--vm` 示例 |
| 显式 `--vm-bytes` | 原样保留，只告警不裁剪 |

`mem`/`combo` 固定追加 `--vm-keep`：内存常驻并反复重写，避免默认 malloc→free 循环造成的脉冲式压力。对应实现：`stress-lib-commands.sh L193-230`（三道上限）、`L232-302`（单根推导/下调）、`L400-407`（命令组装）。

### 2.3 硬盘：一盘一流，页缓存单独预留

```text
每块数据盘：1 个 hdd worker，--hdd 1 --hdd-bytes 10G，cwd = 该盘挂载目录
系统盘：--sysdisk-only 时 1 个 worker，cwd = /stresstest-hdd
```

盘数只影响两件事：

1. hdd 进程数（D 个，各自独立终端/结果目录）；
2. 内存的 `cap_disk`：`MemTotal − (D × 10G × 1.2 + 8G)`，为页缓存/脏页留空间。

`--peer-disks N` 用于“COMBO 与独立盘任务并发”的编排：它只把 N 带入 `cap_disk`，**不启动任何 hdd 进程**；出现该参数时 COMBO 也不再自动扫描 `/mnt/HDD*`，避免二次压盘（`stress-lib-commands.sh L38-48`（校验）、`L139-142`（combo 不再自动扫描）、`L198-215`（盘流计数））。

12 盘 + 512G 的例子：`cap_disk = 512 − (12×10×1.2 + 8) = 360G`，16 个 worker 时单 worker 自动降到 22G，总量 352G；不会把页缓存挤没。

### 2.4 并发预算：100 个 CPU worker 留出的共享池

| 场景 | 可运行进程 | 共享池（128 线程） |
|---|---|---|
| A：CPU+内存 | 100 + 16~24 = 116~124 | 4~12 |
| B：CPU+内存+12 盘 | 100 + 16~24 + 12 = 128~136 | -8~0 |

hdd worker 大部分时间阻塞在 I/O，短时超订可以接受；CPU worker 不会把 hdd 完全饿死。若把 CPU worker 提到 128，VM 和 hdd 会被挤掉，盘测试吞吐会明显下降，因此 100 是“CPU 压满 + 盘可运行”的折中。

---

## 3. 场景 A：CPU+内存组合压测

### 3.1 进程结构

```text
stress-test.sh start combo
  └─ stress --cpu 100 --vm N --vm-bytes X --vm-keep --timeout 10h
       ├─ 100 个 CPU worker（整数/浮点循环）
       └─ N 个 VM worker（malloc→写→常驻→重写）
  └─ monitor-loop（每 30s 采样，写 monitor.csv/error.log/status.txt）
```

一个 stress 进程、一个结果目录；没有磁盘负载。

### 3.2 四组配置的分配结果

| 配置 | CPU | VM | 单 worker | 总量 |
|---|---|---|---|---|
| 512G/16×32 | 100 | 16 | 26G | 416G |
| 1024G/16×64 | 100 | 16 | 56G | 896G |
| 1152G/18×64 | 100 | 18 | 56G | 1008G |
| 768G/24×32 | 100 | 24 | 26G | 624G |

### 3.3 追踪什么

| 证据 | 内容 | 位置 |
|---|---|---|
| 分配依据 | 物理核、nproc、CPU worker、DIMM、单 worker、三道上限、`--vm-keep` | `run-config.txt` 的 `资源计划` 行 |
| 运行曲线 | 时间、load1、CPU%、内存总量/已用/可用、swap、磁盘读写 MB/s | `monitor.csv` |
| 实际执行 | 每个 stress 进程的 cmdline、cwd、VmRSS、Threads；实际 `--cpu/--vm/--vm-bytes/--vm-keep` | `runtime-snapshot.txt`、`actual-params.txt` |
| 结束快照 | 最终状态、exitcode、最后一次实际参数 | `runtime-final.txt` |
| 异常 | 内核 I/O 错误、OOM、stress stderr | `error.log` |
| 退出状态 | `OK/FAILED/ABORTED/STOPPED`、OOM 标记 | `status.txt` |
| 结论 | 结论、CPU 均值/峰值、内存峰值、采样空洞、错误前 3 条、执行一致性 | `summary.txt` |

### 3.4 验收口径（场景 A）

| 维度 | 建议判据 | 谁来判 |
|---|---|---|
| CPU 负载 | 纯 CPU 阶段所有逻辑 CPU `%idle ≤ 5`；混合阶段 CPU% 均值 ≥ 90% | 人工看 `monitor.csv`/`mpstat` |
| 内存压力 | `mem_avail` 接近计划余量（±5%），`swap_used = 0` | 人工看 `monitor.csv` |
| 内存常驻 | VM 总量达到计划值，不出现周期性回落 | 人工看 `monitor.csv` |
| 内核/进程错误 | 无 `dmesg io:`、无 OOM、无 stress 非 0 退出 | 脚本 `review` |
| 结论 | `summary.txt` 为“正常”，且 `status=OK` | 脚本 `review` |
| 执行一致性 | `summary` 的 `== 执行一致性 ==` 为 PASS（旧目录可为 UNKNOWN） | 脚本 `review` |
| 时长 | 冒烟 30min；默认 10h；验收建议 24h | 运行参数 |

能证明：全核调度、DRAM 持续压力、CPU/内存功耗与散热、ECC/MCE 等 RAS 事件是否出现。
不能证明：内存带宽是否达标、数据位是否翻转、磁盘/网络是否可靠。

---

## 4. 场景 B：CPU+内存+硬盘混合压测

### 4.1 进程结构（oneclick all）

```text
批次目录 oneclick-YYYYmmdd-HHMMSS/
  ├─ COMBO 任务：stress --cpu 100 --vm N --vm-bytes X --vm-keep --peer-disks=N+1
  │     （一个终端、一个结果目录，不启动 hdd）
  ├─ HDD01 任务：cd /mnt/HDD01 && stress --hdd 1 --hdd-bytes 10G
  ├─ ...
  └─ SYSDISK 任务：cd /stresstest-hdd && stress --hdd 1 --hdd-bytes 10G
```

每个任务独立终端/后台进程、独立结果目录和监控；批次级 `summary` 聚合。COMBO 的 `--peer-disks` 等于“数据盘数 + 1（系统盘）”，只用于内存预留。

### 4.2 资源分配

| 配置 | 数据盘 | CPU | VM | 单 worker | COMBO 内存 | 每盘 hdd |
|---|---|---|---|---|---|---|
| 配置1 | 1 | 100 | 16 | 26G | 416G | 1 |
| 配置2 | 2 | 100 | 16 | 56G | 896G | 2 |
| 配置3 | 6 | 100 | 18 | 56G | 1008G | 6 |
| 配置4 | 2 | 100 | 24 | 26G | 624G | 2 |

12 盘 + 小内存时，`cap_disk` 会自动把 COMBO 单 worker 下调（512G → 22G，1024G → 约 54G，1152G → 约 55G），保证页缓存有空间。

### 4.3 追踪什么

| 对象 | 证据 | 说明 |
|---|---|---|
| COMBO | `run-config` 的 `peer_disks/disk_streams_eff/cap_disk_g`、`monitor.csv`、`error.log` | 证明 CPU/内存分配已为并发盘让路 |
| 每块盘 | 各自 `monitor.csv`、`error.log`、`summary.txt`、`devices.txt` | I/O 错误按设备名过滤，能定位到具体盘 |
| 运行证据 | 各自 `runtime-snapshot.txt`/`actual-params.txt`；COMBO 的实际 CPU/VM worker、每盘的实际 cwd/hdd 进程数 | 证明实际执行与计划一致 |
| 系统盘 | 独立结果目录 + 覆盖边界说明 | 只代表根文件系统，不代表整盘 |
| 批次 | `failed-tasks.txt`、`aborted`、批次 `summary` | 哪些盘启动失败/被跳过 |

已知边界：COMBO 没有 `--dirs` 时 `devices.txt` 为空，dmesg I/O 错误不过滤，可能同时落到 COMBO 和对应盘任务的 `error.log`。这是**保守判定**（不会漏掉盘错误），但 COMBO 的异常不能单独作为“CPU/内存故障”的证据，需看错误行里的设备名和对应盘任务。

### 4.4 验收口径（场景 B）

| 维度 | 建议判据 | 谁来判 |
|---|---|---|
| COMBO | 满足场景 A 的 CPU/内存判据；`cap_disk_g` 已按盘数扣减 | 人工 + `run-config` |
| 每块数据盘 | `summary` 正常；无 `dmesg io:`；无 ENOSPC；`devices.txt` 命中本盘 | 脚本 `review` |
| 系统盘 | 只按根文件系统压测判定；ENOSPC 标为空间不足而非盘故障 | 脚本 `review` |
| 批次 | `failed-tasks.txt` 为空；无 `aborted`；批次退出码 0 | 脚本/人工 |
| 执行一致性 | COMBO 与各盘任务的 `== 执行一致性 ==` 均为 PASS 或合理 UNKNOWN | 脚本 `review` |
| 盘健康 | NVMe `media errors`、`percentage_used`、温度无异常增长 | 人工 `nvme smart-log` |
| 时长 | 冒烟 30min；默认 10h；验收建议 24h | 运行参数 |

能证明：CPU/内存/PCIe/NVMe/RAID 卡在并发负载下的稳定性、页缓存与盘写回的相互影响、整机最大功耗与散热。
不能证明：单盘性能上限、顺序/随机 IOPS 是否达标、数据完整性。

---

## 5. 效果追踪与判定机制

### 5.1 `monitor.csv`

表头（`stress-lib-monitor.sh L68`）：

```text
时间,load1,cpu_usage%,mem_total,mem_used,mem_avail,swap_used,disk_read_MBps,disk_write_MBps
```

- 采样间隔默认 30s（`MONITOR_INTERVAL`）；
- `mem_*`/`swap_used` 来自 `/proc/meminfo`，单位 kB；
- `cpu_usage% = 1 − (idle + iowait)/total`，**iowait 计为空闲**，混合场景不能只看这个值判断 CPU 是否压满；
- 磁盘读写来自 `/proc/diskstats` 所有条目求和，是全局粗指标，可能包含分区重复计数，不能替代每盘 `iostat`/`fio`；
- `mem_used = MemTotal − MemFree`，包含页缓存；判断内存压力应看 `mem_avail` 和 `swap_used`。

### 5.2 错误与状态

- dmesg 增量检测：按时间戳/行数游标只处理新行；I/O 关键字包括 `EXT4-fs error`、`I/O error`、`Buffer I/O error`、`blk_update_request`、`critical medium error`、ata/nvme 失败等（`stress-lib-monitor.sh L89-134`）。
- 设备归因：每个 hdd/combo 任务写 `devices.txt`；命中行只写入匹配的任务；无匹配信息写 `error-unattributed.log`，不静默丢弃（`stress-lib-devices.sh L32-51`、`stress-lib-monitor.sh L185-196`）。
- `status.txt`：`OK`（退出码 0）、`FAILED`（非 0）、`ABORTED`（OOM/退出码缺失）、`STOPPED`（手动停止），并记录 `oom=yes/no`（`stress-lib-commands.sh L1178-1192`）。

### 5.3 `review` 结论优先级

| 顺序 | 条件 | 结论 |
|---|---|---|
| a | `error.log` 含 `dmesg io:` | 异常（内核 I/O 错误） |
| b | `error.log`/`error-HDD*.log`/`error-SYSDISK.log` 含 `No space left on device` | 异常（空间不足，非盘故障） |
| c | `error.log` 含 `检测到 stress` 或 `dmesg` | 异常（进程/内核报错） |
| d | `status.txt` | `OK`→正常；`FAILED`→异常；`ABORTED`→按 reason；`STOPPED`→已手动停止 |
| e | 无 `status.txt` | 旧目录兼容判定 |

实现：`stress-lib-commands.sh L762-1244`（cmd_review）。`status=OK` 不会覆盖已命中的 I/O/OOM/错误。

### 5.4 `summary.txt` 包含什么

结论、异常点（退出码、error.log 前 3 条、未归因 I/O 数）、运行状态、OOM、CPU 均值/峰值、内存峰值、磁盘读写峰值、采样空洞、覆盖边界。对应 `stress-lib-commands.sh L1094-1173`。

### 5.5 运行时证据链

目的：把“计划了什么”与“实际怎么跑”对拍，避免只有计划和结果、没有过程证据。

**快照时点**：启动后立即 `start`；运行 60s、600s；之后每 600s 一次；监控退出时写 `runtime-final.txt`。只有 `60s/600s/periodic` 参与一致性判定，`start` 只作展示。

**采集方式**：从 `stress.pids` 的 wrapper 出发，扫描 `/proc/*/status` 的 `PPid` 收集其全部后代（wrapper 已 exec 成 `stress` 时自身即 stress），不再按 cwd 额外纳入进程，避免并发/残留进程混入。

**`runtime-snapshot.txt`**：按块追加，每块记录时间、label、任务目录，以及每个进程的 `pid/ppid/cmdline/cwd/VmRSS/Threads/State`。

**`actual-params.txt`**：记录 `main_cpu/main_vm/main_vm_bytes/vm_keep/hdd_processes/hdd_dirs/rss_total_kb/found/label`；`found=0` 且已有 `found>0` 证据时不覆盖，手动 `snapshot` 也不覆盖已有的 60s/600s/periodic 证据。

**执行一致性（review/summary）**：

| 检查 | 判定 |
|---|---|
| CPU worker | 计划 `cpu_workers` vs 实际 `main_cpu` |
| VM worker | 计划 `dimms` vs 实际 `main_vm` |
| `--vm-keep` | mem/combo 必须为 yes |
| hdd 进程数 | 计划 `disk_streams` vs 实际 hdd 进程数，且 cwd 集合数须一致（peer 数只展示，不参与） |
| hdd cwd | 每个 hdd 进程的 cwd 必须在计划 dirs 集合内；cwd 不可读 → UNKNOWN |
| 常驻内存 | 600s/periodic 快照的 RSS 总量 vs 计划内存，误差 ≤15%；只有 60s → UNKNOWN |

结果三态：**PASS**（有 60s/600s/periodic 证据且一致）、**FAIL**（有 600s/periodic 证据且不一致）、**UNKNOWN**（旧目录、缺字段、只有 start/60s、cwd 不可读或 RSS 未到 600s）。UNKNOWN 不改变结论；FAIL 只在原结论为“正常”时改写为“异常（执行与计划不一致）”，I/O、ENOSPC、STOPPED 的优先级不变。

### 5.6 脚本自动判 vs 人工判

| 项目 | 脚本自动 | 人工补充 |
|---|---|---|
| 进程退出码 | 是 | — |
| 内核 I/O/OOM/ENOSPC | 是 | — |
| CPU 是否压满、频率、温度 | 否 | `mpstat`、`ipmitool`、`sensors` |
| 内存是否达到计划值 | 否（只记录峰值） | `monitor.csv` 的 `mem_avail` |
| 盘性能/健康 | 否 | `iostat`、`nvme smart-log` |
| 网络/电源冗余 | 否 | `iperf3`、拔电测试 |

---

## 6. 可靠性论证

1. **单一事实源**：CPU/内存/盘参数只在 `stress-test.sh` 推导；oneclick 只拼 `start ...` 命令，不出现公式或固定值。单测与一键的 `physical_cores/nproc/dimms/per_worker_g/cap_*` 可对拍（测试 A5）。
2. **案例可复现**：四组现场配置精确得到 100/16×26G、100/16×56G、100/18×56G、100/24×26G；新机型按物理核 × 每核线程数缩放，不依赖机型分支。
3. **三道上限防超配**：模块 88%、MemTotal 92%、盘页缓存预留取最小；12 盘小内存自动下调，不靠现场手工拍数。
4. **并发不重复压盘**：`--peer-disks` 出现即禁用 COMBO 自动扫描 `/mnt/HDD*`；只有显式 `--dirs` 才在 COMBO 内启动 hdd；每盘任务独立终端。
5. **结论不被 OK 掩盖**：I/O 错误优先级最高，`status=OK` 不能覆盖；ENOSPC 与盘故障分开。
6. **失败可继续、可追溯**：COMBO 失败中止；单盘失败跳过并继续，批次 rc=1，`failed-tasks.txt`/`commands.txt` 保留证据。
7. **安全边界**：系统盘硬跳过；默认不清盘，`--rebuild` 才重建；分区无文件系统才自动格式化；blkid 失败重试 5 次后跳过；mount 失败不启动压测。
8. **测试证据**：9 个套件全部通过；核心 7 个套件 826 项断言 0 失败（oneclick 89、visibility 73、dirs 92、hdd-align 233、calibration 83、combo 187、runtime 69），另有 spec-driven 142 项与 memory-guard 全套通过；变异验证确认断言不是空壳。
9. **执行可对拍**：`actual-params.txt` 记录实际 CPU/VM worker、`--vm-bytes`、`--vm-keep`、hdd 进程数与 cwd；`review` 与计划逐项比较，PASS/FAIL/UNKNOWN 三态，UNKNOWN 不误判，FAIL 不覆盖 I/O 优先级。
10. **运行快照可追溯**：60s/600s/每 600s 记录进程 cmdline、cwd、VmRSS、Threads；`runtime-final.txt` 保存最终状态，复盘可还原“当时到底怎么跑的”。

---

## 7. 边界与残余风险

| 风险/边界 | 影响 | 处理/说明 |
|---|---|---|
| `stress` 不是基准工具 | 只有负载，没有带宽/IOPS/延迟数字 | 需要性能数字时另跑 STREAM/fio/iperf3 |
| 不校验数据位 | 不能发现静默位翻转 | 依赖 ECC 计数器；需要时加 memtester |
| `monitor.csv` 的 CPU% 把 iowait 当空闲 | 混合场景 CPU 利用率被低估 | 看 `mpstat` 的 `%usr+%sys`；纯 CPU 阶段再判 idle |
| 磁盘 IO 是全局求和 | 可能重复计分区、无法分盘 | 分盘性能用 `iostat -x`/`fio`；本工具只做稳定性 |
| COMBO 无设备清单 | 盘 I/O 错误可能同时落到 COMBO 与盘任务 | 保守不漏判；按错误行的设备名和盘任务 `summary` 定位 |
| 12 盘 + 小内存页缓存紧张 | 盘吞吐下降、抖动 | `cap_disk` 自动下调；或分阶段先盘后混合 |
| dmesg 游标同时间戳 | 极少数同秒追加行可能漏检 | 关键字+时间窗口复核；关键场景保留完整 dmesg |
| SMT 关闭 | CPU worker 按逻辑线程（=物理核）78.125% 推导，worker 减半（如 7380 → 50），不再是 1.56 倍超订 | 属预期口径；需要保守时用 `--cpu` 覆盖 |
| 系统盘只测根文件系统 | 不覆盖 /boot、EFI、swap、未分配空间；LVM/RAID 可能跨盘 | `run-config`/`summary` 已注明，不宣称“整盘通过” |
| 默认 10h | 与现场 24h 不同 | 验收显式 `--timeout 24h` |
| 快照竞态/短任务 | 启动瞬间或 <60s 的任务可能没有 60s 以上证据 | 一致性判 UNKNOWN，不误判 FAIL；结论仍按 status/error |
| 手动 `snapshot` | 只作展示，不作为一致性证据 | 设计如此；证据只认 60s/600s/periodic |
| wrapper 已退出、stress 被 init 收养 | 该进程无法按 wrapper 树统计 | 少计而非误计；以成熟快照和盘任务证据为准 |
| 未在真实麒麟/海光验证 | 假二进制测试不能替代现场 | 首次现场先 30min 冒烟，核对 `run-config`、`runtime-snapshot` 与 `monitor.csv` |

---

## 8. 验收口径清单

### 场景 A（CPU+内存）

- [ ] `run-config.txt` 的 CPU/DIMM/单 worker/三道上限与预期一致；
- [ ] 纯 CPU 阶段 `%idle ≤ 5`；混合阶段 CPU% 均值 ≥ 90%；
- [ ] `mem_avail` 接近计划余量，`swap_used = 0`；
- [ ] `error.log` 无 `dmesg io:`、无 OOM；`status=OK`；
- [ ] `summary.txt` 结论“正常”；采样空洞可解释；
- [ ] `summary.txt` 的 `== 执行一致性 ==` 为 PASS（旧目录可为 UNKNOWN）；
- [ ] 时长满足要求（冒烟 30min / 默认 10h / 验收 24h）。

### 场景 B（CPU+内存+硬盘）

- [ ] 场景 A 的所有项；
- [ ] `run-config` 的 `peer_disks`、`cap_disk_g` 已按并发盘数扣减；
- [ ] 每块盘 `summary` 正常，`error.log` 无 I/O/ENOSPC；
- [ ] COMBO 与各盘任务的 `== 执行一致性 ==` 为 PASS 或合理 UNKNOWN；
- [ ] 批次 `failed-tasks.txt` 为空、无 `aborted`、批次退出码 0；
- [ ] `nvme smart-log` 的 media errors/温度/磨损无异常增长；
- [ ] 明确记录“盘吞吐不是性能数字”，性能另测。

### 判定规则

- 任何 `dmesg io:`、OOM、非 0 退出、ENOSPC（标为空间不足）→ 不通过；
- `status=OK` 但 `error.log` 命中 → 不通过；
- 只有“负载达到计划值 + 无错误 + 时长足够 + 证据文件齐全”才算压测到位。

---

## 9. 附录

### 9.1 公式速查

```text
CPU worker      = round(逻辑线程 × 25/32)     # 逻辑线程 = 物理核×每核线程数；SMT 开启时等价 round(物理核×1.5625)；失败回退 nproc×78%
VM worker       = DIMM 根数
单 worker       = 单条容量 − max(6G, 单条/8)
cap_module      = 模块总容量 × 88%
cap_mem         = MemTotal × 92%
cap_disk        = MemTotal − (盘流 × 10G × 1.2 + 8G)
cap             = min(cap_module, cap_mem, cap_disk)
hdd worker      = 每数据盘 1 个；系统盘单独 1 个
```

### 9.2 代码位置

| 机制 | 位置 |
|---|---|
| CPU 推导 | `stress-lib-common.sh L97-120`、`stress-lib-commands.sh L100-120` |
| 内存三道上限/单根推导 | `stress-lib-commands.sh L193-230`、`L232-302` |
| stress 参数组装 | `stress-lib-commands.sh L400-407` |
| 设备归因 | `stress-lib-devices.sh L32-51`、`stress-lib-monitor.sh L185-196` |
| 运行时快照/实际参数 | `stress-lib-snapshot.sh L4-217` |
| monitor 采样 | `stress-lib-monitor.sh L63-246` |
| dmesg 检测 | `stress-lib-monitor.sh L89-134` |
| status 判定 | `stress-lib-commands.sh L1178-1192` |
| review/执行一致性 | `stress-lib-commands.sh L762-1244`（cmd_review） |
| snapshot 子命令 | `stress-lib-commands.sh L1248-1255`（cmd_snapshot） |
| oneclick all 计划 | `oneclick-lib-run.sh L280-309` |
| 失败策略 | `oneclick-lib-run.sh L708-719`（failed-tasks.txt / COMBO 中止 / 单盘跳过）、`L741-744`（批次退出码） |

### 9.3 术语

- **COMBO**：CPU+内存组合任务，一个 stress 进程、一个结果目录；
- **peer-disks**：COMBO 之外并发运行的 hdd 流数量，只参与内存预留；
- **cap_disk**：为页缓存/脏页预留后允许的常驻内存上限；
- **压到位**：资源达到计划值、持续足够时长、且无内核/进程/空间错误。
