# 服务器组合负载压测分析报告（7380 · combo · 2026-11-17）

| 项目 | 内容 |
|---|---|
| 报告编号 | STRESS-NT3-FINAL-20261117 |
| 数据目录 | `tmp/newtest-3/`（`stress-test-1`、`stress-test-2` 两个容器，均为完整 1h 运行） |
| 测试机型 | Hygon C86-3G 7380 32-core Processor（128 逻辑线程 / 64 物理核） |
| 测试类型 | combo（CPU + 内存，`--peer-disks 0`，无磁盘任务） |
| 内存配置 | 1877 GiB（32 条 × 64 GiB） |
| 启动参数 | `stress --cpu 110 --vm 32 --vm-bytes 56G --vm-keep --timeout 1h` |
| 实测时长 | 3607s（09:26 批）/ 3603s（17:18 批） |
| 综合判定 | **OK · 运行正常，CPU/内存压力功能有效** |

## 1. 结论摘要

1. **运行正常**：两批均跑满 1 小时并正常收尾——`stress.log` 有 `successful run completed in 3607s / 3603s`，`stress.exitcode=0`，`status.txt` 均为 `state=OK / reason=all-exitcode-zero / oom=no`，`runtime-final.txt` 齐全。
2. **功能有效**：
   - CPU 压力有效：112 个稳态采样点 CPU 使用率 **100.0%（最低也是 100.0%）**，load1 均值 141.6 / 141.7，与 110 个 CPU worker + 32 个 VM worker 的配置相符；
   - 内存压力有效：`--vm-keep` 常驻生效，内存稳定在 **1798.8–1799.0 GiB**（占 MemTotal 的 **95.8%**），1 小时内无回落；结束后 30 秒内释放至 3.6–87.7 GiB；
   - 监控与判定有效：每批 116 个采样点、约 30s 节拍，`status.txt` / `exitcode` / `runtime-final.txt` 三件套齐全。
3. **稳定性**：swap 全程 0，无 OOM 记录，无非 0 退出码，无 write 相关错误；MemAvailable 稳定在 **73.2 GiB** 未继续恶化。
4. **参数风险仍在**：`--vm 32 --vm-bytes 56G` = 1792 GiB，超过脚本上限 1726 GiB（MemTotal×92%）66 GiB。本次 1 小时运行未出问题，但 95.8% 的内存占用没有多少余量，建议按 4 章修正。

## 2. 测试环境

| 项目 | 配置 |
|---|---|
| 机型 | Hygon C86-3G 7380 32-core Processor，64 物理核 / 128 线程 |
| 内存 | 1877 GiB（32 × 64 GiB），swap 4.0 GiB |
| 系统盘 | /dev/mapper/klas-root（392G，挂载 /） |
| 数据盘 | 本次未参与（`peer_disks=0`，`disk_streams_eff=0`，无 hdd 进程） |

## 3. 参数与执行结果

| 项目 | stress-test-2（09:26 批） | stress-test-1（17:18 批） |
|---|---|---|
| 开始时间 | 2026-11-17 09:26:35 | 2026-11-17 17:18:11 |
| 结束时间 | 2026-11-17 10:27:05 | 2026-11-17 18:18:44 |
| 实测时长 | 3607s | 3603s |
| 退出码 | 0 | 0 |
| 收尾行 | `successful run completed in 3607s` | `successful run completed in 3603s` |
| `status.txt` | `OK / all-exitcode-zero` | `OK / all-exitcode-zero` |
| OOM | no | no |
| dmesg I/O | no | **yes（1 条，属误报，见 7.2）** |
| 采样点数 | 116 | 116 |

参数核查：

| 项目 | 数值 | 判定 |
|---|---|---|
| 内存需求 | 32 × 56G = 1792 GiB | 超过上限 |
| 分配上限 | MemTotal 1877 × 92% = 1726 GiB | 超 66 GiB |
| 实测占用 | 1798.8–1799.0 GiB（95.8%） | 比声明需求高约 7 GiB（进程自身开销） |
| CPU worker | 110 | 128 线程的 86%，实测 CPU 饱和 |
| 内存常驻 | `--vm-keep` | 生效，全程不释放 |

## 4. 资源指标（整机口径，剔除首尾各 2 点）

| 指标 | stress-test-2 | stress-test-1 |
|---|---|---|
| CPU 使用率均值 / 最低 | **100.0% / 100.0%** | **100.0% / 100.0%** |
| load1 均值 / 最高 | 141.7 / 142.9 | 141.6 / 143.0 |
| 内存峰值 | 1798.9 GiB（95.8%） | 1799.0 GiB（95.8%） |
| MemAvailable 最低 | 73.2 GiB | 73.2 GiB |
| swap 峰值 | 0 | 0 |
| 磁盘读写 | 读 0；写仅 3/116 个窗口非零（≤1.1 MB/s） | 读 0；写仅 9/116 个窗口非零（≤0.2 MB/s） |
| 内存释放 | 10:27:05 降至 3.6 GiB | 18:18:13 降至 87.7 GiB，18:18:43 降至 3.5 GiB |

说明：磁盘 I/O 接近 0 属预期——combo 未启动 hdd 进程；偶发非零为系统后台写入，与测试负载无关。

## 5. 采样质量

| 项目 | 结果 |
|---|---|
| 采样区间 | 3599s / 3602s（覆盖整个 1h） |
| 采样点数 | 116（理论 120，覆盖率 96.7%，≥90% 门槛） |
| 常规间隔 | 30s / 31s |
| 最大间隔 | 45s，每批各 6 次，恰好每 10 分钟一次 |
| 走时偏差 | 约 4.3%（3266→3579 区间累计），超过 1% 容差 |

成因：45s 间隔与 `runtime-snapshot` 的 600s periodic 抓取一一对应（扫描 144 个进程约 15s），阻塞了监控循环，不是系统停摆或时钟跳变。运行时长以 `stress` 收尾行的 3603s / 3607s 为准，不受该偏差影响。

## 6. 判定（依据解读方案 v3）

| 闸门 | 结论 |
|---|---|
| B 运行完整性 | **B1**：每个任务 `exitcode=0` 且有收尾行 → 正常结束（确定） |
| C 指标口径 | 纯 CPU+内存混合，整机口径可用；不拆分单项性能数字 |
| D 覆盖性 | 无数据盘任务（`disk_streams_eff=0`），覆盖项不适用 |
| E 观测有效性（负载达成） | CPU 100%（≥90% 达标）；内存 1799.0 GiB ≥ 声明目标 1792 GiB 的 100%，远超 80% 门槛；swap=0、无 OOM |
| 时间锚点 | 服务器时间连续，收尾时间与 `timeout 1h` 自洽 |

**综合判定：OK。** 组合负载下整机稳定，负载真实加上且 1 小时无异常。

## 7. 稳定性与异常

### 7.1 稳定性

- 112 个稳态采样点中 CPU 始终 100%，load 稳定在 140±3，无抖动或塌陷；
- 内存曲线：启动后约 90 秒爬满 1798.9 GiB，此后 59 分钟保持平稳，结束后干净释放；
- swap 全程 0，`oom=no`，无非 0 退出码，无 stress 错误输出。

### 7.2 唯一一条 dmesg 记录（误报）

```
[2026-11-17 18:06:14] dmesg io: [ 3720.993241] EXT4-fs (nvme0n1): mounted filesystem with ordered data mode. Opts: errors=remount-ro
```

这是 `nvme0n1` 在测试期间被挂载的内核消息，因包含 `Opts: errors=remount-ro` 命中脚本 I/O 正则（`EXT4-fs .*error`）被记入，**不是磁盘错误**；因此 `stress-test-1` 的 `status.txt` 记为 `io=yes`，但状态仍是 `OK`。该批 18:06 有人挂载了这块盘，与 CPU/内存测试无冲突。

## 8. 功能有效性评估

| 功能 | 是否有效 | 证据 |
|---|---|---|
| CPU 压力（110 worker） | **有效** | CPU 100% 持续 112 个采样点；load1 ≈ 142，与 worker 数匹配 |
| 内存压力（32 × 56G，keep） | **有效** | 1798.8–1799.0 GiB 常驻 1 小时，结束即释放；swap/OOM 均为 0 |
| 监控采集 | **有效** | 每批 116 点、覆盖率 96.7%、最大间隔 45s，无空洞 |
| 状态判定与收尾 | **有效** | `status.txt`（OK）、`stress.exitcode=0`、`runtime-final.txt`、收尾行齐全 |
| OOM / I/O 检测 | **部分有效** | OOM 判定正确（no）；I/O 正则存在误报（挂载事件被记为 dmesg io） |
| 内存上限保护 | **未生效（设计如此）** | 显式 `--vm-bytes` 超上限只告警、不裁剪，本次超 66 GiB 仍继续执行 |

## 9. 适用范围

- 仅说明“CPU + 内存组合负载下整机稳定 1 小时”，不代表 CPU / 内存单项性能上限；
- 未涉及磁盘、网络、文件系统校验，不构成整机验收结论；
- 内存指标口径为 `MemTotal − MemFree`（含 page cache），非单一 stress 进程占用；
- 本次为 1 小时短时测试，不能替代 10 小时长稳结论。

## 10. 问题与建议

| 优先级 | 问题 | 建议 |
|---|---|---|
| P0 | 显式 `--vm-bytes 56G` 超上限 66 GiB | 只传 `--vm 32`，由脚本裁到 32×53G=1696G（90.3%）；或手填 52G（88.6%）留余量 |
| P1 | dmesg I/O 正则把 `Opts: errors=remount-ro` 当错误 | 正则排除 `Opts: errors=`；或在 review 中区分“挂载事件”与真实 I/O 错误 |
| P1 | periodic 快照阻塞监控，采样被拉长到 45s | 快照放到后台子进程执行，避免拖慢采样节拍 |
| P2 | 测试期间挂载 `nvme0n1` | 压测期间避免挂载/卸载其他设备，减少误报来源 |
| P2 | 仅 1 小时 | 正式验收按 10h 长稳执行，并保留 `status.txt` 与 dmesg 证据 |

## 11. 未确认项

- 两批各 1 小时，未覆盖长稳；内存 95.8% 的高占用在 10h 场景下的表现未知；
- `stress-test-1` 与 `stress-test-2` 是否为同一台物理机（配置完全一致，缺主机序列号证据）；
- 18:06 挂载 `nvme0n1` 的操作目的与执行人。

## 12. 复核入口

- `tmp/newtest-3/stress-test-1/20261117-171811-combo/`：`status.txt`、`stress.exitcode`、`stress.log`、`monitor.csv`（116 点）、`runtime-final.txt`
- `tmp/newtest-3/stress-test-2/20261117-092635-combo/`：同上
- `tmp/newtest-3/*/operations.log`：`mem-plan` / `resource-plan` / `start`
