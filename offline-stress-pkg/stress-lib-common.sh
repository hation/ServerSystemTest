# ---------- 公共工具 ----------

now() { date '+%Y-%m-%d %H:%M:%S'; }

# 追加一条操作记录到根级 operations.log
log_op() { echo "[$(now)] $*" >> "$STRESS_TEST_ROOT/operations.log"; }

# 实测逻辑线程数：优先 NPROC_BIN，失败回退 CPUINFO 计数；彻底失败输出空串
logical_cpus() {
    local n=""
    n=$("$NPROC_BIN" 2>/dev/null)
    case "$n" in ''|*[!0-9]*) n="" ;; esac
    if [ -z "$n" ] || [ "$n" -lt 1 ]; then
        n=$(grep -c '^processor' "$CPUINFO" 2>/dev/null)
        case "$n" in ''|*[!0-9]*) n="" ;; esac
        [ -n "$n" ] && [ "$n" -lt 1 ] && n=""
    fi
    echo "$n"
}

# 物理核数：优先 lscpu -p=Core,Socket 去重计数；失败回退 /proc/cpuinfo 的 (physical id, core id)
# 两者都失败输出 0（由调用方回退 nproc 百分比）
physical_cores() {
    local n=""
    n=$("$LSCPU_BIN" -p=Core,Socket 2>/dev/null | LC_ALL=C awk -F, '
        $1 ~ /^[0-9]+$/ && $2 ~ /^[0-9]+$/ {
            k = $1 ":" $2
            if (!(k in seen)) { seen[k] = 1; n++ }
        }
        END { print n + 0 }')
    case "$n" in ''|*[!0-9]*) n=0 ;; esac
    if [ "$n" -lt 1 ]; then
        n=$(LC_ALL=C awk -F: '
            function add() {
                if (pid != "" && cid != "") {
                    k = pid ":" cid
                    if (!(k in seen)) { seen[k] = 1; n++ }
                }
                pid = ""; cid = ""
            }
            /^processor[ \t]*:/ { add() }
            /^physical id[ \t]*:/ { pid = $2; gsub(/[ \t]/, "", pid) }
            /^core id[ \t]*:/ { cid = $2; gsub(/[ \t]/, "", cid) }
            END { add(); print n + 0 }' "$CPUINFO" 2>/dev/null)
        case "$n" in ''|*[!0-9]*) n=0 ;; esac
    fi
    echo "$n"
}

# SMT 每核线程数探测（参与 CPU worker 分配）：输出 2（开）/ 1（关）/ 空串（未知/不支持）。
# 优先级与 smt_status 一致：lscpu "Thread(s) per core" → /sys/devices/system/cpu/smt/active → /sys/devices/system/cpu/smt/control → 未知
smt_tpc() {
    local tpc=""
    tpc=$("$LSCPU_BIN" 2>/dev/null | grep -i "Thread(s) per core" | tr -dc '0-9')
    case "$tpc" in
        1|2) echo "$tpc"; return 0 ;;
    esac
    if [ -f /sys/devices/system/cpu/smt/active ]; then
        case "$(cat /sys/devices/system/cpu/smt/active 2>/dev/null)" in
            1) echo 2; return 0 ;;
            0) echo 1; return 0 ;;
        esac
    fi
    if [ -f /sys/devices/system/cpu/smt/control ]; then
        case "$(cat /sys/devices/system/cpu/smt/control 2>/dev/null)" in
            on) echo 2; return 0 ;;
            off|forceoff) echo 1; return 0 ;;
            notsupported) return 0 ;;
        esac
    fi
    echo ""
}

# SMT 状态探测（每核线程数来自 smt_tpc；参与 CPU worker 分配）：
# 优先级 lscpu "Thread(s) per core" → /sys/devices/system/cpu/smt/active → /sys/devices/system/cpu/smt/control → 未知
# 输出：开(每核2线程) / 关(每核1线程) / 不支持 / 未知
smt_status() {
    local tpc
    tpc=$(smt_tpc)
    case "$tpc" in
        2) echo "开(每核2线程)"; return 0 ;;
        1) echo "关(每核1线程)"; return 0 ;;
    esac
    if [ -f /sys/devices/system/cpu/smt/control ]; then
        case "$(cat /sys/devices/system/cpu/smt/control 2>/dev/null)" in
            notsupported) echo "不支持"; return 0 ;;
        esac
    fi
    echo "未知"
}

# 自动推导 CPU worker 数（唯一公式）：max(1, round(逻辑线程 × 25/32))；
# 公式口径：所有机型统一；逻辑线程 = 物理核 × 每核线程数（SMT 探测，未知默认按开 tpc=2）；
# SMT 关闭（每核1线程）时逻辑线程减半，worker 相应减半：5380→25、7360→38、7380→50。
# 物理核识别失败回退 round(nproc × CPU_MAX_PCT%)。成功设置 CPU_WORKERS_AUTO / CPU_PHYS_CORES /
# CPU_LOGICAL_THREADS / CPU_SMT_TPC 并返回 0；物理核与 nproc 均不可用时返回 1（由调用方报错退出）。
cpu_workers_auto() {
    local c w n tpc logical
    c=$(physical_cores)
    CPU_PHYS_CORES="$c"
    CPU_WORKERS_AUTO=""
    CPU_LOGICAL_THREADS=""
    CPU_SMT_TPC=""
    if [ "$c" -ge 1 ]; then
        tpc=$(smt_tpc)
        [ -z "$tpc" ] && tpc=2
        logical=$(( c * tpc ))
        w=$(( (logical * 25 + 16) / 32 ))
        CPU_LOGICAL_THREADS="$logical"
        CPU_SMT_TPC="$tpc"
    else
        n=$(logical_cpus)
        case "$n" in ''|*[!0-9]*) return 1 ;; esac
        [ "$n" -ge 1 ] || return 1
        w=$(( (n * CPU_MAX_PCT + 50) / 100 ))
    fi
    [ "$w" -lt 1 ] && w=1
    CPU_WORKERS_AUTO="$w"
    return 0
}

# 从 lscpu/CPUINFO 提取 CPU 型号（多品牌）：
#   海光 "Hygon C86-3G 5380 ..." → "5380"（纯数字）
#   AMD "AMD EPYC 7763 ..." → "EPYC-7763"
#   Intel "Intel(R) Xeon(R) Gold 6338 ..." → "Xeon-6338"
# 兼容中英文 lscpu 输出（Model name / 型号名称）、大小写与多空格；无品牌匹配输出空串（调用方回退逻辑线程分界）
detect_cpu_model() {
    local s=""
    s=$("$LSCPU_BIN" 2>/dev/null | grep -iE "Model name|型号名称" | head -1)
    [ -z "$s" ] && s=$(grep -iE "model name" "$CPUINFO" 2>/dev/null | head -1)
    case "$s" in
        *[Cc]86-3[Gg]*)
            echo "$s" | sed -nE 's/.*[Cc]86-3[Gg][[:space:]]+([0-9]+).*/\1/p' | head -1 ;;
        *[Ee][Pp][Yy][Cc]*)
            echo "$s" | sed -nE 's/.*[Ee][Pp][Yy][Cc][[:space:]]*([0-9]+).*/EPYC-\1/p' | head -1 ;;
        *[Xx][Ee][Oo][Nn]*)
            # 取 Xeon 后第一组 3~4 位连续数字（跳过 E5- 这类 1~2 位嵌入数字），输出统一 Xeon-<数字>
            echo "$s" | sed -nE 's/.*[Xx][Ee][Oo][Nn][^0-9]*([0-9]{1,2}[^0-9]+)*([0-9]{3,4})([^0-9]|$).*/Xeon-\2/p' | head -1 ;;
        *) echo "" ;;
    esac
}

# 机型标称逻辑线程数（仅用于报告标注与交叉校验）：海光 5380/7360/7380 + AMD EPYC / Intel Xeon 典型型号；
# 未知型号输出空串（调用方跳过标称校验、不误报）
nominal_threads() {
    case "$1" in
        5380) echo 64 ;;
        7360) echo 96 ;;
        7380) echo 128 ;;
        EPYC-7763) echo 128 ;;
        EPYC-7543) echo 64 ;;
        Xeon-6338) echo 64 ;;
        Xeon-8380) echo 112 ;;
        *) echo "" ;;
    esac
}

# 实测线程数与机型标称值交叉校验：偏差 >10% 时提示并记日志，不改变任何参数。
# $3 为 SMT 状态文本（smt_status 输出），用于区分"实测≈标称一半"的提示口径
check_model_threads() {
    local model="$1" n="$2" smt="$3" nominal diff pct hint=""
    nominal=$(nominal_threads "$model")
    [ -n "$nominal" ] || return 0
    case "$n" in ''|*[!0-9]*) return 0 ;; esac
    diff=$(( nominal - n )); [ "$diff" -lt 0 ] && diff=$(( -diff ))
    [ $(( diff * 100 )) -gt $(( nominal * 10 )) ] || return 0
    pct=$(( diff * 100 / nominal ))
    # 实测约为标称一半 → 结合 SMT 状态区分：SMT 关闭时逻辑线程减半属预期；SMT 开启/未知仍提示疑似单路 CPU
    if [ $(( n * 2 )) -ge $(( nominal * 9 / 10 )) ] && [ $(( n * 2 )) -le $(( nominal * 11 / 10 )) ]; then
        case "$smt" in
            *"关(每核1线程)"*) hint="，SMT 关闭（每核1线程），逻辑线程减半属预期；CPU worker 将按逻辑线程 78.125% 推导" ;;
            *) hint="，疑似单路 CPU（另一路未识别）" ;;
        esac
    fi
    if [ -n "$hint" ]; then
        echo "警告：机型 $model 标称 ${nominal} 线程，实测 ${n} 线程（偏差 ${pct}%）${hint}"
    else
        echo "警告：机型 $model 标称 ${nominal} 线程，实测 ${n} 线程（偏差 ${pct}%）；CPU 参数按实测推导"
    fi
    log_op "model-check 机型 $model 标称 ${nominal} 线程，实测 ${n} 线程（偏差 ${pct}%，仅交叉校验）"
}

# dmidecode 有效槽位容量 token（每行一个）：只认行首 Size: 且值为正数容量，
# 自动排除 "No Module Installed"/"Unknown"/"0 MB"，也不会误计 "Installed Size:"。
# 根数统计与单根容量判定都从这一份输出派生，避免两处过滤逻辑漂移
dimm_capacities_dmidecode() {
    "$DMI_BIN" -t 17 2>/dev/null | LC_ALL=C awk -F: '
        /^[[:space:]]*Size:/ {
            v = $2
            gsub(/^[ \t]+|[ \t]+$/, "", v)
            if (v ~ /^[1-9][0-9]*[[:space:]]*(MB|GB|TB)/) print v
        }'
}

# 容量 token 行数 → 有效槽位根数
dimm_lines_count() { awk 'NF{n++} END{print n+0}'; }

# DIMM 根数探测（方式一 dmidecode）
dimm_count_dmidecode() { dimm_capacities_dmidecode | dimm_lines_count; }

# DIMM 根数探测（方式二 EDAC）：$EDAC_ROOT/mc*/dimm*/size 且内容 > 0
dimm_count_edac() {
    local f n=0
    for f in "$EDAC_ROOT"/mc*/dimm*/size; do
        [ -f "$f" ] || continue
        [ "$(cat "$f" 2>/dev/null)" -gt 0 ] 2>/dev/null && n=$((n + 1))
    done
    echo "$n"
}

# DIMM 根数自动探测：dmidecode → EDAC；根数写入 DIMM_COUNT、来源写入 DIMM_SOURCE（dmidecode|edac|none）、
# dmidecode 命中时的容量 token 列表写入 DIMM_CAPS。
# 注意：需在当前 shell 调用（如 `dimm_count_auto >/dev/null`）才能回传上述全局变量
dimm_count_auto() {
    local n caps
    DIMM_CAPS=""
    caps=$(dimm_capacities_dmidecode)
    n=$(printf '%s\n' "$caps" | dimm_lines_count)
    if [ "$n" -ge 1 ] && [ "$n" -le 256 ]; then
        DIMM_COUNT="$n"; DIMM_SOURCE="dmidecode"; DIMM_CAPS="$caps"; echo "$n"; return 0
    fi
    n=$(dimm_count_edac)
    if [ "$n" -ge 1 ] && [ "$n" -le 256 ]; then
        DIMM_COUNT="$n"; DIMM_SOURCE="edac"; echo "$n"; return 0
    fi
    DIMM_COUNT=0; DIMM_SOURCE="none"; echo 0
}

# 由容量 token 列表判定单根容量：全部一致写该容量（如 64 GiB），混合写“混合（按总量均分）”
dimm_capacity_desc() {
    local tok g first="" n=0 mixed=0
    while IFS= read -r tok; do
        [ -n "$tok" ] || continue
        g=$(dimm_cap_gib "$tok")
        if [ -z "$g" ]; then
            mixed=1
            continue
        fi
        n=$((n + 1))
        if [ -z "$first" ]; then
            first="$g"
        elif [ "$g" -ne "$first" ]; then
            mixed=1
        fi
    done <<< "$1"
    [ "$n" -ge 1 ] || return 0
    if [ "$mixed" -eq 1 ]; then
        printf '混合（按总量均分）'
    else
        printf '%s GiB' "$first"
    fi
}

# 单条容量 token 转 GiB 整数：解析前导数字+单位，忽略后缀（如 "32 GB (Single Rank)"）；
# MB 四舍五入到 GiB，GB 按 GiB，TB×1024。无法解析输出空串
dimm_cap_gib() {
    printf '%s\n' "$1" | LC_ALL=C awk '
        {
            v = $0
            gsub(/^[ \t]+|[ \t]+$/, "", v)
            if (v !~ /^[0-9]+[ \t]*(MB|GB|TB)/) exit
            n = v; sub(/[ \t]*(MB|GB|TB).*$/, "", n); n = n + 0
            u = v; sub(/^[0-9]+[ \t]*/, "", u); u = substr(u, 1, 2)
            if (u == "MB") print int((n + 512) / 1024)
            else if (u == "TB") print n * 1024
            else print n
        }'
}

# 容量 token 列表全部一致时输出单条 GiB（整数）；混合或无法解析输出空串
dimm_cap_gib_uniform() {
    local tok g first="" n=0
    while IFS= read -r tok; do
        [ -n "$tok" ] || continue
        g=$(dimm_cap_gib "$tok")
        case "$g" in ''|*[!0-9]*) return 0 ;; esac
        if [ "$n" -eq 0 ]; then
            first="$g"
        elif [ "$g" -ne "$first" ]; then
            return 0
        fi
        n=$((n + 1))
    done <<< "$1"
    [ "$n" -ge 1 ] && printf '%s' "$first"
}

# 内存计划（兜底路径）：target=MemTotal×MEM_TARGET_PCT%，单 worker=round(target/根数) GiB，
# 回落至 MemTotal×MEM_TOTAL_MAX_PCT% 以内。成功返回 0 并设置 PLAN_PER_GB / PLAN_TOTAL_GB / PLAN_TARGET_GB；
# 单 worker <1G 返回 1
mem_plan() {
    local total_mb="$1" workers="$2" target_mb cap_mb per_gb
    case "$total_mb" in ''|*[!0-9]*) return 1 ;; esac
    case "$workers" in ''|*[!0-9]*) return 1 ;; esac
    [ "$workers" -ge 1 ] || return 1
    target_mb=$(( total_mb * MEM_TARGET_PCT / 100 ))
    per_gb=$(( (target_mb + workers * 512) / (workers * 1024) ))
    [ "$per_gb" -lt 1 ] && return 1
    cap_mb=$(( total_mb * MEM_TOTAL_MAX_PCT / 100 ))
    while [ $(( per_gb * workers * 1024 )) -gt "$cap_mb" ] && [ "$per_gb" -gt 1 ]; do
        per_gb=$(( per_gb - 1 ))
    done
    [ $(( per_gb * workers * 1024 )) -gt "$cap_mb" ] && return 1
    PLAN_PER_GB=$per_gb
    PLAN_TOTAL_GB=$(( per_gb * workers ))
    PLAN_TARGET_GB=$(( (target_mb + 512) / 1024 ))
}

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

# MemTotal（MB）；MemTotal 缺失或数值非法时输出空串
mem_total_mb() {
    awk '/^MemTotal:/{if($2 ~ /^[0-9]+$/){printf "%d", $2/1024; exit}}' "$MEMINFO_FILE" 2>/dev/null
}

# 尺寸文本转 MB：54G→55296、26G→26624、256M→256、纯数字按 MB；无法解析输出空串。
# 数字段一律按十进制解析（010G 视为 10G，避免 bash 的 8 进制误读）
parse_size_mb() {
    local s="$1" n u
    n=$(printf '%s' "$s" | sed -n 's/^\([0-9]\+\)[KkMmGgTt]$/\1/p')
    if [ -z "$n" ]; then
        case "$s" in
            ''|*[!0-9]*) return 0 ;;
            *) n=$(( 10#$s )); echo "$n"; return 0 ;;
        esac
    fi
    n=$(( 10#$n ))
    u=$(printf '%s' "$s" | sed -n 's/^[0-9]\+\([KkMmGgTt]\)$/\1/p' | tr 'kmgt' 'KMGT')
    case "$u" in
        K) echo $(( n / 1024 )) ;;
        M) echo "$n" ;;
        G) echo $(( n * 1024 )) ;;
        T) echo $(( n * 1024 * 1024 )) ;;
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

