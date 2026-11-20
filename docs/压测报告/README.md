# 压测报告归档索引

服务器压力测试报告的归档目录。按“一批一目录”组织，每个批次目录内有一份 `README.md`（批次汇总与共性问题）和逐台机器的分析报告。

## 批次列表

| 批次 | 测试日期 | 归档日期 | 机器数 | 结论分布 | 批次目录 |
|---|---|---|---|---|---|
| 首批（stress-test-3-1 ~ 21-1） | 2026-11-14 | 2026-11-16 | 19 | OK 11 / OK_LIMITED 8 | [20261114-7380-首批](20261114-7380-首批/README.md) |
| newtest-2（0003 ~ 0015、stress-test-1） | 2026-11-15 | 2026-11-16 | 15 | OK 1 / OK_LIMITED 14 | [newtest-2-20261116](newtest-2-20261116/README.md) |
| newtest-3（stress-test-1、stress-test-2） | 2026-11-17 | 2026-11-17 | 2 容器 | OK 2（各跑满 1h，CPU 100%、内存 95.8%，无 OOM） | [组合负载压测分析报告](newtest-3-20261117/压测分析报告-7380-stress-test-1与stress-test-2-20261117.md) |
| newtest-3（stress-test-3、stress-test-4） | 2026-11-18 | 2026-11-18 | 2 容器 | OK 2（各跑满 1h，CPU 100%、内存 89.8% 且参数未超限） | [组合负载压测分析报告](newtest-3-20261117/压测分析报告-7380-stress-test-3与stress-test-4-20261118.md) |
| test-mission-4（stress-test-3/4/5） | 2026-11-19 | 2026-11-19 | 3 | RUNNING（启动成功、参数合理、待长稳；7360 时钟偏移 2 个月） | [启动核查与参数合理性报告](test-mission-4-20261119/启动核查与参数合理性-7380与7360-stress-test-3-4-5-20261119.md) |
| test-mission-4（stress-test-6） | 2026-11-19 | 2026-11-19 | 1 | RUNNING（启动成功、1TB 机型内存占 90% 偏高、待长稳） | [启动核查与参数合理性报告](test-mission-4-20261119/启动核查与参数合理性-7380-stress-test-6-20261119.md) |
| test-mission-4（stress-test-6-mid） | 2026-11-19 | 2026-11-19 | 1 | RUNNING（7360 机中途：hdd 追加成功、CPU 94.9%、内存达成、待长稳） | [中途运行分析报告](test-mission-4-20261119/中途运行分析-7360-stress-test-6-mid-20261119.md) |
| test-mission-4（stress-test-3-mid / 4-mid） | 2026-11-19 | 2026-11-19 | 2 | RUNNING（7380 机中途：hdd 追加成功、CPU 90.6%、内存达成、待长稳） | [中途运行分析报告](test-mission-4-20261119/中途运行分析-7380-stress-test-3-mid与stress-test-4-mid-20261119.md) |
| test-mission-4（stress-test-3-end） | 2026-11-19 | 2026-11-19 | 1 | ABORTED（断电中断：combo 差 19.8 分钟、hdd 差 5/5.5 分钟，均未完成） | [断电中断分析报告](test-mission-4-20261119/断电中断分析-7380-stress-test-3-end-20261119.md) |
| test-mission-5（stress-test） | 2026-11-20 | 2026-11-20 | 1 | RUNNING（启动成功、覆盖 1:1；CPU 45 与内存 288G 配置偏低，未满载） | [启动核查与参数合理性报告](test-mission-5-20261120/启动核查与参数合理性-7380-stress-test-20261120.md) |
| test-mission-5（stress-test-1 ~ 10） | 2026-11-20 | 2026-11-20 | 10 | OK 10（5380 全机长稳 10h：CPU 100%、内存受盘流预留裁剪、写非零 100%；st6 旧批次中断重跑） | [批次归档 README](test-mission-5-20261120/README.md) |
| test-mission-6（stress-test-1） | 2026-11-20 | 2026-11-20 | 1 | RUNNING（full 中高强度启动成功：CPU 90/内存 1008G 89.9% 未超限，参数推导正确） | [中高强度核查报告](test-mission-6-20261120/中高强度核查-7380-stress-test-1-20261120.md) |

## 归档规则

- **目录**：`docs/压测报告/<批次标识>-<归档日期>/`，一批一目录，不再把报告直接放在 `docs/` 根目录。
- **批次索引**：每个批次目录一份 `README.md`，含数据来源、汇总表、共性问题与单机要点。
- **单机报告命名**：`压测分析报告-<机型>-<机器标识>-<归档日期>.md`，例如 `压测分析报告-7380-0003-20261116.md`；旧批次沿用当时的 `服务器综合压力测试报告-7380-<机器标识>-<日期>.md`。机型与机器标识均在文件名中，可直接辨认来源机器。
- **判定方法**：[压测输出日志解读方案（v3）](../superpowers/specs/2026-11-14-stress-log-interpretation-design.md) —— 六态判定（OK / OK_LIMITED / RUNNING / ABORTED / INVALID / UNKNOWN）、B/C/D/E 闸门、硬规则 R-01。
- **数据目录**：原始快照保留在 `tmp/<批次>/<机器>/`，报告中的每条数值都可回到对应批次的 `run-config.txt`、`monitor.csv`、`stress*.log`、`*.exitcode`、`error.log` 复核。
