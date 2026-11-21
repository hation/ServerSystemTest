usage() {
    cat <<'EOF'
用法:
  bash oneclick.sh                                   # 菜单（推荐）
  bash oneclick.sh all|hdd|sysdisk|cpu|mem|full|clean [--timeout 10h]
  bash oneclick.sh --high [--timeout 10h]            # 一键中高强度整机压测（等价 full，不弹菜单）
  bash oneclick.sh status
  bash oneclick.sh review
  bash oneclick.sh --help

运行子命令:
  all       求稳强度整机压测：CPU+内存组合 + 每块数据盘独立任务 + 系统盘；参数自动推导，保守
            （--no-hdd 时排除硬盘，仅测 CPU+内存）
  full      中高强度整机压测（参数默认按朋友规则推导：CPU≈round(逻辑线程×70%)、VM=DIMM 根数、
            vm-bytes=脚本单根推导公式 单条容量−max(单条/8,6G)、不裁剪；可用 FULL_CPU/FULL_VM/FULL_VMBYTES 显式覆盖）
  --high    一键中高强度：无模式时直接中高整机压测（等价 full）；all --high 亦等价 full；
            cpu/mem/hdd/sysdisk 带 --high 时提示忽略；与 --no-hdd 互斥
  hdd       只测数据盘（每个 /mnt/HDD* 一个任务）
  sysdisk   只测系统盘
  cpu       只测 CPU
  mem       只测内存
  clean     清空数据盘：卸载并 wipefs 全部非系统盘、非U盘（交互 y/N 确认；不进批次）
  status    查看最近一次批次的启动状态
  review    对最近一次批次逐个复盘并生成汇总

菜单项:
  1) 求稳强度压测（CPU+内存组合 + 每盘独立 + 系统盘；参数自动推导，保守）
  2) 中高强度整机压测（同上任务构成；参数按朋友规则推导，FULL_* 显式设置可覆盖）
  3) 测 CPU+内存（排除硬盘）
  4) 只测硬盘（数据盘）
  5) 只测系统盘
  6) 只测 CPU
  7) 只测内存
  8) 查看状态
  9) 生成复盘
  10) 清空数据盘（全部非系统盘、非U盘；卸载并 wipefs 整盘，需 y 确认）
  0) 退出

选项:
  --timeout <时长>   所有任务统一超时，默认 10h（数字 + 可选 d/h/m/s，如 10h、30m）
  --rebuild          重新分区并格式化数据盘（会清空数据盘；仅 all/hdd/full 生效）
  --no-hdd           仅 all 模式生效：排除所有硬盘（数据盘+系统盘），仅测 CPU+内存（COMBO peer=0）；跳过自动挂载，与 --rebuild 互斥
  --no-cleanup       批次结束后不自动清空本批数据盘（默认自动清空本批数据盘）
  --high             一键中高强度整机压测（等价 full；仅 all/full 生效，与 --no-hdd 互斥；cpu/mem/hdd/sysdisk 带 --high 时忽略）
  --quiet            不在终端打印实际执行的命令（命令仍写入批次目录）
  --help             显示本帮助

执行顺序:
  前置检查 → 自动挂载（all/hdd/full）→ CPU+内存组合 → 每块数据盘一个窗口 → 系统盘
  → 等待全部结束 → 自动逐个复盘 → 自动清空本批数据盘（--no-cleanup 可关）
  → 输出汇总（批次目录 summary.txt，存在异常结论则退出码 1）
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
      echo "REBUILD=$REBUILD"; echo "SHOW_CMD=$SHOW_CMD"; echo "CLEANUP=$CLEANUP"; } > "$BATCH/env.txt"
}

