usage() {
    cat <<'EOF'
用法:
  bash oneclick.sh                                   # 菜单（推荐）
  bash oneclick.sh all|hdd|sysdisk|cpu|mem [--timeout 10h]
  bash oneclick.sh status
  bash oneclick.sh review
  bash oneclick.sh --help

运行子命令:
  all       全测：CPU+内存组合 + 每块数据盘独立任务 + 系统盘（--no-hdd 时排除硬盘，仅测 CPU+内存）
  hdd       只测数据盘（每个 /mnt/HDD* 一个任务）
  sysdisk   只测系统盘
  cpu       只测 CPU
  mem       只测内存
  status    查看最近一次批次的启动状态
  review    对最近一次批次逐个复盘并生成汇总

菜单项:
  1) 全测（CPU+内存组合 + 每盘独立 + 系统盘）
  2) 测 CPU+内存（排除硬盘）
  3) 只测硬盘（数据盘）
  4) 只测系统盘
  5) 只测 CPU
  6) 只测内存
  7) 查看状态
  8) 生成复盘
  0) 退出

选项:
  --timeout <时长>   所有任务统一超时，默认 10h（数字 + 可选 d/h/m/s，如 10h、30m）
  --rebuild          重新分区并格式化数据盘（会清空数据盘；仅 all/hdd 生效）
  --no-hdd           仅 all 模式生效：排除所有硬盘（数据盘+系统盘），仅测 CPU+内存（COMBO peer=0）；跳过自动挂载，与 --rebuild 互斥
  --quiet            不在终端打印实际执行的命令（命令仍写入批次目录）
  --help             显示本帮助

执行顺序:
  前置检查 → 自动挂载（all/hdd）→ CPU+内存组合 → 每块数据盘一个窗口 → 系统盘
  → 等待全部结束 → 自动逐个复盘 → 输出汇总（批次目录 summary.txt，存在异常结论则退出码 1）
任务窗口:
  标题固定为 压测-组合CPU+内存 / 压测-HDDxx / 压测-系统盘 / 压测-CPU / 压测-内存；
  无图形环境（SSH、无 DISPLAY）自动降级为后台并行执行，输出写入批次目录 <任务>.out。
提示:
  默认复用数据盘已有文件系统；仅 --rebuild（或菜单输入 y）才会重新分区并格式化数据盘。
  启动阶段 COMBO 失败即中止批次；单盘/系统盘启动失败会记录到 failed-tasks.txt 后继续其余任务，最终退出码 1。
EOF
}

now() { date '+%Y-%m-%d %H:%M:%S'; }

die() { echo "$*"; exit 1; }

# ---------- 命令显示与落盘 ----------
# 所有实际执行的命令都以 argv 形式经受控函数显示/记录：显示串由 printf '%q' 派生，可直接复制重跑。

cmd_line() { local s="" a; for a in "$@"; do [ -n "$s" ] && s="$s "; s="$s$(printf '%q' "$a")"; done; printf '%s' "$s"; }
show_argv()  { local l; l=$(cmd_line "$@"); [ "$SHOW_CMD" = "1" ] && printf '  $ %s\n' "$l"; [ -n "${BATCH:-}" ] && [ -d "$BATCH" ] && printf '%s\n' "$l" >> "$BATCH/commands.txt"; }
show_once_argv() { local l; l=$(cmd_line "$@"); [ "$SHOW_CMD" = "1" ] && printf '  $ %s\n' "$l"; if [ -n "${BATCH:-}" ] && [ -d "$BATCH" ]; then grep -Fxq -- "$l" "$BATCH/commands.txt" 2>/dev/null || printf '%s\n' "$l" >> "$BATCH/commands.txt"; fi; }
record_sh()  { local l; l=$(cmd_line "$@"); [ -n "${BATCH:-}" ] && [ -f "$BATCH/commands.sh" ] && printf '%s\n' "$l" >> "$BATCH/commands.sh"; }
show_run()   { show_argv "$@"; record_sh "$@"; }

# 主终端任务命令：STRESS_ARGV 保存“当前任务实际执行的 argv”（含 type/timeout/extra），
# 统一顺序为 bash <ST> start <type> --timeout <T> [extra...]；LAST_TASK_CMD 供失败重跑提示使用
STRESS_ARGV=()
stress_argv() {
    local type="$1" timeout="$2" e
    shift 2
    STRESS_ARGV=(bash "$ST" start "$type" --timeout "$timeout")
    for e in "$@"; do STRESS_ARGV+=("$e"); done
}

write_env_file() {
    { echo "BATCH=$BATCH"; echo "MODE=$MODE"; echo "START_TIME=$START_TIME";
      echo "TIMEOUT=$TIMEOUT"; echo "STRESS_TEST_ROOT=$STRESS_TEST_ROOT";
      echo "STRESS_TEST_SH=$ST"; echo "DISK_MOUNT_SH=$DM"; echo "TERM_KIND=$TERM_KIND";
      echo "POLL_INTERVAL=$POLL_INTERVAL"; echo "READY_TIMEOUT=$READY_TIMEOUT";
      echo "REBUILD=$REBUILD"; echo "SHOW_CMD=$SHOW_CMD"; } > "$BATCH/env.txt"
}

