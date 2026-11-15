#!/bin/bash
# stress-test.sh —— 压测主控脚本（Kylin V10 SP3，三类机型 CPU/内存/硬盘压测）
# 用法：
#   bash stress-test.sh start <cpu|mem|hdd|combo> [--model 5380|7380|7360|auto] [--timeout 10h] \
#       [--cpu N] [--vm N] [--vm-bytes X] [--hdd-bytes X] [--dirs "d1 d2"] [--sysdisk] [--sysdisk-only]
#   说明：hdd 模式无 /mnt/HDD* 挂载点时加 --sysdisk 可仅压系统盘；--sysdisk-only 无论是否有数据盘都只压系统盘；
#         combo 无数据盘时降级为 CPU/内存（或配合 --sysdisk 压系统盘）。
#   bash stress-test.sh status
#   bash stress-test.sh stop
#   bash stress-test.sh review [--dir <结果目录>]
# 环境变量（测试接缝）：
#   STRESS_TEST_ROOT 结果根目录（默认 /root/stress-test）
#   MONITOR_INTERVAL 监控间隔秒（默认 30）
#   CPU_MAX_PCT      CPU worker 推导上限（逻辑线程数的百分比，默认 86）
#   NPROC_BIN        逻辑线程数取值命令（默认 nproc）
#   MEM_TARGET_PCT   内存目标（MemTotal 的百分比，默认 82）
#   MEM_MAX_PCT      内存分配上限（MemTotal 的百分比，默认 85）
#   MEMINFO_FILE     MemTotal 取值文件（默认 /proc/meminfo）
#   DMI_BIN          DIMM 根数探测命令（默认 dmidecode）
#   EDAC_ROOT        DIMM 根数第二探测来源（默认 /sys/devices/system/edac/mc）
# 退出码：0=正常（含无运行任务）；1=用法错误/前置条件不满足
# 说明：全程不 set -e；压测与监控均 nohup 后台运行、全部落盘，可脱离 ssh 会话。

STRESS_TEST_ROOT="${STRESS_TEST_ROOT:-/root/stress-test}"
MONITOR_INTERVAL="${MONITOR_INTERVAL:-30}"
DF_BIN="${DF_BIN:-df}"
DMESG_BIN="${DMESG_BIN:-dmesg}"
MEM_MAX_PCT="${MEM_MAX_PCT:-85}"          # 内存分配上限（MemTotal 的百分比），与解读方案的 80% 达成阈值不是同一概念
MEM_TARGET_PCT="${MEM_TARGET_PCT:-82}"    # 内存目标（MemTotal 的百分比），单 worker 按根数均分后四舍五入
MEMINFO_FILE="${MEMINFO_FILE:-/proc/meminfo}"
CPU_MAX_PCT="${CPU_MAX_PCT:-86}"          # CPU worker 数推导上限（逻辑线程数的百分比）
NPROC_BIN="${NPROC_BIN:-nproc}"           # 逻辑线程数取值入口（测试接缝）
DMI_BIN="${DMI_BIN:-dmidecode}"           # DIMM 根数探测入口（测试接缝）
EDAC_ROOT="${EDAC_ROOT:-/sys/devices/system/edac/mc}"  # DIMM 根数第二探测来源（测试接缝）
SCRIPT="$(readlink -f "$0" 2>/dev/null || echo "$0")"

# ---------- 公共工具 ----------

usage() {
    cat <<'EOF'
用法:
  bash stress-test.sh start <cpu|mem|hdd|combo> [--model 5380|7380|7360|auto] [--timeout 10h] \
      [--cpu N] [--vm N] [--vm-bytes X] [--hdd-bytes X] [--dirs "d1 d2"] [--sysdisk] [--sysdisk-only]
  bash stress-test.sh status
  bash stress-test.sh stop
  bash stress-test.sh review [--dir <结果目录>]

推导规则（不传对应参数时自动生效）:
  CPU worker 数 = floor(逻辑线程数 × 86%)（环境变量 CPU_MAX_PCT，默认 86）
  内存总量 = MemTotal × 82%（环境变量 MEM_TARGET_PCT，默认 82），硬上限 MemTotal × 85%（MEM_MAX_PCT）
  内存条根数 = --vm（默认按 DIMM 自动探测，等于实际内存条根数；探测失败时可手动 --vm N）

示例:
  bash stress-test.sh start cpu                # 按实测逻辑线程推导跑 CPU 压测（默认 10h）
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

# 实测逻辑线程数：优先 NPROC_BIN，失败回退 /proc/cpuinfo 计数，再失败为 1
logical_cpus() {
    local n=""
    n=$("$NPROC_BIN" 2>/dev/null)
    case "$n" in ''|*[!0-9]*) n="" ;; esac
    if [ -z "$n" ] || [ "$n" -lt 1 ]; then
        n=$(grep -c '^processor' /proc/cpuinfo 2>/dev/null)
        case "$n" in ''|*[!0-9]*) n=1 ;; esac
        [ "$n" -lt 1 ] && n=1
    fi
    echo "$n"
}

# 自动推导 CPU worker 数：max(1, floor(nproc × CPU_MAX_PCT%))；显式 --cpu 不走此路径
cpu_workers_auto() {
    local n w
    n=$(logical_cpus)
    w=$(( n * CPU_MAX_PCT / 100 ))
    [ "$w" -lt 1 ] && w=1
    echo "$w"
}

# 机型标称逻辑线程数（仅用于报告标注与交叉校验）
nominal_threads() {
    case "$1" in 5380) echo 64 ;; 7360) echo 96 ;; 7380) echo 128 ;; *) echo "" ;; esac
}

# 实测线程数与机型标称值交叉校验：偏差 >10% 时提示并记日志，不改变任何参数
check_model_threads() {
    local model="$1" n="$2" nominal diff pct hint=""
    nominal=$(nominal_threads "$model")
    [ -n "$nominal" ] || return 0
    case "$n" in ''|*[!0-9]*) return 0 ;; esac
    diff=$(( nominal - n )); [ "$diff" -lt 0 ] && diff=$(( -diff ))
    [ $(( diff * 100 )) -gt $(( nominal * 10 )) ] || return 0
    pct=$(( diff * 100 / nominal ))
    # 实测约为标称一半 → 提示疑似单路 CPU
    if [ $(( n * 2 )) -ge $(( nominal * 9 / 10 )) ] && [ $(( n * 2 )) -le $(( nominal * 11 / 10 )) ]; then
        hint="，疑似单路 CPU（另一路未识别）"
    fi
    echo "警告：机型 $model 标称 ${nominal} 线程，实测 ${n} 线程（偏差 ${pct}%）${hint}；CPU 参数按实测推导"
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
    printf '%s\n' "$1" | LC_ALL=C awk '
        NF {
            v = $0
            gsub(/^[ \t]+|[ \t]+$/, "", v)
            gsub(/[ \t]+/, " ", v)
            n++; seen[v] = 1; last = v
        }
        END {
            if (n == 0) exit
            u = 0
            for (k in seen) u++
            if (u > 1) { printf "混合（按总量均分）"; exit }
            sub(/ MB$/, " MiB", last)
            sub(/ GB$/, " GiB", last)
            sub(/ TB$/, " TiB", last)
            printf "%s", last
        }'
}

# 内存计划：target=MemTotal×MEM_TARGET_PCT%，单 worker=round(target/根数) GiB，回落至硬上限以内。
# 成功返回 0 并设置 PLAN_PER_GB / PLAN_TOTAL_GB / PLAN_TARGET_GB；单 worker <1G 返回 1
mem_plan() {
    local total_mb="$1" workers="$2" target_mb cap_mb per_gb
    case "$total_mb" in ''|*[!0-9]*) return 1 ;; esac
    case "$workers" in ''|*[!0-9]*) return 1 ;; esac
    [ "$workers" -ge 1 ] || return 1
    target_mb=$(( total_mb * MEM_TARGET_PCT / 100 ))
    per_gb=$(( (target_mb + workers * 512) / (workers * 1024) ))
    [ "$per_gb" -lt 1 ] && return 1
    cap_mb=$(( total_mb * MEM_MAX_PCT / 100 ))
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

# ---------- start ----------

cmd_start() {
    local type="$1"
    shift || true
    [ -n "$type" ] || { usage; exit 1; }
    case "$type" in
        cpu|mem|hdd|combo) ;;
        *) echo "未知压测类型：$type（应为 cpu|mem|hdd|combo）"; usage; exit 1 ;;
    esac

    # 参数解析：--model / --timeout / --cpu / --vm / --vm-bytes / --hdd-bytes / --dirs / --sysdisk / --sysdisk-only
    local model="auto" timeout="10h" cpu_opt="" vm_opt="" vm_bytes_opt="" hdd_bytes_opt="" dirs_opt="" dirs_given=0 sysdisk=0 sysdisk_only=0
    local vm_from_preset=1 bytes_from_preset=1   # 显式参数置 0，用于内存裁剪分支判定
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
            --vm)        vm_opt="$2";       vm_from_preset=0; shift 2 ;;
            --vm-bytes)  vm_bytes_opt="$2"; bytes_from_preset=0; shift 2 ;;
            --hdd-bytes) hdd_bytes_opt="$2"; shift 2 ;;
            --dirs)      dirs_opt="$2"; dirs_given=1; shift 2 ;;
            --sysdisk)   sysdisk=1;         shift 1 ;;
            --sysdisk-only) sysdisk=1; sysdisk_only=1; shift 1 ;;
            *) echo "未知参数：$1"; usage; exit 1 ;;
        esac
    done

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
        if [ "$mem_gb" -ge 800 ]; then model=7380
        elif [ "$n" -ge 120 ]; then model=7380
        elif [ "$n" -ge 90 ]; then model=7360
        else model=5380; fi
        echo "检测到机型 $model（仅用于报告标注与交叉校验）"
    fi
    case "$model" in 5380|7380|7360) ;;
        *) echo "未知机型：$model（应为 5380|7380|7360|auto）"; exit 1 ;;
    esac

    # CPU 参数：按实测逻辑线程推导（显式 --cpu 直接使用）；hdd 模式不推导、不校验
    local cpus=0 cpu_note=""
    if [ "$type" != "hdd" ]; then
        cpus=$(logical_cpus)
        check_model_threads "$model" "$cpus"
        if [ -z "$cpu_opt" ]; then
            cpu_opt=$(cpu_workers_auto)
            cpu_note="（nproc ${cpus} × ${CPU_MAX_PCT}%）"
        else
            cpu_note="（显式 --cpu）"
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

    # 内存计划（仅 mem/combo）：--vm = 实测 DIMM 根数，单 worker = round(MemTotal × MEM_TARGET_PCT% / 根数) GiB。
    # 放在结果目录创建之前：探测/推导失败时直接退出，不留下 <时间戳>-mem 结果目录、不启动 stress。
    # 显式 --vm / --vm-bytes 优先且不被改写（显式传空值按“未提供”处理，回退自动探测）。
    local mem_dimm_desc="" mem_per_desc="" mem_target_desc="" mem_plan_desc="" mem_total_gb_desc=""
    if [ "$type" = "mem" ] || [ "$type" = "combo" ]; then
        local total_mb="" dimm_cap=""
        # 1) worker 数 = DIMM 根数
        if [ -n "$vm_opt" ]; then
            case "$vm_opt" in
                ''|*[!0-9]*) echo "参数 --vm 取值非法：$vm_opt（应为正整数根数）"; exit 1 ;;
            esac
            vm_opt=$(( 10#$vm_opt ))      # 前导零按十进制归一化（08→8、010→10）
            [ "$vm_opt" -ge 1 ] || { echo "参数 --vm 取值非法：$vm_opt（应为正整数根数）"; exit 1; }
            DIMM_SOURCE="显式 --vm"
            vm_from_preset=0
        else
            dimm_count_auto >/dev/null     # 当前 shell 执行，DIMM_COUNT / DIMM_SOURCE 可回传
            vm_opt="$DIMM_COUNT"
            vm_from_preset=1
            if [ "$DIMM_SOURCE" = "none" ] || [ "$vm_opt" -lt 1 ]; then
                local sg_total_mb=""
                sg_total_mb=$(mem_total_mb)
                echo "无法探测内存条根数（dmidecode/EDAC 均不可用），本次 ${type} 压测已中止。"
                if [ -n "$sg_total_mb" ] && mem_plan "$sg_total_mb" 16; then
                    echo "已按 MemTotal $(( (sg_total_mb + 512) / 1024 ))G 算好一条可直接执行的命令（16 个 worker 平分 ${MEM_TARGET_PCT}%，总量 ${PLAN_TOTAL_GB}G，未超 ${MEM_MAX_PCT}% 上限）："
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
        # 2) 单 worker 字节：显式 --vm-bytes 原样保留（但必须可解析）；否则按 MemTotal 推导并在 85% 上限内回落
        if [ -n "$vm_bytes_opt" ]; then
            bytes_from_preset=0
            local chk_mb=""
            chk_mb=$(parse_size_mb "$vm_bytes_opt")
            case "$chk_mb" in ''|*[!0-9]*) chk_mb=0 ;; esac
            if [ "$chk_mb" -lt 1 ]; then
                echo "参数 --vm-bytes 取值非法：$vm_bytes_opt（应为整数加单位，如 --vm-bytes 51G）"
                exit 1
            fi
            mem_target_desc="内存目标: 未推导（显式 --vm-bytes）"
        else
            total_mb=$(mem_total_mb)
            if [ -z "$total_mb" ]; then
                echo "无法读取 MemTotal（$MEMINFO_FILE），已中止；请检查该文件或用 --vm-bytes 显式指定"
                exit 1
            fi
            if ! mem_plan "$total_mb" "$vm_opt"; then
                echo "单 worker 内存不足 1G（MemTotal $(( total_mb / 1024 ))G / ${vm_opt} 根），无法压测"
                exit 1
            fi
            vm_bytes_opt="${PLAN_PER_GB}G"
            bytes_from_preset=1
            mem_total_gb_desc=$(( (total_mb + 512) / 1024 ))
            mem_target_desc="内存目标: ${PLAN_TOTAL_GB}G（实际下发 ${vm_opt}×${PLAN_PER_GB}G；理论 MemTotal $(( (total_mb + 512) / 1024 ))G × ${MEM_TARGET_PCT}% ≈ ${PLAN_TARGET_GB}G）"
        fi
        # 3) 落盘用描述：根数来源与单根容量
        mem_dimm_desc="内存条根数: ${vm_opt}（来源: ${DIMM_SOURCE}）"
        case "$DIMM_SOURCE" in
            dmidecode)
                dimm_cap=$(dimm_capacity_desc "$DIMM_CAPS")
                mem_per_desc="单根容量: ${dimm_cap:-未探测}"
                ;;
            edac)
                if [ "$bytes_from_preset" -eq 1 ]; then
                    mem_per_desc="单根容量: 均分 ${PLAN_PER_GB}G（MemTotal / 根数）"
                else
                    mem_per_desc="单根容量: 均分（MemTotal / 根数，未推导）"
                fi
                ;;
            *)  mem_per_desc="单根容量: 未探测" ;;
        esac
        # 4) 推导依据落盘（根目录已创建，operations.log 可用）
        local plan_per="" plan_total="" cur_per_mb=""
        if [ "$bytes_from_preset" -eq 1 ]; then
            plan_per="${PLAN_PER_GB}G"
            plan_total="${PLAN_TOTAL_GB}G"
        else
            cur_per_mb=$(parse_size_mb "$vm_bytes_opt")
            case "$cur_per_mb" in ''|*[!0-9]*) cur_per_mb=0 ;; esac
            plan_per="$vm_bytes_opt"
            plan_total="$(( vm_opt * cur_per_mb / 1024 ))G"
        fi
        log_op "mem-plan dimms=${vm_opt} source=${DIMM_SOURCE} per=${plan_per} total=${plan_total} target=${MEM_TARGET_PCT}% cap=${MEM_MAX_PCT}% cpu=${cpu_opt}(nproc=${cpus},pct=${CPU_MAX_PCT})"
        mem_plan_desc="内存计划：${vm_opt} 根 × ${plan_per} = ${plan_total}（来源: ${DIMM_SOURCE}；MemTotal × ${MEM_TARGET_PCT}%，上限 ${MEM_MAX_PCT}%）"
    fi

    # 建结果目录（时间戳，防覆盖；同秒冲突时顺延）
    local ts dir
    while :; do
        ts=$(date '+%Y%m%d-%H%M%S')
        dir="$STRESS_TEST_ROOT/$ts-$type"
        [ -d "$dir" ] || break
        sleep 1
    done
    mkdir -p "$dir" || { echo "无法创建结果目录：$dir"; exit 1; }

    # 内存分配上限裁剪（仅 mem/combo）：预设值按 MemTotal × MEM_MAX_PCT% 裁剪；
    # 显式 --vm-bytes 不裁剪（只警告），显式 --vm 不改 worker 数（只降单 worker 字节）
    local mem_cap_desc="" mem_need_desc=""
    if [ "$type" = "mem" ] || [ "$type" = "combo" ]; then
        local total_mb per_mb cap_mb need_mb cap_gb total_gb
        total_mb=$(mem_total_mb)
        per_mb=$(parse_size_mb "$vm_bytes_opt")
        if [ -z "$total_mb" ] || [ -z "$per_mb" ]; then
            echo "提示：无法读取 MemTotal 或解析 vm-bytes（$vm_bytes_opt），未做内存裁剪"
            mem_cap_desc="内存分配上限: 未知（无法读取 MemTotal 或解析 vm-bytes）"
            mem_need_desc="内存需求: 未做内存裁剪（无法读取 MemTotal 或解析 vm-bytes）"
        else
            cap_mb=$(( total_mb * MEM_MAX_PCT / 100 ))
            need_mb=$(( vm_opt * per_mb ))
            # 展示口径：MemTotal 与“MemTotal × 上限%”都四舍五入到 GiB；
            # cap_mb 仍按原始 MB 参与裁剪判断，展示值不参与任何比较
            total_gb=$(( (total_mb + 512) / 1024 ))
            cap_gb=$(( (total_gb * MEM_MAX_PCT + 50) / 100 ))
            mem_cap_desc="内存分配上限: ${cap_gb}G（MemTotal ${total_gb}G × ${MEM_MAX_PCT}%）"
            if [ "$need_mb" -le "$cap_mb" ]; then
                echo "内存需求 $(( need_mb / 1024 ))G 未超过分配上限 ${cap_gb}G（MemTotal ${total_gb}G × ${MEM_MAX_PCT}%）"
                mem_need_desc="内存需求: 实际 $(( need_mb / 1024 ))G（未超限）"
            elif [ "$bytes_from_preset" -eq 0 ]; then
                # 分支 C：显式 --vm-bytes，完全不裁剪
                echo "警告：内存需求 $(( need_mb / 1024 ))G 超过物理内存分配上限 ${cap_gb}G（MemTotal ${total_gb}G × ${MEM_MAX_PCT}%），可能触发 OOM；按显式参数继续"
                mem_need_desc="内存需求: 实际 $(( need_mb / 1024 ))G（显式 --vm-bytes，超分配上限）"
            else
                # 分支 A/B：--vm-bytes 来自预设，降单 worker 字节并向下取整到 1G；
                # 仅当 --vm 也来自预设且单 worker 不足 1G 时，才把 worker 数减到上限
                local old_vm="$vm_opt" old_per_mb="$per_mb" old_need_gb new_need_mb new_need_gb
                old_need_gb=$(( need_mb / 1024 ))
                per_mb=$(( (cap_mb / vm_opt) / 1024 * 1024 ))
                if [ "$per_mb" -lt 1024 ]; then
                    if [ "$vm_from_preset" -eq 1 ]; then
                        vm_opt=$(( cap_mb / 1024 )); [ "$vm_opt" -lt 1 ] && vm_opt=1
                    fi
                    per_mb=1024
                fi
                vm_bytes_opt="$(( per_mb / 1024 ))G"
                new_need_mb=$(( vm_opt * per_mb ))
                new_need_gb=$(( new_need_mb / 1024 ))
                if [ "$vm_from_preset" -eq 1 ]; then
                    echo "已按物理内存裁剪内存预设：${old_vm}×$(( old_per_mb / 1024 ))G(${old_need_gb}G) → ${vm_opt}×$(( per_mb / 1024 ))G(${new_need_gb}G)，分配上限 ${cap_gb}G（MemTotal ${total_gb}G × ${MEM_MAX_PCT}%）"
                    log_op "mem-clamp 已按物理内存裁剪内存预设：${old_vm}×$(( old_per_mb / 1024 ))G(${old_need_gb}G) → ${vm_opt}×$(( per_mb / 1024 ))G(${new_need_gb}G)，分配上限 ${cap_gb}G（MemTotal ${total_gb}G × ${MEM_MAX_PCT}%）"
                    mem_need_desc="内存需求: 预设 ${old_need_gb}G / 实际 ${new_need_gb}G（已裁剪）"
                else
                    echo "已按物理内存裁剪单 worker 字节：$(( old_per_mb / 1024 ))G → $(( per_mb / 1024 ))G（worker 数按显式 --vm 保持 ${vm_opt}）"
                    log_op "mem-clamp 已按物理内存裁剪单 worker 字节：$(( old_per_mb / 1024 ))G → $(( per_mb / 1024 ))G（worker 数按显式 --vm 保持 ${vm_opt}）"
                    mem_need_desc="内存需求: 实际 ${new_need_gb}G（显式 --vm，已裁剪单 worker 字节）"
                    # 单 worker 已压到 1G 下限仍超限（worker 数按显式 --vm 不动）→ 仅追加警告
                    if [ "$new_need_mb" -gt "$cap_mb" ]; then
                        echo "警告：安全线不足以支撑该 worker 数（${vm_opt} × $(( per_mb / 1024 ))G = ${new_need_gb}G > 分配上限 ${cap_gb}G），按显式 --vm 继续"
                    fi
                fi
            fi
        fi
    fi

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
            cpu) echo "CPU 逻辑线程: $cpus"; echo "CPU worker 数: $cpu_opt$cpu_note" ;;
            mem) echo "CPU 逻辑线程: $cpus"; echo "CPU worker 数: $cpu_opt$cpu_note"; echo "$mem_dimm_desc"; echo "$mem_per_desc"; echo "$mem_target_desc"; echo "$mem_cap_desc"; echo "VM worker 数: $vm_opt"; echo "VM 字节: $vm_bytes_opt"; echo "$mem_need_desc" ;;
            hdd) echo "HDD 字节: $hdd_bytes_opt" ;;
            combo) echo "CPU 逻辑线程: $cpus"; echo "CPU worker 数: $cpu_opt$cpu_note"; echo "$mem_dimm_desc"; echo "$mem_per_desc"; echo "$mem_target_desc"; echo "$mem_cap_desc"; echo "VM worker 数: $vm_opt"; echo "VM 字节: $vm_bytes_opt"; echo "HDD 字节: $hdd_bytes_opt"; echo "$mem_need_desc" ;;
        esac
        echo "错误日志: error.log（stderr 实时记录）"
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

    log_op "start type=$type model=$model timeout=$timeout dir=$dir cmd=stress $stress_args"

    # 启动完成提示前打印最终命令与推导依据（设计 6.7），便于操作者当场核对
    [ -n "$mem_plan_desc" ] && echo "$mem_plan_desc"
    echo "命令: stress $stress_args"
    if [ "$type" = "mem" ] || [ "$type" = "combo" ]; then
        local disp_per_mb disp_total_gb mem_derive
        disp_per_mb=$(parse_size_mb "$vm_bytes_opt")
        case "$disp_per_mb" in ''|*[!0-9]*) disp_per_mb=0 ;; esac
        disp_total_gb=$(( vm_opt * disp_per_mb / 1024 ))
        if [ "$bytes_from_preset" -eq 1 ]; then
            mem_derive="${vm_opt} 根 × ${vm_bytes_opt} = ${disp_total_gb}G（MemTotal ${mem_total_gb_desc}G × ${MEM_TARGET_PCT}%，上限 ${MEM_MAX_PCT}%）"
        else
            mem_derive="${vm_opt} 根 × ${vm_bytes_opt} = ${disp_total_gb}G（显式 --vm-bytes 未推导）"
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

    # 结论判定：优先读 status.txt（monitor-loop 落盘的结束状态）；旧目录无 status.txt 时沿用原判定：
    # exitcode 文件数与 stress.pids 数一致（无缺失，缺失=进程被 KILL 未及写退出码）且全部为 0、
    # 且 error.log 无报错（不存在/仅表头/不含"检测到"与"dmesg"）→ 正常；否则异常
    local conclusion="正常" ec code err_lines pids_count ec_count abnormal=0 state="" reason="" is_bad=0 oom_field=""
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
    if [ "$abnormal" -eq 0 ] && [ -f "$dir/error.log" ] && grep -qE '检测到 stress|dmesg:' "$dir/error.log" 2>/dev/null; then
        abnormal=1
    fi
    if [ -f "$dir/status.txt" ]; then
        state=$(grep '^state=' "$dir/status.txt" 2>/dev/null | head -1 | cut -d'=' -f2-)
        reason=$(grep '^reason=' "$dir/status.txt" 2>/dev/null | head -1 | cut -d'=' -f2-)
        oom_field=$(grep '^oom=' "$dir/status.txt" 2>/dev/null | head -1 | cut -d'=' -f2-)
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
            if [ -f "$dir/error.log" ] && grep -qE '检测到 stress|dmesg:' "$dir/error.log" 2>/dev/null; then
                echo "  error.log 含报错记录（详见 == 错误日志 == 段）"
            fi
        fi
        echo "生成时间: $(now)"
        echo "结果目录: $dir"
        echo "类型: $type"
        echo "机型: $model"
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
        echo "原始数据: monitor.csv / run-config.txt / info-before.txt / stress*.log / error.log"
    } > "$dir/summary.txt"
    cat "$dir/summary.txt"
}

# ---------- monitor-loop（内部子命令，start 后台调用） ----------

# 结束状态落盘（离线复盘用，免去猜 exitcode 缺失原因）：$1=state $2=reason
write_status() {
    local pc ecc
    pc=$(awk 'NF{n++} END{print n+0}' "$dir/stress.pids" 2>/dev/null)
    ecc=$(ls "$dir"/*.exitcode 2>/dev/null | wc -l)
    {
        echo "state=$1"
        echo "reason=$2"
        echo "pids=$pc exitcodes=$ecc"
        echo "oom=$([ "${oom_seen:-0}" -eq 1 ] && echo yes || echo no)"
        echo "end_time=$(now)"
    } > "$dir/status.txt"
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

    # 巡检状态：上一轮存活数；dmesg 可用性；dmesg 行游标（只读探测，不清空 ring buffer，多批次互不抢证据）
    local prev_alive dmesg_ok=1 oom_seen=0 dmesg_cursor=0 ec code dmesg_hits line logged=""
    prev_alive=$(alive_pids "$pids_file")
    "$DMESG_BIN" >/dev/null 2>&1 || dmesg_ok=0   # 只读探测可用性/权限；失败（非 root/无 dmesg）→ 后续整个检测跳过
    if [ "$dmesg_ok" -eq 1 ]; then
        # 游标基线：当前 ring buffer 行数，之后只读取新增行；落盘便于排查与监控重启后对齐
        dmesg_cursor=$("$DMESG_BIN" 2>/dev/null | wc -l)
        echo "$dmesg_cursor" > "$dir/.dmesg.cursor"
    fi

    # stop 通过 SIGTERM 置位，打断 sleep 等待后立刻落盘 STOPPED 状态
    local stop_flag=0
    trap 'stop_flag=1' TERM

    while :; do
        # 循环体内收到 TERM 时也要立即落盘 STOPPED，否则 stop 会等满一个采样间隔后 KILL 掉监控
        [ "$stop_flag" -eq 1 ] && { write_status STOPPED manual-stop; exit 0; }
        sleep "$interval" & wait $! 2>/dev/null
        if [ "$stop_flag" -eq 1 ]; then write_status STOPPED manual-stop; exit 0; fi
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

        # dmesg 增量 OOM 检测（只读游标，不清空 ring buffer；多批次各自维护游标，互不抢 OOM 证据）
        if [ "$dmesg_ok" -eq 1 ]; then
            dmesg_total=$("$DMESG_BIN" 2>/dev/null | wc -l)
            [ "$dmesg_total" -lt "$dmesg_cursor" ] && dmesg_cursor=0   # ring buffer 回绕/被外部清空 → 从头读
            dmesg_hits=$("$DMESG_BIN" 2>/dev/null | tail -n +$((dmesg_cursor + 1)) | grep -iE 'oom|out of memory|killed process|Killed')
            dmesg_cursor="$dmesg_total"
            echo "$dmesg_cursor" > "$dir/.dmesg.cursor"
            while IFS= read -r line; do
                [ -n "$line" ] || continue
                echo "[$(now)] dmesg: $line" >> "$dir/error.log"
                oom_seen=1
            done <<< "$dmesg_hits"
        fi

        # stress.pids 全部消失 → 监控循环退出
        [ "$alive" -eq 0 ] && break
    done

    # 循环退出（进程全部消失）：exitcode 文件数少于 pids 数（进程被 KILL 未及写退出码）→ 判异常并补记；
    # 否则所有 exitcode 为 0 且 error.log 无"检测到 stress"/"dmesg:" 记录 → 追加正常结束结论（循环遍历判定，避免 grep 空文件误判）
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
        if [ "$all_zero" -eq 1 ] && ! grep -qE '检测到 stress|dmesg:' "$dir/error.log" 2>/dev/null; then
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
