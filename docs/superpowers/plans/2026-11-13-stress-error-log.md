# 压测执行期间报错准确记录（error.log）实现计划

- 日期：2026-11-13
- 设计文档：`docs/superpowers/specs/2026-11-13-stress-error-log-design.md`（已批准）
- 涉及文件：`offline-stress-pkg/stress-test.sh`（唯一改动文件）
- 执行方式：Subagent-driven development（独立 subagent 实现 → 新 reviewer 复查 → 结尾整支复查）

## Global Constraints

- 仅修改 `offline-stress-pkg/stress-test.sh` 一个文件；其他文件（install.sh/verify.sh/disk-mount.sh/README/手册/zip）不动
- 脚本保持 `set -e` 不启用、纯 LF、中文输出
- monitor.csv 字段、stress 参数预设、机型检测、挂载逻辑一律不动
- 旧目录兼容：无 error.log 时 status/review 不报错

## 任务拆解

### Step 1: cmd_start —— 输出拆分 + error.log 初始化

位置：`cmd_start` 内"组装 stress 参数"之后、"建结果目录"之后。

改动点：
1. **启动命令**（cpu/mem/combo 主进程，当前约 L256、L271 两处）：
   - 原：`nohup sh -c 'stress $1 > "$2/stress.log" 2>&1; echo $? > "$2/stress.exitcode"'`
   - 新：`nohup sh -c 'stress $1 1>"$2/stress.log" 2>"$2/error.log"; echo $? > "$2/stress.exitcode"'`
2. **hdd 每盘**（约 L262）：原 `> "$4/stress-HDD$5.log" 2>&1` → `1>"$4/stress-HDD$5.log" 2>"$4/error-HDD$5.log"`
3. **sysdisk**（约 L267）：原 `> "$4/stress-SYSDISK.log" 2>&1` → `1>"$4/stress-SYSDISK.log" 2>"$4/error-SYSDISK.log"`
4. **error.log 初始化**：建目录后、启动前，追加：
   ```bash
   echo "# 压测错误日志（空=无错误） 开始时间: $(now)" > "$dir/error.log"
   ```
   （hdd/combo 的多盘场景：主进程 error.log 初始化同上；各盘 error-HDDxx.log 由启动命令首行 stderr 写入，无需单独初始化）
5. **run-config.txt 增行**：在"命令:"行前加 `echo "错误日志: error.log（stderr 实时记录）"`

### Step 2: cmd_monitor_loop —— 运行中巡检

位置：`cmd_monitor_loop` 的 while 循环内，写 monitor.csv 之后、`alive_pids` 检查之前；以及循环退出前。

改动点：
1. **上一轮存活数**：循环开始前 `prev_alive=$(alive_pids "$pids_file")`
2. **进程异常退出检测**：每轮写 CSV 后：
   ```bash
   alive=$(alive_pids "$pids_file")
   if [ "$alive" -lt "$prev_alive" ]; then
       for ec in "$dir"/*.exitcode; do
           [ -f "$ec" ] || continue
           code=$(cat "$ec" 2>/dev/null)
           [ "$code" != "0" ] && echo "[$(now)] 检测到 stress 进程异常退出（存活数 ${prev_alive}→${alive}），exitcode=${code}，详见 $(basename "$ec")" >> "$dir/error.log"
       done
   fi
   prev_alive="$alive"
   ```
   注意：正常自然结束（exitcode 0）不追加。多 exitcode 文件时逐个检查非 0 的追加。
3. **dmesg OOM 检测**：每轮增量读取。循环开始前记录基线行数：
   ```bash
   dmesg_line=0
   dmesg -c >/dev/null 2>&1   # 尝试清零权限；失败则后续静默跳过
   ```
   每轮（写 CSV 后）：
   ```bash
   new_dmesg=$(dmesg 2>/dev/null | tail -n +$((dmesg_line+1)))
   dmesg_line=$(dmesg 2>/dev/null | wc -l)
   if [ -n "$new_dmesg" ]; then
       while IFS= read -r line; do
           case "$line" in *[Oo]om*|*"out of memory"*|*"killed process"*|*Killed*) echo "[$(now)] dmesg: $line" >> "$dir/error.log";; esac
       done <<< "$new_dmesg"
   fi
   ```
   - 简化策略（推荐实现）：每轮 `dmesg -c 2>/dev/null` 取增量并清空（root 下有效），无权限时 `dmesg -c` 失败 → 整个 dmesg 检测跳过。实现时选简单可靠的一种，注释说明。
   - 任何 dmesg 失败不阻塞主循环。
4. **循环退出前追加结束结论**（while 循环退出、`alive_pids` 为 0 后）：
   ```bash
   if ! grep -q "检测到 stress" "$dir/error.log" 2>/dev/null && grep -vq "[1-9]" "$dir"/stress*.exitcode 2>/dev/null; then
       echo "[$(now)] 压测结束：全部正常（exitcode=0）" >> "$dir/error.log"
   fi
   ```
   - 简化：遍历所有 *.exitcode，全部为 0 → 追加"全部正常"；否则由前面的异常追加已覆盖，不再重复。注意 grep 空文件行为，用循环判断更稳。

### Step 3: print_status_dir —— 错误日志状态

位置：`print_status_dir` 的"最近监控"段之前。

改动点：追加
```bash
if [ -f "$d/error.log" ]; then
    if [ -s "$d/error.log" ]; then
        echo "错误日志: error.log（$(wc -l < "$d/error.log") 行，最近条目如下）"
        tail -5 "$d/error.log" | sed 's/^/  /'
    else
        echo "错误日志: 无（未发现报错）"
    fi
else
    echo "错误日志: 未生成（旧版本目录）"
fi
```

### Step 4: cmd_review —— 错误日志汇总 + 结论

位置：`cmd_review` 的 summary 生成段（"== 退出码 ==" 段之后）。

改动点：
1. 新增输出段（exitcode 段之后、原始数据行之前）：
   ```bash
   echo ""
   echo "== 错误日志 =="
   if [ -f "$dir/error.log" ]; then
       local err_lines
       err_lines=$(wc -l < "$dir/error.log")
       echo "error.log 共 ${err_lines} 行"
       if [ "$err_lines" -gt 1 ]; then head -20 "$dir/error.log" | sed 's/^/  /'; fi
   else
       echo "未生成错误日志（旧版本目录）"
   fi
   ```
2. **结论判定**：遍历所有 *.exitcode：
   - 全部存在且为 0 且 error.log 不存在或仅表头（≤1 行）→ `结论: 正常`
   - 否则 → `结论: 异常`，并在后文列出异常点（非 0 的 exitcode 文件名+值、error.log 中非表头行）
   - error.log 为空表头（1 行）视为无错误
   - 输出 `结论:` 一行放在 summary.txt 开头"==== 压测复盘总结 ====" 附近（便于一眼查看）

## 验证（tdd）

在 `.superpowers/sdd/2026-11-13-stress-error-log/` 下建 stub 测试：

- stub stress：bash 脚本，支持 `--timeout` 解析，按环境变量模拟行为（静默 exit0 / stderr 报错后 exit1 / 睡眠被杀）
- 测试场景：
  1. 正常：stub exit 0 → error.log 仅表头；review 结论"正常"
  2. stderr 报错：stub 打印 `malloc failed` exit 1 → error.log 含原文；review 结论"异常"
  3. 被杀：stub 睡眠中 kill -9 → monitor 追加"异常退出"；review"异常"
  4. OOM：注入 dmesg 模拟（dmesg 不可用则跳过该场景并记录）
  5. 旧目录：手工造无 error.log 目录 → review 不报错，结论按 exitcode
- 每条测试：`bash -n` + 实际运行 start/status/review 验证

## 交付

- 改完跑 `bash -n`（WSL 路径），全部场景通过后由 reviewer 复查
- 不提交 git（除非用户要求）
