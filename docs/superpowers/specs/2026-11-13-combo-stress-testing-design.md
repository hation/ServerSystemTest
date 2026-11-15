# 2026-11-13 组合压测模式（combo：CPU/内存/硬盘同时）— 设计文档

## 背景与意图（Why）

既有压测体系支持 cpu / mem / hdd 单独测试（每类约 12h，原始数据全保存）。用户新增需求：**组合测试**——同一时段同时压 CPU、内存、硬盘，且测试全程能**查看测试日志**（随时看状态与实时输出）。

## 目标（Goals）

- 新增 `stress-test.sh start combo` 子命令：一次启动三类负载，互不干扰并行运行，默认 10h
- 双轨设计：CPU+内存合并一个 stress 进程；**每个已挂载测试盘各一个 `--hdd` 进程**（全盘覆盖，符合用户逐盘方法论）
- **支持系统盘压力测试**：`--sysdisk` 显式开启时，在系统盘根文件系统上并行一个 `--hdd` 进程（默认关闭，需显式开启）
- 结果统一落盘到一个 `<时间戳>-combo/` 目录：CPU/内存 stress 日志 + 每盘 hdd 日志 + 系统盘 hdd 日志 + 一份全局 30s 监控 CSV + 综合 summary
- **日志全程可查看**：`status` 显示各进程与剩余时长、`tail -f monitor.csv` 实时曲线、各日志文件实时写入
- 现有 cpu/mem/hdd 单测子命令、disk-mount.sh、安装脚本**一律不动**

## 非目标 / 反目标（Non-goals / Anti-goals）

- **不引入 stress-ng**：已侦察确认 EPEL 8 无 stress-ng 包（el8 生态只有 stress/stressapptest），离线服务器装它需第三方 el8 包或源码编译，可行性与收益均不足；普通 stress 组合能力已满足需求
- **不做压测结论判定**：summary 只给事实（退出码/统计），判定由用户完成
- **不改动现有单测流程与数据结构**：combo 是新增子命令，复用既有结果目录/监控/stop/review 机制
- **不做单进程全盘方案**：`--hdd` 只写当前目录所在盘，单进程无法覆盖全部测试盘

## 约束（Constraints）

- 复用既有机制：结果目录命名 `<ts>-combo/`、`run-config.txt`、`info-before.txt`、`monitor.csv`（同字段）、`stress.pids`、`monitor.pid`、根级 `operations.log`、`--timeout` 默认 `10h`、`STRESS_TEST_ROOT`/`MONITOR_INTERVAL` 测试接缝
- 三机型预设与单测一致（逐字）：5380→cpu 54/vm 12/26G；7380→cpu 110/vm 16/54G；7360→cpu 80/vm 16/26G；hdd 每盘 `--hdd 1 --hdd-bytes 10G`
- hdd 盘来源：已挂载测试盘（默认 `/mnt/HDD*`，复用挂载点校验；`--dirs` 显式指定放行，支持根目录）
- **系统盘压测为显式开启**（`--sysdisk`）：默认不压系统盘；`disk-mount.sh` 的"系统盘永不挂载"保证不变（压测与挂载是两层，互不干扰）
- 全部脚本 LF（`.gitattributes` 已生效）、无 `set -e`、中文输出
- 本机 WSL stub 测试 + 服务器侧 `--timeout 60s` 全链路验收

## 方案设计（How，已定）

### `start combo` 行为（关键契约）

1. 参数解析同现有子命令（`--model`/`--timeout`/`--cpu`/`--vm`/`--vm-bytes`/`--hdd-bytes`/`--dirs`）；`--model` 缺省 auto 检测，打印机型与预设
2. **前置校验（先全量、后启动）**：hdd 目录集合（默认 `/mnt/HDD*` 逐目录校验挂载点且非根设备；`--dirs` 仅存在性）任一不通过整体退出，不建目录不启动（复用并保持既有防孤儿语义）
3. 建 `<ts>-combo/` 结果目录 → 写 run-config.txt（机型、组合参数、命令原文）与 info-before.txt
4. 启动 **CPU/内存组合进程**：`nohup stress --cpu N --vm M --vm-bytes X --timeout T` → `stress.log` + `echo $? > stress.exitcode`（记录 PID）
5. 对每个挂载盘启动 **hdd 进程**：`cd <盘目录> && nohup stress --hdd 1 --hdd-bytes Y --timeout T` → `stress-HDDxx.log` + `stress-HDDxx.exitcode`（记录 PID）
6. **`--sysdisk` 开启时**，额外启动系统盘 hdd 进程（见下节），日志 `stress-SYSDISK.log` + `stress-SYSDISK.exitcode`
7. 全部 PID 写入 `stress.pids` → 启动监控循环（跟踪全部 PID，全部消失即退出，写 monitor.csv）
8. 打印启动三连（已启动/查看状态/实时监控）与结果目录

### 系统盘压力测试（`--sysdisk`，显式开启）

用户参考命令：系统盘直接在根目录 `stress --hdd 1 --hdd-bytes 10G`。设计（默认关闭，显式开启）：

1. 触发：`combo` 与 `hdd` 模式均支持 `--sysdisk` 标志（cpu/mem 模式无关，忽略并提示）
2. 位置：系统盘根文件系统上的**专用目录** `/stresstest-hdd`（`mkdir -p`），`cd` 后运行 `stress --hdd 1 --hdd-bytes Y --timeout T`——测试对象同为系统盘（同一文件系统），但避免压测临时文件污染 `/` 根目录
3. **空间预检**：`df -P /` 可用空间 ≥ `--hdd-bytes × 1.2`，不足则报错整体退出（防系统盘写满）；测试完成后提示可清理该目录
4. 日志：`stress-SYSDISK.log` + `stress-SYSDISK.exitcode`，与每盘 hdd 并列；status/stop/review 同等对待
5. 系统盘识别：复用 `df /` 设备识别（区别于挂载测试盘，绝不重复压同一块盘）
6. 文档强调：压测系统盘有写满风险，`--sysdisk` 需操作员显式知情使用

### `status` / `stop` / `review`（combo 复用，日志可见性）

- `status`：显示组合进程与每盘 hdd 进程的存活数、结果目录、剩余时长估算、`tail -5 monitor.csv`——满足"测试日志可查看"
- `stop`：按 `stress.pids` 全部终止 + 杀监控 + 写 operations.log
- `review`：综合 summary.txt——CPU/内存进程起止与退出码、每盘 hdd 各自退出码、monitor 统计（CPU 均值/峰值、内存峰值、IO 峰值）、异常行数；打印
- 全部日志（stress.log / stress-HDDxx.log / monitor.csv / run-config / summary）随结果目录保留，可 `tail -f` 实时看、可拷回 U 盘

### 文档与打包

- `operation-manual.md`：新增"组合测试"一节（命令、日志查看方法、复盘说明），其余不动
- `README.md`：不动（结构已列 stress-test.sh）
- zip 重打（7 条目 + 手册更新版）

## 验收标准

- 本机（WSL stub）：
  1. `bash -n` 通过
  2. stub 冒烟：`start combo`（假 stress + 2 个假挂载目录 + `MONITOR_INTERVAL=1 --timeout 3`）→ 结果目录 `<ts>-combo/` 生成，含 run-config/info-before/stress.log/stress.exitcode/stress-HDD01.log/stress-HDD01.exitcode ×2/monitor.csv（≥2 行）；`status` 显示运行中；等结束后 `status` 显示空闲、`review` 生成综合 summary（含 CPU/内存退出码与两盘 hdd 退出码）
  3. **`--sysdisk` stub 冒烟**：`start combo --sysdisk` → 额外生成 stress-SYSDISK.log + stress-SYSDISK.exitcode，status/review 将其与其它 hdd 同等对待；空间预检不足时（stub df 模拟）整体退出
  4. 回归：cpu/mem/hdd 单测 stub 冒烟仍通过（现有行为不破坏）
  5. combo 前置校验：默认路径存在未挂载目录 → 整体退出不启动（复用既有两阶段语义）
  6. 日志可见性：测试中 `status` 与 `tail monitor.csv` 输出正常
- 服务器侧（用户执行）：`--timeout 60s` combo 全链路 → 正式 10h

## 设计决策记录（我的决定，可推翻）

1. **双轨设计**（CPU/内存一进程 + 每盘 hdd 一进程）：全盘覆盖；单进程方案无法覆盖多盘
2. **不引入 stress-ng**：EPEL 8 无包（已侦察），离线不可行，收益不足
3. **参数同单测预设**：组合模式不降档（用户参考命令同值），可显式覆盖
4. **combo 为新增子命令**，保留单测：三类型可单独跑也可组合跑，互不影响
5. **前置校验先全量后启动**：沿用既有防孤儿语义，失败零副作用
6. **日志可见性**：status + 实时落盘 + tail，不引入任何 Web 看板（无网环境）
7. **系统盘压测默认关闭、显式 `--sysdisk` 开启**：压系统盘有写满风险，须操作员知情；`disk-mount.sh` 挂载层面仍永不碰系统盘
8. **系统盘 hdd 在专用目录 `/stresstest-hdd` 跑**：与"直接在 / 跑"等效（同一文件系统），但避免污染根目录；文档提供清理提示
9. **系统盘 hdd 前做空间预检**（`df -P /` 可用 ≥ `--hdd-bytes × 1.2`）：防系统盘写满影响系统

### builder-check 澄清（我已定案）

1. **"单测子命令一律不动"的含义**：既有 cpu/mem/hdd 的**默认行为与数据结构**不变；`--sysdisk` 是新增的可选标志（默认关闭），hdd 单测与 combo 模式都支持，属扩展而非改动
2. **无数据盘时 `combo --sysdisk` 允许**：hdd 目录集合可为空（无 /mnt/HDD*、无 --dirs），此时仅跑 CPU/内存 + 系统盘；前置校验只在"存在目录但校验失败"时退出，不因"无目录"退出
3. **summary 的"异常行数"改为"监控采样行数"**：只输出事实统计，不做阈值判定（符合"复盘只给事实"原则）
4. **服务器侧 60s 验收建议含 `--sysdisk`**：真实系统盘短时测试风险可控（可选执行，文档标注）
5. **`--dirs` 与 `--sysdisk` 重叠由操作员负责**：`--dirs` 显式指定即用户责任，文档提示勿与系统盘重复，脚本不做强制去重

## 留给实现者的部分

- 脚本内部实现（combo 分支与 --sysdisk 复用现有函数的最小改动方式）
- 手册"组合测试"与"系统盘测试"一节的措辞
- stub 测试的具体构造（含 df 空间预检 stub 模拟）
