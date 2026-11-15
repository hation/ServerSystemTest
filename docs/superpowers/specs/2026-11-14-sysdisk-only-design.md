# 仅系统盘压测模式设计（start hdd --sysdisk 无数据盘降级）

- 日期：2026-11-14
- 状态：待评审
- 修改文件：`offline-stress-pkg/stress-test.sh`（仅前置校验与提示，不改启动/监控/复盘逻辑）

## 1. 问题

当前 `bash stress-test.sh start hdd --sysdisk` 在机器上没有 `/mnt/HDD*` 挂载点时，命中 L152-155 直接报"未发现 /mnt/HDD* 挂载点"并退出，**无法只压系统盘**。唯一变通 `start combo --sysdisk` 会同时压 CPU + 内存，不符合"只压系统盘"。

启动段（L259-274）本身已支持 `dirs` 为空 + `--sysdisk`（组合循环空转、系统盘进程照常启动），因此只需放宽前置校验。

## 2. 方案（最小改动）

1. **hdd 模式无数据盘 + `--sysdisk`**：不再退出，改为提示"未发现 /mnt/HDD* 挂载点，hdd 模式仅压系统盘"，`dirs=()` 继续。
2. **hdd 模式无数据盘且未加 `--sysdisk`**：保持现状报错退出（防止空跑）。
3. `--dirs` 为空串且 `--sysdisk` 开启：同样允许（仅系统盘）。
4. 其余不变：系统盘空间预检、`/stresstest-hdd`、`stress-SYSDISK.log`、`error-SYSDISK.log`、退出码文件、monitor、review 全部复用现有逻辑。

## 3. 用法

```bash
# 只压系统盘（机器上没有挂数据盘，或不需要压数据盘）
sudo bash stress-test.sh start hdd --sysdisk

# 数据盘 + 系统盘（原行为不变）
sudo bash stress-test.sh start hdd --sysdisk --dirs "/mnt/HDD01 /mnt/HDD02"
```

## 4. 结果目录

`<时间戳>-hdd/` 下只有 `stress-SYSDISK.log` / `error-SYSDISK.log` / `stress-SYSDISK.exitcode`（无 `stress-HDDxx.*`），`review` 照常汇总。

## 5. 测试

stub 化验证：
1. hdd + `--sysdisk` + 无 `/mnt/HDD*` → 不退出，启动 1 个系统盘进程，结果目录含 `stress-SYSDISK.*`
2. hdd + 无 `--sysdisk` + 无盘 → 仍退出 1
3. hdd + `--sysdisk` + 有数据盘 → 数据盘 + 系统盘都启动（回归）
4. combo 行为不变（回归）
5. `bash -n` 通过

## 6. 非目标

- 不新增子命令（沿用 `hdd --sysdisk`）
- 不改 combo 降级语义、不改 review/status/monitor
- 不改系统盘测试内容（仍是 stress --hdd 顺序写）
