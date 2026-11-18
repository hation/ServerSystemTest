#!/bin/bash
# oneclick.sh —— 一键压测入口（菜单/子命令）
# 用法：bash oneclick.sh --help
# 说明：启动编排（参数/菜单、前置检查、自动挂载、任务计划、终端窗口或后台启动、
#       内部子命令 __task、就绪握手、失败即停）+ 等待全部结束 + 自动逐个复盘 + 汇总。
#       --no-hdd：仅 all 模式生效，排除所有硬盘（数据盘+系统盘），仅测 CPU+内存（COMBO peer=0），
#       跳过自动挂载且与 --rebuild 互斥。
#       status/review 子命令均基于最近一次批次目录（$STRESS_TEST_ROOT/oneclick-*）。
PKG_DIR="$(cd "$(dirname "$0")" && pwd)"
STRESS_TEST_ROOT="${STRESS_TEST_ROOT:-/root/stress-test}"
ST="${ONECLICK_STRESS_TEST_SH:-$PKG_DIR/stress-test.sh}"
DM="${ONECLICK_DISK_MOUNT_SH:-$PKG_DIR/disk-mount.sh}"
# 相对路径规范化为绝对路径（存在性仍由 precheck 负责检查）
case "$ST" in
    /*) ;;
    *) _abs_dir=$(cd "$(dirname "$ST")" 2>/dev/null && pwd) && ST="$_abs_dir/$(basename "$ST")" ;;
esac
case "$DM" in
    /*) ;;
    *) _abs_dir=$(cd "$(dirname "$DM")" 2>/dev/null && pwd) && DM="$_abs_dir/$(basename "$DM")" ;;
esac
unset _abs_dir
POLL_INTERVAL="${ONECLICK_POLL_INTERVAL:-30}"
# 轮询间隔只接受 >=1 的整数，非法值回落 30（避免 sleep 报错后空转）
case "$POLL_INTERVAL" in
    ''|*[!0-9]*) POLL_INTERVAL=30 ;;
esac
[ "$POLL_INTERVAL" -ge 1 ] || POLL_INTERVAL=30
READY_TIMEOUT="${ONECLICK_READY_TIMEOUT:-180}"
ONECLICK_SKIP_ROOT_CHECK="${ONECLICK_SKIP_ROOT_CHECK:-0}"
# 命令显示开关：默认打印；ONECLICK_SHOW_CMD=0 或 --quiet 关闭（不影响落盘）
SHOW_CMD="${ONECLICK_SHOW_CMD:-1}"
[ "$SHOW_CMD" = "0" ] || SHOW_CMD=1
DEFAULT_TIMEOUT="10h"

TIMEOUT="$DEFAULT_TIMEOUT"
BATCH=""
START_TIME=""
MODE=""
TERM_KIND=""
ABORTED=0
# 启动失败标记：数据盘/系统盘启动失败时置 1（COMBO 失败另由 ABORTED 中止后续），批次最终退出 1
START_FAILED=0
LAST_TASK_CMD=""
# 数据盘重建开关：默认 0（复用已有文件系统）；--rebuild 或菜单输入 y 才置 1
REBUILD=0
# 排除硬盘开关：仅 all 模式生效；--no-hdd 置 1（任务计划只写 COMBO peer=0，跳过数据盘/系统盘任务）
NO_HDD=0
# 自动挂载退出码：all/hdd 记录 disk-mount.sh 的结果，非 0 表示存在跳过/失败盘，批次最终退出 1
MOUNT_RC=0

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

# ---------- 前置检查（仅运行类模式） ----------

precheck() {
    if [ "$ONECLICK_SKIP_ROOT_CHECK" != "1" ] && [ "$(id -u)" -ne 0 ]; then
        echo "请以 root 运行：sudo bash oneclick.sh ..."
        exit 1
    fi
    if ! command -v stress >/dev/null 2>&1; then
        echo "未找到 stress，请先运行：sudo bash install.sh"
        exit 1
    fi
    if [ ! -f "$ST" ]; then
        echo "缺少压测主脚本：$ST"
        exit 1
    fi
    if [ ! -f "$DM" ]; then
        echo "缺少挂载脚本：$DM"
        exit 1
    fi
}

# ---------- 终端探测 ----------

pick_terminal() {
    local gui="${ONECLICK_GUI:-auto}"
    if [ "$gui" = "0" ]; then
        TERM_KIND=none
        return 0
    fi
    if [ "$gui" != "1" ] && [ -z "${DISPLAY:-}" ] && [ -z "${WAYLAND_DISPLAY:-}" ]; then
        TERM_KIND=none
        return 0
    fi
    if command -v gnome-terminal >/dev/null 2>&1; then
        TERM_KIND=gnome-terminal
    elif command -v mate-terminal >/dev/null 2>&1; then
        TERM_KIND=mate-terminal
    elif command -v xterm >/dev/null 2>&1; then
        TERM_KIND=xterm
    else
        TERM_KIND=none
    fi
}

task_title() {
    case "$1" in
        HDD*) echo "压测-$1" ;;
        SYSDISK) echo "压测-系统盘" ;;
        COMBO) echo "压测-组合CPU+内存" ;;
        CPU) echo "压测-CPU" ;;
        MEM) echo "压测-内存" ;;
        *) echo "压测-$1" ;;
    esac
}

# ---------- 启动单个任务（窗口或后台） ----------

launch_task() {
    local id="$1" type="$2"
    shift 2
    local title cmd a
    title=$(task_title "$id")
    cmd="bash $(printf '%q' "$PKG_DIR/oneclick.sh") __task $(printf '%q' "$BATCH") $(printf '%q' "$id") $(printf '%q' "$TIMEOUT") $(printf '%q' "$type")"
    for a in "$@"; do
        cmd="$cmd $(printf '%q' "$a")"
    done
    echo "[$(now)] 启动任务：$id（窗口标题：$title）"
    case "$TERM_KIND" in
        gnome-terminal) gnome-terminal --title="$title" -- bash -c "$cmd" >/dev/null 2>&1 & ;;
        mate-terminal)  mate-terminal  --title="$title" -- bash -c "$cmd" >/dev/null 2>&1 & ;;
        xterm)          xterm -T "$title" -e bash -c "$cmd" >/dev/null 2>&1 & ;;
        *)              ONECLICK_NO_TAIL=1 bash -c "$cmd" >> "$BATCH/$id.out" 2>&1 < /dev/null & ;;
    esac
}

# ---------- 就绪握手 ----------

show_start_log_tail() {
    local id="$1"
    [ -f "$BATCH/$id.start.log" ] || return 0
    echo "---- $id 启动输出（末尾 20 行）----"
    tail -20 "$BATCH/$id.start.log"
    echo "--------------------------------"
}

wait_ready() {
    local id="$1" type="$2" i=0 d
    while [ "$i" -lt "$READY_TIMEOUT" ]; do
        if [ -f "$BATCH/$id.dir" ]; then
            d=$(cat "$BATCH/$id.dir" 2>/dev/null)
            printf '%s|%s|%s\n' "$id" "$type" "$d" >> "$BATCH/tasks.txt"
            return 0
        fi
        if [ -f "$BATCH/$id.fail" ]; then
            echo "任务 $id 启动失败"
            show_start_log_tail "$id"
            return 1
        fi
        sleep 1
        i=$((i + 1))
    done
    echo "任务 $id 启动超时（${READY_TIMEOUT} 秒内未就绪）"
    show_start_log_tail "$id"
    return 1
}

# ---------- 挂载与数据盘枚举 ----------

collect_hdd_dirs() {
    # 挂载点可能含空格：跳过前 5 个空白分隔字段后，保留该行剩余原始字符作为挂载点，
    # 避免按字段取第 6 列时被空格拆坏。
    # 只匹配 /mnt/HDD 开头的顶层挂载点（/mnt/HDD01、/mnt/HDD 01 等），
    # 带 / 的嵌套挂载点（如 /mnt/HDD01/sub）不算数据盘，排除以免重复任务。
    # df 对空格可能输出 \040 形式，这里只精确替换该四字符序列，其他反斜杠原样保留
    # （不能用 printf '%b'：它按最多 3 位八进制贪婪解析，\04001 会被拆成空格 + "1"）。
    df -P 2>/dev/null | awk 'NR > 1 {
        s = $0; n = 0;
        while (n < 5) { sub(/^[ \t]*[^ \t]+/, "", s); n++ }
        sub(/^[ \t]+/, "", s);
        if (s ~ /^\/mnt\/HDD[^/]*$/) print s
    }' | while IFS= read -r m; do
        m=${m//\\040/ }
        printf '%s\n' "$m"
    done | sort -u
}

do_mount() {
    local -a argv=(bash "$DM" mount --disks all --yes)
    # 仅在显式请求时追加 --rebuild（默认复用已有文件系统，不清盘）
    [ "$REBUILD" = "1" ] && argv+=(--rebuild)
    show_run "${argv[@]}"
    "${argv[@]}" 2>&1 | tee "$BATCH/mount.log"
    local rc=${PIPESTATUS[0]}
    return "$rc"
}

# ---------- 生成任务计划 ----------

write_plan() {
    local mode="$1" plan="$BATCH/plan.txt" dirs d id rc
    : > "$plan"
    case "$mode" in
        all|hdd)
            if [ "$NO_HDD" -eq 1 ]; then
                # --no-hdd：排除所有硬盘，跳过自动挂载（MOUNT_RC 保持 0，批次退出码不被挂载结果影响）
                MOUNT_RC=0
            else
                do_mount
                rc=$?
                # 记录挂载结果：存在跳过/失败盘时批次最终退出码须为 1（FR-2）
                MOUNT_RC="$rc"
                if [ "$rc" -ne 0 ]; then
                    if [ "$mode" = "hdd" ]; then
                        # 只测硬盘：部分盘失败但已有挂载点则继续（设计 §7/FR-2），一个都没有才退出
                        dirs=$(collect_hdd_dirs)
                        [ -n "$dirs" ] || die "未发现已挂载的数据盘（/mnt/HDD*），请先运行 bash disk-mount.sh mount"
                    fi
                    echo "警告：自动挂载返回非 0（$rc），继续按当前已挂载盘执行；挂载日志：$BATCH/mount.log"
                fi
            fi
            ;;
    esac
    case "$mode" in
        all)
            if [ "$NO_HDD" -eq 1 ]; then
                # --no-hdd：排除所有硬盘，仅测 CPU+内存（COMBO peer=0），不枚举数据盘、不写系统盘任务
                printf 'COMBO|combo|--peer-disks|0\n' >> "$plan"
                echo "已排除硬盘（--no-hdd），仅测 CPU+内存（COMBO peer=0）"
                return
            fi
            dirs=$(collect_hdd_dirs)
            # 先计数再写计划：计划顺序即启动顺序（COMBO 先启动），N = 数据盘数 + 1（固定含系统盘）
            local hdd_count=0
            if [ -n "$dirs" ]; then
                while IFS= read -r d; do
                    [ -n "$d" ] || continue
                    case "$d" in *'|'*) die "目录名含 | 不受支持：$d" ;; esac
                    hdd_count=$((hdd_count + 1))
                done <<< "$dirs"
            fi
            printf 'COMBO|combo|--peer-disks|%s\n' "$((hdd_count + 1))" >> "$plan"
            if [ "$hdd_count" -eq 0 ]; then
                echo "未发现数据盘，跳过数据盘任务（COMBO peer=1 + 系统盘）"
            else
                while IFS= read -r d; do
                    [ -n "$d" ] || continue
                    case "$d" in *'|'*) die "目录名含 | 不受支持：$d" ;; esac
                    id="${d##*/}"
                    printf '%s|hdd|--dirs|%s\n' "$id" "$d" >> "$plan"
                done <<< "$dirs"
            fi
            printf 'SYSDISK|hdd|--sysdisk-only\n' >> "$plan"
            ;;
        hdd)
            dirs=$(collect_hdd_dirs)
            [ -n "$dirs" ] || die "未发现已挂载的数据盘（/mnt/HDD*），请先运行 bash disk-mount.sh mount"
            while IFS= read -r d; do
                [ -n "$d" ] || continue
                case "$d" in *'|'*) die "目录名含 | 不受支持：$d" ;; esac
                id="${d##*/}"
                printf '%s|hdd|--dirs|%s\n' "$id" "$d" >> "$plan"
            done <<< "$dirs"
            ;;
        sysdisk) printf 'SYSDISK|hdd|--sysdisk-only\n' >> "$plan" ;;
        cpu)     printf 'CPU|cpu|\n' >> "$plan" ;;
        mem)     printf 'MEM|mem|\n' >> "$plan" ;;
        *)       die "未知模式：$mode" ;;
    esac
    echo "==== 任务计划（$plan）===="
    sed 's/^/  /' "$plan"
}

# ---------- 内部子命令 __task：启动一个任务并写就绪标记 ----------

cmd_task() {
    local batch="$1" id="$2" timeout="$3" type="$4"
    shift 4
    mkdir -p "$batch" || { echo "无法创建批次目录：$batch"; exit 1; }
    # 重建本任务 argv 并打印启动 banner；banner 不进 commands.txt（主终端已记录同一条命令）
    stress_argv "$type" "$timeout" "$@"
    if [ "${ONECLICK_SHOW_CMD:-1}" != "0" ]; then
        echo "==== $id 启动命令 ===="
        printf '  $ %s\n' "$(cmd_line "${STRESS_ARGV[@]}")"
        echo "======================"
    fi
    "${STRESS_ARGV[@]}" 2>&1 | tee "$batch/$id.start.log"
    local rc=${PIPESTATUS[0]}
    echo "$rc" > "$batch/$id.startrc"
    if [ "$rc" -ne 0 ]; then
        echo "启动失败（退出码 $rc）"
        : > "$batch/$id.fail"
        exit 1
    fi
    local dir
    dir=$(sed -n 's/^已启动 .*压测：//p' "$batch/$id.start.log" | tail -1)
    if [ -z "$dir" ]; then
        echo "无法从启动输出解析结果目录"
        : > "$batch/$id.fail"
        exit 1
    fi
    echo "$dir" > "$batch/$id.dir"
    if [ "${ONECLICK_NO_TAIL:-0}" = "1" ]; then
        exit 0
    fi
    echo "==== $id 实时监控（Ctrl-C 只退出查看，不影响压测）===="
    if [ -f "$dir/monitor.csv" ]; then
        if [ -f "$dir/monitor.pid" ]; then
            tail -f --pid="$(cat "$dir/monitor.pid")" "$dir/monitor.csv"
        else
            tail -f "$dir/monitor.csv"
        fi
    else
        echo "未找到监控数据：$dir/monitor.csv，跳过实时监控"
    fi
    echo "压测已结束，结果目录：$dir"
    printf '按回车关闭窗口：'
    read -r _ || true
}

# ---------- 完成判定与等待 ----------

# 统计文件中的 PID 行数（忽略空行与非数字行）
count_pid_lines() {
    awk 'NF > 0 && $0 ~ /^[0-9]+$/ { n++ } END { print n + 0 }' "$1" 2>/dev/null
}

# task_done <结果目录>：status.txt 存在即完成；结果目录/pid 清单缺失视为“无需等待”；
# 否则以“进程全部退出 + 退出码文件齐全”兜底
task_done() {
    local dir="$1" pids np=0 alive=0 ec=0 p
    [ -n "$dir" ] || return 1
    [ -f "$dir/status.txt" ] && return 0
    # 目录或 pid 清单缺失时不可能再等到完成标记，直接放行（由复盘输出未知/异常）
    [ -d "$dir" ] || return 0
    pids="$dir/stress.pids"
    [ -f "$pids" ] || return 0
    np=$(count_pid_lines "$pids")
    [ "$np" -gt 0 ] || return 1
    while read -r p; do
        case "$p" in
            ''|*[!0-9]*) continue ;;
        esac
        if kill -0 "$p" 2>/dev/null; then
            alive=$((alive + 1))
        fi
    done < "$pids"
    [ "$alive" -eq 0 ] || return 1
    ec=$(ls "$dir"/*.exitcode 2>/dev/null | wc -l)
    ec=${ec//[[:space:]]/}
    [ "$ec" -ge "$np" ]
}

# 等待批次内所有任务结束（全部完成即返回）
wait_all() {
    local id type dir pending list
    [ -f "$BATCH/tasks.txt" ] || return 0
    while :; do
        pending=0
        list=""
        while IFS='|' read -r id type dir; do
            [ -n "$id" ] || continue
            if ! task_done "$dir"; then
                pending=$((pending + 1))
                list="${list}${list:+, }$id"
            fi
        done < "$BATCH/tasks.txt"
        [ "$pending" -eq 0 ] && return 0
        echo "[$(now)] 进行中 $pending 个：$list"
        sleep "$POLL_INTERVAL"
    done
}

# ---------- 自动逐个复盘 ----------

# 对批次内每个任务执行 stress-test.sh review --dir，结论落 summary.txt；全部“正常”返回 0
run_review_all() {
    local id type dir concl bad=0 st tt
    local -a rv=()
    st="$START_TIME"
    [ -n "$st" ] || st=$(cat "$BATCH/start.time" 2>/dev/null)
    # 旧批次无 start.time 时显示“未知”
    [ -n "$st" ] || st="未知"
    tt="$TIMEOUT"
    [ -f "$BATCH/timeout.txt" ] && tt=$(cat "$BATCH/timeout.txt" 2>/dev/null)

    : > "$BATCH/summary.txt"
    {
        echo "==== 一键压测汇总 ===="
        echo "批次目录: $BATCH"
        echo "开始时间: $st"
        echo "结束时间: $(now)"
        echo "超时: $tt"
        if [ "$MOUNT_RC" -ne 0 ]; then
            echo "自动挂载: 存在跳过/失败盘（退出码 $MOUNT_RC，未挂载盘未参与压测）"
        else
            echo "自动挂载: 正常"
        fi
        echo ""
        printf '%-10s %-8s %s\n' '任务' '类型' '结论'
    } >> "$BATCH/summary.txt"

    if [ -f "$BATCH/tasks.txt" ]; then
        while IFS='|' read -r id type dir; do
            [ -n "$id" ] || continue
            rv=(bash "$ST" review --dir "$dir")
            [ "$SHOW_CMD" = "1" ] && echo "[$(now)] 复盘 $id："
            show_once_argv "${rv[@]}"
            "${rv[@]}" > "$BATCH/$id.review.txt" 2>&1
            concl=$(sed -n 's/^结论: //p' "$BATCH/$id.review.txt" | head -1)
            [ -n "$concl" ] || concl="未知（见 $id.review.txt）"
            printf '%-10s %-8s %s\n' "$id" "$type" "$concl" >> "$BATCH/summary.txt"
            case "$concl" in
                正常) ;;
                *) bad=$((bad + 1)) ;;
            esac
        done < "$BATCH/tasks.txt"
    fi

    {
        echo ""
        echo "启动失败（跳过、未计入复盘）:"
        if [ -s "$BATCH/failed-tasks.txt" ]; then
            while IFS='|' read -r id _; do
                [ -n "$id" ] || continue
                echo "  $id"
            done < "$BATCH/failed-tasks.txt"
        else
            echo "  无"
        fi
    } >> "$BATCH/summary.txt"
    [ -s "$BATCH/failed-tasks.txt" ] && bad=$((bad + 1))

    {
        echo ""
        echo "结果目录:"
        if [ -f "$BATCH/tasks.txt" ]; then
            while IFS='|' read -r id type dir; do
                [ -n "$id" ] || continue
                echo "  $id  $dir"
            done < "$BATCH/tasks.txt"
        fi
    } >> "$BATCH/summary.txt"

    cat "$BATCH/summary.txt"
    [ "$bad" -eq 0 ]
}

# ---------- status / review 子命令 ----------

# 最近一次批次目录（按目录名时间戳排序取最后一个）
latest_batch() {
    ls -1d "$STRESS_TEST_ROOT"/oneclick-* 2>/dev/null | sort | tail -1
}

cmd_status() {
    local batch list id type dir state
    batch=$(latest_batch)
    if [ -z "$batch" ]; then
        exec bash "$ST" status
    fi
    echo "最近批次：$batch"
    printf '%-10s %-8s %s\n' '任务' '类型' '状态'
    # 先判断文件存在再决定读哪个，两者都缺失时按空任务列表处理（不产生重定向报错）
    if [ -f "$batch/plan.txt" ]; then
        list="$batch/plan.txt"
    elif [ -f "$batch/tasks.txt" ]; then
        list="$batch/tasks.txt"
    else
        echo "批次目录缺少 plan.txt/tasks.txt"
        list=""
    fi
    if [ -n "$list" ]; then
        while IFS='|' read -r id type _; do
            [ -n "$id" ] || continue
            dir=""
            [ -f "$batch/tasks.txt" ] && dir=$(awk -F'|' -v k="$id" '$1 == k { d = $3 } END { print d }' "$batch/tasks.txt" 2>/dev/null)
            # 结果目录不存在说明任务未真正产出结果，不能算“已完成”（等待逻辑另按无需等待处理）
            if [ -n "$dir" ] && [ -d "$dir" ] && task_done "$dir"; then
                state="已完成"
            elif [ -f "$batch/$id.fail" ]; then
                state="启动失败"
            elif [ -f "$batch/$id.dir" ]; then
                state="进行中"
            elif [ -f "$batch/aborted" ]; then
                state="未启动"
            else
                state="启动中"
            fi
            printf '%-10s %-8s %s\n' "$id" "$type" "$state"
        done < "$list"
    fi
    bash "$ST" status
    if [ -n "$batch" ] && [ -f "$batch/commands.txt" ]; then
        echo "查看本次执行过的命令：cat $batch/commands.txt"
    fi
}

cmd_review() {
    local batch
    batch=$(latest_batch)
    if [ -n "$batch" ] && [ -f "$batch/tasks.txt" ]; then
        BATCH="$batch"
        START_TIME=$(cat "$batch/start.time" 2>/dev/null)
        echo "复盘批次：$BATCH"
        if run_review_all; then
            exit 0
        fi
        exit 1
    fi
    exec bash "$ST" review
}

# ---------- 运行模式：建批次 → 计划 → 逐条启动 → 就绪握手 → 等待 → 复盘 ----------

run_mode() {
    local mode="$1" stamp k=0 id type n=0 started="" review_rc=0 line f
    local -a extras=() fields=()
    # 重建开关口径：仅 all/hdd 生效；其他模式带 --rebuild 时提示并忽略（在 write_plan 之前复位）
    case "$mode" in
        all|hdd)
            if [ "$REBUILD" = "1" ]; then
                echo "本次将重新分区并格式化数据盘（--rebuild）"
            else
                echo "未指定 --rebuild，本次复用已有文件系统；如需重建请加 --rebuild"
            fi
            ;;
        *)
            if [ "$REBUILD" = "1" ]; then
                echo "提示：--rebuild 仅对 all/hdd 生效，本次忽略"
                REBUILD=0
            fi
            ;;
    esac
    precheck
    # 命令显示开关必须传给子进程，窗口/后台里的 __task 才会同样遵守 --quiet
    export ONECLICK_SHOW_CMD="$SHOW_CMD"

    mkdir -p "$STRESS_TEST_ROOT" || die "无法创建结果根目录：$STRESS_TEST_ROOT"
    stamp=$(date '+%Y%m%d-%H%M%S')
    BATCH="$STRESS_TEST_ROOT/oneclick-$stamp"
    while [ -e "$BATCH" ]; do
        k=$((k + 1))
        BATCH="$STRESS_TEST_ROOT/oneclick-$stamp-$k"
    done
    mkdir -p "$BATCH" || die "无法创建批次目录：$BATCH"
    START_TIME=$(now)
    echo "$START_TIME" > "$BATCH/start.time"
    echo "$TIMEOUT" > "$BATCH/timeout.txt"

    # 批次命令清单必须早于 write_plan 建好（do_mount 在 write_plan 内执行）
    MODE="$mode"
    : > "$BATCH/commands.txt"
    {
        echo '#!/bin/bash'
        echo "# 由 oneclick.sh 生成：批次 $BATCH"
        echo "# 警告：执行本脚本会重新发起一轮压测，产生新的结果目录。"
        echo "# 复盘请用：bash $(printf '%q' "$ST") review --dir <新结果目录>"
        echo 'set -u'
    } > "$BATCH/commands.sh"
    chmod 0644 "$BATCH/commands.sh"

    pick_terminal
    if [ "$TERM_KIND" = "none" ]; then
        echo "未检测到图形终端，改为后台并行执行；实时数据：tail -f <结果目录>/monitor.csv"
    fi
    write_env_file
    echo "批次目录：$BATCH"

    write_plan "$mode"
    [ -s "$BATCH/plan.txt" ] || die "任务计划为空，未启动任何任务"

    while IFS= read -r line; do
        [ -n "$line" ] || continue
        # plan.txt 按 | 分隔，附加参数各占一个字段；IFS 只含 |，空格是普通字符
        IFS='|' read -r -a fields <<< "$line"
        [ "${#fields[@]}" -ge 2 ] || continue
        id="${fields[0]}"; type="${fields[1]}"
        extras=()
        for f in "${fields[@]:2}"; do
            if [ -n "$f" ]; then extras+=("$f"); fi
        done
        # 先算出该任务实际要执行的 argv，主终端显示/落盘与失败重跑提示共用同一串
        stress_argv "$type" "$TIMEOUT" "${extras[@]}"
        LAST_TASK_CMD=$(cmd_line "${STRESS_ARGV[@]}")
        [ "$SHOW_CMD" = "1" ] && echo "[$(now)] 任务 $id 将执行："
        show_run "${STRESS_ARGV[@]}"
        launch_task "$id" "$type" "${extras[@]}"
        if wait_ready "$id" "$type"; then
            n=$((n + 1))
            started="${started}${started:+, }$id"
        else
            echo "该任务压测命令（可直接复制重跑）："
            printf '  $ %s\n' "$LAST_TASK_CMD"
            # 失败任务落盘：summary 与 failed-tasks.txt 可见（格式：任务ID|完整命令）
            printf '%s|%s\n' "$id" "$LAST_TASK_CMD" >> "$BATCH/failed-tasks.txt"
            echo "已启动任务：${started:-无}"
            if [ "$id" = "COMBO" ]; then
                # COMBO 是核心 CPU+内存负载：失败即中止本批次，不再启动后续任务
                echo "因 $id 启动失败，停止启动后续任务（CPU+内存组合未起来）"
                ABORTED=1
                echo "任务 $id 启动失败，已停止启动后续任务" > "$BATCH/aborted"
                break
            fi
            # 数据盘/系统盘启动失败：记录后跳过，继续启动其余任务；最终退出码 1
            START_FAILED=1
            echo "因 $id 启动失败，已跳过并继续启动后续任务（记录：$BATCH/failed-tasks.txt）"
        fi
    done < "$BATCH/plan.txt"

    echo "已启动 $n 个任务（批次目录：$BATCH）"
    if [ "$START_FAILED" -eq 1 ]; then
        echo "启动失败并跳过的任务：$(awk -F'|' 'NF > 0 { printf "%s%s", sep, $1; sep = ", " }' "$BATCH/failed-tasks.txt" 2>/dev/null)（见 $BATCH/failed-tasks.txt）"
    fi
    [ "$n" -gt 0 ] || exit 1

    echo "[$(now)] 等待全部任务结束（轮询间隔 ${POLL_INTERVAL} 秒）"
    # 主终端 Ctrl-C 只结束等待，不停止压测（设计 §7）；正常结束后恢复默认信号处理
    trap 'echo; echo "已停止等待（压测仍在后台运行）：bash stress-test.sh status / stop"; exit 130' INT
    wait_all
    trap - INT
    echo "[$(now)] 全部任务已结束，开始逐个复盘"
    run_review_all
    review_rc=$?

    if [ "$ABORTED" -eq 1 ] || [ "$START_FAILED" -eq 1 ] || [ "$review_rc" -ne 0 ] || [ "$MOUNT_RC" -ne 0 ]; then
        exit 1
    fi
    exit 0
}

# ---------- 菜单 ----------

show_menu() {
    cat <<EOF
==== 一键压测 ====
  1) 全测（CPU+内存组合 + 每盘独立 + 系统盘）
  2) 测 CPU+内存（排除硬盘）
  3) 只测硬盘（数据盘）
  4) 只测系统盘
  5) 只测 CPU
  6) 只测内存
  7) 查看状态
  8) 生成复盘
  0) 退出
当前超时：$TIMEOUT（可用 --timeout 覆盖）
EOF
}

# 菜单 1/3 启动前询问一次是否重建数据盘；默认 N（仅 y/Y 视为确认）
ask_rebuild() {
    local ans=""
    printf '是否重新分区并格式化数据盘？(y/N)：'
    if ! IFS= read -r ans; then
        # 读取失败（EOF）时补换行，避免后续提示与询问挤在同一行
        echo
        ans=""
    fi
    case "$ans" in
        y|Y) REBUILD=1 ;;
        *) REBUILD=0 ;;
    esac
}

menu_loop() {
    local choice
    while :; do
        show_menu
        printf '请选择（0-8）：'
        if ! IFS= read -r choice; then
            echo
            exit 0
        fi
        case "$choice" in
            # CLI 已带 --rebuild 时不再询问，直接按重建语义执行
            # 项 1/3（all/hdd）前显式复位 NO_HDD=0，防上一轮选 2（NO_HDD=1）串味
            1) NO_HDD=0; if [ "$REBUILD" = "0" ]; then ask_rebuild; fi; run_mode all ;;
            2) NO_HDD=1; REBUILD=0; run_mode all ;;
            3) NO_HDD=0; if [ "$REBUILD" = "0" ]; then ask_rebuild; fi; run_mode hdd ;;
            4) run_mode sysdisk ;; 5) run_mode cpu ;; 6) run_mode mem ;; 7) cmd_status ;; 8) cmd_review ;;
            0) exit 0 ;;
            *) echo "无效选择：$choice（请输入 0-8）" ;;
        esac
    done
}

# ---------- 参数解析与分发 ----------

main() {
    if [ "${1:-}" = "__task" ]; then
        shift
        if [ $# -lt 4 ]; then
            echo "内部子命令 __task 参数不足（需要 <batch> <id> <timeout> <type>）"
            exit 1
        fi
        cmd_task "$@"
        exit 0
    fi

    local mode=""
    while [ $# -gt 0 ]; do
        case "$1" in
            -h|--help)
                usage
                exit 0
                ;;
            --quiet)
                SHOW_CMD=0
                shift
                ;;
            --rebuild)
                REBUILD=1
                shift
                ;;
            --no-hdd)
                NO_HDD=1
                shift
                ;;
            --timeout)
                if [ $# -lt 2 ]; then
                    echo "缺少 --timeout 取值"
                    exit 1
                fi
                TIMEOUT="$2"
                shift 2
                ;;
            --timeout=*)
                TIMEOUT="${1#*=}"
                shift
                ;;
            all|hdd|sysdisk|cpu|mem)
                mode="$1"
                shift
                ;;
            status)
                mode=status
                shift
                ;;
            review)
                mode=review
                shift
                ;;
            *)
                echo "未知参数：$1"
                usage
                exit 1
                ;;
        esac
    done

    if [ "$NO_HDD" -eq 1 ] && [ "$mode" != "all" ]; then
        echo "--no-hdd 仅支持 all 模式"
        exit 1
    fi
    if [ "$NO_HDD" -eq 1 ] && [ "$REBUILD" -eq 1 ]; then
        echo "--rebuild 与 --no-hdd 不能同时使用（--no-hdd 不涉及任何硬盘）"
        exit 1
    fi

    if ! [[ "$TIMEOUT" =~ ^[0-9]+[dhms]?$ ]]; then
        echo "--timeout 取值非法：$TIMEOUT（应形如 10h / 30m / 8h）"
        exit 1
    fi

    case "$mode" in
        "") menu_loop ;;
        status) cmd_status ;;
        review) cmd_review ;;
        all|hdd|sysdisk|cpu|mem) run_mode "$mode" ;;
    esac
}

main "$@"
