# ---------- 运行时证据（实际进程快照） ----------

# 读取 actual-params.txt 中的字段（$1=文件 $2=键名），缺失输出空串
read_actual_param() {
    grep "^$2=" "$1" 2>/dev/null | head -1 | cut -d'=' -f2-
}

# 判断 cmdline 是否 stress 本体：直接执行 stress，或 shebang 脚本（bash/sh + 脚本名 stress）。
# 用于排除 `sh -c 'stress ...'` wrapper，避免 hdd 进程数被重复统计。
is_stress_proc() {
    local cmd="$1" first second
    set -- $cmd
    first="${1##*/}"
    [ "$first" = "stress" ] && return 0
    case "$first" in bash|sh|dash) ;; *) return 1 ;; esac
    second="${2##*/}"
    [ "$second" = "stress" ]
}

# 执行一致性只认 60s/600s/periodic 快照；start/manual 仅展示
is_evidence_label() {
    case "$1" in
        60s|600s|periodic) return 0 ;;
        *) return 1 ;;
    esac
}

# 仅 600s/periodic 快照可作稳态判定（RSS、hdd 进程数）；60s 只作早期观察
is_mature_label() {
    case "$1" in
        600s|periodic) return 0 ;;
        *) return 1 ;;
    esac
}

# 从快照行中取 cmdline（保留路径/参数中的空格）
snapshot_cmdline() {
    printf '%s' "$1" | sed -n 's/^.*[[:space:]]cmdline=//p' 2>/dev/null
}

# 从快照行中取 cwd（到 " cmdline=" 为止，保留 cwd 中的空格）
snapshot_cwd() {
    printf '%s' "$1" | sed -n 's/^.*[[:space:]]cwd=//; s/[[:space:]]cmdline=.*$//p' 2>/dev/null
}

# 从 runtime-snapshot.txt 中取指定 label 的最后一个 found>0 快照块（$1=文件 $2=label）
# 同 label 后续追加的 found=0 空块不得覆盖已有有效证据。
snapshot_block_by_label() {
    awk -v want="$2" '
        /^==== 运行快照 ====$/ { inb = 1; buf = ""; lbl = ""; fnd = ""; next }
        !inb { next }
        /^$/ {
            if (lbl == want && fnd != "" && fnd + 0 > 0) last = buf
            inb = 0; next
        }
        { buf = buf $0 "\n" }
        /^label: / { lbl = substr($0, 8) }
        /^found: / { fnd = substr($0, 8) }
        END {
            if (inb && lbl == want && fnd != "" && fnd + 0 > 0) last = buf
            printf "%s", last
        }
    ' "$1" 2>/dev/null
}

# 运行时快照：$1=结果目录 $2=label（start/60s/600s/periodic/manual）
# 追加写 runtime-snapshot.txt；解析实际参数覆盖写 actual-params.txt。
# /proc 不可用或无进程时仍写 found=0，不报错。
runtime_snapshot() {
    local dir="$1" label="${2:-manual}"
    [ -n "$dir" ] && [ -d "$dir" ] || return 0

    local -A ppid_of=() children=() seen=() have=()
    local -A cmd_of=() cwd_of=() rss_of=() state_of=() threads_of=()
    local st line pid cp queue cur kids k cwd cmd rss state threads
    local found_n=0 rss_total=0 order="" wrappers=""

    # 1) 扫描 /proc/*/status 的 PPid，建立父子关系
    for st in /proc/[0-9]*/status; do
        [ -r "$st" ] || continue
        pid="${st#/proc/}"; pid="${pid%/status}"
        cp=""
        while IFS= read -r line; do
            case "$line" in
                PPid:*) cp="${line#PPid:}"; cp="${cp//[[:space:]]/}"; break ;;
            esac
        done < "$st" 2>/dev/null
        case "$cp" in ''|*[!0-9]*) continue ;; esac
        ppid_of[$pid]="$cp"
        children[$cp]="${children[$cp]} $pid"
    done

    # 2) 从 stress.pids 的 wrapper PID 出发，收集 wrapper 自身及全部后代
    if [ -f "$dir/stress.pids" ]; then
        while IFS= read -r pid; do
            case "$pid" in ''|*[!0-9]*) continue ;; esac
            [ -n "${seen[$pid]:-}" ] && continue
            seen[$pid]=1
            order="$order $pid"
            wrappers="$wrappers $pid"
        done < "$dir/stress.pids"
    fi
    queue="$wrappers"
    while [ -n "$queue" ]; do
        set -- $queue
        cur="$1"; shift
        queue="$*"
        kids="${children[$cur]:-}"
        for k in $kids; do
            [ -n "${seen[$k]:-}" ] && continue
            seen[$k]=1
            order="$order $k"
            queue="$queue $k"
        done
    done

    # 3) 逐个采集 pid/ppid/cmdline/cwd/VmRSS/Threads/State
    #    只信 stress.pids 的 wrapper 及其 /proc 后代；wrapper 已 exec 成 stress 时自身即 stress。
    #    不按 cwd 补充扫描，避免把同目录残留/并发 stress 计入。
    for pid in $order; do
        st="/proc/$pid/status"
        [ -r "$st" ] || continue
        read -r state threads rss <<< "$(awk '/^State:/{s=$2} /^Threads:/{t=$2} /^VmRSS:/{r=$2} END{printf "%s %s %s", s, t, r+0}' "$st" 2>/dev/null)"
        [ -n "$state" ] || continue          # 进程已退出（/proc 条目消失的竞态）
        cmd=$(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null)
        cmd="${cmd% }"
        cwd=$(readlink "/proc/$pid/cwd" 2>/dev/null)
        [ -n "$cwd" ] || cwd="?"
        case "$rss" in ''|*[!0-9]*) rss=0 ;; esac
        case "$threads" in ''|*[!0-9]*) threads=0 ;; esac
        have[$pid]=1
        cmd_of[$pid]="$cmd"; cwd_of[$pid]="$cwd"; rss_of[$pid]="$rss"
        state_of[$pid]="$state"; threads_of[$pid]="$threads"
        found_n=$((found_n + 1))
        rss_total=$((rss_total + rss))
    done

    # 4) 追加快照块（空行分隔，便于 review 按 label 取块）
    {
        echo "==== 运行快照 ===="
        echo "时间: $(now)"
        echo "label: $label"
        echo "task_dir: $dir"
        echo "found: $found_n"
        for pid in $order; do
            [ -n "${have[$pid]:-}" ] || continue
            echo "pid=$pid ppid=${ppid_of[$pid]:-0} rss_kb=${rss_of[$pid]} threads=${threads_of[$pid]} state=${state_of[$pid]} cwd=${cwd_of[$pid]} cmdline=${cmd_of[$pid]}"
        done
        echo ""
    } >> "$dir/runtime-snapshot.txt"

    # 5) 解析实际参数（main 取含 --cpu/--vm 的 stress 进程；hdd 取含 --hdd 的 stress 进程）
    local main_pid="" main_fallback="" main_cpu="" main_vm="" main_vm_bytes="" vm_keep="no"
    local hdd_processes=0 hdd_dirs="" hdd_dirs_seen=""
    for pid in $order; do
        [ -n "${have[$pid]:-}" ] || continue
        cmd="${cmd_of[$pid]}"
        case " $cmd " in
            *" --cpu "*|*" --vm "*)
                if is_stress_proc "$cmd"; then
                    main_pid="$pid"
                    break
                fi
                [ -z "$main_fallback" ] && main_fallback="$pid"
                ;;
        esac
    done
    main_pid="${main_pid:-$main_fallback}"
    if [ -n "$main_pid" ]; then
        cmd="${cmd_of[$main_pid]}"
        main_cpu=$(printf '%s' "$cmd" | sed -n 's/.*--cpu[[:space:]][[:space:]]*\([0-9][0-9]*\).*/\1/p' | head -1)
        main_vm=$(printf '%s' "$cmd" | sed -n 's/.*--vm[[:space:]][[:space:]]*\([0-9][0-9]*\).*/\1/p' | head -1)
        main_vm_bytes=$(printf '%s' "$cmd" | sed -n 's/.*--vm-bytes[[:space:]][[:space:]]*\([0-9][0-9KkMmGgTt]*\).*/\1/p' | head -1)
        case " $cmd " in *" --vm-keep "*) vm_keep="yes" ;; *) vm_keep="no" ;; esac
    fi
    for pid in $order; do
        [ -n "${have[$pid]:-}" ] || continue
        cmd="${cmd_of[$pid]}"
        is_stress_proc "$cmd" || continue
        case " $cmd " in *" --hdd "*) ;; *) continue ;; esac
        hdd_processes=$((hdd_processes + 1))
        cwd="${cwd_of[$pid]}"
        case ",$hdd_dirs_seen," in
            *",$cwd,"*) ;;
            *) hdd_dirs_seen="${hdd_dirs_seen:+$hdd_dirs_seen,}$cwd" ;;
        esac
    done
    hdd_dirs="$hdd_dirs_seen"

    # 6) 写 actual-params：found=0 不覆盖已有有效证据；manual 只展示，不覆盖 60s/600s/periodic 证据
    local old_found="" old_label="" write_ap=1
    if [ -f "$dir/actual-params.txt" ]; then
        old_found=$(read_actual_param "$dir/actual-params.txt" found)
        case "$old_found" in ''|*[!0-9]*) old_found=0 ;; esac
        old_label=$(read_actual_param "$dir/actual-params.txt" label)
        if [ "$found_n" -le 0 ] && [ "$old_found" -gt 0 ]; then
            write_ap=0
        fi
        if [ "$label" = "manual" ] && is_evidence_label "$old_label"; then
            write_ap=0
        fi
    fi
    [ "$write_ap" -eq 1 ] || return 0

    {
        echo "timestamp=$(now)"
        echo "label=$label"
        echo "main_cpu=${main_cpu:-}"
        echo "main_vm=${main_vm:-}"
        echo "main_vm_bytes=${main_vm_bytes:-}"
        echo "vm_keep=$vm_keep"
        echo "hdd_processes=$hdd_processes"
        echo "hdd_dirs=$hdd_dirs"
        echo "rss_total_kb=$rss_total"
        echo "found=$found_n"
    } > "$dir/actual-params.txt"
}

