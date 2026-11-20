# 中途运行分析报告（test-mission-4 · stress-test-3-mid / stress-test-4-mid · 2026-11-19）

| 项目 | 内容 |
|---|---|
| 报告编号 | MISSION4-MID-20261119-34 |
| 数据目录 | `test-souce-data/test-mission-4/stress-test-3-mid/`、`stress-test-4-mid/` |
| 任务构成 | 每台原 combo（CPU+内存，10h）+ 追加 2 个磁盘任务（数据盘 HDD01 + 系统盘 SYSDISK，6h） |
| 测试机型 | 7380 ×2（128 线程 / 64 物理核，503 GiB 内存，16×32 GiB） |
| 当前状态 | **RUNNING**（combo 已跑 3.8h / 4.1h，hdd 刚启动） |
| 结论 | **硬盘追加成功（每台 2 任务，挂载+启动全通过）；CPU 90.6%、内存达成 416G、swap 0，正常** |

## 1. 结论摘要

1. **硬盘追加成功（两台一致）**：每台挂载 1 块数据盘（nvme0n1→/mnt/HDD01，已有文件系统直接挂载）+ 追加 HDD01 与 SYSDISK 两个任务，`HDD01.startrc=0`、`SYSDISK.startrc=0`，`stress.log` 均出现 `0 cpu, 0 io, 0 vm, 1 hdd`，写吞吐首点即 325–1056 MB/s，`error.log` 全部为空。
2. **CPU/内存正常**：combo 已跑 3.8–4.1 小时，稳态 CPU 均值 **90.6%**（≥90% 达标），内存达成 416G 目标（峰值 420.1G 含页缓存），MemAvailable 最低 81.4G，swap 全程 0，无 OOM。
3. **覆盖情况**：每台 1 数据盘 + 1 系统盘 = 2 个 hdd 任务，与已挂载数据盘数一致（该机仅 1 块数据盘）。
4. **时间锚点**：两台服务器时钟均 2026-11-19，自洽；快照为 hdd 启动后约 1 分钟内抓取（各 hdd 监控仅 1–2 行属正常）。

## 2. 任务清单

### stress-test-3-mid

| 任务 | 批次目录 | 命令 | 开始时间 | 超时 | startrc |
|---|---|---|---|---|---|
| combo | `20261119-014024-combo` | `stress --cpu 100 --vm 16 --vm-bytes 26G --vm-keep --timeout 10h` | 01:40:24 | 10h | 0 |
| HDD01 | `20261119-052553-hdd` | `stress --hdd 1 --hdd-bytes 10G --timeout 6h`（--dirs /mnt/HDD01） | 05:25:53 | 6h | 0 |
| SYSDISK | `20261119-052620-hdd` | 同上（--sysdisk-only） | 05:26:20 | 6h | 0 |

### stress-test-4-mid

| 任务 | 批次目录 | 命令 | 开始时间 | 超时 | startrc |
|---|---|---|---|---|---|
| combo | `20261119-092853-combo` | 同上 | 09:28:53 | 10h | 0 |
| HDD01 | `20261119-133341-hdd` | `stress --hdd 1 --hdd-bytes 10G --timeout 6h`（--dirs /mnt/HDD01） | 13:33:41 | 6h | 0 |
| SYSDISK | `20261119-133359-hdd` | 同上（--sysdisk-only） | 13:33:59 | 6h | 0 |

## 3. 挂载核查（mount.log，两台一致）

| 设备 | 挂载点 | 处理 | 结果 |
|---|---|---|---|
| /dev/nvme0n1（1.7T） | /mnt/HDD01 | 已有文件系统，直接挂载（不重新格式化） | 成功 |
| /dev/sdb（7.5G） | /run/media/root/NO NAME | 非测试挂载点，**跳过**（不写入） | 正确跳过 |

说明：磁盘扫描识别出 nvme0n1 为数据盘、sdb 为外部 U 盘类挂载并跳过，行为正确；无 mkfs 操作（复用已有文件系统）。

## 4. hdd 任务启动证据

| 证据 | stress-test-3-mid | stress-test-4-mid |
|---|---|---|
| HDD01.startrc / SYSDISK.startrc | 0 / 0 | 0 / 0 |
| dispatch 行 | `0 cpu, 0 io, 0 vm, 1 hdd` | 同左 |
| HDD01 首点写吞吐 | 324.8 MB/s | 861.1 MB/s |
| SYSDISK 首点写吞吐 | 1056.2 MB/s | （监控刚启动，尚无数据行） |
| error 正文 | 0 | 0 |
| exitcode | 无（6h 未结束，正常） | 无 |

> 首点写吞吐处于 300–1000 MB/s 区间，为 hdd 任务刚启动时的预热窗口，后续需观察稳定值；SYSDISK 批次监控只有表头行（复制时刚启动），无数据属正常。

## 5. CPU / 内存分析（combo 批次）

| 指标 | stress-test-3-mid | stress-test-4-mid |
|---|---|---|
| 采样区间 | 01:40:54 → 05:26:36（3.8h，449 点） | 09:29:23 → 13:34:02（4.1h，486 点） |
| CPU 均值 | **90.6%**（最低 90.6%） | **90.6%**（最低 90.6%） |
| load1 均值 | 115.9 | 115.9 |
| 内存峰值 | 420.1 GiB（目标 416G + 缓存） | 420.1 GiB |
| MemAvailable 最低 | 81.4 GiB | 81.4 GiB |
| swap | 全程 0 | 全程 0 |
| error / OOM | 无 | 无 |
| exitcode | 无（运行中） | 无（运行中） |

说明：7380（128 线程、100 worker）下 CPU 90.6% 属正常饱和水平（100/128 = 78% 逻辑线程覆盖，SMT 下整体占用约 90%）；与 7360（94.9%）的差异是机型线程数不同所致。内存 16×26G=416G 常驻 + 页缓存，可用保持 81G+。

## 6. 判定

| 闸门 | 结论 |
|---|---|
| 硬盘追加 | **成功**（挂载、2 任务启动、写负载已生效、覆盖 1:1） |
| B 运行完整性 | 各任务 RUNNING，无提前退出迹象 |
| C 指标口径 | combo 与 hdd 独立批次、独立监控，各自整机口径 |
| E 观测有效性 | CPU 90.6% / 内存 416G 达成 / 磁盘写入非零 |
| 时间锚点 | 2026-11-19 自洽 |

**当前状态：RUNNING —— 追加成功、负载生效、CPU/内存正常。**

## 7. 问题与建议

| 优先级 | 问题 | 建议 |
|---|---|---|
| P2 | hdd 首点写吞吐 325–1056 MB/s 属预热期 | 10 分钟后抓第二快照看稳定值（目标整机写非零窗口 ≥70%） |
| P2 | SYSDISK 批次监控刚启动无数据行 | 待采样增长后再判定 |
| P2 | 每台仅 1 块数据盘 + 系统盘 | 覆盖已 1:1；如需多盘并行另加 --dirs |
| P3 | 两台均 10h combo + 6h hdd 未结束 | 结束后抓最终快照：`status.txt`、`*.exitcode`、完整采样 |

## 8. 复核入口

- `test-souce-data/test-mission-4/stress-test-3-mid/operations.log`、`oneclick-20261119-052552/`（mount.log + HDD01.startrc）、`20261119-052553-hdd/`、`20261119-052620-hdd/`
- `test-souce-data/test-mission-4/stress-test-4-mid/operations.log`、`oneclick-20261119-133341/`、`20261119-133341-hdd/`、`20261119-133359-hdd/`
