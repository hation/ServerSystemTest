# 压测脚本内存预设与运行期取证修复设计

- 日期：2026-11-15
- 状态：待评审
- 触发事故：`tmp/stress-test-2-8-1`（2026-11-15 07:03 启动的 7380 机型，物理内存 502 GiB）
- 涉及文件：`offline-stress-pkg/stress-test.sh`、`offline-stress-pkg/operation-manual.md`

## 1. 事故复盘（事实）

| 时间 | 事实 | 证据 |
|---|---|---|
| 07:02:16 | `mkfs.ext4 /dev/nvme0n1` 后挂载到 `/mnt/HDD01` | `mount.log` |
| 07:03:28 | mem 任务按预设启动：`--vm 16 --vm-bytes 54G`（合计 864G） | `20261115-070328-mem/run-config.txt` |
| 07:03:28–07:34:52 | 4 个 monitor 循环一行采样都没落盘 | 4 份 `monitor.csv` 均只有 1 行数据，mtime 均为 07:34:52 |
| 07:34:52 | 内核 OOM：`Out of memory: Killed process 42685 (stress)`，anon-rss 38.1G | `20261115-070333-hdd/error.log` |
| 07:34:53 | `stress: FAIL: worker 42685 got signal 9` | `20261115-070328-mem/error.log` |
| 07:34:52+ | 4 个批次同时写出第 1 个采样点（load 185，swap 4 GiB 用满） | 各 `monitor.csv` |

机器实际配置（`info-before.txt`）：`Mem: 502Gi`、`Swap: 4.0Gi`、128 线程。

## 2. 根因（逻辑缺陷清单）

| 编号 | 缺陷 | 位置 | 后果 |
|---|---|---|---|
| B1 | 内存需求与物理内存无任何关联：预设 `16 × 54G = 864G` 直接下发 | `preset_vm` / `preset_vm_bytes`（stress-test.sh:50-52） | 502 GiB 机器必然 OOM |
| B2 | `--model auto` 只用 `nproc` 判机型，不看内存 | stress-test.sh:139-150 | 128 线程但仅 502 GiB 的机器被判为 7380，套用 1024G 机型的预设 |
| B3 | 启动前无内存上限校验 | `cmd_start` 参数组装段（stress-test.sh:155-159） | 明知会死也照常启动 |
| B4 | 多个 `monitor-loop` 并发执行 `dmesg -c`（清空式读取），互相抢日志 | stress-test.sh:568、611 | OOM 完整证据只落在 1 个批次，其余批次只剩碎片 |
| B5 | worker 被 KILL 后可能不产生 `*.exitcode`，且无任何状态文件 | stress-test.sh:621-636 | 离线只能靠 `error.log` 猜，无法机读判定 |
| B6 | `review` 的监控覆盖时长按“行数 × 间隔”计算，不按“开始时间 → 末行时间” | stress-test.sh:452-459 | 本次 `rows=1` 被算成“覆盖 30 秒”，31 分钟采样空洞完全看不见 |

## 3. 目标与非目标

### 目标

- 预设内存需求超过物理内存安全线时，自动裁剪到安全线以内，压测能真正跑满 10 小时。
- 裁剪过程必须留痕：`operations.log`、`run-config.txt`、启动输出三处可查。
- 多个批次并发时，内核 OOM 证据不再被互相清空。
- 批次结束时落盘一份机读状态（正常 / 异常 / 人为停止 + 原因）。
- `review` 能识别“监控采样空洞”，不再把 1 个采样点算成“已覆盖 30 秒”。

### 非目标

- 不改 `disk-mount.sh`、`mount-iso.sh`、`usb-eject.sh`。
- 不改 `monitor.csv` 的 9 列格式（下游解读方案已按此格式固化）。
- 不做常驻守护、告警、自动重启。
- 不解决 `dmesg` 只保留 OOM 关键字的采集盲区（沿用现状，见解读方案 L4）。
- 不改“机型 → CPU worker 数”的预设。

## 4. 设计决策

| 编号 | 决策 | 依据 |
|---|---|---|
| D1 | 内存安全线 = `MemTotal × MEM_MAX_PCT%`，**`MEM_MAX_PCT` 默认 85**，可用环境变量覆盖 | 用户确认“按 MemTotal 自动裁剪”。取 85 而非 80：现有三档预设本就落在 81%–84%（5380 312/384=81.2%、7360 416/512=81.2%、7380 864/1024=84.4%），85% 能完整保留既有机型的压测强度与历史可比性；只有内存显著小于机型标称值的机器才会被裁剪。注意 85% 是**分配上限**，与解读方案 4.3 的 80%**内存达成阈值**是两个不同概念，不要混用 |
| D2 | 裁剪只作用于**预设值**；用户显式 `--vm-bytes` 不裁剪，只打印醒目警告后照常启动；用户显式 `--vm` 时 worker 数不自动减少 | 不擅自改写用户显式参数，避免“偷偷换成别的压测强度” |
| D3 | 裁剪优先“降单 worker 字节数”，worker 数不变；仅当 `--vm`、`--vm-bytes` **都来自预设**且单 worker 不足 1G 时才减少 worker 数 | 保持并发度与混合负载形态，便于和历史数据横向比较 |
| D4 | `dmesg` 由清空式改为“游标增量读取”，多个 monitor 各自记录、允许重复 | 改动最小且彻底消除互抢；去重收益低于实现成本 |
| D5 | 结束状态写入 `status.txt`（`state=` / `reason=`），`review` 优先读它，缺失则回退旧逻辑 | 旧结果目录仍可 review |
| D6 | 采样空洞以 `run-config` 开始时间为锚点计算覆盖率 | 事故中首末采样点相同，只有锚定开始时间才能暴露 31 分钟空洞 |
| D7 | 机型判定保持不变（仍按 `nproc`/内存），只增加内存裁剪与显式提示 | 机型是产品标识；同型号不同内存容量是现实情况，裁剪即可覆盖 |

## 5. 详细设计

### 5.1 内存安全线裁剪（B1/B2/B3）

新增常量与工具函数（放在“公共工具”区）：

```bash
MEM_MAX_PCT="${MEM_MAX_PCT:-85}"   # 内存分配上限：MemTotal 的百分比（注意与解读方案的 80% 达成阈值不同）

# MemTotal（MB）
mem_total_mb() { awk '/^MemTotal:/{printf "%d", $2/1024}' /proc/meminfo 2>/dev/null; }

# 尺寸文本转 MB：支持 K/M/G/T（大小写不敏感）、纯数字按 MB
parse_size_mb() { ... }   # 无法解析时输出空串
```

在 `cmd_start` 预设取值之后、组装 `stress_args` 之前插入裁剪逻辑，仅对 `type=mem|combo` 生效：

1. 记录来源：`vm_from_preset`（`--vm` 未显式给出时为 1）、`bytes_from_preset`（`--vm-bytes` 未显式给出时为 1）。
2. `cap_mb = mem_total_mb * MEM_MAX_PCT / 100`
3. `need_mb = vm_opt * parse_size_mb(vm_bytes_opt)`
4. 若 `need_mb > cap_mb`，按三条分支处理：

   | 分支 | 条件 | 行为 |
   |---|---|---|
   | A 全预设 | `vm_from_preset=1` 且 `bytes_from_preset=1` | `per_mb = cap_mb / vm_opt` 向下取整到 1G；`per_mb < 1024` 时改为 `vm_opt = cap_mb/1024`（至少 1）、`per_mb = 1024`；写回 `vm_bytes_opt="${per_mb/1024}G"`。输出 `已按物理内存裁剪内存预设：16×54G(864G) → 16×26G(416G)，分配上限 427G（MemTotal 502G × 85%）`，并 `log_op mem-clamp ...` |
   | B 显式 `--vm` | `vm_from_preset=0`，`bytes_from_preset=1` | **不改 worker 数**；`per_mb = cap_mb / vm_opt` 向下取整到 1G，最低 1G；若因此 `vm_opt × per_mb > cap_mb`，追加警告“安全线不足以支撑该 worker 数”。输出 `已按物理内存裁剪单 worker 字节：54G → 26G（worker 数按显式 --vm 保持 16）` |
   | C 显式 `--vm-bytes` | `bytes_from_preset=0` | **完全不裁剪**；输出 `警告：内存需求 864G 超过物理内存分配上限 427G（MemTotal 502G × 85%），可能触发 OOM；按显式参数继续` |

5. `run-config.txt` 在 `mem`/`combo` 分支追加两行：
   - `内存分配上限: 427G（MemTotal 502G × 85%）`
   - `内存需求: 预设 864G / 实际 416G（已裁剪）`、`内存需求: 实际 416G（显式 --vm，已裁剪单 worker 字节）`、`内存需求: 实际 864G（显式 --vm-bytes，超分配上限）`、`内存需求: 实际 416G（未超限）` 四选一
6. 启动输出（`echo "已启动..."` 之前）同样打印上述结论，让操作者当场看见。

边界：`parse_size_mb` 返回空（如 `--vm-bytes 1G5`）→ 跳过裁剪并提示“无法解析 vm-bytes，未做内存裁剪”。

> 本次事故机器（502G）按 85% 计算：上限 427G，16 worker → 26G/worker，合计 416G（占物理内存 82.9%），仍然远高于 691G 达成门槛在本机型上的等价要求（502G × 80% ≈ 402G 已满足“压到设计值 80% 左右”）。

### 5.2 `dmesg` 增量读取（B4）

`cmd_monitor_loop` 中：

- 基线：`dmesg_ok` 用只读探测（`dmesg >/dev/null 2>&1`），**不再执行 `dmesg -c`**。
- 游标文件：`$dir/.dmesg.cursor`，保存“已处理到的 dmesg 总行数”。
- **初始化**：monitor 启动时先 `dmesg | wc -l` 写入游标（等价于旧 `-c` 的“只看启动之后的新事件”语义），避免把缓冲区里的历史 OOM 误记到本批次。
- 每轮：
  ```
  total=$(dmesg 2>/dev/null | wc -l)
  cursor=$(cat .dmesg.cursor 2>/dev/null || echo 0)
  [ "$total" -lt "$cursor" ] && cursor=0        # 环形缓冲回绕/被清空
  hits=$(dmesg 2>/dev/null | tail -n +$((cursor + 1)) | grep -iE 'oom|out of memory|killed process|Killed')
  echo "$total" > .dmesg.cursor
  ```
- 命中内容仍按现有格式追加 `[时间] dmesg: ...` 到 `error.log`，并置 `oom_seen=1`。
- 允许各批次重复记录同一事件（可接受，且保证单批次证据完整）。

### 5.3 结束状态落盘（B5）

`cmd_monitor_loop` 循环结束后写 `$dir/status.txt`（覆盖写）：

```
state=OK            # OK | FAILED | ABORTED | STOPPED
reason=all-exitcode-zero
pids=4 exitcodes=4
oom=no
end_time=2026-11-15 07:34:53
```

判定顺序：

| 条件 | state | reason |
|---|---|---|
| 收到 TERM（`trap`，来自 `stop`） | `STOPPED` | `manual-stop` |
| 存在 `exitcode != 0` | `FAILED` | `nonzero-exitcode` |
| `oom_seen=1` 且 `exitcodes < pids` | `ABORTED` | `oom-killed` |
| `exitcodes < pids` | `ABORTED` | `missing-exitcode` |
| 其余 | `OK` | `all-exitcode-zero` |

- 循环体内原有 `error.log` 追加逻辑保持不变。
- **等待必须可被信号打断**：`sleep "$interval" & wait $!` 替代 `sleep "$interval"`，并在 `wait` 返回后检查 `stop_flag`；`trap 'stop_flag=1' TERM`。否则 TERM 要等 `sleep 30` 跑完才执行 trap，`stop` 拿不到 `STOPPED`。
- `stop_one` 顺序改为：① 给 monitor 发 TERM；② 轮询最多 2 秒（10 × 0.2s）等待 `status.txt` 出现；③ 仍未退出则 `kill -KILL`；④ 最后再按原逻辑停止 stress 进程。这样 monitor 在 stress 还活着时就写下了 `STOPPED`，不会把人工停止误判成 `ABORTED`。

### 5.4 `review` 增强（B5/B6）

1. 结论优先读 `status.txt`：

   | status | review 结论 |
   |---|---|
   | `OK` | 正常 |
   | `FAILED` | 异常（退出码非 0） |
   | `ABORTED` | 异常（`reason` 中文映射：`oom-killed` → 内存耗尽被内核杀死；`missing-exitcode` → 进程异常退出未留退出码） |
   | `STOPPED` | 已手动停止 |
   | 文件缺失 | 回退现有 exitcode/error.log 判定 |

2. 采样覆盖率（以 `run-config` 的“开始时间”为锚点）：

   ```
   start_epoch = date -d "<开始时间>" +%s
   last_epoch  = date -d "<末行时间>"   +%s
   span        = last_epoch - start_epoch
   expected    = max(1, span / interval)
   coverage    = rows / expected * 100
   ```
   - `span` 为空（无法解析）→ 覆盖率标 `不可判定`。
   - `coverage < 90%` → 追加 `采样空洞: 是（末行距开始 N 秒，应有 E 点，实际 R 点，覆盖率 C%）`。
   - 否则 → `采样空洞: 无（覆盖率 C%）`。

3. `summary.txt` 同时写入：
   - `运行状态: <state>（<reason>）`（status.txt 缺失时写“未记录”）
   - `监控覆盖时长` 保留现有语义（首末行差），另加 `采样空洞` 行，避免歧义。

### 5.5 文档同步

`operation-manual.md` 第 8 节（预设表下方）：

- 补充说明：`7380` 存在 512G / 1024G 两种内存配置，脚本会按 `MemTotal × 85%` 自动裁剪 `vm-bytes`；显式 `--vm-bytes` 不裁剪但会警告，显式 `--vm` 只裁剪单 worker 字节、不改 worker 数。
- 第 245 行“内存总量勿超物理内存”改为指向自动裁剪机制，并说明 `MEM_MAX_PCT` 可调（默认 85，含义是“分配上限”，不是验收门槛）。

## 6. 兼容性

| 项 | 处理 |
|---|---|
| 旧结果目录（无 `status.txt`/无 `.dmesg.cursor`） | `review` 走原逻辑；monitor 不读旧游标（新批次才有） |
| `monitor.csv` 9 列 | 不变 |
| `--vm-bytes` 显式用法 | 行为不变（仅多一条超限警告） |
| `stop` | 多写一份 `status.txt`，原有输出不变 |
| 打包 | `offline-stress-pkg.zip` 是否需要重打，由实施时按仓库习惯决定（上次改动后有重打先例） |

## 7. 验收标准

用 WSL + 假 `stress` / 假 `dmesg` / 假 `/proc/meminfo` 前置跑，全部可离线复现：

| 编号 | 场景 | 期望 |
|---|---|---|
| T1 | 模拟 MemTotal=502G，`start mem`（auto 判 7380，vm=16、bytes=54G 均来自预设） | 命令为 `--vm 16 --vm-bytes 26G`（416G ≤ 427G 上限），`run-config` 标“已裁剪”，启动输出与 `operations.log` 均留痕 |
| T2 | MemTotal=1024G，`start mem` | 不裁剪，`--vm 16 --vm-bytes 54G`（864G ≤ 870G 上限） |
| T3 | MemTotal=502G，显式 `--vm-bytes 54G`（`--vm` 用预设 16） | 不裁剪，输出“超过物理内存分配上限”警告，`run-config` 标“显式 --vm-bytes，超分配上限” |
| T4 | MemTotal=502G，显式 `--vm 32`（`--vm-bytes` 用预设 54G） | 不改 worker 数（仍 32），`--vm-bytes` 降为 13G（427/32≈13.3），`run-config` 标“显式 --vm，已裁剪单 worker 字节” |
| T5 | 并发两个批次各起 monitor，假 `dmesg` 记录每次调用参数 | 所有调用都不含 `-c`；两个 `error.log` 都能拿到同一批 OOM 行 |
| T6 | 假 stress 被 SIGKILL（不写 exitcode），且此前无历史 OOM 行 | `status.txt` 为 `ABORTED` / `oom-killed`，`review` 结论为“异常（内存耗尽被内核杀死）” |
| T7 | 假 `dmesg` 缓冲区预置 5 行历史 OOM，monitor 启动后再产生新行 | 历史 5 行**不**写入本批 `error.log`（游标初始化生效） |
| T8 | `interval=30`，monitor 只写 1 行且该行时间为“开始时间 + 1800 秒” | `summary.txt` 出现“采样空洞: 是”，覆盖率约 1.7%（`expected=60`、`rows=1`） |
| T9 | 正常跑完（fake stress exit 0） | `status.txt` 为 `OK`，`review` 结论“正常” |
| T10 | `start cpu` / `start hdd` | 行为与原脚本一致（回归），`status.txt` 正常生成 |
| T11 | `stop` 人为停止（monitor 正处于 `sleep 30` 中） | 2 秒内写出 `status.txt`=`STOPPED`，`review` 结论“已手动停止” |
| T12 | 语法与用法 | `bash -n stress-test.sh` 通过；`bash stress-test.sh`（无参数）输出用法 |

## 8. 风险

| 风险 | 处置 |
|---|---|
| 裁剪后压测强度低于历史批次 | `run-config` 同时记录预设与实际，报告里可区分；横向对比时以实际值为准 |
| 游标方案在 `dmesg` 环形缓冲回绕时漏事件 | 回绕时 cursor 归零，宁可重复也不漏 |
| `parse_size_mb` 解析失败 | 跳过裁剪并明确提示，不静默改参 |
| 4 个 monitor 同时读 `dmesg` 带来额外开销 | 每 30 秒一次只读调用，开销可忽略 |
