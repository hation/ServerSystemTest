# 一键压测编排统一：CPU+内存组合任务 + 每盘独立终端

- 日期：2026-11-17
- 状态：**已确认（用户 2026-11-17），待实现**
- 关联：`2026-11-17-cpu-mem-general-allocation-design.md`（v3，参数算法）
- 目标：`oneclick all` 与单测 `stress-test.sh start combo` 使用同一套参数推导与执行口径，同时保留“每块数据盘一个终端”的现场习惯

## 1. 意图与现状

现状（已核实）：

- oneclick 不自己算 CPU/内存，只调用 `stress-test.sh start <type> --timeout`，参数推导已与单测同源；
- 但 `oneclick all` 把 CPU、MEM 拆成两个独立任务，而单测 `combo` 是一个 stress 进程同时跑 CPU+内存；
- `combo` 若带 `--dirs`，会在内部再为每盘启动 hdd 后台进程；若不带 `--dirs`，则只跑 CPU+内存，但内存计划不知道外部还有多少盘在并发。

目标编排（用户确认）：

```text
oneclick all =
  COMBO     : CPU+内存组合任务，一个终端、一个结果目录
  HDD01..N  : 每块数据盘一个终端，cd 到 /mnt/HDDxx 后跑 stress --hdd
  SYSDISK   : 系统盘任务，/stresstest-hdd，独立终端
```

## 2. 目标

1. `oneclick all` 只产生一个 CPU+内存任务（COMBO），不再分别产生 CPU、MEM。
2. 每块数据盘仍是一个独立任务/终端，结果目录独立，互不覆盖。
3. 系统盘保留为独立 SYSDISK 任务（用户确认）。
4. COMBO 的内存计划必须知道“同时还有多少盘在跑”，否则 `cap_disk` 不生效；新增 `--peer-disks N` 只参与内存预留，不在 COMBO 内启动 hdd。
5. `oneclick cpu|mem|hdd|sysdisk` 单资源模式保持不变。
6. `commands.txt`/`commands.sh`/`env.txt` 与实际 argv 一致，可直接复核。

## 3. 非目标

- 不改 v3 参数公式（物理核×1.5625、单根规则、三道上限）。
- 不改挂载/分区/格式化、`--rebuild`、菜单 y/N。
- 不改 monitor/review/结论判定。
- 不引入新二进制。
- 不把每盘任务合并进 COMBO 结果目录。

## 4. 详细设计

### 4.1 `stress-test.sh`：新增 `--peer-disks N`

```text
start combo [--dirs ...] [--sysdisk] --peer-disks N
start mem   [--peer-disks N]
```

- `N` 为非负整数；仅对 `combo`/`mem` 生效，`cpu`/`hdd` 收到时只告警、不改变行为。
- 语义：**对端并发 hdd 流数量**，只用于 `cap_disk` 计算和展示，不启动任何 hdd 进程。
- 有效盘流：

```text
actual = 数据盘目录数 + (--sysdisk ? 1 : 0)
disk_streams_eff = max(actual, peer_disks)
cap_disk = MemTotal − (disk_streams_eff × hdd_bytes × 1.2 + 8G)
```

- 若同时有 `--dirs` 和 `--peer-disks`，取两者较大值，避免重复计算或低估。
- `run-config.txt` / `operations.log` / 资源计划行新增：`peer_disks=N`、`disk_streams_eff=X`、`disk_streams_source=actual|peer|max`。
- 显式 `--vm-bytes` 仍原样保留、不裁剪；`--peer-disks` 只影响自动推导路径。
- hdd 进程启动循环仍只遍历 `--dirs` 的实际目录，`peer_disks` 不会产生额外进程。
- **`--peer-disks` 出现即视为显式声明外部盘流**：combo/mem 不再自动 glob `/mnt/HDD*`；只有显式 `--dirs` 才在 combo 内启动 hdd。`--peer-disks 0` 表示纯 CPU+内存。未出现该参数时保持原有自动 glob 行为。

### 4.2 `oneclick.sh`：`all` 计划改造

`write_plan all` 的计划行（顺序即启动顺序）：

```text
COMBO|combo|--peer-disks|N
HDD01|hdd|--dirs|/mnt/HDD01
...
SYSDISK|hdd|--sysdisk-only
```

- `N = 数据盘目录数 + 1`（`all` 固定包含 SYSDISK）。
- 没有数据盘时：仅 `COMBO|combo|--peer-disks|1` + `SYSDISK`，不再输出 CPU/MEM。
- `cpu`/`mem` 模式保持原样；`hdd` 模式不传 `--peer-disks`。
- 实际命令示例：

```bash
bash stress-test.sh start combo --peer-disks 13 --timeout 10h
bash stress-test.sh start hdd --dirs /mnt/HDD01 --timeout 10h
bash stress-test.sh start hdd --sysdisk-only --timeout 10h
```

- 任务 ID/窗口标题：`COMBO`、`HDD01..`、`SYSDISK`；批次等待与 summary 仍按结果目录聚合。
- 挂载、`--rebuild`、菜单选项、`--quiet` 不变。

### 4.3 全局一致性

- 参数只在 `stress-test.sh` 推导一次；oneclick 不出现任何 CPU/内存公式或固定值。
- 单测 `start combo --dirs ... --sysdisk` 与 oneclick `COMBO + 每盘任务 + SYSDISK` 的最终内存口径一致：
  - 单测：`actual` 就是盘数，`cap_disk` 生效；
  - oneclick：`peer_disks` 传入同样盘数，`cap_disk` 生效；
  - 两条路径的 `physical_cores/nproc/dimms/per_worker_g/cap_*` 应相等。

### 4.4 启动失败策略

- **COMBO 启动失败**：中止本批次，不再启动后续任务，退出码 1（核心 CPU+内存负载未起来）。
- **数据盘任务启动失败**：标记该盘失败，跳过并继续启动其余数据盘和 SYSDISK；批次最终退出码 1，summary 列出失败/跳过的盘。
- **SYSDISK 启动失败**：标记失败，批次退出码 1；它排在最后，不影响已启动任务。
- 等待逻辑只等待成功启动的任务；失败任务在批次目录留下 `.fail`/`.startrc`，commands.txt 仍记录尝试执行的完整命令。

## 5. 验收

| 编号 | 场景 | 期望 |
|---|---|---|
| A1 | `oneclick all` 计划 | 含 1 个 COMBO、N 个 HDD、1 个 SYSDISK；无独立 CPU/MEM |
| A2 | COMBO argv | 含 `--cpu/--vm/--vm-bytes/--vm-keep`，不含 `--hdd` |
| A3 | 每盘 argv | 含 `--hdd 1 --dirs <dir>`，任务 cwd 为该目录 |
| A4 | `--peer-disks` | 512G/16×32/peer=12 → 22G/worker、总量 352G；不产生 hdd 进程 |
| A5 | 与单测一致 | 同盘数下 `start combo --dirs ...` 与 oneclick COMBO 的 `per_worker_g/cap_disk_g` 相同 |
| A6 | 无数据盘 | COMBO peer=1 + SYSDISK，不报错 |
| A7 | 命令可见性 | commands.txt/commands.sh 含 COMBO、每盘、SYSDISK 的完整命令 |
| A8 | 回归 | 既有全部套件 0 失败；zip SHA256 一致 |
| A9 | `--peer-disks` 防重复 | COMBO argv 无 `--dirs`，进程树中无 combo 内 hdd；不会二次写盘 |
| A10 | 失败策略 | 单盘启动失败继续其余任务、退出码 1；COMBO 失败中止；SYSDISK 失败仅置退出码 1 |

## 6. 测试计划

- oneclick 套件：`all` 计划、窗口/任务 ID、COMBO 参数、每盘参数、无数据盘分支。
- command-visibility 套件：三条命令与落盘一致。
- calibration 套件：`--peer-disks` 对 `cap_disk` 的影响、与 `--dirs` 取 max、不会启动 hdd、cpu/hdd 告警。
- hdd-align 套件：确认未破坏每盘挂载/目录校验。
- 全量回归 + 重打 zip。

## 7. 风险

| 风险 | 处理 |
|---|---|
| COMBO 与各盘并发时页缓存不足 | `--peer-disks` 把并发盘数带入 `cap_disk`；oneclick 自动传 |
| 系统盘任务启动失败但 peer 已计入 | 内存偏保守，不会 OOM；summary 标注失败 |
| COMBO 重复压盘 | `--peer-disks` 出现即禁用自动 glob；只有显式 `--dirs` 才在 combo 内启动 hdd |
| 窗口变多 | 保持现有“每任务一窗口/后台降级”机制，不新增窗口类型 |
| 计划行顺序影响启动 | COMBO 先启动，再逐盘，最后 SYSDISK；等待逻辑不变 |
| 显式 `--vm-bytes` 绕过限制 | 保持既有告警行为，文档明确 |

## 8. 留给实现者的决定

- `--peer-disks` 的参数校验文案与 `disk_streams_source` 的具体字符串。
- COMBO 窗口标题是否带“CPU+内存”副标题。
- 测试假件的组织方式（沿用现有 lib.sh）。
