# 压测参数按实测规格动态推导（DIMM 根数驱动）设计

- 日期：2026-11-15
- 状态：已批准（2026-11-15）
- 触发事故：`tmp/stress-test-2-8-1`（7380、128 线程、502 GiB，按写死的 `16×54G=864G` 启动，31 分钟后被 OOM 杀死）
- 涉及文件：`offline-stress-pkg/stress-test.sh`、`offline-stress-pkg/operation-manual.md`、`offline-stress-pkg/README.md`、`offline-stress-pkg.zip`
- 与既有设计的关系：取代 [2026-11-15-stress-memory-guard-design.md](2026-11-15-stress-memory-guard-design.md) 中“机型预设”的取值方式；该文档的内存裁剪、dmesg 游标、status.txt、review 采样空洞等成果全部保留

## 1. 意图与为什么

现有脚本按 `--model 5380|7380|7360` 查表下发 CPU worker 与内存参数，同一份 `16×54G` 被下发到 20 台实测内存为 502.5 / 754.5 / 994.7 / 1120.7 GiB 的机器上，分别占物理内存的 172% / 114% / 86.9% / 77.1%。其中 502 GiB 必然 OOM，754 GiB 的 20-1 打满了 4 GiB Swap。

本次改造要把“按型号查表”换成“按实测规格推导”，并满足用户明确要求：**`--vm` 必须等于服务器实际内存条根数**。

## 2. 已确认的口径（用户确认，不得擅改）

| 项 | 口径 |
|---|---|
| CPU worker | `floor(nproc × 86%)` |
| 内存总量 | `MemTotal × 82%`，硬上限 `MemTotal × 85%` |
| `--vm` | 等于实际内存条根数 |
| 根数探测失败 | 中断本次 mem/combo 启动，提示手动传 `--vm N` |

## 3. 目标

- `start cpu`：CPU worker 只由 `nproc` 推导，不再依赖型号。
- `start mem` / `start combo`：worker 数等于实测 DIMM 根数，单 worker 字节由 `MemTotal × 82% / 根数` 推导，最终命令必然不超过物理内存 85%。
- 推导依据全部落盘，事后可回溯：根数、来源、单根容量、目标总量、占比。
- 保留显式 `--cpu` / `--vm` / `--vm-bytes` 的覆盖能力。
- 保留另一会话已完成的裁剪、dmesg 游标、status.txt、review 增强。

## 4. 非目标

- 不改 `disk-mount.sh`、`mount-iso.sh`、`usb-eject.sh`。
- 不改 `monitor.csv` 9 列格式。
- 不改 combo 中每盘 `--hdd` 的启动方式和 `--sysdisk` 语义。
- 不引入 `numactl --interleave=all`（单独决策，本次不做）。
- 不为 7360 单独设置 80% 的 CPU 比例。
- 不做热插拔内存、动态重算。

## 5. 反目标（即使能跑也算失败）

- 探测不到根数时静默回退到 16 并继续压测。
- 推导出的总量超过 `MemTotal × 85%`。
- 推导过程只在屏幕输出、没有落到 `run-config.txt` / `operations.log`。
- 改动破坏旧结果目录的 `review` 兼容。

## 6. 详细设计

### 6.1 常量与测试接缝

在文件头环境变量区新增（保留现有 `DF_BIN` / `DMESG_BIN` / `MEMINFO_FILE` / `MEM_MAX_PCT`）：

```bash
CPU_MAX_PCT="${CPU_MAX_PCT:-86}"     # CPU worker 占逻辑线程比例
MEM_TARGET_PCT="${MEM_TARGET_PCT:-82}"  # 内存目标占 MemTotal 比例
NPROC_BIN="${NPROC_BIN:-nproc}"      # 测试接缝
DMI_BIN="${DMI_BIN:-dmidecode}"      # 测试接缝
EDAC_ROOT="${EDAC_ROOT:-/sys/devices/system/edac/mc}"  # 测试接缝
```

`MEM_MAX_PCT` 继续作为硬上限（默认 85），语义不变：分配上限，不是报告里的 80% 达成门槛。

### 6.2 CPU worker 推导

```bash
logical_cpus() {
    local n
    n=$("$NPROC_BIN" 2>/dev/null)
    case "$n" in ''|*[!0-9]*) n=$(awk '/^processor:/{c++} END{print c+0}' /proc/cpuinfo 2>/dev/null) ;; esac
    case "$n" in ''|*[!0-9]*|0) n=1 ;; esac
    echo "$n"
}

cpu_workers_auto() {
    local n w
    n=$(logical_cpus)
    w=$(( n * CPU_MAX_PCT / 100 ))
    [ "$w" -lt 1 ] && w=1
    echo "$w"
}
```

- `--cpu` 显式给值时直接用，不算比例。
- `start hdd` 不做 CPU 推导。

### 6.3 DIMM 根数探测（仅 mem/combo）

探测顺序固定为 dmidecode → EDAC；任一成功且结果 >0 即采用。

**方式一：dmidecode**

```bash
dimm_count_dmidecode() {
    "$DMI_BIN" -t 17 2>/dev/null | LC_ALL=C awk -F: '
        /^[[:space:]]*Size:/ {
            v = $2
            gsub(/^[ \t]+|[ \t]+$/, "", v)
            if (v ~ /^[1-9][0-9]*[[:space:]]*(MB|GB|TB)/) n++
        }
        END { print n+0 }'
}
```

规则：
- 只统计 `Size:` 行（不会误匹配 `Installed Size:`）。
- 只统计以正数开头、后接 MB/GB/TB 的已安装槽位。
- 自动排除 `No Module Installed`、`Unknown`、`Not Installed`、`0 MB`。
- 混合容量时全部计入（每根都是有效根数）。

**方式二：EDAC**

```bash
dimm_count_edac() {
    local f n=0
    for f in "$EDAC_ROOT"/mc*/dimm*/size; do
        [ -f "$f" ] || continue
        [ "$(cat "$f" 2>/dev/null)" -gt 0 ] 2>/dev/null && n=$((n + 1))
    done
    echo "$n"
}
```

**失败处理**：两者都返回 0，且用户未显式传 `--vm` 时：

```
无法探测内存条根数（dmidecode/EDAC 均不可用），本次 mem/combo 压测已中止。
请安装 dmidecode 后重试，或用 --vm <根数> 手动指定，例如：
  bash stress-test.sh start mem --vm 16
```

退出码 1，不创建结果目录、不启动任何 stress（与现有前置校验一致）。`start cpu` 不受影响。

### 6.4 内存总量与单 worker 字节

输入：`total_mb`（MemTotal）、`workers`、`MEM_TARGET_PCT`、`MEM_MAX_PCT`。

1. `target_mb = total_mb * MEM_TARGET_PCT / 100`
2. `per_gb = (target_mb + workers * 512) / (workers * 1024)`（四舍五入到 1 GiB，保证不低于 82%，从而高于报告 80% 达成门槛）
3. `per_gb < 1` → 报错退出：`单 worker 内存不足 1G（MemTotal XG / N 根），无法压测`
4. 硬上限回退：`while per_gb * workers * 1024 > total_mb * MEM_MAX_PCT / 100; do per_gb--; done`；若降到 0 则报错
5. `vm_bytes_opt="${per_gb}G"`

四舍五入的理由：若向下取整，502.5 GiB / 16 根会得到 25G×16=400G（79.6%），低于报告 80% 达成门槛；四舍五入得到 26G×16=416G（82.8%）。

### 6.5 参数优先级

| 用户输入 | worker 数 | 单 worker 字节 | 说明 |
|---|---|---|---|
| 都不传 | DIMM 根数 | 按 6.4 推导 | 默认路径 |
| 只传 `--vm N` | N | 按 6.4 用 N 推导 | 用户覆盖根数，仍需 85% 校验 |
| 只传 `--vm-bytes X` | DIMM 根数 | X | 不裁剪；总量超 85% 时醒目告警后继续（保留现有分支 C） |
| 都传 | N | X | 不裁剪；超限仅告警 |
| `--cpu N` | — | — | 直接用 N，不按比例 |

`--vm 0` / 非数字 / `--vm-bytes` 无法解析：沿用现有参数校验风格，报错退出。

### 6.6 机型与交叉校验

- `--model auto` 保留，用于报告字段与校验，**不参与参数分配**。
- 型号标称逻辑线程：5380=64、7360=96、7380=128。
- `abs(nproc - 标称) / 标称 > 10%` 时输出：

```
提示：实测 64 线程与机型 7380 标称 128 线程偏差 50%，疑似单路或关闭超线程；
      参数按实测值计算。
```

- 该提示只打印与写入 `operations.log`，不中止。

### 6.7 落盘字段

`run-config.txt` 在 mem/combo 分支追加（cpu 分支只加 CPU 推导行）：

```
CPU 逻辑线程: 128
CPU worker 数: 110（nproc 128 × 86%）
内存条根数: 16（来源: dmidecode）
单根容量: 64 GiB
内存目标: 816G（实际下发 16×51G；理论 MemTotal 995G × 82% ≈ 816G）
内存分配上限: 846G（MemTotal 995G × 85%）
VM worker 数: 16
VM 字节: 51G
```

- `内存目标` 与 `operations.log` 的 `total` 一律写**实际下发总量**（单 worker × 根数）；`MemTotal × 82%` 的理论值只出现在括号说明里，避免两个数字自相矛盾。
- `单根容量` 取值规则：dmidecode 成功时写槽位实测容量（如 `64 GiB`）；EDAC 或容量不可知时写 `均分 XG（MemTotal / 根数）`；显式 `--vm` 且未探测时写 `未探测`。
- 混合容量时 `单根容量` 写 `混合（按总量均分）`。
- 显式 `--vm` 时来源写 `显式 --vm`；显式 `--vm-bytes` 时内存目标写 `未推导（显式 --vm-bytes）`。
- 旧字段 `VM worker 数` / `VM 字节` 保留，位置不变，避免下游解析断裂。

`info-before.txt` 追加：

```
==== dmidecode -t 17 ====
（dmidecode -t 17 2>&1；不可用时输出失败原因）
==== numactl -H ====
（command -v numactl 可用则执行，否则输出“numactl 未安装”）
```

`operations.log` 增加一条：

```
mem-plan dimms=16 source=dmidecode per=51G total=816G target=82% cap=85% cpu=110(nproc=128,pct=86)
```

启动输出在 `已启动 ...` 之前打印最终命令与推导依据，方便操作者当场核对。

### 6.8 与现有代码的叠加方式

- 删除 `preset_cpu` / `preset_vm` / `preset_vm_bytes` 三个查表函数及其调用；改为 6.2 / 6.3 / 6.4 的函数。
- 保留 6.1 的 `MEM_MAX_PCT` 与裁剪块：它现在主要服务于“显式 `--vm-bytes` 超限告警”和“显式 `--vm` 的兜底”，分支 A/B 在自动推导路径下不会触发（推导结果必然 ≤82%）。
- `cmd_start` 中“机型解析”保留，但删除“使用预设参数”的提示文案，改为校验提示。
- `info-before` / `run-config` 的写入位置不变，只增字段。
- `cmd_monitor_loop`、`write_status`、`cmd_review`、combo/hdd/sysdisk 逻辑一律不改。

### 6.9 边界情况

| 情况 | 处理 |
|---|---|
| MemTotal 读取失败 + 自动推导 | mem/combo 中止，提示检查 `/proc/meminfo` |
| MemTotal 读取失败 + 显式 `--vm-bytes` | 告警后继续（尊重显式参数），`run-config` 标注“未校验” |
| 根数 > 256 或为 0 | 视为探测失败，走 6.3 失败处理 |
| 混合容量 | 根数全部计入，按总量均分；`单根容量` 标注“混合” |
| 推导结果在 85% 附近 | 循环降 1G 直到 ≤85% |
| 单 worker <1G | 报错退出 |
| 显式 `--vm` 很大导致单 worker <1G | 报错退出，提示根数与内存不匹配 |
| 显式 `--vm-bytes` 超 85% | 告警后继续（保持现有行为），`run-config` 标注“显式 --vm-bytes，超分配上限” |
| dmidecode 无 root | 命令失败 → 走 EDAC → 仍失败则中止 |
| 旧结果目录 review | 无新增字段时按旧逻辑解析，不受影响 |

## 7. 测试计划（离线可复现）

沿用现有 `DF_BIN` / `MEMINFO_FILE` / `DMESG_BIN` 假件手法，新增 `NPROC_BIN` / `DMI_BIN` / `EDAC_ROOT`。

| 编号 | 场景 | 期望 |
|---|---|---|
| T1 | 96T / 16 根 / 512GiB（7360） | `--cpu 82 --vm 16 --vm-bytes 26G` |
| T2 | 128T / 12 根 / 754.5GiB（7380） | `--cpu 110 --vm 12 --vm-bytes 52G` |
| T3 | 128T / 16 根 / 994.7GiB（7380） | `--cpu 110 --vm 16 --vm-bytes 51G` |
| T4 | 128T / 18 根 / 1120.7GiB（7380） | `--cpu 110 --vm 18 --vm-bytes 51G` |
| T5 | 64T / 12 根 / 384GiB（5380） | `--cpu 55 --vm 12 --vm-bytes 26G` |
| T6 | 128T / 16 根 / 502.5GiB | `--cpu 110 --vm 16 --vm-bytes 26G`，总量 416G |
| T7 | dmidecode 失败、EDAC 有 16 根 | 成功，来源 `edac` |
| T8 | dmidecode 与 EDAC 均失败，`start mem` | 退出码 1，提示 `--vm`，不建结果目录 |
| T9 | dmidecode 与 EDAC 均失败，`start cpu` | 正常运行，`--cpu` 按 nproc 推导 |
| T10 | 显式 `--vm 8`（502.5GiB，探测到 16 根） | 8 worker，单 worker 52G，总量 416G（82.8%），标注来源 `显式 --vm` |
| T11 | 显式 `--vm-bytes 54G`（502.5GiB / 16 根） | 不裁剪，告警，`run-config` 标注超限 |
| T12 | 混合容量（4×32GiB + 4×64GiB） | 根数 8，按总量均分，标注“混合” |
| T13 | `start combo` | CPU/内存按上述推导，hdd 部分与现状一致 |
| T14 | `bash -n` 与无参数用法 | 通过，用法文案同步更新（去掉“按预设跑”的措辞） |

测试脚本放 `.superpowers/sdd/2026-11-15-spec-driven-stress-params/tests/`，不提交假件到发布包。

## 8. 验收标准

- T1–T14 全部通过，并把实际生成的 `run-config.txt` 关键行贴进交付记录。
- 20 台历史数据回算：四种内存规格全部落在 81–83%，CPU 全部为 110。
- `start mem` 在 dmidecode 缺失时明确中止，不产生任何 stress 进程。
- `monitor.csv`、`status.txt`、`review` 输出与改造前一致。

## 9. 风险

| 风险 | 处置 |
|---|---|
| 现场 Kylin 未装 dmidecode | 本次不改 `install.sh` / `verify.sh`（避免扩大范围）；操作手册要求预装，启动时报错提示安装或 `--vm` 手动指定 |
| EDAC 未加载 | 仅作为第二来源；两路都失败即中止，不猜 |
| 1120.7GiB 那批从 864G 提到 918G | 属预期；报告需按新目标重算 80% 门槛（918×80%=734G） |
| 994.7GiB 那批从 864G 降到 816G | 属预期；与历史批次横向对比时以实际值为准 |
| `dmidecode` 输出本地化/格式变化 | 用 `LC_ALL=C` 且只匹配 `Size:` 数值行；T1–T6 覆盖不同容量 |
| 显式参数组合绕过校验 | T10/T11 覆盖；`run-config` 标注来源 |

## 10. 文档与打包

- `operation-manual.md`：预设表改为“参数推导规则”，补充 DIMM 探测失败处理、`--vm` 手动指定示例、四种内存规格的实测回算表。
- `README.md`：命令示例改为不带 `--model` 的默认路径，说明 `--model` 仅用于报告标注。
- 重新打包 `offline-stress-pkg.zip`（项目惯例）。

## 11. 留给实现者的决定

- 函数命名与拆分粒度，只要保持 6.2–6.4 的行为不变。
- 假件测试的具体组织方式，沿用现有 `.superpowers/sdd/.../tests/` 风格即可。
- 日志文案的措辞，只要包含 6.7 列出的关键数值与来源。
