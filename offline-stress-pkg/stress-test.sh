#!/bin/bash
# stress-test.sh —— 压测主控脚本（Kylin V10 SP3，三类机型 CPU/内存/硬盘压测）
# 用法：
#   bash stress-test.sh start <cpu|mem|hdd|combo> [--model 5380|7380|7360|auto] [--timeout 12h] \
#       [--cpu N] [--vm N] [--vm-bytes X] [--hdd-bytes X] [--dirs "d1 d2"] [--sysdisk]
#   bash stress-test.sh status
#   bash stress-test.sh stop
#   bash stress-test.sh review [--dir <结果目录>]
# 环境变量（测试接缝）：
#   STRESS_TEST_ROOT 结果根目录（默认 /root/stress-test）
#   MONITOR_INTERVAL 监控间隔秒（默认 30）
# 退出码：0=正常（含无运行任务）；1=用法错误/前置条件不满足
# 说明：全程不 set -e；压测与监控均 nohup 后台运行、全部落盘，可脱离 ssh 会话。

STRESS_TEST_ROOT="${STRESS_TEST_ROOT:-/root/stress-test}"
MONITOR_INTERVAL="${MONITOR_INTERVAL:-30}"
DF_BIN="${DF_BIN:-df}"
SCRIPT="$(readlink -f "$0" 2>/dev/null || echo "$0")"

# ---------- 公共工具 ----------

usage() {
    cat <<'EOF'
用法:
  bash stress-test.sh start <cpu|mem|hdd|combo> [--model 5380|7380|7360|auto] [--timeout 12h] \
      [--cpu N] [--vm N] [--vm-bytes X] [--hdd-bytes X] [--dirs "d1 d2"] [--sysdisk]
  bash stress-test.sh status
  bash stress-test.sh stop
  bash stress-test.sh review [--dir <结果目录>]

示例:
  bash stress-test.sh start cpu                # 按自动检测机型预设跑 CPU 压测（默认 12h）
  bash stress-test.sh start mem --model 7380   # 按 7380 预设跑内存压测
  bash stress-test.sh start hdd --dirs "/mnt/HDD01 /mnt/HDD02"
  bash stress-test.sh start combo --dirs "/mnt/HDD01 /mnt/HDD02" --sysdisk  # CPU+内存+每盘 hdd+系统盘
  bash stress-test.sh review --dir /root/stress-test/20261113-143000-cpu
EOF
}

now() { date '+%Y-%m-%d %H:%M:%S'; }

# 追加一条操作记录到根级 operations.log
log_op() { echo "[$(now)] $*" >> "$STRESS_TEST_ROOT/operations.log"; }

# 三机型内置预设（与设计文档一致，逐字值）
preset_cpu() { case "$1" in 5380|7380) echo 110;; 7360) echo 80;; *) echo "";; esac; }
preset_vm() { case "$1" in 5380) echo 12;; 7380|7360) echo 16;; *) echo "";; esac; }
preset_vm_bytes() { case "$1" in 5380|7360) echo 26G;; 7380) echo 54G;; *) echo "";; esac; }

# timeout 文本转秒：支持 12h / 30m / 45s / 1d / 纯数字（秒）
parse_timeout_sec() {
    case "$1" in
        *d) echo $(( ${1%d} * 86400 )) ;;
        *h) echo $(( ${1%h} * 3600 )) ;;
        *m) echo $(( ${1%m} * 60 )) ;;
        *s) echo $(( ${1%s} )) ;;
        *)  echo "$1" ;;
    esac
}

# 统计 stress.pids 中仍存活的 PID 数
alive_pids() {
    local pids_file="$1" pid alive=0
    [ -f "$pids_file" ] || { echo 0; return; }
    while IFS= read -r pid; do
        [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null && alive=$((alive + 1))
    done < "$pids_file"
    echo "$alive"
}

# 剩余秒数转中文时长（负数表示已到期）
fmt_remain() {
    local s="$1" h m out=""
    if [ "$s" -lt 0 ]; then echo "已到期，等待退出"; return; fi
    h=$(( s / 3600 )); m=$(( (s % 3600) / 60 )); s=$(( s % 60 ))
    [ "$h" -gt 0 ] && out="${h}小时"
    [ "$m" -gt 0 ] && out="${out}${m}分"
    out="${out}${s}秒"
    echo "$out"
}

# ---------- start ----------

cmd_start() {
    local type="$1"
    shift || true
    [ -n "$type" ] || { usage; exit 1; }
    case "$type" in
        cpu|mem|hdd|combo) ;;
        *) echo "未知压测类型：$type（应为 cpu|mem|hdd|combo）"; usage; exit 1 ;;
    esac

    # 参数解析：--model / --timeout / --cpu / --vm / --vm-bytes / --hdd-bytes / --dirs / --sysdisk
    local model="auto" timeout="12h" cpu_opt="" vm_opt="" vm_bytes_opt="" hdd_bytes_opt="" dirs_opt="" sysdisk=0
    while [ $# -gt 0 ]; do
        case "$1" in
            --model|--timeout|--cpu|--vm|--vm-bytes|--hdd-bytes|--dirs)
                if [ $# -lt 2 ]; then echo "参数 $1 缺少取值"; usage; exit 1; fi
                ;;
        esac
        case "$1" in
            --model)     model="$2";        shift 2 ;;
            --timeout)   timeout="$2";      shift 2 ;;
            --cpu)       cpu_opt="$2";      shift 2 ;;
            --vm)        vm_opt="$2";       shift 2 ;;
            --vm-bytes)  vm_bytes_opt="$2"; shift 2 ;;
            --hdd-bytes) hdd_bytes_opt="$2"; shift 2 ;;
            --dirs)      dirs_opt="$2";     shift 2 ;;
            --sysdisk)   sysdisk=1;         shift 1 ;;
            *) echo "未知参数：$1"; usage; exit 1 ;;
        esac
    done

    # cpu/mem 模式下 --sysdisk 无效，仅提示（hdd/combo 才生效）
    if [ "$sysdisk" -eq 1 ] && { [ "$type" = "cpu" ] || [ "$type" = "mem" ]; }; then
        echo "提示：--sysdisk 仅对 hdd/combo 模式生效，cpu/mem 模式忽略该选项"
    fi

    # 机型解析（缺省 auto）：mem>=800G→7380；nproc>=120→5380；否则 7360
    if [ "$model" = "auto" ]; then
        local mem_gb n
        mem_gb=$(awk '/^MemTotal:/{printf "%.0f", $2/1048576}' /proc/meminfo 2>/dev/null)
        [ -z "$mem_gb" ] && mem_gb=0
        n=$(nproc 2>/dev/null); [ -z "$n" ] && n=1
        if [ "$mem_gb" -ge 800 ]; then model=7380
        elif [ "$n" -ge 120 ]; then model=5380
        else model=7360; fi
        echo "检测到机型 $model，使用预设参数"
    fi
    case "$model" in 5380|7380|7360) ;;
        *) echo "未知机型：$model（应为 5380|7380|7360|auto）"; exit 1 ;;
    esac

    # 预设参数，显式参数覆盖
    [ -z "$cpu_opt" ] && cpu_opt=$(preset_cpu "$model")
    [ -z "$vm_opt" ] && vm_opt=$(preset_vm "$model")
    [ -z "$vm_bytes_opt" ] && vm_bytes_opt=$(preset_vm_bytes "$model")
    [ -z "$hdd_bytes_opt" ] && hdd_bytes_opt="10G"

    # 前置校验：stress 已安装
    command -v stress >/dev/null 2>&1 || { echo "未找到 stress，请先运行 bash install.sh 安装"; exit 1; }

    # hdd/combo 前置校验：先全量收集并校验压测盘目录，存在且任一无效即整体退出（不启动任何 stress、不建结果目录，防孤儿进程）
    # combo 模式目录集合可为空（无数据盘降级为仅 CPU/内存，或配合 --sysdisk 仅压系统盘）；hdd 模式仍要求非空
    local dirs=() d
    if [ "$type" = "hdd" ] || [ "$type" = "combo" ]; then
        if [ -n "$dirs_opt" ]; then
            dirs=($dirs_opt)
        else
            dirs=(/mnt/HDD*)
            [ -e "${dirs[0]}" ] || {
                if [ "$type" = "hdd" ]; then
                    echo "未发现 /mnt/HDD* 挂载点，请先运行 bash disk-mount.sh mount 或使用 --dirs 指定"; exit 1
                fi
                dirs=()
                echo "警告：未发现 /mnt/HDD* 挂载点，combo 模式无数据盘（仅 CPU/内存，或配合 --sysdisk 压系统盘）"
            }
        fi
        if [ "${#dirs[@]}" -gt 0 ]; then
            for d in "${dirs[@]}"; do
                [ -d "$d" ] || { echo "挂载点不存在：$d（请先挂载或检查 --dirs）"; exit 1; }
            done
            # 默认 /mnt/HDD* 分支：目录存在≠已挂载（umount 不删目录），多轮流程第二轮会误把压测文件写到系统根文件系统。
            # 额外校验每个目录确实已挂载、且底层设备不是根设备（--dirs 显式指定的目录不要求，用户自己负责）。
            if [ -z "$dirs_opt" ]; then
                local root_dev dev
                root_dev=$(df -P / 2>/dev/null | awk 'NR==2{print $1}')
                for d in "${dirs[@]}"; do
                    dev=$(findmnt -n -o SOURCE "$d" 2>/dev/null || df -P "$d" 2>/dev/null | awk 'NR==2{print $1}')
                    if [ -z "$dev" ] || { [ -n "$root_dev" ] && [ "$dev" = "$root_dev" ]; }; then
                        echo "目录 $d 不是已挂载的独立文件系统（设备=${dev:-未挂载}，系统盘=${root_dev:-未知}），不能作为压测盘"
                        echo "请先运行 bash disk-mount.sh mount 挂载测试盘，或用 --dirs 显式指定压测目录"
                        exit 1
                    fi
                done
            fi
        elif [ "$type" = "hdd" ]; then
            echo "未指定任何压测盘目录（--dirs 为空）"; exit 1
        fi
    fi

    # --sysdisk 前置校验：建系统盘压测目录并预检 / 可用空间（hdd-bytes 按 G 换算 ×1.2），不足整体退出（不启动任何进程、不建结果目录）
    if [ "$sysdisk" -eq 1 ] && { [ "$type" = "hdd" ] || [ "$type" = "combo" ]; }; then
        mkdir -p /stresstest-hdd 2>/dev/null || { echo "无法创建系统盘压测目录 /stresstest-hdd（可能需要 root 权限）"; exit 1; }
        local gb need_kb avail_kb
        gb="${hdd_bytes_opt%[Gg]}"
        case "$gb" in
            ''|*[!0-9]*) echo "--sysdisk 空间预检要求 hdd-bytes 以 G 为单位（当前：$hdd_bytes_opt）"; exit 1 ;;
        esac
        need_kb=$(( gb * 12 * 1048576 / 10 ))
        avail_kb=$("$DF_BIN" -P / 2>/dev/null | awk 'NR==2{print $4}')
        if [ -z "$avail_kb" ] || [ "$avail_kb" -lt "$need_kb" ]; then
            echo "系统盘 / 可用空间不足：需要 ≥ ${need_kb} kB（${hdd_bytes_opt}×1.2），当前可用 ${avail_kb:-未知} kB"
            exit 1
        fi
    fi

    # 建结果目录（时间戳，防覆盖；同秒冲突时顺延）
    mkdir -p "$STRESS_TEST_ROOT" || { echo "无法创建结果根目录：$STRESS_TEST_ROOT"; exit 1; }
    local ts dir
    while :; do
        ts=$(date '+%Y%m%d-%H%M%S')
        dir="$STRESS_TEST_ROOT/$ts-$type"
        [ -d "$dir" ] || break
        sleep 1
    done
    mkdir -p "$dir" || { echo "无法创建结果目录：$dir"; exit 1; }

    # 组装 stress 参数与超时秒数
    local stress_args timeout_sec start_time
    case "$type" in
        cpu) stress_args="--cpu $cpu_opt --timeout $timeout" ;;
        mem) stress_args="--vm $vm_opt --vm-bytes $vm_bytes_opt --timeout $timeout" ;;
        hdd) stress_args="--hdd 1 --hdd-bytes $hdd_bytes_opt --timeout $timeout" ;;
        combo) stress_args="--cpu $cpu_opt --vm $vm_opt --vm-bytes $vm_bytes_opt --timeout $timeout" ;;
    esac
    timeout_sec=$(parse_timeout_sec "$timeout")
    start_time=$(now)

    # 写 run-config.txt 与 info-before.txt
    {
        echo "机型: $model"
        echo "类型: $type"
        echo "开始时间: $start_time"
        echo "超时: $timeout"
        echo "超时秒数: $timeout_sec"
        echo "监控间隔: ${MONITOR_INTERVAL}s"
        echo "结果目录: $dir"
        case "$type" in
            cpu) echo "CPU worker 数: $cpu_opt" ;;
            mem) echo "VM worker 数: $vm_opt"; echo "VM 字节: $vm_bytes_opt" ;;
            hdd) echo "HDD 字节: $hdd_bytes_opt" ;;
            combo) echo "CPU worker 数: $cpu_opt"; echo "VM worker 数: $vm_opt"; echo "VM 字节: $vm_bytes_opt"; echo "HDD 字节: $hdd_bytes_opt" ;;
        esac
        echo "命令: stress $stress_args"
    } > "$dir/run-config.txt"

    {
        echo "==== lscpu ===="
        lscpu 2>&1
        echo "==== free -h ===="
        free -h 2>&1
        echo "==== df -h ===="
        df -h 2>&1
        echo "==== lsblk ===="
        lsblk 2>&1
        echo "==== stress --version ===="
        stress --version 2>&1
    } > "$dir/info-before.txt"

    # 后台启动 stress（nohup；combo 先起 CPU/内存组合进程，再每盘一条 hdd，--sysdisk 再补系统盘；
    # 目录已在上方全量校验，这里只负责启动）
    : > "$dir/stress.pids"
    if [ "$type" = "combo" ] || [ "$type" = "hdd" ]; then
        if [ "$type" = "combo" ]; then
            nohup sh -c 'stress $1 > "$2/stress.log" 2>&1; echo $? > "$2/stress.exitcode"' _ "$stress_args" "$dir" >/dev/null 2>&1 &
            echo "$!" >> "$dir/stress.pids"
        fi
        local i=1 num
        for d in "${dirs[@]}"; do
            num=$(printf "%02d" "$i")
            nohup sh -c 'cd "$1" && stress --hdd 1 --hdd-bytes "$2" --timeout "$3" > "$4/stress-HDD$5.log" 2>&1; echo $? > "$4/stress-HDD$5.exitcode"' _ "$d" "$hdd_bytes_opt" "$timeout" "$dir" "$num" >/dev/null 2>&1 &
            echo "$!" >> "$dir/stress.pids"
            i=$((i + 1))
        done
        if [ "$sysdisk" -eq 1 ]; then
            nohup sh -c 'cd "$1" && stress --hdd 1 --hdd-bytes "$2" --timeout "$3" > "$4/stress-SYSDISK.log" 2>&1; echo $? > "$4/stress-SYSDISK.exitcode"' _ "/stresstest-hdd" "$hdd_bytes_opt" "$timeout" "$dir" >/dev/null 2>&1 &
            echo "$!" >> "$dir/stress.pids"
        fi
    else
        nohup sh -c 'stress $1 > "$2/stress.log" 2>&1; echo $? > "$2/stress.exitcode"' _ "$stress_args" "$dir" >/dev/null 2>&1 &
        echo "$!" >> "$dir/stress.pids"
    fi

    # 后台启动监控循环（随 stress 全部结束自动退出）
    nohup bash "$SCRIPT" monitor-loop "$dir" >/dev/null 2>&1 &
    echo "$!" > "$dir/monitor.pid"

    log_op "start type=$type model=$model timeout=$timeout dir=$dir cmd=stress $stress_args"

    echo "已启动 ${type} 压测：$dir"
    echo "查看状态：bash stress-test.sh status"
    echo "实时监控：tail -f $dir/monitor.csv"
}

# ---------- status ----------

cmd_status() {
    local running=0 d
    for d in "$STRESS_TEST_ROOT"/*-cpu "$STRESS_TEST_ROOT"/*-mem "$STRESS_TEST_ROOT"/*-hdd "$STRESS_TEST_ROOT"/*-combo; do
        [ -d "$d" ] || continue
        [ -f "$d/stress.pids" ] || continue
        if [ "$(alive_pids "$d/stress.pids")" -gt 0 ]; then
            running=1
            print_status_dir "$d"
        fi
    done
    if [ "$running" -eq 0 ]; then
        echo "无运行中的压测"
        exit 0
    fi
}

print_status_dir() {
    local d="$1" type="${1##*-}" pids
    echo "---- 运行中压测：$type ----"
    echo "结果目录: $d"
    pids=$(tr '\n' ' ' < "$d/stress.pids")
    echo "stress 存活进程数: $(alive_pids "$d/stress.pids")（PID: $pids）"
    if [ -f "$d/monitor.pid" ] && kill -0 "$(cat "$d/monitor.pid")" 2>/dev/null; then
        echo "监控进程: 运行中（PID $(cat "$d/monitor.pid")）"
    else
        echo "监控进程: 已退出"
    fi
    # 剩余时长估算：run-config 开始时间 + 超时秒数 - 当前时间
    if [ -f "$d/run-config.txt" ]; then
        local start_line timeout_line timeout_sec start_epoch remain
        start_line=$(grep '^开始时间:' "$d/run-config.txt")
        timeout_line=$(grep '^超时秒数:' "$d/run-config.txt")
        timeout_sec="${timeout_line#*: }"
        start_epoch=$(date -d "${start_line#*: }" +%s 2>/dev/null)
        if [ -n "$start_epoch" ] && [ -n "$timeout_sec" ] && [ "$timeout_sec" -gt 0 ] 2>/dev/null; then
            remain=$(( start_epoch + timeout_sec - $(date +%s) ))
            echo "剩余时长估算: $(fmt_remain "$remain")（超时 ${timeout_sec} 秒）"
        fi
    fi
    echo "最近监控（tail -5 monitor.csv）:"
    tail -5 "$d/monitor.csv" 2>/dev/null | sed 's/^/  /'
    echo
}

# ---------- stop ----------

cmd_stop() {
    local found=0 d
    for d in "$STRESS_TEST_ROOT"/*-cpu "$STRESS_TEST_ROOT"/*-mem "$STRESS_TEST_ROOT"/*-hdd "$STRESS_TEST_ROOT"/*-combo; do
        [ -d "$d" ] || continue
        [ -f "$d/stress.pids" ] || continue
        local alive mpid mon_alive=0
        alive=$(alive_pids "$d/stress.pids")
        if [ -f "$d/monitor.pid" ]; then
            mpid=$(cat "$d/monitor.pid")
            kill -0 "$mpid" 2>/dev/null && mon_alive=1
        fi
        if [ "$alive" -gt 0 ] || [ "$mon_alive" -eq 1 ]; then
            found=1
            stop_one "$d"
        fi
    done
    if [ "$found" -eq 0 ]; then
        echo "没有运行中的压测，无需停止"
    fi
}

stop_one() {
    local d="$1" pid i=0
    echo "---- 停止：$d ----"
    while IFS= read -r pid; do
        [ -n "$pid" ] || continue
        if kill -0 "$pid" 2>/dev/null; then
            pkill -TERM -P "$pid" 2>/dev/null   # 先杀 stress 子进程
            kill -TERM "$pid" 2>/dev/null
            i=0
            while [ "$i" -lt 6 ] && kill -0 "$pid" 2>/dev/null; do
                sleep 0.5
                i=$((i + 1))
            done
            kill -KILL "$pid" 2>/dev/null
            echo "已停止 stress 进程 $pid"
        fi
    done < "$d/stress.pids"
    if [ -f "$d/monitor.pid" ]; then
        local mpid
        mpid=$(cat "$d/monitor.pid")
        if kill -0 "$mpid" 2>/dev/null; then
            kill -TERM "$mpid" 2>/dev/null
            sleep 0.5
            kill -KILL "$mpid" 2>/dev/null
            echo "已停止监控进程 $mpid"
        fi
    fi
    log_op "stop dir=$d"
}

# ---------- review ----------

cmd_review() {
    local dir=""
    while [ $# -gt 0 ]; do
        case "$1" in
            --dir) if [ $# -lt 2 ]; then echo "--dir 缺少参数"; exit 1; fi; dir="$2"; shift 2 ;;
            *) echo "未知参数：$1"; usage; exit 1 ;;
        esac
    done
    if [ -z "$dir" ]; then
        dir=$(ls -1d "$STRESS_TEST_ROOT"/*-cpu "$STRESS_TEST_ROOT"/*-mem "$STRESS_TEST_ROOT"/*-hdd "$STRESS_TEST_ROOT"/*-combo 2>/dev/null | sort | tail -1)
        [ -n "$dir" ] || { echo "未找到任何压测结果目录（$STRESS_TEST_ROOT 下无 <时间戳>-<cpu|mem|hdd|combo> 目录）"; exit 1; }
        echo "使用最新结果目录：$dir"
    fi
    [ -d "$dir" ] || { echo "结果目录不存在：$dir"; exit 1; }
    [ -f "$dir/monitor.csv" ] || { echo "未找到监控数据：$dir/monitor.csv"; exit 1; }

    # 统计 monitor.csv：行数 / CPU 均值峰值 / 内存峰值 / IO 峰值
    local rows cpu_mean cpu_max mem_max rd_max wr_max
    read -r rows cpu_mean cpu_max mem_max rd_max wr_max <<< "$(awk -F',' 'NR==1{next} {rows++; cpu+=$3; if($3+0>c)c=$3+0; if($5+0>m)m=$5+0; if($8+0>r)r=$8+0; if($9+0>w)w=$9+0} END{printf "%d %.1f %.1f %.0f %.1f %.1f", rows, (rows?cpu/rows:0), c, m, r, w}' "$dir/monitor.csv")"

    # 监控覆盖时长估算
    local interval_raw interval duration
    interval_raw=$(grep '^监控间隔:' "$dir/run-config.txt" 2>/dev/null | cut -d' ' -f2-)
    interval="${interval_raw%s}"
    [ -n "$interval" ] || interval=30
    if [ "$rows" -ge 2 ]; then duration=$(( (rows - 1) * interval ))
    elif [ "$rows" -eq 1 ]; then duration=$interval
    else duration=0; fi

    # run-config 起止信息
    local type model start_time plan_timeout end_est start_epoch
    type="${dir##*-}"
    model=$(grep '^机型:' "$dir/run-config.txt" 2>/dev/null | cut -d' ' -f2-)
    start_time=$(grep '^开始时间:' "$dir/run-config.txt" 2>/dev/null | cut -d' ' -f2-)
    plan_timeout=$(grep '^超时:' "$dir/run-config.txt" 2>/dev/null | cut -d' ' -f2-)
    # 结束时间按 epoch 推算，避免 date 对 "<时间> + N seconds" 字符串的歧义解析
    start_epoch=$(date -d "$start_time" +%s 2>/dev/null)
    if [ -n "$start_epoch" ]; then
        end_est=$(date -d "@$(( start_epoch + duration ))" '+%Y-%m-%d %H:%M:%S' 2>/dev/null)
    fi

    # 生成 summary.txt 并打印
    {
        echo "==== 压测复盘总结 ===="
        echo "生成时间: $(now)"
        echo "结果目录: $dir"
        echo "类型: $type"
        echo "机型: $model"
        echo "开始时间: $start_time"
        echo "计划超时: $plan_timeout"
        echo "预计结束时间: ${end_est:-未知}（按监控覆盖时长估算）"
        echo "监控采样行数: $rows"
        echo "监控覆盖时长: ${duration} 秒（间隔 ${interval} 秒）"
        echo "CPU 使用率: 均值 ${cpu_mean}%，峰值 ${cpu_max}%"
        echo "内存峰值 (mem_used): ${mem_max} kB"
        echo "磁盘读峰值: ${rd_max} MB/s"
        echo "磁盘写峰值: ${wr_max} MB/s"
        echo ""
        echo "== 退出码 =="
        local ec_files=("$dir"/*.exitcode)
        if [ -e "${ec_files[0]}" ]; then
            for f in "${ec_files[@]}"; do
                [ -f "$f" ] || continue
                echo "$(basename "$f"): $(cat "$f")"
            done
        else
            echo "未找到退出码文件（可能仍在运行或未执行）"
        fi
        echo "（0 表示 stress 正常结束，非 0 表示异常或被中断）"
        echo ""
        echo "原始数据: monitor.csv / run-config.txt / info-before.txt / stress*.log"
    } > "$dir/summary.txt"
    cat "$dir/summary.txt"
}

# ---------- monitor-loop（内部子命令，start 后台调用） ----------

cmd_monitor_loop() {
    local dir="$1"
    [ -n "$dir" ] || { echo "用法: stress-test.sh monitor-loop <结果目录>"; exit 1; }
    [ -d "$dir" ] || { echo "结果目录不存在：$dir"; exit 1; }
    local csv="$dir/monitor.csv" pids_file="$dir/stress.pids" interval="$MONITOR_INTERVAL"
    echo "时间,load1,cpu_usage%,mem_total,mem_used,mem_avail,swap_used,disk_read_MBps,disk_write_MBps" > "$csv"

    # 首采样（/proc/stat 与 /proc/diskstats 基线）
    local stat1 disk1
    stat1=$(awk '/^cpu /{for(i=2;i<=8;i++) tot+=$i; idle=$5+$6; print tot, idle}' /proc/stat 2>/dev/null)
    disk1=$(awk '{r+=$6; w+=$10} END{print r, w}' /proc/diskstats 2>/dev/null)
    [ -n "$stat1" ] || stat1="0 0"
    [ -n "$disk1" ] || disk1="0 0"

    while :; do
        sleep "$interval"
        local stat2 disk2 ts load1 mem cpu io alive
        stat2=$(awk '/^cpu /{for(i=2;i<=8;i++) tot+=$i; idle=$5+$6; print tot, idle}' /proc/stat 2>/dev/null)
        disk2=$(awk '{r+=$6; w+=$10} END{print r, w}' /proc/diskstats 2>/dev/null)
        [ -n "$stat2" ] || stat2="$stat1"
        [ -n "$disk2" ] || disk2="$disk1"

        ts=$(date '+%Y-%m-%d %H:%M:%S')
        load1=$(awk '{print $1}' /proc/loadavg 2>/dev/null)
        [ -n "$load1" ] || load1="0"
        mem=$(awk '/^MemTotal:/{mt=$2}/^MemFree:/{mf=$2}/^MemAvailable:/{ma=$2}/^SwapTotal:/{st=$2}/^SwapFree:/{sf=$2} END{printf "%d,%d,%d,%d", mt, mt-mf, ma, st-sf}' /proc/meminfo 2>/dev/null)
        [ -n "$mem" ] || mem="0,0,0,0"

        # CPU% = 两次 /proc/stat 采样差值的非空闲占比
        cpu=$(awk -v s1="$stat1" -v s2="$stat2" 'BEGIN{split(s1,a," ");split(s2,b," ");dT=b[1]-a[1];dI=b[2]-a[2];if(dT>0)printf "%.1f",(1-dI/dT)*100;else printf "%.1f",0}')
        # 磁盘 IO = 全部设备 sectors 差值 x 512 字节 / 间隔
        io=$(awk -v d1="$disk1" -v d2="$disk2" -v iv="$interval" 'BEGIN{split(d1,a," ");split(d2,b," ");r=(b[1]-a[1])*512/iv/1048576;w=(b[2]-a[2])*512/iv/1048576;if(r<0)r=0;if(w<0)w=0;printf "%.1f,%.1f",r,w}')

        echo "$ts,$load1,$cpu,$mem,$io" >> "$csv"
        stat1="$stat2"
        disk1="$disk2"

        # stress.pids 全部消失 → 监控循环退出
        alive=$(alive_pids "$pids_file")
        [ "$alive" -eq 0 ] && break
    done
}

# ---------- 子命令分发 ----------

CMD="${1:-}"
shift || true
case "$CMD" in
    start)         cmd_start "$@" ;;
    status)        cmd_status ;;
    stop)          cmd_stop ;;
    review)        cmd_review "$@" ;;
    monitor-loop)  cmd_monitor_loop "$@" ;;
    *) usage; exit 1 ;;
esac
