# 服务器压力测试报告归档 · test-mission-5（2026-11-20）

## 归档说明

- **数据来源**：`test-souce-data/test-mission-5/`（10 台 5380，2026-11-20 导入；另有此前 1 台 7380 的启动核查报告同目录，见文末）。
- **归档目录**：`docs/压测报告/test-mission-5-20261120/`。
- **判定方法**：解读方案 v3（六态 + B/C/D/E 闸门）。

## 汇总表

| 机器 | 状态 | 命令 | CPU均值 | 内存峰值(占MemTotal) | swap | 写吞吐 | 写非零 | hdd | 收尾(s) | 报告 |
|---|---|---|---|---|---|---|---|---|---|---|
| **stress-test-1** | OK | `stress --cpu 50 --vm 12 --vm-bytes 14G --vm-keep --timeout 10h` | 100.0% | 298.9G（79.4%） | 0.0 | 6114.23 MB/s | 100.0% | 16/16 | 36001 | [压测分析报告-5380-stress-test-1-20261120.md](压测分析报告-5380-stress-test-1-20261120.md) |
| **stress-test-10** | OK | `stress --cpu 50 --vm 12 --vm-bytes 14G --vm-keep --timeout 10h` | 100.0% | 295.5G（78.5%） | 10496.0 | 6223.8 MB/s | 100.0% | 16/16 | 36001 | [压测分析报告-5380-stress-test-10-20261120.md](压测分析报告-5380-stress-test-10-20261120.md) |
| **stress-test-2** | OK | `stress --cpu 50 --vm 12 --vm-bytes 14G --vm-keep --timeout 10h` | 100.0% | 304.1G（80.7%） | 0.0 | 6174.49 MB/s | 100.0% | 16/16 | 36001 | [压测分析报告-5380-stress-test-2-20261120.md](压测分析报告-5380-stress-test-2-20261120.md) |
| **stress-test-3** | OK | `stress --cpu 50 --vm 12 --vm-bytes 14G --vm-keep --timeout 10h` | 100.0% | 309.1G（82.1%） | 0.0 | 6366.38 MB/s | 100.0% | 16/16 | 36000 | [压测分析报告-5380-stress-test-3-20261120.md](压测分析报告-5380-stress-test-3-20261120.md) |
| **stress-test-4** | OK | `stress --cpu 50 --vm 12 --vm-bytes 26G --vm-keep --timeout 9h` | 99.99% | 354.1G（94.0%） | 512.0 | 1439.25 MB/s | 100.0% | 4/4 | 32403 | [压测分析报告-5380-stress-test-4-20261120.md](压测分析报告-5380-stress-test-4-20261120.md) |
| **stress-test-5** | OK | `stress --cpu 50 --vm 12 --vm-bytes 14G --vm-keep --timeout 10h` | 100.0% | 301.3G（80.0%） | 0.0 | 6221.14 MB/s | 100.0% | 16/16 | 36000 | [压测分析报告-5380-stress-test-5-20261120.md](压测分析报告-5380-stress-test-5-20261120.md) |
| **stress-test-6** | OK | `stress --cpu 50 --vm 12 --vm-bytes 14G --vm-keep --timeout 10h` | 100.0% | 296.0G（78.6%） | 0.0 | 5965.14 MB/s | 100.0% | 16/16 | 36000 | [压测分析报告-5380-stress-test-6-20261120.md](压测分析报告-5380-stress-test-6-20261120.md) |
| **stress-test-7** | OK | `stress --cpu 50 --vm 12 --vm-bytes 14G --vm-keep --timeout 10h` | 100.0% | 295.7G（78.5%） | 0.0 | 6295.21 MB/s | 100.0% | 16/16 | 36000 | [压测分析报告-5380-stress-test-7-20261120.md](压测分析报告-5380-stress-test-7-20261120.md) |
| **stress-test-8** | OK | `stress --cpu 50 --vm 12 --vm-bytes 14G --vm-keep --timeout 10h` | 100.0% | 302.6G（80.4%） | 0.0 | 6140.35 MB/s | 100.0% | 16/16 | 36001 | [压测分析报告-5380-stress-test-8-20261120.md](压测分析报告-5380-stress-test-8-20261120.md) |
| **stress-test-9** | OK | `stress --cpu 50 --vm 12 --vm-bytes 14G --vm-keep --timeout 10h` | 100.0% | 295.2G（78.4%） | 0.0 | 6341.19 MB/s | 100.0% | 16/16 | 36000 | [压测分析报告-5380-stress-test-9-20261120.md](压测分析报告-5380-stress-test-9-20261120.md) |

- OK：10/10 台。

## 共性问题

- 全部 5380（64 线程/376G/12×32G），参数为 all 模式自动推导：CPU 50（64×25/32）、VM 12、vm-bytes 受盘流页缓存预留裁剪（16 盘整机下 14G/worker ≈ 168G 目标）。
- 内存达成度低于 82% 设计目标属 all 求稳档的预期行为（盘流预留优先），非缺陷。
- 磁盘指标为整机汇总，非单盘结论。

## 单机要点

- `stress-test-4`：仅 4 个 hdd 任务（3 数据盘 + 1 系统盘），盘流少所以 vm-bytes 未被裁剪（26G → 312G 目标），内存达成度高于其它 8 台；`--timeout 9h` 而非 10h。
- `stress-test-6`：含 **2026-11-19 晚 20:19 旧批次**（采样 24 行即中断，无 status.txt）与 **2026-11-20 早 09:45 重跑批次**（完整 OK）。旧批次判定：中断/重跑，不计入本次结果。

## 阅读顺序

1. 本 README（批次总览）；
2. 对应机器的单机报告；
3. 需要复核时回到 `test-souce-data/test-mission-5/<机器>/`（run-config、monitor.csv、status.txt、stress*.log）。
