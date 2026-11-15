# 压测执行期间报错准确记录（error.log）设计

- 日期：2026-11-13
- 状态：待评审
- 关联脚本：`offline-stress-pkg/stress-test.sh`（start / monitor-loop / status / review）
- 需求来源：用户检查 7380 压测数据时发现——stress.log 运行中仅有一行 `dispatching hogs`，无法判断执行期间是否报错；退出码与报错分散在多个文件，无专门错误日志。用户确认需求：**压测期间任何报错都实时写入专门的 error.log，运行中 + 事后均可准确查看**。

## 1. 现状

| 项 | 当前行为 | 缺口 |
|---|---|---|
| stress 输出 | `stress ... > stress.log 2>&1`，stdout/stderr 混写 | stderr（报错文本）不单独成档 |
| 退出码 | `echo $? > stress.exitcode`，各盘 stress-HDDxx.exitcode | 仅记录数字，无自动解读/聚合 |
| 运行中检测 | monitor-loop 每 30s 采样；`alive_pids` 为 0 时静默退出 | 进程异常消失不标记、不记录 |
| 系统错误 | 无 | OOM/硬件错误不采集 |
| 复盘 | review 打印各 exitcode 原文 | 无"本次压测是否异常"结论 |

## 2. 目标

- 压测期间任何报错（stress 自身 stderr、进程异常退出、OOM kill）**实时**写入结果目录专门的 `error.log`
- `status` 运行中可见 error.log 状态；`review` 事后汇总并给出"正常/异常"结论
- 无报错时 error.log 为空（或仅表头注释），明确表示"运行无错误"

## 3. 方案

### 3.1 start：输出拆分 + 错误日志初始化

- cpu/mem/combo 主进程启动命令改为：
  `stress $ARGS 1>stress.log 2>error.log; echo $? > stress.exitcode`
  - stdout（正常 info，含 `successful run complete`）→ stress.log
  - stderr（报错，如 `malloc failed`）→ error.log
- hdd 每盘同理：`1>stress-HDDxx.log 2>error-HDDxx.log`，退出码 → stress-HDDxx.exitcode
- `--sysdisk` 系统盘：`1>stress-SYSDISK.log 2>error-SYSDISK.log`
- 建目录后初始化 error.log：写入表头 `# 压测错误日志（空=无错误） 开始时间: <now>`
- run-config.txt 增加一行 `错误日志: error.log（stderr 实时记录）`

> 说明：stress 的 `--hdd` 每盘进程由脚本用 `sh -c 'cd "$1" && stress ...'` 启动，输出重定向在启动命令内完成，逐盘独立 error 日志不串扰。

### 3.2 monitor-loop：运行中巡检追加错误记录

在现有每轮采样写 monitor.csv 之后（`alive_pids` 检查之前）追加：

- **进程异常退出检测**：对比上一轮 `alive_pids` 存活数，若本轮减少且结果目录存在对应 `.exitcode` 文件且内容非 0，向 error.log 追加一行：
  `[<时间>] 检测到 stress 进程异常退出（存活数 <n1>→<n2>），exitcode=<值>，详见 <对应日志>`
  - 正常自然结束（到 `--timeout` 退出码 0）不追加
- **OOM/系统错误检测**：每轮增量读取 `dmesg`（记录上次行号，仅取新增行），过滤 `oom|out of memory|killed process|Killed` 关键字，命中则追加到 error.log：
  `[<时间>] dmesg: <匹配行原文>`
  - `dmesg` 不可用（非 root/无权限）时静默跳过，不阻塞主循环
- 监控循环结束（进程全部消失）时，若 error.log 无报错追加且所有 exitcode 为 0，追加一行：
  `[<时间>] 压测结束：全部正常（exitcode=0）`

### 3.3 status：显示错误日志状态

`print_status_dir` 增加：
- `错误日志: error.log（N 行，最近条目如下）`，`tail -5 error.log` 展示
- error.log 不存在或为空时显示 `错误日志: 无（未发现报错）`

### 3.4 review：错误日志汇总 + 结论

- 新增输出段：
  - `错误日志: error.log 共 N 行`，非空则全文打印（限制行数）
  - `结论: 正常 / 异常`——判定规则：所有 *.exitcode 为 0 且 error.log 无报错 → `正常`；任一 exitcode 非 0 或 error.log 有报错 → `异常`，并列出异常点（exitcode 值、error.log 报错行）
- 兼容：旧结果目录无 error.log → 显示 `未生成错误日志（旧版本目录）`，结论仅按 exitcode 判定

### 3.5 涉及文件

仅 `offline-stress-pkg/stress-test.sh` 一个脚本：
- cmd_start：启动命令输出拆分、error.log 初始化、run-config 增行
- cmd_monitor_loop：巡检追加逻辑（退出检测 + dmesg OOM + 结束结论）
- print_status_dir：错误日志状态段
- cmd_review：错误日志汇总 + 结论判定

## 4. 测试方案（tdd，stub 化）

沿用既有测试接缝（`STRESS_TEST_ROOT`、`MONITOR_INTERVAL` 环境变量 + 本地 stub stress），在 `.superpowers/sdd/` 下用 stub 验证：

1. **正常路径**：stub stress 静默 exit 0 → error.log 为空表头；review 结论 `正常`
2. **stderr 报错**：stub stress 向 stderr 打印 `malloc failed` 后 exit 1 → error.log 含原文；review 结论 `异常` 且列出该行
3. **进程被杀**：stub stress 被 kill -9 → monitor 巡检追加"异常退出"记录 + exitcode 非 0；review 结论 `异常`
4. **OOM 模拟**：stub 环境注入 dmesg 匹配行 → error.log 追加 dmesg 原文
5. **旧目录兼容**：无 error.log 的结果目录 → review 不报错，仅按 exitcode 判定

## 5. 非目标

- 不改监控数据采集逻辑（monitor.csv 字段不变）
- 不改 stress 参数预设 / 机型检测 / 挂载逻辑
- 不新增部署依赖（仅用 dmesg，无权限时降级跳过）
- 不改旧目录历史数据

## 6. 验收标准

- 运行中 `status` 能看到 error.log 状态与最近条目
- `review` 对 正常/异常/被杀/旧目录 四种场景给出正确结论
- 全流程 bash -n 通过；既有功能（cpu/mem/hdd/combo start、status、stop）回归不受影响
