# ---------- monitor-loop（内部子命令，start 后台调用） ----------

# 结束状态落盘（离线复盘用，免去猜 exitcode 缺失原因）：$1=state $2=reason
write_status() {
    local pc ecc un_n
    pc=$(awk 'NF{n++} END{print n+0}' "$dir/stress.pids" 2>/dev/null)
    ecc=$(ls "$dir"/*.exitcode 2>/dev/null | wc -l)
    un_n=$(awk 'NF{n++} END{print n+0}' "$dir/error-unattributed.log" 2>/dev/null)
    {
        echo "state=$1"
        echo "reason=$2"
        echo "pids=$pc exitcodes=$ecc"
        echo "oom=$([ "${oom_seen:-0}" -eq 1 ] && echo yes || echo no)"
        echo "io=$([ "${io_seen:-0}" -eq 1 ] && echo yes || echo no)"
        echo "unattributed=${un_n:-0}"
        echo "end_time=$(now)"
    } > "$dir/status.txt"
}

# 运行结束快照：落盘最终 status/exitcode 与最后一次 actual-params 副本（不再抓已退出进程）
write_runtime_final() {
    local dir="$1" f any=0
    {
        echo "==== 运行结束快照 ===="
        echo "时间: $(now)"
        echo "最终状态:"
        if [ -f "$dir/status.txt" ]; then
            sed 's/^/  /' "$dir/status.txt"
        else
            echo "  未生成 status.txt"
        fi
        echo "退出码:"
        for f in "$dir"/*.exitcode; do
            [ -f "$f" ] || continue
            any=1
            echo "  $(basename "$f")=$(cat "$f" 2>/dev/null)"
        done
        [ "$any" -eq 0 ] && echo "  未找到退出码文件"
        echo "== actual-params =="
        if [ -f "$dir/actual-params.txt" ]; then
            cat "$dir/actual-params.txt"
        else
            echo "未生成 actual-params.txt"
        fi
    } > "$dir/runtime-final.txt"
}

# dmesg 快照行数（空快照为 0）
dmesg_snap_lines() {
    if [ -z "$1" ]; then echo 0; else printf '%s\n' "$1" | wc -l; fi
}

# dmesg 快照的最大内核时间戳（行首 "[   123.456]"）；无时间戳行时输出空串
dmesg_max_ts() {
    printf '%s\n' "$1" | LC_ALL=C awk '
        { if (match($0, /^\[[[:space:]]*[0-9]+(\.[0-9]+)?\]/)) {
              t = substr($0, RSTART + 1, RLENGTH - 2); gsub(/[[:space:]]/, "", t)
              if (t + 0 > m) m = t + 0
              n++ } }
        END { if (n > 0) printf "%.6f", m }'
}

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

    # 巡检状态：上一轮存活数；dmesg 可用性；dmesg 游标（时间戳 + 行数兜底，只读探测不清 ring buffer）
    local prev_alive dmesg_ok=1 oom_seen=0 io_seen=0 dmesg_cursor=0 dmesg_ts="" dmesg_snap dmesg_max dmesg_total \
          ec code dmesg_hits line dev_re="" logged=""
    prev_alive=$(alive_pids "$pids_file")
    # 运行时快照调度基准：以 run-config 开始时间为锚点，避免监控重启后重复采样
    local start_epoch snap60=0 snap600=0 last_periodic=0 start_raw
    start_raw=$(grep '^开始时间:' "$dir/run-config.txt" 2>/dev/null | head -1 | cut -d' ' -f2-)
    [ -n "$start_raw" ] && start_epoch=$(date -d "$start_raw" +%s 2>/dev/null)
    case "$start_epoch" in ''|*[!0-9]*) start_epoch=$(date +%s) ;; esac
    "$DMESG_BIN" >/dev/null 2>&1 || dmesg_ok=0   # 只读探测可用性/权限；失败（非 root/无 dmesg）→ 后续整个检测跳过
    if [ "$dmesg_ok" -eq 1 ]; then
        # 首轮基线：行数兜底 + 当前最大时间戳；之后只处理比游标更新的行，不重复记录旧行
        dmesg_snap=$("$DMESG_BIN" 2>/dev/null)
        dmesg_cursor=$(dmesg_snap_lines "$dmesg_snap")
        echo "$dmesg_cursor" > "$dir/.dmesg.cursor"
        dmesg_ts=$(dmesg_max_ts "$dmesg_snap")
        [ -n "$dmesg_ts" ] && echo "$dmesg_ts" > "$dir/.dmesg.ts"
    fi

    # stop 通过 SIGTERM 置位，打断 sleep 等待后立刻落盘 STOPPED 状态
    local stop_flag=0
    trap 'stop_flag=1' TERM

    while :; do
        # 循环体内收到 TERM 时也要立即落盘 STOPPED，否则 stop 会等满一个采样间隔后 KILL 掉监控
        [ "$stop_flag" -eq 1 ] && { write_status STOPPED manual-stop; write_runtime_final "$dir"; exit 0; }
        sleep "$interval" & wait $! 2>/dev/null
        if [ "$stop_flag" -eq 1 ]; then write_status STOPPED manual-stop; write_runtime_final "$dir"; exit 0; fi
        local stat2 disk2 ts load1 mem cpu io alive dmesg_total
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

        # 进程存活数减少 → 检查各 *.exitcode，非 0（异常退出）实时记入 error.log；正常自然结束（0）不记录；
        # logged 清单记录已追加过的 exitcode 文件名，多进程分轮退出时同一文件不重复追加
        alive=$(alive_pids "$pids_file")
        if [ "$alive" -lt "$prev_alive" ]; then
            for ec in "$dir"/*.exitcode; do
                [ -f "$ec" ] || continue
                case " $logged " in *" $(basename "$ec") "*) continue ;; esac
                code=$(cat "$ec" 2>/dev/null)
                if [ "$code" != "0" ]; then
                    echo "[$(now)] 检测到 stress 进程异常退出（存活数 ${prev_alive}→${alive}），exitcode=${code}，详见 $(basename "$ec")" >> "$dir/error.log"
                    logged="$logged $(basename "$ec")"
                fi
            done
        fi
        prev_alive="$alive"

        # 运行时证据：运行 60s、600s、之后每 600s 抓取一次实际进程快照（进程已全部退出则不抓）
        if [ "$alive" -gt 0 ]; then
            local elapsed
            elapsed=$(( $(date +%s) - start_epoch ))
            if [ "$elapsed" -ge 60 ] && [ "$snap60" -eq 0 ]; then
                runtime_snapshot "$dir" 60s
                snap60=1
            fi
            if [ "$elapsed" -ge 600 ] && [ "$snap600" -eq 0 ]; then
                runtime_snapshot "$dir" 600s
                snap600=1
                last_periodic="$elapsed"
            elif [ "$snap600" -eq 1 ] && [ $(( elapsed - last_periodic )) -ge 600 ]; then
                runtime_snapshot "$dir" periodic
                last_periodic="$elapsed"
            fi
        fi

        # dmesg 增量检测（每轮只取一次快照）：优先时间戳游标，无法解析时间戳时退回行数游标。
        # 逐行先判内核 I/O 错误（按 devices.txt 归因），再判 OOM（同一行只记一次）
        if [ "$dmesg_ok" -eq 1 ]; then
            dmesg_snap=$("$DMESG_BIN" 2>/dev/null)
            dmesg_total=$(dmesg_snap_lines "$dmesg_snap")
            dmesg_max=$(dmesg_max_ts "$dmesg_snap")
            if [ -n "$dmesg_max" ] && [ -n "$dmesg_ts" ]; then
                # 时间戳回退（ring 被清空/系统重启）→ 从头处理，避免漏检
                if awk -v a="$dmesg_max" -v b="$dmesg_ts" 'BEGIN{exit !(a+0 < b+0)}'; then dmesg_ts=0; fi
                dmesg_hits=$(printf '%s\n' "$dmesg_snap" | LC_ALL=C awk -v c="$dmesg_ts" '
                    { if (match($0, /^\[[[:space:]]*[0-9]+(\.[0-9]+)?\]/)) {
                          t = substr($0, RSTART + 1, RLENGTH - 2); gsub(/[[:space:]]/, "", t)
                          if (t + 0 > c + 0) print } }')
                dmesg_ts="$dmesg_max"
                echo "$dmesg_ts" > "$dir/.dmesg.ts"
                dmesg_cursor="$dmesg_total"
                echo "$dmesg_cursor" > "$dir/.dmesg.cursor"
            else
                # 无时间戳（测试假件/异常格式）：行数游标；总行数下降视为 ring 回绕 → 从头读
                [ "$dmesg_total" -lt "$dmesg_cursor" ] && dmesg_cursor=0
                dmesg_hits=$(printf '%s\n' "$dmesg_snap" | tail -n +$((dmesg_cursor + 1)))
                dmesg_cursor="$dmesg_total"
                echo "$dmesg_cursor" > "$dir/.dmesg.cursor"
            fi
            # 设备边界匹配正则每轮重建：devices.txt 被删除/为空即退化为不过滤（旧目录兼容）
            dev_re=""
            if [ -s "$dir/devices.txt" ]; then
                dev_re=$(awk 'NF{gsub(/[^0-9A-Za-z_.-]/, "", $0); if ($0 != "") a = a (a ? "|" : "") $0} END{if (a != "") printf "(^|[^[:alnum:]])(%s)([^[:alnum:]]|$)", a}' "$dir/devices.txt")
            fi
            while IFS= read -r line; do
                [ -n "$line" ] || continue
                if printf '%s\n' "$line" | grep -qiE "$DMESG_IO_RE"; then
                    if [ -n "$dev_re" ] && ! printf '%s\n' "$line" | grep -qiE "$dev_re"; then
                        echo "[$(now)] dmesg io 未归因: $line" >> "$dir/error-unattributed.log"
                    else
                        echo "[$(now)] dmesg io: $line" >> "$dir/error.log"
                        io_seen=1
                    fi
                    continue
                fi
                if printf '%s\n' "$line" | grep -qiE "$DMESG_OOM_RE"; then
                    echo "[$(now)] dmesg: $line" >> "$dir/error.log"
                    oom_seen=1
                fi
            done <<< "$dmesg_hits"
        fi

        # stress.pids 全部消失 → 监控循环退出
        [ "$alive" -eq 0 ] && break
    done

    # 循环退出（进程全部消失）：exitcode 文件数少于 pids 数（进程被 KILL 未及写退出码）→ 判异常并补记；
    # 否则所有 exitcode 为 0 且 error.log 无"检测到 stress"/"dmesg" 记录 → 追加正常结束结论（循环遍历判定，避免 grep 空文件误判）
    local pids_count ec_count all_zero=1
    pids_count=$(awk 'NF{n++} END{print n+0}' "$pids_file" 2>/dev/null)
    ec_count=$(ls "$dir"/*.exitcode 2>/dev/null | wc -l)
    if [ "$pids_count" -gt "$ec_count" ]; then
        echo "[$(now)] 检测到 stress 进程异常退出（未生成退出码文件，pids 数 ${pids_count} vs exitcode 数 ${ec_count}）" >> "$dir/error.log"
    else
        for ec in "$dir"/*.exitcode; do
            [ -f "$ec" ] || continue
            [ "$(cat "$ec" 2>/dev/null)" = "0" ] || { all_zero=0; break; }
        done
        if [ "$all_zero" -eq 1 ] && ! grep -qE '检测到 stress|dmesg' "$dir/error.log" 2>/dev/null; then
            echo "[$(now)] 压测结束：全部正常（exitcode=0）" >> "$dir/error.log"
        fi
    fi

    # 结束状态判定（顺序：非 0 退出码 > OOM 未落盘退出码 > 退出码缺失 > 全部正常）
    local nonzero=0
    for ec in "$dir"/*.exitcode; do
        [ -f "$ec" ] || continue
        [ "$(cat "$ec" 2>/dev/null)" = "0" ] || { nonzero=1; break; }
    done
    if [ "$nonzero" -eq 1 ]; then
        write_status FAILED nonzero-exitcode
    elif [ "${oom_seen:-0}" -eq 1 ] && [ "$ec_count" -lt "$pids_count" ]; then
        write_status ABORTED oom-killed
    elif [ "$ec_count" -lt "$pids_count" ]; then
        write_status ABORTED missing-exitcode
    else
        write_status OK all-exitcode-zero
    fi

    # 落盘运行结束证据（status/exitcode/actual-params 副本）
    write_runtime_final "$dir"
}
