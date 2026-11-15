# 2026-11-13 服务器压测实操体系（三类机型 CPU/内存/硬盘）— 设计文档

## 背景与意图（Why）

既有离线安装包已可离线装好 `stress`。现在需要一套**完整压测实操体系**：三类服务器（海光 5380 / 7380 / 7360）各做 CPU、内存、硬盘压力测试，每次约 12 小时。核心诉求三条：**测试中实时可见状态**、**测试后能复盘**、**测试过程原始数据全部保存**。服务器无外网，全部在本机离线包内交付。

## 目标（Goals）

- 交付 2 个压测脚本（主控 `stress-test.sh` + 挂载辅助 `disk-mount.sh`）与 1 份实操文档（`operation-manual.md`），并入现有 `offline-stress-pkg` 离线包
- CPU/内存测试：一条命令按机型预设参数启动，后台运行，日志与监控全程落盘
- 硬盘测试：自动识别并挂载非系统盘（含分区格式化，需确认），每盘独立跑 `stress --hdd`，挂载与测试全程写日志
- 测试中随时可查状态（`status` 子命令 + 实时日志）
- 测完自动生成文本复盘总结；原始数据（stress 日志、监控 CSV、配置快照、挂载日志）完整保留
- 数据可拷回 U 盘（文档给出拷回步骤）

## 非目标 / 反目标（Non-goals / Anti-goals）

- **不做压测结论判定**（如"通过/不通过"标准）——只记录数据与事实，判定由用户根据数据自行完成
- **不做 HTML 图表报告**（用户已选文本总结+原始数据）
- **不做跨服务器远程管理**——服务器无网，操作与数据都在本机
- **不覆盖监控大盘/看板类工具**（无网，脚本化监控足够）
- **不做无确认的格式化/覆盖动作**——任何分区格式化与压测文件写入前，必须先展示计划并得到确认；测试盘为已确认的空盘
- **不覆盖压测范围确认机制**——逐盘确认是强制流程（用户已选）

## 约束（Constraints）

- 服务器无外网、U 盘传输；脚本为 bash；有 root/可 sudo；允许短时负载（12h 压测本身是负载，属用户既定计划）
- stress 已由离线包安装（`/usr/bin/stress`，1.0.4）
- 每次测试约 10h → 默认 `--timeout 10h`
- 监控粒度 30 秒一条（用户已确认）；10h ≈ 1200 行
- 复盘产出：文本总结 + 原始数据（用户已确认）；参数按机型内置预设、可显式覆盖（用户已确认）
- 三机型（来自用户提供的电脑配置信息与参考命令）：
  - 服务器一：2×海光 5380（双 C 共 64 线程），384GB（12×32G），12×8TB HDD + 2×480G SSD + 2×1.92T NVMe
  - 服务器二：2×海光 7380（双 C 共 128 线程），1024GB（16×64G），2×3.84T NVMe + 1×480G SSD
  - 服务器三：2×海光 7360（双 C 共 96 线程），512GB（16×32G），2×3.84T NVMe + 1×480G SSD
- 用户参考命令（压测参数依据）：
  - 5380：`stress --cpu 54 --vm 12 --vm-bytes 26G --timeout 10h`
  - 7360：CPU 线程压到 80 左右
  - 硬盘：每盘 `stress --hdd 1 --hdd-bytes 10G`；系统盘不分区不测（或在根目录跑）
  - 内存条压测：`--vm` = 内存条根数，`--vm-bytes` ≈ 单条容量×0.8（32G 条→26G，64G 条→54G）
- 仓库 `core.autocrlf=true` → 新增 .sh 文件必须遵守 `.gitattributes`（`*.sh text eol=lf`，已存在）

## 关键技术事实（已确认）

- stress 的 hdd 模式在**当前工作目录**写压测文件 → 每盘需在各自挂载点目录下运行
- 挂载点约定：`/mnt/HDDxx`（xx=01..N，按实际盘数）
- 系统盘识别：`df /` 的底层盘符（sda 等）为系统盘，跳过
- 监控数据源（全部无需额外安装，Kylin 自带）：`/proc/loadavg`、`/proc/meminfo`、`/proc/stat`、`/proc/diskstats`
- stress 正常跑完 `--timeout` 后退出码 0；被中断/失败退出码非 0 → 复盘以退出码为成败依据

## 方案设计（How，已定）

### 新增交付物（并入 offline-stress-pkg）

```
offline-stress-pkg/
├── stress-test.sh      # 主控：start cpu|mem|hdd / status / stop / review
├── disk-mount.sh       # 挂载辅助：mount / umount / list 子命令
├── operation-manual.md      # 实操文档（安装→挂载→测试→查看→复盘→拷回）
└── ...（既有 install.sh / verify.sh / rpms / README.md 不动）
```

### 结果数据目录（服务器上）

```
/root/stress-test/
├── mount.log            # 挂载/卸载全步骤日志（disk-mount.sh 写入，跨测试共享）
├── <YYYYmmdd-HHMMSS>-<cpu|mem|hdd>/     # 每次测试一个目录
│   ├── run-config.txt     # 机型、参数、开始时间、命令原文
│   ├── stress.log         # stress 原始输出（hdd 模式为 stress-HDDxx.log 每盘一份）
│   ├── monitor.csv        # 30 秒一条系统状态（原始数据，可 Excel 打开）
│   ├── info-before.txt    # 测试前快照：lscpu / free -h / df -h / lsblk / stress --version
│   └── summary.txt        # 自动生成的复盘总结（见下）
└── operations.log         # 主控脚本操作记录（start/stop 历史，防误操作复盘）
```

### monitor.csv 字段（30s 一行，逗号分隔，UTF-8）

`时间, load1, cpu_usage%, mem_total, mem_used, mem_avail, swap_used, disk_read_MBps, disk_write_MBps`
（磁盘 IO 从 /proc/diskstats 差值计算；CPU 从 /proc/stat 差值计算）

### 机型内置预设（默认 timeout 10h，全部可显式覆盖）

| 机型 | CPU 测试 | 内存测试 | 硬盘测试（每盘） |
|---|---|---|---|
| 5380（服务器一） | `--cpu 54` | `--vm 12 --vm-bytes 26G` | `--hdd 1 --hdd-bytes 10G` × N 盘 |
| 7380（服务器二） | `--cpu 110` | `--vm 16 --vm-bytes 54G` | `--hdd 1 --hdd-bytes 10G` × 2 盘 |
| 7360（服务器三） | `--cpu 80` | `--vm 16 --vm-bytes 26G` | `--hdd 1 --hdd-bytes 10G` × 2 盘 |

### 各脚本行为（关键契约）

**stress-test.sh**
- 子命令：`start cpu|mem|hdd`、`status`、`stop`、`review`
- `start`：校验 stress 已装 → 读机型预设（`--model` 或自动从 lscpu 推断）→ 建结果目录 → 写 info-before.txt 与 run-config.txt → nohup 后台启动 stress（日志重定向到结果目录）→ 后台启动 30s 监控循环写 monitor.csv → 输出"结果目录 + 查看方法"
- `status`：列出运行中的 stress/监控进程 + tail 最新监控几行 + 剩余时长估算（从 run-config 计算）
- `stop`：优雅终止本测试的 stress 与监控，写 operations.log
- `review`：读结果目录 → 生成 summary.txt（起止时间、时长、stress 退出码、monitor 统计：CPU 均值/峰值、内存峰值、IO 峰值、异常行数）→ 打印
- hdd 模式：检测已挂载测试盘（默认 /mnt/HDD*，可 `--dirs` 指定）→ 每盘一个 `stress --hdd 1 --hdd-bytes 10G` 后台进程，日志 stress-HDDxx.log
- 全程不 `set -e`；操作与结果全落盘

**disk-mount.sh**
- 子命令：`list`（lsblk + 标出系统盘/已挂载/未分区）、`mount`（逐盘确认流程）、`umount`（卸载全部测试盘）
- `mount` 流程（强制逐盘确认，用户已确认测试盘为空盘）：
  1. 列出全部非系统盘（盘符、容量、分区状态、挂载点）
  2. 交互确认：输入要纳入测试的盘符（逗号分隔；`all` = 全部）→ 打印**完整执行计划**（每盘：设备、容量、动作：mkfs+挂载到 /mnt/HDDxx 或 直接挂载）→ 单个 `y` 确认后执行
  3. 执行：无分区的盘先 `mkfs.ext4 -m 0`，再挂载到 `/mnt/HDDxx`；已有分区直接挂载；每步写 mount.log（时间/命令/结果）
  4. 支持非交互参数 `--disks sdb,sdc`（等价于交互选择）
- 系统盘（`df /` 所在盘）永不处理，list 中标红提示
- `umount` 逐盘列出并确认后卸载（可选 `--all` 跳过确认）

### 实操文档（operation-manual.md）内容清单

1. 适用环境与准备（三机型、先跑 install.sh 装 stress）
2. 快速上手三条命令（CPU/内存/硬盘）
3. 硬盘测试完整流程：`disk-mount.sh list` → `mount`（含 --format 与确认说明）→ `stress-test.sh start hdd` → 完成后 `umount`
4. 查看测试状态（status / tail monitor.csv / 各日志）
5. 测完复盘（review 生成 summary.txt，原始数据位置说明）
6. 数据拷回 U 盘（`cp -r /root/stress-test/* /mnt/usb/`）
7. 常见问题（进程被杀、目录已存在、盘未挂载、--timeout 单位秒/时等）

### 验收标准

- 本机侧（Windows/WSL 可测）：脚本 `bash -n` 通过；`disk-mount.sh list`/`mount` 在**无盘环境**（WSL）下正确报错或提示；`stress-test.sh` 子命令分支逻辑用 stub 模拟 stress 进程验证（start 建目录写日志、status 识别运行、stop 清理、review 从假数据生成 summary）；monitor 循环用假 /proc 数据跑 2 行验证 CSV 格式；脚本全部 LF、zip 重打且内容一致
- 服务器侧（用户执行）：三类型各跑短时（如 `--timeout 60s`）确认日志/监控/复盘全链路可用，再正式 10h

## 设计决策记录（我的决定，可推翻）

1. **默认 10h、可覆盖**：`--timeout 10h` 为预设默认，显式参数优先
2. **分区格式化策略（基于"测试盘全为空盘"的确认）**：选定盘无分区 → 自动 `mkfs.ext4 -m 0`；已有分区 → 直接挂载；执行前打印完整计划并需单个 `y` 确认
3. **逐盘确认强制**：`mount` 必须先列出非系统盘并交互选择纳入盘（或 `--disks` 指定），杜绝误测（用户已选逐盘确认）
4. **系统盘永不处理**：按 `df /` 识别并硬跳过
5. **每盘独立 stress 日志**：hdd 模式 stress-HDDxx.log，便于逐盘复盘
6. **监控用 /proc 差值计算**，不依赖 top/iostat（无需额外安装，兼容最小环境）
7. **复盘只给事实**：summary 含退出码与统计，不下"通过/不通过"结论
8. **结果目录命名带时间戳与类型**，防覆盖、可多轮对比
9. **不重打包 zip 中的旧文件**：zip 重打时保持 install.sh/verify.sh/README 字节不变（LF 已保证）

## 留给实现者的部分

- 脚本内部具体实现（子命令解析、/proc 差值算法、错误处理粒度）
- 实操文档的具体措辞与示例输出
- 本机 stub 测试的具体构造
