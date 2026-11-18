#!/bin/bash
# stress-test.sh —— 压测主控脚本（Kylin V10 SP3，三类机型 CPU/内存/硬盘压测）
# 用法：
#   bash stress-test.sh start <cpu|mem|hdd|combo> [--model 5380|7380|7360|auto] [--timeout 10h] \
#       [--cpu N] [--vm N] [--vm-bytes X] [--hdd-bytes X] [--dirs "d1 d2"] [--sysdisk] [--sysdisk-only] \
#       [--peer-disks N]
#   说明：hdd 模式无 /mnt/HDD* 挂载点时加 --sysdisk 可仅压系统盘；--sysdisk-only 无论是否有数据盘都只压系统盘；
#         combo 无数据盘时降级为 CPU/内存（或配合 --sysdisk 压系统盘）；
#         combo/mem 的 --peer-disks N 只声明对端并发 hdd 流数（参与内存预留），不启动 hdd 进程；
#         出现该参数即不再自动扫描 /mnt/HDD*（仅显式 --dirs 才在 combo 内启动 hdd），0 表示纯 CPU+内存。
#   bash stress-test.sh status
#   bash stress-test.sh stop
#   bash stress-test.sh review [--dir <结果目录>]
# 环境变量（测试接缝）：
#   STRESS_TEST_ROOT 结果根目录（默认 /root/stress-test）
#   MONITOR_INTERVAL 监控间隔秒（默认 30）
#   FINDMNT_BIN      挂载点设备解析命令（默认 findmnt）
#   LSBLK_BIN        设备名解析命令（默认 lsblk，用于追加 KNAME 归因）
#   CPU_MAX_PCT      CPU worker 兜底百分比（物理核识别失败时按 nproc × 78%，默认 78）
#   NPROC_BIN        逻辑线程数取值命令（默认 nproc）
#   LSCPU_BIN        物理核探测命令（默认 lscpu，-p=Core,Socket 去重）
#   CPUINFO          物理核兜底探测文件（默认 /proc/cpuinfo）
#   MEM_TARGET_PCT   内存兜底目标（MemTotal 的百分比，默认 82，仅混合/未探测容量时使用）
#   MEM_MAX_PCT      模块总容量分配上限（百分比，默认 88）
#   MEM_TOTAL_MAX_PCT MemTotal 分配上限（百分比，默认 92）
#   MEMINFO_FILE     MemTotal 取值文件（默认 /proc/meminfo）
#   DMI_BIN          DIMM 根数探测命令（默认 dmidecode）
#   EDAC_ROOT        DIMM 根数第二探测来源（默认 /sys/devices/system/edac/mc）
# 退出码：0=正常（含无运行任务）；1=用法错误/前置条件不满足
# 说明：全程不 set -e；压测与监控均 nohup 后台运行、全部落盘，可脱离 ssh 会话。
#       CPU worker 按逻辑线程（物理核 × 每核线程数，SMT 探测；未知默认开）× 25/32 推导。

STRESS_TEST_ROOT="${STRESS_TEST_ROOT:-/root/stress-test}"
MONITOR_INTERVAL="${MONITOR_INTERVAL:-30}"
DF_BIN="${DF_BIN:-df}"
DMESG_BIN="${DMESG_BIN:-dmesg}"
FINDMNT_BIN="${FINDMNT_BIN:-findmnt}"
LSBLK_BIN="${LSBLK_BIN:-lsblk}"
# dmesg 内核 I/O 错误正则（大小写不敏感；口径见设计 6.3）
DMESG_IO_RE='EXT4-fs error|EXT4-fs .*error|I/O error|Buffer I/O error|blk_update_request|critical medium error|ata[0-9.]+: .*(failed|error)|nvme[0-9]+.*(error|timeout|reset)|reset .*failed'
# dmesg OOM 正则（沿用既有口径）
DMESG_OOM_RE='oom|out of memory|killed process|Killed'
MEM_MAX_PCT="${MEM_MAX_PCT:-88}"          # 模块总容量分配上限（百分比），案例 87.5% 需落在 88% 内
MEM_TARGET_PCT="${MEM_TARGET_PCT:-82}"    # 内存兜底目标（MemTotal 的百分比），仅混合/未探测容量时使用
MEM_TOTAL_MAX_PCT="${MEM_TOTAL_MAX_PCT:-92}"  # MemTotal 分配上限（百分比）
MEMINFO_FILE="${MEMINFO_FILE:-/proc/meminfo}"
CPU_MAX_PCT="${CPU_MAX_PCT:-78}"          # 物理核识别失败时的 CPU 兜底百分比（逻辑线程数的百分比）
NPROC_BIN="${NPROC_BIN:-nproc}"           # 逻辑线程数取值入口（测试接缝）
LSCPU_BIN="${LSCPU_BIN:-lscpu}"           # 物理核探测入口（测试接缝）
CPUINFO="${CPUINFO:-/proc/cpuinfo}"       # 物理核兜底探测文件（测试接缝）
# 磁盘页缓存/脏页预留：D × hdd-bytes × 1.2 + 8G（D 为数据盘目录数 + --sysdisk）
DISK_CACHE_FACTOR_PCT="${DISK_CACHE_FACTOR_PCT:-120}"   # 1.2 倍，整数百分比用于 bash 运算
DISK_CACHE_MIN_G="${DISK_CACHE_MIN_G:-8}"
DMI_BIN="${DMI_BIN:-dmidecode}"           # DIMM 根数探测入口（测试接缝）
EDAC_ROOT="${EDAC_ROOT:-/sys/devices/system/edac/mc}"  # DIMM 根数第二探测来源（测试接缝）
SCRIPT="$(readlink -f "$0" 2>/dev/null || echo "$0")"

# ---------- 公共工具 ----------

usage() {
    cat <<'EOF'
用法:
  bash stress-test.sh start <cpu|mem|hdd|combo> [--model 5380|7380|7360|auto] [--timeout 10h] \
      [--cpu N] [--vm N] [--vm-bytes X] [--hdd-bytes X] [--dirs "d1 d2"] [--sysdisk] [--sysdisk-only] \
      [--peer-disks N]
  bash stress-test.sh status
  bash stress-test.sh stop
  bash stress-test.sh review [--dir <结果目录>]
  bash stress-test.sh snapshot <结果目录>   # 立即抓取一次运行时证据快照

推导规则（不传对应参数时自动生效）:
  CPU worker 数 = max(1, round(逻辑线程数 × 25/32))，逻辑线程 = 物理核 × 每核线程数（SMT 探测，未知默认开）；
                  SMT 关闭（每核1线程）时逻辑线程减半，worker 相应减半（5380→25、7360→38、7380→50）；
                  物理核识别失败回退 nproc × 78%（环境变量 CPU_MAX_PCT）
  内存单 worker = 单条容量 − max(6G, 单条容量/8)，VM worker = DIMM 根数
  内存上限 = min(模块总容量 × 88%, MemTotal × 92%,
                 MemTotal − (盘数 × hdd-bytes × 1.2 + 8G))，超限逐 GiB 下调单 worker
  混合容量 / EDAC 无容量 / 显式 --vm ≠ DIMM 数 → MemTotal × 82% 均分（上限 92%）
  mem / combo 固定追加 --vm-keep（内存常驻）；hdd 每块数据盘 1 个进程
  内存条根数 = --vm（默认按 DIMM 自动探测，等于实际内存条根数；探测失败时可手动 --vm N）
  --peer-disks N（仅 combo/mem）：对端并发 hdd 流数，cap_disk 按 max(实际盘数, N) 预留；
                         只影响内存推导与展示，不启动 hdd 进程；出现即不再自动扫描 /mnt/HDD*

示例:
  bash stress-test.sh start cpu                # 按逻辑线程推导跑 CPU 压测（默认 10h）
  bash stress-test.sh start mem                # 按实测 MemTotal 与内存条根数推导跑内存压测（默认 10h）
  bash stress-test.sh start hdd --dirs "/mnt/HDD01 /mnt/HDD02"
  bash stress-test.sh start hdd --sysdisk       # 仅压系统盘（无数据盘时）
  bash stress-test.sh start hdd --sysdisk-only  # 仅压系统盘（无论是否有数据盘）
  bash stress-test.sh start combo --dirs "/mnt/HDD01 /mnt/HDD02" --sysdisk  # CPU+内存+每盘 hdd+系统盘
  bash stress-test.sh review --dir /root/stress-test/20261113-143000-cpu
EOF
}

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

# 机型标称逻辑线程数（仅用于报告标注与交叉校验）
nominal_threads() {
    case "$1" in 5380) echo 64 ;; 7360) echo 96 ;; 7380) echo 128 ;; *) echo "" ;; esac
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

# ---------- 设备归因（devices.txt） ----------

# 取目录对应挂载设备（findmnt SOURCE），并解析软链（by-uuid/by-id → 真实设备）；解析失败输出空串
dev_of_path() {
    local src real
    src=$("$FINDMNT_BIN" -n -o SOURCE --target "$1" 2>/dev/null | head -1)
    [ -n "$src" ] || return 0
    real=$(readlink -f "$src" 2>/dev/null)
    if [ -n "$real" ]; then echo "$real"; else printf '%s\n' "$src"; fi
}

# 由设备名推导整盘名：sdb1→sdb、nvme0n1p1→nvme0n1；
# 仅 sd/vd/hd/nvme/mmcblk 前缀参与推导，dm-/md/映射名不生成伪整盘名
whole_disk_of() {
    local base="$1" whole
    case "$base" in
        sd*|vd*|hd*|nvme*|mmcblk*) ;;
        *) echo ""; return ;;
    esac
    whole=$(printf '%s' "$base" | sed -E 's/p[0-9]+$//')
    if [ "$whole" != "$base" ]; then echo "$whole"; return; fi
    case "$base" in
        nvme[0-9]*n[0-9]*|mmcblk[0-9]*) echo "" ;;          # 本身已是整盘名
        *[0-9]) printf '%s' "$base" | sed -E 's/[0-9]+$//' ;;
        *) echo "" ;;
    esac
}

# 写设备归因文件：每行一个设备名（不含 /dev/），去重保序；
# 除 basename 外追加 lsblk KNAME（如 LVM 的 dm-0），便于内核 dm 日志归因；
# 解析失败则不写该类行，文件为空表示“不做设备过滤”（兼容旧目录）
write_devices_file() {
    local out="$1"
    shift
    local d src base kname name seen=""
    : > "$out"
    for d in "$@"; do
        [ -n "$d" ] || continue
        src=$(dev_of_path "$d")
        [ -n "$src" ] || continue
        base=$(basename "$src")
        kname=$("$LSBLK_BIN" -no KNAME "$src" 2>/dev/null | head -1 | tr -d '[:space:]')
        for name in "$base" "$kname" "$(whole_disk_of "$base")"; do
            [ -n "$name" ] || continue
            case " $seen " in *" $name "*) continue ;; esac
            seen="$seen $name"
            printf '%s\n' "$name" >> "$out"
        done
    done
}

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

# ---------- start ----------

cmd_start() {
    local type="$1"
    shift || true
    [ -n "$type" ] || { usage; exit 1; }
    case "$type" in
        cpu|mem|hdd|combo) ;;
        *) echo "未知压测类型：$type（应为 cpu|mem|hdd|combo）"; usage; exit 1 ;;
    esac

    # 参数解析：--model / --timeout / --cpu / --vm / --vm-bytes / --hdd-bytes / --dirs / --sysdisk / --sysdisk-only / --peer-disks
    local model="auto" timeout="10h" cpu_opt="" vm_opt="" vm_bytes_opt="" hdd_bytes_opt="" dirs_opt="" dirs_given=0 sysdisk=0 sysdisk_only=0
    local peer_disks_opt="" peer_given=0 peer_disks=0
    local bytes_from_preset=1   # 显式 --vm-bytes 置 0，用于内存裁剪分支判定
    while [ $# -gt 0 ]; do
        case "$1" in
            --model|--timeout|--cpu|--vm|--vm-bytes|--hdd-bytes|--dirs|--peer-disks)
                if [ $# -lt 2 ]; then echo "参数 $1 缺少取值"; usage; exit 1; fi
                ;;
        esac
        case "$1" in
            --model)     model="$2";        shift 2 ;;
            --timeout)   timeout="$2";      shift 2 ;;
            --cpu)       cpu_opt="$2";      shift 2 ;;
            --vm)        vm_opt="$2";       shift 2 ;;
            --vm-bytes)  vm_bytes_opt="$2"; bytes_from_preset=0; shift 2 ;;
            --hdd-bytes) hdd_bytes_opt="$2"; shift 2 ;;
            --dirs)      dirs_opt="$2"; dirs_given=1; shift 2 ;;
            --peer-disks) peer_disks_opt="$2"; peer_given=1; shift 2 ;;
            --sysdisk)   sysdisk=1;         shift 1 ;;
            --sysdisk-only) sysdisk=1; sysdisk_only=1; shift 1 ;;
            *) echo "未知参数：$1"; usage; exit 1 ;;
        esac
    done

    # --peer-disks N：非负整数；仅 combo/mem 生效，cpu/hdd 收到时只告警、不改变行为
    if [ "$peer_given" -eq 1 ]; then
        case "$peer_disks_opt" in
            ''|*[!0-9]*) echo "参数 --peer-disks 取值非法：$peer_disks_opt（应为非负整数，如 12 或 0）"; usage; exit 1 ;;
        esac
        peer_disks=$(( 10#$peer_disks_opt ))
        if [ "$type" != "combo" ] && [ "$type" != "mem" ]; then
            echo "提示：--peer-disks 仅对 combo/mem 模式生效，$type 模式忽略该选项"
            peer_given=0
            peer_disks=0
        fi
    fi

    # cpu/mem 模式下 --sysdisk 无效，仅提示（hdd/combo 才生效；--sysdisk-only 在下方单独提示，避免重复）
    if [ "$sysdisk" -eq 1 ] && [ "$sysdisk_only" -ne 1 ] && { [ "$type" = "cpu" ] || [ "$type" = "mem" ]; }; then
        echo "提示：--sysdisk 仅对 hdd/combo 模式生效，cpu/mem 模式忽略该选项"
    fi

    # --sysdisk-only 模式校验（先于机型解析）
    if [ "$sysdisk_only" -eq 1 ]; then
        if [ "$type" = "combo" ]; then
            echo "combo 模式包含 CPU/内存，仅压系统盘请用：bash stress-test.sh start hdd --sysdisk-only"
            exit 1
        fi
        if [ "$type" = "cpu" ] || [ "$type" = "mem" ]; then
            echo "提示：--sysdisk-only 仅对 hdd 模式生效，当前模式忽略该选项"
            sysdisk=0
        elif [ "$dirs_given" -eq 1 ]; then
            echo "--sysdisk-only 与 --dirs 不能同时使用（仅压系统盘时不会压数据盘）"
            exit 1
        fi
    fi

    # 结果根目录（非结果目录，提前创建）：作为 operations.log 的落脚点，
    # 保证机型交叉校验、内存推导等前置步骤的日志都能落盘
    mkdir -p "$STRESS_TEST_ROOT" || { echo "无法创建结果根目录：$STRESS_TEST_ROOT"; exit 1; }

    # 机型解析（缺省 auto）：mem>=800G→7380；nproc>=120→7380；nproc>=90→7360；否则 5380
    if [ "$model" = "auto" ]; then
        local mem_gb n
        mem_gb=$(awk '/^MemTotal:/{printf "%.0f", $2/1048576}' "$MEMINFO_FILE" 2>/dev/null)
        [ -z "$mem_gb" ] && mem_gb=0
        n=$(logical_cpus)
        case "$n" in ''|*[!0-9]*) n=0 ;; esac
        if [ "$mem_gb" -ge 800 ]; then model=7380
        elif [ "$n" -ge 120 ]; then model=7380
        elif [ "$n" -ge 90 ]; then model=7360
        else model=5380; fi
        echo "检测到机型 $model（仅用于报告标注与交叉校验）"
    fi
    case "$model" in 5380|7380|7360) ;;
        *) echo "未知机型：$model（应为 5380|7380|7360|auto）"; exit 1 ;;
    esac

    # CPU 参数：按逻辑线程推导（显式 --cpu 直接使用）；hdd 模式不推导、不校验
    # 逻辑线程 = 物理核 × 每核线程数（SMT 探测，未知默认开）；物理核识别失败时回退 round(nproc × CPU_MAX_PCT%)
    # SMT 状态在此探测一次（参与 CPU worker 分配）；hdd 模式不探测（不推导 CPU）
    local cpus="" phys_cores=0 cpu_note="" smt_txt=""
    if [ "$type" != "hdd" ]; then
        smt_txt=$(smt_status)
        cpus=$(logical_cpus)
        case "$cpus" in ''|*[!0-9]*) cpus="" ;; esac
        [ -n "$cpus" ] && check_model_threads "$model" "$cpus" "$smt_txt"
        if [ -z "$cpu_opt" ]; then
            if ! cpu_workers_auto; then
                echo "无法探测 CPU 数量（nproc 与物理核均不可用），已中止；请检查 nproc/lscpu 或用 --cpu 显式指定"
                exit 1
            fi
            cpu_opt="$CPU_WORKERS_AUTO"
            phys_cores="$CPU_PHYS_CORES"
            if [ "$phys_cores" -ge 1 ]; then
                if [ "$CPU_SMT_TPC" = "1" ]; then
                    cpu_note="（逻辑线程 ${CPU_LOGICAL_THREADS} × 25/32，SMT 关/每核1线程）"
                else
                    cpu_note="（逻辑线程 ${CPU_LOGICAL_THREADS} × 25/32，SMT 开/每核2线程）"
                fi
            else
                cpu_note="（物理核识别失败，nproc ${cpus} × ${CPU_MAX_PCT}%）"
            fi
        else
            cpu_note="（显式 --cpu）"
            phys_cores=$(physical_cores)
        fi
    fi

    # 内存参数（--vm / --vm-bytes）在下方“内存计划”段按实测 DIMM 根数与 MemTotal 推导；
    # 显式参数优先，显式传空值（如 --vm ""）按“未提供”处理，回退自动探测
    [ -z "$hdd_bytes_opt" ] && hdd_bytes_opt="10G"

    # 前置校验：stress 已安装
    command -v stress >/dev/null 2>&1 || { echo "未找到 stress，请先运行 bash install.sh 安装"; exit 1; }

    # hdd/combo 前置校验：先全量收集并校验压测盘目录，存在且任一无效即整体退出（不启动任何 stress、不建结果目录，防孤儿进程）
    # combo 模式目录集合可为空（无数据盘降级为仅 CPU/内存，或配合 --sysdisk 仅压系统盘）；
    # hdd 模式目录集合非空，仅当加 --sysdisk 时允许为空（无数据盘时仅压系统盘）；
    # --sysdisk-only 时数据盘集合强制为空，不扫描 /mnt/HDD*、不校验挂载（无论是否存在数据盘）
    local dirs=() d
    if [ "$sysdisk_only" -eq 1 ]; then
        dirs=()
    elif [ "$type" = "hdd" ] || [ "$type" = "combo" ]; then
        if [ "$dirs_given" -eq 1 ]; then
            dirs=($dirs_opt)          # 显式 --dirs（含空串）：空串表示不压数据盘
        elif [ "$type" = "combo" ] && [ "$peer_given" -eq 1 ]; then
            # --peer-disks 出现即视为显式声明外部盘流：不再自动 glob /mnt/HDD*，避免 combo 内重复压盘
            dirs=()
            echo "提示：已指定 --peer-disks=${peer_disks}，combo 不再自动扫描 /mnt/HDD*（不启动 hdd 进程）"
        else
            dirs=(/mnt/HDD*)
            [ -e "${dirs[0]}" ] || {
                dirs=()
                if [ "$type" = "hdd" ]; then
                    if [ "$sysdisk" -eq 1 ]; then
                        echo "未发现 /mnt/HDD* 挂载点，hdd 模式仅压系统盘"
                    else
                        echo "未发现 /mnt/HDD* 挂载点，请先运行 bash disk-mount.sh mount 或使用 --dirs 指定"; exit 1
                    fi
                else
                    echo "警告：未发现 /mnt/HDD* 挂载点，combo 模式无数据盘（仅 CPU/内存，或配合 --sysdisk 压系统盘）"
                fi
            }
        fi
        if [ "${#dirs[@]}" -gt 0 ]; then
            for d in "${dirs[@]}"; do
                [ -d "$d" ] || { echo "挂载点不存在：$d（请先挂载或检查 --dirs）"; exit 1; }
            done
            # 目录存在≠已挂载（umount 不删目录），多轮流程第二轮会误把压测文件写到系统根文件系统。
            # 默认 glob 与显式 --dirs 一视同仁：每个目录必须是已挂载的独立文件系统，且底层设备不是根设备。
            local root_dev dev
            root_dev=$("$DF_BIN" -P / 2>/dev/null | awk 'NR==2{print $1}')
            for d in "${dirs[@]}"; do
                dev=$("$FINDMNT_BIN" -n -o SOURCE --target "$d" 2>/dev/null | head -1)
                if [ -z "$dev" ] || { [ -n "$root_dev" ] && [ "$dev" = "$root_dev" ]; }; then
                    echo "目录 $d 不是已挂载的独立文件系统（设备=${dev:-未挂载}，系统盘=${root_dev:-未知}），不能作为压测盘"
                    echo "请先运行 bash disk-mount.sh mount 挂载测试盘，或用 --dirs 显式指定压测目录"
                    exit 1
                fi
            done
        elif [ "$type" = "hdd" ] && [ "$sysdisk" -ne 1 ]; then
            echo "未指定任何压测盘目录（--dirs 为空）"; exit 1
        elif [ "$type" = "combo" ] && [ "$dirs_given" -eq 1 ]; then
            echo "警告：combo 模式无数据盘（--dirs 为空，仅 CPU/内存，或配合 --sysdisk 压系统盘）"
        fi
    fi

    # --sysdisk 前置校验：建系统盘压测目录并预检 / 可用空间（hdd-bytes 按 G 换算 ×1.2），不足整体退出（不启动任何进程、不建结果目录）
    if [ "$sysdisk" -eq 1 ] && { [ "$type" = "hdd" ] || [ "$type" = "combo" ]; }; then
        mkdir -p /stresstest-hdd 2>/dev/null || { echo "无法创建系统盘压测目录 /stresstest-hdd（可能需要 root 权限）"; exit 1; }
        local gb need_kb avail_kb
        gb="${hdd_bytes_opt%[Gg]}"
        case "$gb" in
            ''|*[!0-9]*) echo "系统盘压测（--sysdisk/--sysdisk-only）空间预检要求 hdd-bytes 以 G 为单位（当前：$hdd_bytes_opt）"; exit 1 ;;
        esac
        need_kb=$(( gb * 12 * 1048576 / 10 ))
        avail_kb=$("$DF_BIN" -P / 2>/dev/null | awk 'NR==2{print $4}')
        if [ -z "$avail_kb" ] || [ "$avail_kb" -lt "$need_kb" ]; then
            echo "系统盘 / 可用空间不足：需要 ≥ ${need_kb} kB（${hdd_bytes_opt}×1.2），当前可用 ${avail_kb:-未知} kB"
            exit 1
        fi
    fi

    # 盘数 D（数据盘目录数 + --sysdisk 的系统盘）；仅 hdd/combo 计入
    local disk_streams=0 disk_streams_eff=0 disk_streams_source="actual"
    if [ "$type" = "hdd" ] || [ "$type" = "combo" ]; then
        disk_streams=${#dirs[@]}
        [ "$sysdisk" -eq 1 ] && disk_streams=$((disk_streams + 1))
    fi
    # 有效盘流：combo/mem 显式 --peer-disks 时取 max(实际盘数, peer)；hdd/cpu 只用实际盘数。
    # peer 只参与 cap_disk 预留与展示，不产生 hdd 进程。
    disk_streams_eff="$disk_streams"
    if [ "$peer_given" -eq 1 ]; then
        if [ "$peer_disks" -gt "$disk_streams" ]; then
            disk_streams_eff="$peer_disks"
            disk_streams_source="peer"
        elif [ "$peer_disks" -lt "$disk_streams" ]; then
            disk_streams_source="actual"
        else
            disk_streams_source="max"
        fi
    fi

    # 内存计划（仅 mem/combo）：DIMM 根数/容量决定单 worker，三道上限取最小后逐 GiB 下调。
    # 放在结果目录创建之前：探测/推导失败时直接退出，不留下 <时间戳>-mem 结果目录、不启动 stress。
    # 显式 --vm / --vm-bytes 优先且不被改写（显式传空值按“未提供”处理，回退自动探测）。
    local mem_dimm_desc="" mem_per_desc="" mem_target_desc="" mem_plan_desc="" mem_total_gb_desc=""
    local mem_cap_desc="" mem_need_desc="" vm_keep="no" res_plan_line=""
    local per_g="" cap_module_g="" cap_mem_g="" cap_disk_g=""
    if [ "$type" = "mem" ] || [ "$type" = "combo" ]; then
        vm_keep="yes"
        local total_mb="" probe_source="none" probe_count=0 probe_caps="" uniform_g="" module_count=0
        local cap_module_mb="" cap_mem_mb="" cap_disk_mb="" cap_mb="" cap_g=""
        local per_mb=0 need_mb=0 reserve_g=0 clamped=0 old_per_g=0 dimm_cap="" fallback_reason=""

        dimm_count_auto >/dev/null     # 始终探测：显式 --vm 也需 DIMM 根数做一致性判定
        probe_source="$DIMM_SOURCE"; probe_count="$DIMM_COUNT"; probe_caps="$DIMM_CAPS"

        # 1) worker 数 = DIMM 根数（显式 --vm 优先）
        if [ -n "$vm_opt" ]; then
            case "$vm_opt" in
                ''|*[!0-9]*) echo "参数 --vm 取值非法：$vm_opt（应为正整数根数）"; exit 1 ;;
            esac
            vm_opt=$(( 10#$vm_opt ))      # 前导零按十进制归一化（08→8、010→10）
            [ "$vm_opt" -ge 1 ] || { echo "参数 --vm 取值非法：$vm_opt（应为正整数根数）"; exit 1; }
            DIMM_SOURCE="显式 --vm"
        else
            vm_opt="$probe_count"
            if [ "$probe_source" = "none" ] || [ "$vm_opt" -lt 1 ]; then
                local sg_total_mb=""
                sg_total_mb=$(mem_total_mb)
                echo "无法探测内存条根数（dmidecode/EDAC 均不可用），本次 ${type} 压测已中止。"
                if [ -n "$sg_total_mb" ] && mem_plan "$sg_total_mb" 16; then
                    echo "已按 MemTotal $(( (sg_total_mb + 512) / 1024 ))G 算好一条可直接执行的命令（16 个 worker 平分 ${MEM_TARGET_PCT}%，总量 ${PLAN_TOTAL_GB}G，未超 ${MEM_TOTAL_MAX_PCT}% 上限）："
                    echo "  bash stress-test.sh start ${type} --vm 16 --vm-bytes ${PLAN_PER_GB}G --timeout ${timeout}"
                    echo "若已知实际内存条根数，更推荐只填根数、单 worker 字节由脚本自动推导："
                    echo "  bash stress-test.sh start ${type} --vm <实际根数> --timeout ${timeout}"
                else
                    echo "MemTotal 也无法读取，需同时显式给出根数与单 worker 字节（总量应约等于 MemTotal × ${MEM_TARGET_PCT}%），例如："
                    echo "  bash stress-test.sh start ${type} --vm <实际根数> --vm-bytes 26G --timeout ${timeout}"
                fi
                echo "根数获取：开机 BIOS 内存信息或机箱/主板标签；已装 lshw 时可用 sudo lshw -class memory | grep -c 'bank:'"
                echo "装上 dmidecode 后重试即可恢复自动探测（离线包已内置：在包目录执行 sudo bash install.sh）；combo 的 --dirs / --sysdisk 等参数请按原命令补上。"
                exit 1
            fi
        fi

        # 2) MemTotal 与三道 cap（显式 --vm-bytes 时 MemTotal 可缺失，仅告警）
        total_mb=$(mem_total_mb)
        if [ -z "$total_mb" ] && [ -z "$vm_bytes_opt" ]; then
            echo "无法读取 MemTotal（$MEMINFO_FILE），已中止；请检查该文件或用 --vm-bytes 显式指定"
            exit 1
        fi
        if [ -n "$total_mb" ]; then
            mem_total_gb_desc=$(( (total_mb + 512) / 1024 ))
            cap_mem_mb=$(( total_mb * MEM_TOTAL_MAX_PCT / 100 ))
            cap_mem_g=$(( cap_mem_mb / 1024 ))
            if [ "$disk_streams_eff" -gt 0 ]; then
                local hdd_mb disk_need_mb
                hdd_mb=$(parse_size_mb "$hdd_bytes_opt")
                case "$hdd_mb" in ''|*[!0-9]*) hdd_mb=10240 ;; esac
                disk_need_mb=$(( disk_streams_eff * hdd_mb * DISK_CACHE_FACTOR_PCT / 100 + DISK_CACHE_MIN_G * 1024 ))
                cap_disk_mb=$(( total_mb - disk_need_mb ))
                if [ "$cap_disk_mb" -le 0 ]; then
                    echo "内存不足以支撑当前盘流（${disk_streams_eff} 个 hdd 流预留 $(( disk_need_mb / 1024 ))G，MemTotal ${mem_total_gb_desc}G），请减少盘数或降低 --hdd-bytes"
                    exit 1
                fi
                cap_disk_g=$(( cap_disk_mb / 1024 ))
            fi
        fi

        # 3) 容量一致性：仅 dmidecode 且全部 token 一致时可用单根规则；VM 数须等于 DIMM 根数
        if [ "$probe_source" = "dmidecode" ] && [ "$probe_count" -ge 1 ]; then
            uniform_g=$(dimm_cap_gib_uniform "$probe_caps")
        fi
        module_count="$probe_count"
        if [ -n "$uniform_g" ] && [ "$module_count" -ge 1 ] && [ "$vm_opt" -eq "$module_count" ]; then
            cap_module_mb=$(( uniform_g * module_count * 1024 * MEM_MAX_PCT / 100 ))
            cap_module_g=$(( cap_module_mb / 1024 ))
        fi
        cap_mb=""
        [ -n "$cap_module_mb" ] && cap_mb="$cap_module_mb"
        if [ -n "$cap_mem_mb" ] && { [ -z "$cap_mb" ] || [ "$cap_mem_mb" -lt "$cap_mb" ]; }; then cap_mb="$cap_mem_mb"; fi
        if [ -n "$cap_disk_mb" ] && { [ -z "$cap_mb" ] || [ "$cap_disk_mb" -lt "$cap_mb" ]; }; then cap_mb="$cap_disk_mb"; fi
        [ -n "$cap_mb" ] && cap_g=$(( cap_mb / 1024 ))

        # 4) 单 worker 字节
        if [ -n "$vm_bytes_opt" ]; then
            # 显式 --vm-bytes 原样保留，只告警不裁剪
            bytes_from_preset=0
            local chk_mb=""
            chk_mb=$(parse_size_mb "$vm_bytes_opt")
            case "$chk_mb" in ''|*[!0-9]*) chk_mb=0 ;; esac
            if [ "$chk_mb" -lt 1 ]; then
                echo "参数 --vm-bytes 取值非法：$vm_bytes_opt（应为整数加单位，如 --vm-bytes 51G）"
                exit 1
            fi
            per_mb=$chk_mb
            per_g=$(( per_mb / 1024 ))
            mem_target_desc="内存目标: 未推导（显式 --vm-bytes）"
        elif [ -n "$uniform_g" ] && [ "$vm_opt" -eq "$module_count" ] && [ -n "$cap_mb" ]; then
            # 单根规则：单 worker = 单条容量 − max(6G, 单条容量/8)
            bytes_from_preset=1
            reserve_g=$(( uniform_g / 8 )); [ "$reserve_g" -lt 6 ] && reserve_g=6
            per_g=$(( uniform_g - reserve_g )); [ "$per_g" -lt 1 ] && per_g=1
            old_per_g=$per_g
            while [ $(( per_g * vm_opt * 1024 )) -gt "$cap_mb" ] && [ "$per_g" -gt 1 ]; do
                per_g=$(( per_g - 1 )); clamped=1
            done
            if [ $(( per_g * vm_opt * 1024 )) -gt "$cap_mb" ]; then
                echo "单 worker 已降至 1G 仍超上限（MemTotal ${mem_total_gb_desc}G / ${vm_opt} 根，分配上限 ${cap_g}G），无法压测"
                exit 1
            fi
            vm_bytes_opt="${per_g}G"
            mem_target_desc="内存目标: $(( per_g * vm_opt ))G（实际下发 ${vm_opt}×${per_g}G；单根 ${uniform_g}G − 预留 ${reserve_g}G）"
            if [ "$clamped" -eq 1 ]; then
                echo "已按分配上限裁剪：${vm_opt}×${old_per_g}G → ${vm_opt}×${per_g}G（上限 ${cap_g}G）"
                log_op "mem-clamp dimms=${vm_opt} old_per=${old_per_g}G new_per=${per_g}G cap=${cap_g}G"
                mem_target_desc="${mem_target_desc}，超上限已下调"
            fi
        else
            # 兜底：混合容量 / EDAC 无容量 / 显式 --vm ≠ DIMM 数 → MemTotal×82% 均分，上限 92%
            bytes_from_preset=1
            if [ "$probe_count" -lt 1 ]; then
                fallback_reason="未探测到 DIMM 容量"
            elif [ "$probe_source" = "edac" ]; then
                fallback_reason="EDAC 无容量"
            elif [ "$vm_opt" -ne "$module_count" ]; then
                fallback_reason="显式 --vm=${vm_opt} 与 DIMM 根数=${module_count} 不一致"
            else
                fallback_reason="DIMM 容量混合或无法解析"
            fi
            log_op "mem-fallback reason=${fallback_reason} per=${MEM_TARGET_PCT}% cap=${MEM_TOTAL_MAX_PCT}%"
            if ! mem_plan "$total_mb" "$vm_opt"; then
                echo "单 worker 内存不足 1G（MemTotal $(( total_mb / 1024 ))G / ${vm_opt} 根），无法压测"
                exit 1
            fi
            per_g=$PLAN_PER_GB
            # 三道上限取最小后仍逐 GiB 下调（如 combo 多盘时 cap_disk 更低）
            if [ -n "$cap_mb" ]; then
                old_per_g=$per_g
                while [ $(( per_g * vm_opt * 1024 )) -gt "$cap_mb" ] && [ "$per_g" -gt 1 ]; do
                    per_g=$(( per_g - 1 )); clamped=1
                done
                if [ $(( per_g * vm_opt * 1024 )) -gt "$cap_mb" ]; then
                    echo "单 worker 已降至 1G 仍超上限（MemTotal ${mem_total_gb_desc}G / ${vm_opt} 根，分配上限 ${cap_g}G），无法压测"
                    exit 1
                fi
            fi
            vm_bytes_opt="${per_g}G"
            mem_target_desc="内存目标: $(( per_g * vm_opt ))G（实际下发 ${vm_opt}×${per_g}G；MemTotal ${mem_total_gb_desc}G × ${MEM_TARGET_PCT}% ≈ ${PLAN_TARGET_GB}G，兜底均分；原因: ${fallback_reason}）"
            if [ "$clamped" -eq 1 ]; then
                echo "已按分配上限裁剪：${vm_opt}×${old_per_g}G → ${vm_opt}×${per_g}G（上限 ${cap_g}G）"
                log_op "mem-clamp dimms=${vm_opt} old_per=${old_per_g}G new_per=${per_g}G cap=${cap_g}G"
                mem_target_desc="${mem_target_desc}，超上限已下调"
            fi
        fi

        # 5) 落盘用描述：根数来源与单根容量
        mem_dimm_desc="内存条根数: ${vm_opt}（来源: ${DIMM_SOURCE}）"
        if [ -n "$uniform_g" ] && [ "$vm_opt" -eq "$module_count" ]; then
            dimm_cap=$(dimm_capacity_desc "$probe_caps")
            mem_per_desc="单根容量: ${dimm_cap:-${uniform_g} GiB}"
        elif [ "$probe_source" = "dmidecode" ]; then
            dimm_cap=$(dimm_capacity_desc "$probe_caps")
            mem_per_desc="单根容量: ${dimm_cap:-未探测}"
        elif [ "$probe_source" = "edac" ]; then
            if [ "$bytes_from_preset" -eq 1 ]; then
                mem_per_desc="单根容量: 均分 ${per_g}G（MemTotal / 根数）"
            else
                mem_per_desc="单根容量: 均分（MemTotal / 根数，未推导）"
            fi
        else
            mem_per_desc="单根容量: 未探测"
        fi

        # 6) 分配上限描述与需求核对
        if [ -n "$cap_mb" ]; then
            local cm_txt cn_txt cd_txt
            if [ -n "$cap_module_g" ]; then cm_txt="${cap_module_g}G（模块总容量 × ${MEM_MAX_PCT}%）"; else cm_txt="不生效"; fi
            if [ -n "$total_mb" ]; then
                cn_txt="${cap_mem_g}G（MemTotal × ${MEM_TOTAL_MAX_PCT}%）"
                if [ "$disk_streams_eff" -gt 0 ]; then
                    cd_txt="${cap_disk_g}G（预留 ${disk_streams_eff}×${hdd_bytes_opt}×${DISK_CACHE_FACTOR_PCT}%+${DISK_CACHE_MIN_G}G）"
                else
                    cd_txt="不生效（无 hdd 流）"
                fi
                mem_cap_desc="内存分配上限: ${cap_g}G（取最小：${cm_txt} / ${cn_txt} / 磁盘后 ${cd_txt}）"
            else
                echo "提示：MemTotal 不可用，cap_mem/cap_disk 已跳过，仅按模块容量上限判定"
                mem_cap_desc="内存分配上限: ${cap_g}G（MemTotal 不可用，cap_mem/cap_disk 已跳过；${cm_txt}）"
            fi
            if [ "$bytes_from_preset" -eq 1 ]; then per_mb=$(( per_g * 1024 )); fi
            need_mb=$(( vm_opt * per_mb ))
            local need_txt
            if [ $(( need_mb % 1024 )) -eq 0 ]; then need_txt="$(( need_mb / 1024 ))G"; else need_txt="${need_mb}M"; fi
            if [ "$need_mb" -le "$cap_mb" ]; then
                echo "内存需求 ${need_txt} 未超过分配上限 ${cap_g}G"
                mem_need_desc="内存需求: 实际 ${need_txt}（未超限）"
            elif [ "$bytes_from_preset" -eq 0 ]; then
                echo "警告：内存需求 ${need_txt} 超过物理内存分配上限 ${cap_g}G，可能触发 OOM；按显式参数继续"
                mem_need_desc="内存需求: 实际 ${need_txt}（显式 --vm-bytes，超分配上限）"
            else
                echo "警告：内存需求 ${need_txt} 超过分配上限 ${cap_g}G，按当前参数继续"
                mem_need_desc="内存需求: 实际 ${need_txt}（超分配上限）"
            fi
        elif [ -z "$total_mb" ]; then
            echo "提示：MemTotal 不可用，cap_mem/cap_disk 无法计算，未做内存裁剪"
            mem_cap_desc="内存分配上限: 未知（MemTotal 不可用，cap_mem/cap_disk 已跳过）"
            mem_need_desc="内存需求: 未做内存裁剪（MemTotal 不可用）"
        else
            echo "提示：无法解析 vm-bytes（$vm_bytes_opt），未做内存裁剪"
            mem_cap_desc="内存分配上限: 未知（无法解析 vm-bytes）"
            mem_need_desc="内存需求: 未做内存裁剪（无法解析 vm-bytes）"
        fi

        # 7) 推导依据落盘（显式 --vm-bytes 保留原始值与规范化 MB，不用取整 GiB 冒充）
        local plan_per="" plan_total=""
        if [ "$bytes_from_preset" -eq 1 ]; then
            plan_per="${per_g}G"
            plan_total="$(( per_g * vm_opt ))G"
        else
            plan_per="$vm_bytes_opt"
            if [ $(( per_mb % 1024 )) -eq 0 ]; then
                plan_total="$(( per_mb * vm_opt / 1024 ))G"
            else
                plan_total="$(( per_mb * vm_opt ))M"
            fi
        fi
        log_op "mem-plan dimms=${vm_opt} source=${DIMM_SOURCE} per=${plan_per} total=${plan_total} per_mb=${per_mb}M total_mb=$(( per_mb * vm_opt ))M target=${MEM_TARGET_PCT}% cap=${cap_g:-unknown}G cap_module_g=${cap_module_g:-none} cap_mem_g=${cap_mem_g:-none} cap_disk_g=${cap_disk_g:-none} disk_streams=${disk_streams} peer_disks=${peer_disks} disk_streams_eff=${disk_streams_eff} disk_streams_source=${disk_streams_source} vm_keep=${vm_keep} cpu=${cpu_opt}(nproc=${cpus:-none},physical_cores=${phys_cores}) smt=${smt_txt:-none}"
        mem_plan_desc="内存计划：${vm_opt} 根 × ${plan_per} = ${plan_total}（来源: ${DIMM_SOURCE}；上限 ${cap_g:-未知}G；--vm-keep 常驻）"
    fi

    # 资源计划汇总（显示与落盘）：覆盖 physical_cores/nproc/cpu_workers/dimms/per_worker_g/
    # mem_total_g/cap_module_g/cap_mem_g/cap_disk_g/disk_streams/peer_disks/disk_streams_eff/vm_keep/smt
    local per_worker_g_txt="none" per_worker_mb_txt="none" per_worker_raw="none"
    if [ "$type" = "mem" ] || [ "$type" = "combo" ]; then
        per_worker_mb_txt="$per_mb"
        per_worker_raw="$vm_bytes_opt"
        if [ $(( per_mb % 1024 )) -eq 0 ]; then per_worker_g_txt=$(( per_mb / 1024 )); fi
    fi
    res_plan_line="physical_cores=${phys_cores:-none} nproc=${cpus:-none} cpu_workers=${cpu_opt:-none} dimms=${vm_opt:-none} per_worker_g=${per_worker_g_txt} per_worker_mb=${per_worker_mb_txt} per_worker_raw=${per_worker_raw} mem_total_g=${mem_total_gb_desc:-none} cap_module_g=${cap_module_g:-none} cap_mem_g=${cap_mem_g:-none} cap_disk_g=${cap_disk_g:-none} disk_streams=${disk_streams} peer_disks=${peer_disks} disk_streams_eff=${disk_streams_eff} disk_streams_source=${disk_streams_source} vm_keep=${vm_keep} smt=${smt_txt:-none}"
    log_op "resource-plan $res_plan_line"

    # 建结果目录（时间戳，防覆盖；同秒冲突时顺延）
    local ts dir
    while :; do
        ts=$(date '+%Y%m%d-%H%M%S')
        dir="$STRESS_TEST_ROOT/$ts-$type"
        [ -d "$dir" ] || break
        sleep 1
    done
    mkdir -p "$dir" || { echo "无法创建结果目录：$dir"; exit 1; }

    # 组装 stress 参数与超时秒数（mem/combo 固定追加 --vm-keep，cpu/hdd 不加）
    local stress_args timeout_sec start_time
    case "$type" in
        cpu) stress_args="--cpu $cpu_opt --timeout $timeout" ;;
        mem) stress_args="--vm $vm_opt --vm-bytes $vm_bytes_opt --vm-keep --timeout $timeout" ;;
        hdd) stress_args="--hdd 1 --hdd-bytes $hdd_bytes_opt --timeout $timeout" ;;
        combo) stress_args="--cpu $cpu_opt --vm $vm_opt --vm-bytes $vm_bytes_opt --vm-keep --timeout $timeout" ;;
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
        echo "盘流: peer_disks=$peer_disks disk_streams=$disk_streams disk_streams_eff=$disk_streams_eff disk_streams_source=$disk_streams_source"
        echo "结果目录: $dir"
        case "$type" in
            cpu)
                echo "物理核数: $phys_cores"
                echo "CPU 逻辑线程: ${cpus:-未知}"
                echo "SMT 状态: ${smt_txt}"
                echo "CPU worker 数: $cpu_opt$cpu_note"
                echo "VM keep: $vm_keep"
                echo "HDD 进程数: $disk_streams"
                echo "资源计划: $res_plan_line"
                ;;
            mem)
                echo "物理核数: $phys_cores"
                echo "CPU 逻辑线程: ${cpus:-未知}"
                echo "SMT 状态: ${smt_txt}"
                echo "CPU worker 数: $cpu_opt$cpu_note"
                echo "$mem_dimm_desc"
                echo "$mem_per_desc"
                echo "$mem_target_desc"
                echo "$mem_cap_desc"
                echo "VM worker 数: $vm_opt"
                echo "VM 字节: $vm_bytes_opt"
                echo "VM keep: $vm_keep（mem 固定追加 --vm-keep）"
                echo "HDD 进程数: $disk_streams"
                echo "$mem_need_desc"
                echo "资源计划: $res_plan_line"
                ;;
            hdd)
                echo "HDD 字节: $hdd_bytes_opt"
                echo "HDD 进程数: $disk_streams"
                echo "VM keep: $vm_keep"
                echo "资源计划: $res_plan_line"
                ;;
            combo)
                echo "物理核数: $phys_cores"
                echo "CPU 逻辑线程: ${cpus:-未知}"
                echo "SMT 状态: ${smt_txt}"
                echo "CPU worker 数: $cpu_opt$cpu_note"
                echo "$mem_dimm_desc"
                echo "$mem_per_desc"
                echo "$mem_target_desc"
                echo "$mem_cap_desc"
                echo "VM worker 数: $vm_opt"
                echo "VM 字节: $vm_bytes_opt"
                echo "VM keep: $vm_keep（combo 固定追加 --vm-keep）"
                echo "HDD 字节: $hdd_bytes_opt"
                echo "HDD 进程数: $disk_streams"
                echo "$mem_need_desc"
                echo "资源计划: $res_plan_line"
                ;;
        esac
        # 系统盘口径（FR-10）：仅 hdd/combo 的 --sysdisk 生效
        if [ "$sysdisk" -eq 1 ] && { [ "$type" = "hdd" ] || [ "$type" = "combo" ]; }; then
            echo "压测对象: 系统盘（根文件系统压测）"
            echo "覆盖边界: 不覆盖 /boot、/boot/efi、swap、未分配空间；LVM/RAID 下写入可能跨多个物理盘"
        fi
        echo "错误日志: error.log（stderr 实时记录）"
        echo "命令: stress $stress_args"
    } > "$dir/run-config.txt"

    # 写设备归因文件（FR-6）：数据盘目录 + 系统盘（--sysdisk 时按根文件系统）的设备名，
    # 供 monitor-loop 做 dmesg I/O 错误按盘归因；文件为空表示不过滤
    if [ "$type" = "hdd" ] || [ "$type" = "combo" ]; then
        local dev_sources=("${dirs[@]}")
        [ "$sysdisk" -eq 1 ] && dev_sources+=("/")
        write_devices_file "$dir/devices.txt" "${dev_sources[@]}"
    fi

    {
        echo "==== lscpu ===="
        lscpu 2>&1
        echo "==== free -h ===="
        free -h 2>&1
        echo "==== df -h ===="
        df -h 2>&1
        echo "==== lsblk ===="
        lsblk 2>&1
        echo "==== dmidecode -t 17 ===="
        if ! "$DMI_BIN" -t 17 2>&1; then
            echo "dmidecode 不可用（$DMI_BIN），无法采集内存条信息"
        fi
        echo "==== numactl -H ===="
        if command -v numactl >/dev/null 2>&1; then
            numactl -H 2>&1
        else
            echo "numactl 未安装"
        fi
        echo "==== stress --version ===="
        stress --version 2>&1
    } > "$dir/info-before.txt"

    # 初始化错误日志（表头注释；stderr 实时写入，monitor 巡检追加运行期异常，空=无错误）
    echo "# 压测错误日志（空=无错误） 开始时间: $(now)" > "$dir/error.log"

    # 后台启动 stress（nohup；combo 先起 CPU/内存组合进程，再每盘一条 hdd，--sysdisk 再补系统盘；
    # 目录已在上方全量校验，这里只负责启动）
    : > "$dir/stress.pids"
    if [ "$type" = "combo" ] || [ "$type" = "hdd" ]; then
        if [ "$type" = "combo" ]; then
            nohup sh -c 'stress $1 1>"$2/stress.log" 2>>"$2/error.log"; echo $? > "$2/stress.exitcode"' _ "$stress_args" "$dir" >/dev/null 2>&1 &
            echo "$!" >> "$dir/stress.pids"
        fi
        local i=1 num
        for d in "${dirs[@]}"; do
            num=$(printf "%02d" "$i")
            nohup sh -c 'cd "$1" && stress --hdd 1 --hdd-bytes "$2" --timeout "$3" 1>"$4/stress-HDD$5.log" 2>"$4/error-HDD$5.log"; echo $? > "$4/stress-HDD$5.exitcode"' _ "$d" "$hdd_bytes_opt" "$timeout" "$dir" "$num" >/dev/null 2>&1 &
            echo "$!" >> "$dir/stress.pids"
            i=$((i + 1))
        done
        if [ "$sysdisk" -eq 1 ]; then
            nohup sh -c 'cd "$1" && stress --hdd 1 --hdd-bytes "$2" --timeout "$3" 1>"$4/stress-SYSDISK.log" 2>"$4/error-SYSDISK.log"; echo $? > "$4/stress-SYSDISK.exitcode"' _ "/stresstest-hdd" "$hdd_bytes_opt" "$timeout" "$dir" >/dev/null 2>&1 &
            echo "$!" >> "$dir/stress.pids"
        fi
    else
        nohup sh -c 'stress $1 1>"$2/stress.log" 2>>"$2/error.log"; echo $? > "$2/stress.exitcode"' _ "$stress_args" "$dir" >/dev/null 2>&1 &
        echo "$!" >> "$dir/stress.pids"
    fi

    # 后台启动监控循环（随 stress 全部结束自动退出）
    nohup bash "$SCRIPT" monitor-loop "$dir" >/dev/null 2>&1 &
    echo "$!" > "$dir/monitor.pid"

    # 启动即时快照：记录实际 PID 树、cmdline、cwd、RSS 与实际参数
    runtime_snapshot "$dir" start

    log_op "start type=$type model=$model timeout=$timeout dir=$dir cmd=stress $stress_args"

    # 启动完成提示前打印最终命令与推导依据（设计 6.7），便于操作者当场核对
    echo "资源计划: $res_plan_line"
    [ -n "$mem_plan_desc" ] && echo "$mem_plan_desc"
    [ -n "$mem_cap_desc" ] && echo "$mem_cap_desc"
    echo "命令: stress $stress_args"
    if [ "$type" = "mem" ] || [ "$type" = "combo" ]; then
        local disp_per_mb disp_total mem_derive
        disp_per_mb=$(parse_size_mb "$vm_bytes_opt")
        case "$disp_per_mb" in ''|*[!0-9]*) disp_per_mb=0 ;; esac
        if [ $(( disp_per_mb % 1024 )) -eq 0 ]; then
            disp_total="$(( vm_opt * disp_per_mb / 1024 ))G"
        else
            disp_total="$(( vm_opt * disp_per_mb ))M"
        fi
        if [ "$bytes_from_preset" -eq 1 ]; then
            mem_derive="${vm_opt} 根 × ${vm_bytes_opt} = ${disp_total}（上限 ${cap_g:-未知}G；--vm-keep 常驻）"
        else
            mem_derive="${vm_opt} 根 × ${vm_bytes_opt} = ${disp_total}（显式 --vm-bytes 未推导；--vm-keep 常驻）"
        fi
        echo "推导: CPU ${cpu_opt}${cpu_note}; 内存 ${mem_derive}"
    elif [ "$type" = "cpu" ]; then
        echo "推导: CPU ${cpu_opt}${cpu_note}"
    fi
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
    # 错误日志状态（旧目录无 error.log 时兼容显示；error.log 恒含表头 1 行，行数 ≤1 视为无报错）
    if [ -f "$d/error.log" ]; then
        if [ "$(wc -l < "$d/error.log")" -gt 1 ]; then
            echo "错误日志: error.log（$(wc -l < "$d/error.log") 行，最近条目如下）"
            tail -5 "$d/error.log" | sed 's/^/  /'
        else
            echo "错误日志: 无（未发现报错）"
        fi
    else
        echo "错误日志: 未生成（旧版本目录）"
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
    # 先让监控循环落盘结束状态（TERM 置位停止标记、打断 sleep 等待），最多轮询 2 秒
    if [ -f "$d/monitor.pid" ]; then
        local mpid
        mpid=$(cat "$d/monitor.pid")
        if kill -0 "$mpid" 2>/dev/null; then
            kill -TERM "$mpid" 2>/dev/null
            i=0
            while [ "$i" -lt 10 ] && [ ! -f "$d/status.txt" ] && kill -0 "$mpid" 2>/dev/null; do
                sleep 0.2
                i=$((i + 1))
            done
            if kill -0 "$mpid" 2>/dev/null; then
                kill -KILL "$mpid" 2>/dev/null
            fi
            echo "已停止监控进程 $mpid"
        fi
    fi
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
    # 间隔为空/非数字/0 时回落默认 30 秒，避免后续 duration 乘法与覆盖率除法（除零）中断 review
    case "$interval" in ''|*[!0-9]*|0) interval=30 ;; esac
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

    # 采样空洞：以 run-config 开始时间为锚点，末行时间距开始即实际跨度；只按行数估算会在机器长时间
    # 无采样（事故中仅 1 行）时严重高估覆盖率。无法解析开始时间或末行时间时判不可判定，不做除法
    local last_ts last_epoch span_sec expected coverage hole
    case "$start_epoch" in ''|*[!0-9]*) start_epoch="" ;; esac
    last_ts=$(awk -F',' 'NF{v=$1} END{if(v!="") print v}' "$dir/monitor.csv" 2>/dev/null)
    last_epoch=$(date -d "$last_ts" +%s 2>/dev/null)
    case "$last_epoch" in ''|*[!0-9]*) last_epoch="" ;; esac
    if [ -n "$start_epoch" ] && [ -n "$last_epoch" ]; then
        span_sec=$(( last_epoch - start_epoch ))
        [ "$span_sec" -lt 0 ] && span_sec=0
        expected=$(( span_sec / interval ))
        [ "$expected" -lt 1 ] && expected=1
        coverage=$(( rows * 100 / expected ))
        [ "$coverage" -gt 100 ] && coverage=100   # 展示值封顶 100%，不影响下方 <90 判定
        if [ "$coverage" -lt 90 ]; then
            hole="是（末行距开始 ${span_sec} 秒，应有 ${expected} 点，实际 ${rows} 点，覆盖率 ${coverage}%）"
        else
            hole="无（覆盖率 ${coverage}%）"
        fi
    else
        coverage="不可判定"
        hole="不可判定（开始时间或末行时间无法解析）"
    fi

    # 结论判定（FR-7，严格顺序）：
    # a) error.log 含 dmesg io: → 异常（内核 I/O 错误，盘故障优先，不被 ENOSPC 掩盖）
    # b) ENOSPC（error.log / error-HDD*.log / error-SYSDISK.log）→ 异常（空间不足，非磁盘故障）
    # c) error.log 命中（检测到 stress / dmesg）→ 异常（压测进程/内核报错）
    # d) 按 status.txt：OK→正常、FAILED→异常（退出码非 0）、ABORTED→按 reason、STOPPED→已手动停止
    # e) 无 status.txt → 沿用旧判定（exitcode 缺失/非 0/error.log 命中 → 异常，否则正常）
    local conclusion="正常" ec code err_lines pids_count ec_count abnormal=0 state="" reason="" is_bad=0 oom_field="" err_hit=0 io_hit=0 enospc=0 un_n=0
    pids_count=$(awk 'NF{n++} END{print n+0}' "$dir/stress.pids" 2>/dev/null)
    ec_count=$(ls "$dir"/*.exitcode 2>/dev/null | wc -l)
    if [ "$pids_count" -gt "$ec_count" ]; then
        abnormal=1
    else
        for ec in "$dir"/*.exitcode; do
            [ -f "$ec" ] || continue
            code=$(cat "$ec" 2>/dev/null)
            [ "$code" = "0" ] || { abnormal=1; break; }
        done
    fi
    if [ -f "$dir/error.log" ]; then
        grep -qE '检测到 stress|dmesg' "$dir/error.log" 2>/dev/null && err_hit=1
        grep -qF 'dmesg io:' "$dir/error.log" 2>/dev/null && io_hit=1
    fi
    [ "$abnormal" -eq 0 ] && [ "$err_hit" -eq 1 ] && abnormal=1
    for f in "$dir/error.log" "$dir"/error-HDD*.log "$dir/error-SYSDISK.log"; do
        [ -f "$f" ] || continue
        if grep -q 'No space left on device' "$f" 2>/dev/null; then enospc=1; break; fi
    done
    if [ -f "$dir/error-unattributed.log" ]; then
        un_n=$(awk 'NF{n++} END{print n+0}' "$dir/error-unattributed.log" 2>/dev/null)
        [ -n "$un_n" ] || un_n=0
    fi
    if [ -f "$dir/status.txt" ]; then
        state=$(grep '^state=' "$dir/status.txt" 2>/dev/null | head -1 | cut -d'=' -f2-)
        reason=$(grep '^reason=' "$dir/status.txt" 2>/dev/null | head -1 | cut -d'=' -f2-)
        oom_field=$(grep '^oom=' "$dir/status.txt" 2>/dev/null | head -1 | cut -d'=' -f2-)
    fi
    if [ "$io_hit" -eq 1 ]; then
        conclusion="异常（内核 I/O 错误，见 error.log）"
    elif [ "$enospc" -eq 1 ]; then
        conclusion="异常（空间不足 ENOSPC，非磁盘故障）"
    elif [ "$err_hit" -eq 1 ]; then
        conclusion="异常（压测进程/内核报错，见 error.log）"
    elif [ -f "$dir/status.txt" ]; then
        case "$state" in
            OK)      conclusion="正常" ;;
            FAILED)  conclusion="异常（退出码非 0）" ;;
            ABORTED)
                case "$reason" in
                    oom-killed)       conclusion="异常（内存耗尽被内核杀死）" ;;
                    missing-exitcode) conclusion="异常（进程异常退出未留退出码）" ;;
                    *)                conclusion="异常（进程异常退出）" ;;
                esac ;;
            STOPPED) conclusion="已手动停止" ;;
            *)       [ "$abnormal" -eq 1 ] && conclusion="异常" ;;
        esac
    else
        [ "$abnormal" -eq 1 ] && conclusion="异常"
    fi
    case "$conclusion" in 异常*) is_bad=1 ;; esac

    # ---------- 执行一致性（计划 vs 实际运行证据） ----------
    # 仅 label=60s/600s/periodic 且 found>0 的快照可作执行一致性证据；start/manual
    # （如任务结束后手动 snapshot）只作展示，不足以判 FAIL。
    # 计划/实际字段缺失一律 UNKNOWN；FAIL 仅在原结论为“正常”时改写结论。
    local ap="$dir/actual-params.txt"
    local cons_status="PASS" cons_lines="" cons_fail=0 cons_unknown=0 cons_conflict=0
    local rc_plan rc_cmd tok plan_cpu="" plan_vm="" plan_per_mb="" plan_disk="" plan_peer="" plan_eff="" plan_keep=""
    local ap_main_cpu="" ap_main_vm="" ap_hdd_n="" ap_hdd_dirs="" ap_vm_keep=""
    local ap_label="" ap_found="" ev_ok=0
    local type_is_mem=0 type_is_hdd=0 block="" planned_kb=0
    local hdd_cwd_list="" hdd_cwd_n=0 block_hdd_n=0 cwd_unknown=0 nl=$'\n'
    case "$type" in mem|combo) type_is_mem=1 ;; esac
    case "$type" in hdd|combo) type_is_hdd=1 ;; esac

    rc_plan=$(grep '^资源计划:' "$dir/run-config.txt" 2>/dev/null | head -1 | cut -d' ' -f2-)
    rc_cmd=$(grep '^命令:' "$dir/run-config.txt" 2>/dev/null | head -1 | cut -d' ' -f2-)
    for tok in $rc_plan; do
        case "$tok" in
            cpu_workers=*)      plan_cpu="${tok#*=}" ;;
            dimms=*)            plan_vm="${tok#*=}" ;;
            per_worker_mb=*)    plan_per_mb="${tok#*=}" ;;
            disk_streams=*)     plan_disk="${tok#*=}" ;;
            peer_disks=*)       plan_peer="${tok#*=}" ;;
            disk_streams_eff=*) plan_eff="${tok#*=}" ;;
            vm_keep=*)          plan_keep="${tok#*=}" ;;
        esac
    done

    if [ ! -f "$ap" ]; then
        cons_status="UNKNOWN"
        cons_unknown=1
        cons_lines="未找到 actual-params.txt（旧版本目录或无运行快照）→ UNKNOWN（不改变结论）\n"
    else
        ap_label=$(read_actual_param "$ap" label)
        ap_found=$(read_actual_param "$ap" found)
        case "$ap_found" in ''|*[!0-9]*) ap_found=0 ;; esac
        if [ "$ap_found" -le 0 ]; then
            cons_status="UNKNOWN"
            cons_unknown=1
            cons_lines="actual-params 无有效进程证据（found=${ap_found:-缺失}）→ UNKNOWN（不改变结论）\n"
        elif ! is_evidence_label "$ap_label"; then
            cons_status="UNKNOWN"
            cons_unknown=1
            cons_lines="仅有启动/手动快照（label=${ap_label:-缺失}），不作为执行一致性证据 → UNKNOWN（不改变结论）\n"
        else
            ev_ok=1
        fi
    fi

    if [ "$ev_ok" -eq 1 ]; then
        ap_main_cpu=$(read_actual_param "$ap" main_cpu)
        ap_main_vm=$(read_actual_param "$ap" main_vm)
        ap_vm_keep=$(read_actual_param "$ap" vm_keep)
        ap_hdd_n=$(read_actual_param "$ap" hdd_processes)
        ap_hdd_dirs=$(read_actual_param "$ap" hdd_dirs)
        case "$ap_hdd_n" in ''|*[!0-9]*) ap_hdd_n="" ;; esac
        block=$(snapshot_block_by_label "$dir/runtime-snapshot.txt" "$ap_label")

        # cwd 集合直接从快照的 cwd= 行解析（保留空格/逗号）；hdd_dirs 为逗号拼接，仅作展示。
        hdd_cwd_list=""; hdd_cwd_n=0; block_hdd_n=0; cwd_unknown=0
        if [ -n "$block" ]; then
            local ln cmd cur_cwd
            while IFS= read -r ln; do
                [ -n "$ln" ] || continue
                cmd=$(snapshot_cmdline "$ln")
                [ -n "$cmd" ] || continue
                is_stress_proc "$cmd" || continue
                case " $cmd " in *" --hdd "*) ;; *) continue ;; esac
                block_hdd_n=$((block_hdd_n + 1))
                cur_cwd=$(snapshot_cwd "$ln")
                case "$cur_cwd" in
                    ''|'?') cwd_unknown=1; continue ;;
                esac
                case "$nl$hdd_cwd_list$nl" in
                    *"$nl$cur_cwd$nl"*) ;;
                    *) hdd_cwd_list="${hdd_cwd_list:+$hdd_cwd_list$nl}$cur_cwd"; hdd_cwd_n=$((hdd_cwd_n + 1)) ;;
                esac
            done <<< "$block"
        fi

        # 1) CPU worker
        if [ "$type" = "hdd" ]; then
            cons_lines="${cons_lines}CPU worker: 计划 无（hdd 模式不压 CPU）/ 实际 ${ap_main_cpu:-未记录} → 不适用\n"
        elif [ -z "$plan_cpu" ] || [ "$plan_cpu" = "none" ]; then
            cons_lines="${cons_lines}CPU worker: 计划 未记录 / 实际 ${ap_main_cpu:-未记录} → UNKNOWN\n"
            cons_unknown=1
        elif [ -z "$ap_main_cpu" ]; then
            cons_lines="${cons_lines}CPU worker: 计划 ${plan_cpu} / 实际 未记录 → UNKNOWN\n"
            cons_unknown=1
        elif [ "$ap_main_cpu" = "$plan_cpu" ]; then
            cons_lines="${cons_lines}CPU worker: 计划 ${plan_cpu} / 实际 ${ap_main_cpu} → PASS\n"
        else
            cons_lines="${cons_lines}CPU worker: 计划 ${plan_cpu} / 实际 ${ap_main_cpu:-未记录} → FAIL\n"
            cons_fail=1
        fi

        # 2) VM worker
        if [ "$type_is_mem" -eq 0 ]; then
            cons_lines="${cons_lines}VM worker: 计划 无（${type} 模式无内存压测）/ 实际 ${ap_main_vm:-未记录} → 不适用\n"
        elif [ -z "$plan_vm" ] || [ "$plan_vm" = "none" ]; then
            cons_lines="${cons_lines}VM worker: 计划 未记录 / 实际 ${ap_main_vm:-未记录} → UNKNOWN\n"
            cons_unknown=1
        elif [ -z "$ap_main_vm" ]; then
            cons_lines="${cons_lines}VM worker: 计划 ${plan_vm} / 实际 未记录 → UNKNOWN\n"
            cons_unknown=1
        elif [ "$ap_main_vm" = "$plan_vm" ]; then
            cons_lines="${cons_lines}VM worker: 计划 ${plan_vm} / 实际 ${ap_main_vm} → PASS\n"
        else
            cons_lines="${cons_lines}VM worker: 计划 ${plan_vm} / 实际 ${ap_main_vm:-未记录} → FAIL\n"
            cons_fail=1
        fi

        # 3) mem/combo 必须 --vm-keep（常驻内存）
        if [ "$type_is_mem" -eq 1 ]; then
            if [ -z "$plan_keep" ] || [ "$plan_keep" = "none" ]; then
                cons_lines="${cons_lines}vm_keep: 计划 未记录 / 实际 ${ap_vm_keep:-未记录} → UNKNOWN\n"
                cons_unknown=1
            elif [ -z "$ap_main_vm" ] || [ -z "$ap_vm_keep" ]; then
                cons_lines="${cons_lines}vm_keep: 计划 ${plan_keep} / 实际 未记录 → UNKNOWN\n"
                cons_unknown=1
            elif [ "$ap_vm_keep" = "yes" ] && [ "$plan_keep" = "yes" ]; then
                cons_lines="${cons_lines}vm_keep: 计划 yes / 实际 yes → PASS\n"
            else
                cons_lines="${cons_lines}vm_keep: 计划 ${plan_keep} / 实际 ${ap_vm_keep} → FAIL\n"
                cons_fail=1
            fi
        else
            cons_lines="${cons_lines}vm_keep: 计划 no（${type} 不追加 --vm-keep）/ 实际 ${ap_vm_keep:-未记录} → 不适用\n"
        fi

        # 4) hdd 实际进程数 = cwd 集合数，并与计划 disk_streams 对照
        #    （hdd_dirs 为逗号拼接的展示字段，不参与计数；peer_disks 只展示）
        if [ "$type_is_hdd" -eq 0 ]; then
            cons_lines="${cons_lines}hdd 进程数: 计划 0（${type} 模式不压盘）/ 实际 ${ap_hdd_n:-未记录} → 不适用\n"
        elif [ "$ap_hdd_n" = "0" ] && ! is_mature_label "$ap_label"; then
            # 60s 快照出现 0 个 hdd 进程多为子进程刚启动的竞态，只判 UNKNOWN
            cons_lines="${cons_lines}hdd 进程数: ${ap_label} 快照实际进程 0（子进程可能刚启动）→ UNKNOWN\n"
            cons_unknown=1
        elif [ -z "$ap_hdd_n" ]; then
            cons_lines="${cons_lines}hdd 进程数: actual-params 缺少 hdd_processes 字段 → UNKNOWN\n"
            cons_unknown=1
        else
            local plan_disk_num=-1
            case "$plan_disk" in
                ''|none)   plan_disk_num=-1 ;;
                *[!0-9]*)  plan_disk_num=-1 ;;
                *)         plan_disk_num=$(( 10#$plan_disk )) ;;
            esac
            if [ "$ap_hdd_n" -ne "$hdd_cwd_n" ]; then
                if [ "$cwd_unknown" -eq 1 ] || [ "$block_hdd_n" -eq 0 ]; then
                    cons_lines="${cons_lines}hdd 进程数: 计划 disk_streams=${plan_disk:-未记录} / 实际进程 ${ap_hdd_n}（cwd 集合 ${hdd_cwd_n}）→ UNKNOWN（cwd 不可用或快照缺 hdd 进程）\n"
                    cons_unknown=1
                else
                    cons_lines="${cons_lines}hdd 进程数: 计划 disk_streams=${plan_disk:-未记录}（peer_disks=${plan_peer:-0} 不参与判定）/ 实际进程 ${ap_hdd_n}（cwd 集合 ${hdd_cwd_n}）→ FAIL（进程数与 cwd 集合数不一致）\n"
                    cons_fail=1
                fi
            elif [ "$plan_disk_num" -lt 0 ]; then
                cons_lines="${cons_lines}hdd 进程数: 计划 disk_streams 未记录 / 实际 ${ap_hdd_n}（cwd 集合 ${hdd_cwd_n}）→ UNKNOWN\n"
                cons_unknown=1
            elif [ "$ap_hdd_n" -ne "$plan_disk_num" ]; then
                cons_lines="${cons_lines}hdd 进程数: 计划 disk_streams=${plan_disk_num}（peer_disks=${plan_peer:-0}，effective=${plan_eff:-未记录} 不参与判定）/ 实际 ${ap_hdd_n}（cwd 集合 ${hdd_cwd_n}）→ FAIL\n"
                cons_fail=1
            else
                cons_lines="${cons_lines}hdd 进程数: 计划 disk_streams=${plan_disk}（peer_disks=${plan_peer:-0}，effective=${plan_eff:-未记录} 不参与判定）/ 实际 ${ap_hdd_n}（cwd 集合 ${hdd_cwd_n}）→ PASS\n"
            fi

            # 5) 每个 hdd cwd 均有效且在同一 cwd 集合内（集合来自快照，保留空格/逗号）
            if [ "$ap_hdd_n" -eq 0 ] && [ "$hdd_cwd_n" -eq 0 ]; then
                cons_lines="${cons_lines}每个 hdd cwd 在 dirs 集合内: 无 hdd 进程 → PASS\n"
            elif [ "$cwd_unknown" -eq 1 ]; then
                cons_lines="${cons_lines}每个 hdd cwd 在 dirs 集合内: hdd cwd 为 ? 或空 → UNKNOWN\n"
                cons_unknown=1
            elif [ -z "$block" ]; then
                cons_lines="${cons_lines}每个 hdd cwd 在 dirs 集合内: 缺少 ${ap_label} 快照 → UNKNOWN\n"
                cons_unknown=1
            else
                local bad_cwds="" ln cmd ln_cwd
                while IFS= read -r ln; do
                    [ -n "$ln" ] || continue
                    cmd=$(snapshot_cmdline "$ln")
                    [ -n "$cmd" ] || continue
                    is_stress_proc "$cmd" || continue
                    case " $cmd " in *" --hdd "*) ;; *) continue ;; esac
                    ln_cwd=$(snapshot_cwd "$ln")
                    case "$ln_cwd" in ''|'?') continue ;; esac
                    case "$nl$hdd_cwd_list$nl" in
                        *"$nl$ln_cwd$nl"*) ;;
                        *) bad_cwds="$bad_cwds $ln_cwd" ;;
                    esac
                done <<< "$block"
                if [ "$block_hdd_n" -eq 0 ]; then
                    cons_lines="${cons_lines}每个 hdd cwd 在 dirs 集合内: 快照缺少 hdd 进程证据 → UNKNOWN\n"
                    cons_unknown=1
                elif [ -n "$bad_cwds" ]; then
                    cons_lines="${cons_lines}每个 hdd cwd 在 dirs 集合内: 集合 ${ap_hdd_dirs} / 越界 ${bad_cwds# } → FAIL\n"
                    cons_fail=1
                else
                    cons_lines="${cons_lines}每个 hdd cwd 在 dirs 集合内: 集合 ${ap_hdd_dirs} → PASS\n"
                fi
            fi
        fi

        # 6) 常驻内存 RSS 总量与计划总量误差 ≤15%（仅 600s/periodic 快照可判）
        if [ "$type_is_mem" -eq 0 ]; then
            cons_lines="${cons_lines}常驻内存 RSS: 不适用（${type} 模式无内存计划）\n"
        elif ! is_mature_label "$ap_label"; then
            cons_lines="${cons_lines}常驻内存 RSS: 仅有 ${ap_label} 快照，不作 15% 判定 → UNKNOWN\n"
            cons_unknown=1
        elif [ -z "$ap_main_vm" ]; then
            cons_lines="${cons_lines}常驻内存 RSS: 实际进程未记录 → UNKNOWN\n"
            cons_unknown=1
        elif [ -z "$plan_vm" ] || [ "$plan_vm" = "none" ]; then
            cons_lines="${cons_lines}常驻内存 RSS: 计划 dimms 未记录 → UNKNOWN\n"
            cons_unknown=1
        elif [ -z "$plan_per_mb" ] || [ "$plan_per_mb" = "none" ]; then
            cons_lines="${cons_lines}常驻内存 RSS: 计划 per_worker_mb 未记录 → UNKNOWN\n"
            cons_unknown=1
        else
            local plan_vm_num=0 plan_per_num=0
            case "$plan_vm" in ''|*[!0-9]*) ;; *) plan_vm_num=$(( 10#$plan_vm )) ;; esac
            case "$plan_per_mb" in ''|*[!0-9]*) ;; *) plan_per_num=$(( 10#$plan_per_mb )) ;; esac
            planned_kb=$(( plan_vm_num * plan_per_num * 1024 ))
            if [ "$planned_kb" -le 0 ]; then
                # 兜底：从“命令:”解析 --vm / --vm-bytes
                local c_vm c_bytes c_mb
                c_vm=$(printf '%s' "$rc_cmd" | sed -n 's/.*--vm[[:space:]][[:space:]]*\([0-9][0-9]*\).*/\1/p' | head -1)
                c_bytes=$(printf '%s' "$rc_cmd" | sed -n 's/.*--vm-bytes[[:space:]][[:space:]]*\([0-9][0-9KkMmGgTt]*\).*/\1/p' | head -1)
                c_mb=$(parse_size_mb "$c_bytes")
                case "$c_vm" in ''|*[!0-9]*) c_vm=0 ;; esac
                case "$c_mb" in ''|*[!0-9]*) c_mb=0 ;; esac
                planned_kb=$(( c_vm * c_mb * 1024 ))
            fi
            if [ "$planned_kb" -le 0 ]; then
                cons_lines="${cons_lines}常驻内存 RSS: 计划总量无法解析 → UNKNOWN\n"
                cons_unknown=1
            elif [ -z "$block" ]; then
                cons_lines="${cons_lines}常驻内存 RSS: 计划 ${planned_kb} kB / 实际 缺少 ${ap_label} 快照 → UNKNOWN\n"
                cons_unknown=1
            elif ! printf '%s\n' "$block" | grep -q 'rss_kb='; then
                cons_lines="${cons_lines}常驻内存 RSS: 快照缺少 rss_kb 字段 → UNKNOWN\n"
                cons_unknown=1
            else
                local actual_rss diff pct
                actual_rss=$(printf '%s\n' "$block" | awk 'match($0, / rss_kb=[0-9]+/){v=substr($0,RSTART+8,RLENGTH-8); s+=v} END{printf "%d", s+0}')
                if [ "$actual_rss" -le 0 ]; then
                    cons_lines="${cons_lines}常驻内存 RSS: 实际 RSS 未记录 → UNKNOWN\n"
                    cons_unknown=1
                else
                    diff=$(( actual_rss - planned_kb )); [ "$diff" -lt 0 ] && diff=$(( -diff ))
                    pct=$(( diff * 100 / planned_kb ))
                    if [ "$pct" -le 15 ]; then
                        cons_lines="${cons_lines}常驻内存 RSS: 计划 ${planned_kb} kB / 实际 ${actual_rss} kB（偏差 ${pct}%）→ PASS\n"
                    else
                        cons_lines="${cons_lines}常驻内存 RSS: 计划 ${planned_kb} kB / 实际 ${actual_rss} kB（偏差 ${pct}%）→ FAIL\n"
                        cons_fail=1
                    fi
                fi
            fi
        fi
    fi

    # 汇总判定：FAIL 优先；UNKNOWN 仅提示，不改变既有结论。
    # 仅当原结论仍为“正常”时才改写为执行不一致；已异常/已停止保留原结论与优先级。
    if [ "$cons_fail" -eq 1 ]; then
        cons_status="FAIL"
        if [ "$conclusion" = "正常" ]; then
            conclusion="异常（执行与计划不一致）"
            is_bad=1
        else
            cons_conflict=1
        fi
    elif [ "$cons_unknown" -eq 1 ]; then
        cons_status="UNKNOWN"
    else
        cons_status="PASS"
    fi

    # 生成 summary.txt 并打印
    {
        echo "==== 压测复盘总结 ===="
        echo "结论: $conclusion"
        if [ "$is_bad" -eq 1 ]; then
            echo "异常点:"
            if [ "$pids_count" -gt "$ec_count" ]; then
                echo "  退出码文件缺失（pids 数 ${pids_count} vs exitcode 数 ${ec_count}）"
            fi
            for ec in "$dir"/*.exitcode; do
                [ -f "$ec" ] || continue
                code=$(cat "$ec" 2>/dev/null)
                [ "$code" != "0" ] && echo "  $(basename "$ec") = ${code}"
            done
            if [ "$err_hit" -eq 1 ]; then
                echo "  error.log 命中（前 3 条）:"
                grep -E '检测到 stress|dmesg' "$dir/error.log" 2>/dev/null | head -3 | sed 's/^/    /'
            fi
            if [ "$un_n" -gt 0 ]; then
                echo "  未归因内核 I/O 错误 ${un_n} 条（error-unattributed.log，不计入本盘结论）"
            fi
        fi
        echo "生成时间: $(now)"
        echo "结果目录: $dir"
        echo "类型: $type"
        echo "机型: $model"
        # 系统盘口径（FR-10）：run-config 中存在的覆盖边界说明原样回显
        grep -h '^压测对象:' "$dir/run-config.txt" 2>/dev/null
        grep -h '^覆盖边界:' "$dir/run-config.txt" 2>/dev/null
        echo "开始时间: $start_time"
        echo "计划超时: $plan_timeout"
        echo "预计结束时间: ${end_est:-未知}（按监控覆盖时长估算）"
        echo "监控采样行数: $rows"
        echo "监控覆盖时长: ${duration} 秒（间隔 ${interval} 秒）"
        if [ -f "$dir/status.txt" ]; then
            echo "运行状态: ${state}（${reason}）"
            echo "OOM: $([ "$oom_field" = "yes" ] && echo 是 || echo 否)"
        else
            echo "运行状态: 未记录（无 status.txt）"
        fi
        # 未归因内核 I/O 错误：正常结论也显式提示（未归因不改结论）
        if [ "$is_bad" -ne 1 ] && [ "$un_n" -gt 0 ]; then
            echo "未归因内核 I/O 错误 ${un_n} 条（error-unattributed.log，不计入本盘结论）"
        fi
        echo "采样空洞: ${hole}"
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
        echo "== 错误日志 =="
        if [ -f "$dir/error.log" ]; then
            err_lines=$(wc -l < "$dir/error.log")
            echo "error.log 共 ${err_lines} 行"
            if [ "$err_lines" -gt 1 ]; then head -20 "$dir/error.log" | sed 's/^/  /'; fi
        else
            echo "未生成错误日志（旧版本目录）"
        fi
        echo ""
        echo "== 执行一致性 =="
        echo "结论: $cons_status"
        printf '%b' "$cons_lines" | sed 's/^/  /'
        [ "$cons_conflict" -eq 1 ] && echo "执行一致性: FAIL（详见本节）"
        echo ""
        echo "原始数据: monitor.csv / run-config.txt / info-before.txt / stress*.log / error.log / runtime-snapshot.txt / actual-params.txt"
    } > "$dir/summary.txt"
    cat "$dir/summary.txt"
}

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

# ---------- snapshot（手动抓取运行时证据） ----------

cmd_snapshot() {
    local dir="${1:-}"
    [ -n "$dir" ] || { echo "用法: stress-test.sh snapshot <结果目录>"; exit 1; }
    [ -d "$dir" ] || { echo "结果目录不存在：$dir"; exit 1; }
    runtime_snapshot "$dir" manual
    echo "已写入运行快照：$dir/runtime-snapshot.txt"
    [ -f "$dir/actual-params.txt" ] && echo "实际参数：$dir/actual-params.txt"
}

# ---------- 子命令分发 ----------

CMD="${1:-}"
shift || true
case "$CMD" in
    start)         cmd_start "$@" ;;
    status)        cmd_status ;;
    stop)          cmd_stop ;;
    review)        cmd_review "$@" ;;
    snapshot)      cmd_snapshot "$@" ;;
    monitor-loop)  cmd_monitor_loop "$@" ;;
    *) usage; exit 1 ;;
esac
