#!/bin/bash
# disk-mount.sh —— 挂载辅助脚本（Kylin V10 SP3，硬盘压测前挂载测试盘）
# 用法：
#   bash disk-mount.sh list                     # 列出块设备，标出系统盘与分区/挂载状态
#   bash disk-mount.sh mount [--disks sdb,sdc]  # 逐盘选择→计划确认→mkfs/挂载到 /mnt/HDDxx
#   bash disk-mount.sh umount [--all]           # 卸载全部已挂载测试盘（--all 跳过确认）
# 环境变量（测试接缝）：
#   DRY_RUN=1          只打印执行计划，不执行任何写操作（含不写 mount.log）
#   SKIP_ROOT_CHECK=1  跳过 root 检查（仅本地测试用）
#   MOUNT_LOG          挂载日志路径（默认 /root/stress-test/mount.log）
# 退出码：0=正常（含取消/无盘可挂）；1=用法错误/前置不满足/选择含系统盘或无效盘
# 说明：全程不 set -e；系统盘（df / 所在盘）任何分支硬跳过；每步操作写 mount.log。

DRY_RUN="${DRY_RUN:-0}"
SKIP_ROOT_CHECK="${SKIP_ROOT_CHECK:-0}"
MOUNT_LOG="${MOUNT_LOG:-/root/stress-test/mount.log}"

now() { date '+%Y-%m-%d %H:%M:%S'; }

usage() {
    cat <<'EOF'
用法:
  bash disk-mount.sh list
  bash disk-mount.sh mount [--disks sdb,sdc]
  bash disk-mount.sh umount [--all]

说明:
  list    列出全部块设备，标出系统盘（永不测试）、分区状态与挂载点
  mount   收集非系统盘 → 交互选择或 --disks（all=全部）→ 打印完整执行计划
           → 单个 y 确认后执行：无分区空盘 mkfs.ext4 -m 0 后挂载到 /mnt/HDDxx，
             已有分区直接挂载分区；已挂载的盘跳过
  umount  列出已挂载测试盘（/mnt/HDD*）并确认后逐个卸载（--all 跳过确认）

测试接缝（本地测试用）:
  DRY_RUN=1           只打印计划不执行
  SKIP_ROOT_CHECK=1   跳过 root 检查
EOF
}

root_check() {
    if [ "$SKIP_ROOT_CHECK" != "1" ] && [ "$(id -u)" -ne 0 ]; then
        echo "请以 root 运行：sudo bash disk-mount.sh"
        exit 1
    fi
}

# ---------- 系统盘识别（df / 的底层设备，任何分支硬跳过） ----------

sys_disk_base() {
    local dev base
    dev=$(df / 2>/dev/null | awk 'NR==2{print $1}')
    [ -n "$dev" ] || return 0
    base=$(lsblk -no pkname "$dev" 2>/dev/null | head -1)
    if [ -n "$base" ]; then echo "$base"; return 0; fi
    echo "$dev" | sed -E 's#^/dev/(sd[a-z]+)[0-9]*$#\1#; s#^/dev/(nvme[0-9]+n[0-9]+)p[0-9]+$#\1#; s#^/dev/(vd[a-z]+)[0-9]*$#\1#; s#^/dev/(mmcblk[0-9]+)p[0-9]+$#\1#; s#^/dev/##'
}

SYS_BASE="$(sys_disk_base)"

# 是否系统盘（或其分区）
is_sys_disk_or_part() {
    local n="$1"
    [ -n "$SYS_BASE" ] || return 1
    [ "$n" = "$SYS_BASE" ] && return 0
    case "$n" in
        "${SYS_BASE}"[0-9]*|"${SYS_BASE}"p[0-9]*) return 0 ;;
    esac
    return 1
}

# ---------- 块设备收集 ----------

# 读取块设备（TYPE=disk 的 sd*/nvme*），输出行：盘符 容量 分区数 已挂载 首分区
disk_lines() {
    lsblk -o NAME,SIZE,TYPE,MOUNTPOINT -l 2>/dev/null | awk '
        $3=="disk" && ($1 ~ /^sd[a-z]+$/ || $1 ~ /^nvme[0-9]+n[0-9]+$/) {
            if (d!="") print d, sz, np, mnt, fp
            d=$1; sz=$2; np=0; mnt=($4!="" ? 1 : 0); fp=""; next
        }
        $3=="part" && d!="" && substr($1,1,length(d))==d {
            np++
            if (fp=="") fp=$1
            if ($4!="") mnt=1
            next
        }
        END { if (d!="") print d, sz, np, mnt, fp }
    '
}

DISK_NAMES=() DISK_SIZES=() DISK_NPARTS=() DISK_MOUNTED=() DISK_FPARTS=()

collect_non_sys_disks() {
    local line n
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        set -- $line
        n="$1"
        is_sys_disk_or_part "$n" && continue   # 系统盘硬跳过
        DISK_NAMES+=("$n"); DISK_SIZES+=("$2"); DISK_NPARTS+=("$3"); DISK_MOUNTED+=("$4"); DISK_FPARTS+=("$5")
    done < <(disk_lines)
}

disk_is_known() {
    local i
    for i in "${!DISK_NAMES[@]}"; do
        [ "${DISK_NAMES[$i]}" = "$1" ] && return 0
    done
    return 1
}

disk_is_mounted() {
    local i
    for i in "${!DISK_NAMES[@]}"; do
        [ "${DISK_NAMES[$i]}" = "$1" ] && [ "${DISK_MOUNTED[$i]}" = "1" ] && return 0
    done
    return 1
}

disk_size() {
    local i
    for i in "${!DISK_NAMES[@]}"; do
        [ "${DISK_NAMES[$i]}" = "$1" ] && { echo "${DISK_SIZES[$i]}"; return 0; }
    done
}

disk_fpart() {
    local i
    for i in "${!DISK_NAMES[@]}"; do
        [ "${DISK_NAMES[$i]}" = "$1" ] && { echo "${DISK_FPARTS[$i]}"; return 0; }
    done
}

disk_status() {
    local i
    for i in "${!DISK_NAMES[@]}"; do
        [ "${DISK_NAMES[$i]}" = "$1" ] || continue
        if [ "${DISK_MOUNTED[$i]}" = "1" ]; then echo "已挂载（跳过）"
        elif [ "${DISK_NPARTS[$i]}" -gt 0 ]; then echo "有分区 ${DISK_FPARTS[$i]}（将直接挂载）"
        else echo "未分区空盘（将 mkfs.ext4 -m 0）"; fi
        return 0
    done
    echo "未知"
    return 1
}

trim() {
    local v="$1"
    v="${v#"${v%%[![:space:]]*}"}"
    v="${v%"${v##*[![:space:]]}"}"
    printf '%s' "$v"
}

# ---------- 公共：执行并写 mount.log ----------

# 执行一条命令，输出实时可见，并追加 "[时间] cmd: ... 结果:$?" 到 MOUNT_LOG
run_log() {
    local rc out
    out=$("$@" 2>&1)
    rc=$?
    [ -n "$out" ] && echo "$out"
    echo "[$(now)] cmd: $* 结果:$rc" >> "$MOUNT_LOG"
    return "$rc"
}

# ---------- list ----------

cmd_list() {
    collect_non_sys_disks
    echo "==== 块设备一览（lsblk） ===="
    lsblk -o NAME,SIZE,TYPE,MOUNTPOINT 2>/dev/null | awk -v sys="$SYS_BASE" '
        NR==1 { print; next }
        {
            mark=""
            if (sys!="" && $1==sys) mark="（系统盘，跳过）"
            else if (sys!="" && index($1,sys)==1 && length($1)>length(sys)) mark="（系统盘分区，跳过）"
            print $0, mark
        }'
    echo
    echo "==== 状态说明 ===="
    if [ -n "$SYS_BASE" ]; then
        echo "系统盘：$SYS_BASE（df / 底层设备，永不测试）"
    else
        echo "系统盘：未知（无法从 df / 识别）"
    fi
    if [ "${#DISK_NAMES[@]}" -eq 0 ]; then
        echo "未发现非系统盘（无 /dev/sd* 或 /dev/nvme* 块设备）"
    else
        echo "非系统盘：${DISK_NAMES[*]}（共 ${#DISK_NAMES[@]} 块）"
        local i
        for i in "${!DISK_NAMES[@]}"; do
            echo "  ${DISK_NAMES[$i]}  ${DISK_SIZES[$i]}  $(disk_status "${DISK_NAMES[$i]}")"
        done
    fi
}

# ---------- mount ----------

cmd_mount() {
    local disks_opt=""
    while [ $# -gt 0 ]; do
        case "$1" in
            --disks) if [ $# -lt 2 ]; then echo "--disks 缺少参数"; usage; exit 1; fi; disks_opt="$2"; shift 2 ;;
            *) echo "未知参数：$1"; usage; exit 1 ;;
        esac
    done

    root_check
    collect_non_sys_disks

    if [ "${#DISK_NAMES[@]}" -eq 0 ]; then
        echo "未发现非系统盘（无 /dev/sd* 或 /dev/nvme* 块设备），无需挂载"
        exit 1
    fi

    # ---------- 选择纳入盘 ----------
    local sel=""
    if [ -n "$disks_opt" ]; then
        sel="$disks_opt"
    elif [ -t 0 ]; then
        echo "==== 可用非系统盘 ===="
        local i
        for i in "${!DISK_NAMES[@]}"; do
            echo "  ${DISK_NAMES[$i]}  ${DISK_SIZES[$i]}  $(disk_status "${DISK_NAMES[$i]}")"
        done
        printf "输入要纳入测试的盘符（逗号分隔，all 全部）："
        IFS= read -r sel || true
    else
        echo "非交互模式（无终端）必须指定盘：bash disk-mount.sh mount --disks sdb,sdc"
        exit 1
    fi

    # ---------- 解析选择 ----------
    local chosen=() raws item
    if [ "$sel" = "all" ]; then
        chosen=("${DISK_NAMES[@]}")
    else
        IFS=',' read -ra raws <<< "$sel"
        for item in "${raws[@]}"; do
            item=$(trim "$item")
            [ -n "$item" ] || continue
            item="${item#/dev/}"
            chosen+=("$item")
        done
    fi
    [ "${#chosen[@]}" -gt 0 ] || { echo "未选择任何盘"; exit 1; }

    # ---------- 校验：含系统盘拒绝；无效盘报错 ----------
    local c
    for c in "${chosen[@]}"; do
        if is_sys_disk_or_part "$c"; then
            echo "拒绝：$c 是系统盘（$SYS_BASE），永不纳入测试"
            exit 1
        fi
        if ! disk_is_known "$c"; then
            echo "盘不存在或不是非系统块设备：$c"
            exit 1
        fi
    done

    # ---------- 打印完整执行计划 ----------
    local num=0 dev mntp fpart act
    echo "==== 挂载执行计划 ===="
    for c in "${chosen[@]}"; do
        dev="/dev/$c"
        if disk_is_mounted "$c"; then
            echo "  跳过  $dev  $(disk_size "$c")  已挂载（跳过）"
            continue
        fi
        num=$((num + 1))
        mntp=$(printf "/mnt/HDD%02d" "$num")
        fpart=$(disk_fpart "$c")
        if [ -n "$fpart" ]; then
            act="有分区：直接挂载 /dev/$fpart → $mntp"
        else
            act="无分区空盘：mkfs.ext4 -m 0 $dev 后挂载 → $mntp"
        fi
        echo "  $(printf "%02d" "$num")  $dev  $(disk_size "$c")  $act"
    done
    if [ "$num" -eq 0 ]; then
        echo "所选盘均已挂载，无需操作"
        exit 0
    fi
    if [ "$DRY_RUN" = "1" ]; then
        echo "（DRY RUN，未执行）"
        exit 0
    fi

    # ---------- 单个 y 确认 ----------
    local ans=""
    printf "请确认执行以上计划（y/N）："
    IFS= read -r ans || true
    case "$ans" in
        y|Y) ;;
        *) echo "已取消，未执行任何操作"; exit 0 ;;
    esac

    # ---------- 执行 ----------
    mkdir -p "$(dirname "$MOUNT_LOG")" || { echo "无法创建日志目录：$(dirname "$MOUNT_LOG")"; exit 1; }
    local n=0
    for c in "${chosen[@]}"; do
        if disk_is_mounted "$c"; then
            echo "跳过已挂载盘：$c"
            continue
        fi
        n=$((n + 1))
        mntp=$(printf "/mnt/HDD%02d" "$n")
        run_log mkdir -p "$mntp"
        fpart=$(disk_fpart "$c")
        if [ -n "$fpart" ]; then
            if run_log mount "/dev/$fpart" "$mntp"; then
                echo "已挂载 $c → $mntp"
            else
                echo "挂载失败：$c → $mntp（结果非 0，见 mount.log）"
            fi
        else
            if run_log mkfs.ext4 -m 0 "/dev/$c"; then
                if run_log mount "/dev/$c" "$mntp"; then
                    echo "已挂载 $c → $mntp"
                else
                    echo "挂载失败：$c → $mntp（结果非 0，见 mount.log）"
                fi
            else
                echo "格式化失败：$c（结果非 0，跳过，见 mount.log）"
            fi
        fi
    done
    echo "全部完成。挂载日志：$MOUNT_LOG"
}

# ---------- umount ----------

cmd_umount() {
    local all=0
    while [ $# -gt 0 ]; do
        case "$1" in
            --all) all=1; shift ;;
            *) echo "未知参数：$1"; usage; exit 1 ;;
        esac
    done
    root_check

    # 收集已挂载测试点（/mnt/HDD*）
    local points=() p
    while IFS= read -r p; do
        [ -n "$p" ] && points+=("$p")
    done < <(df -P 2>/dev/null | awk 'NR>1 && $6 ~ /^\/mnt\/HDD/ {print $6}')

    if [ "${#points[@]}" -eq 0 ]; then
        echo "没有已挂载的测试盘（/mnt/HDD*）"
        exit 0
    fi

    echo "==== 已挂载测试盘 ===="
    local i dev
    for i in "${!points[@]}"; do
        dev=$(df -P "${points[$i]}" 2>/dev/null | awk 'NR==2{print $1}')
        echo "  $((i + 1))  ${points[$i]}  （${dev:-未知设备}）"
    done

    if [ "$DRY_RUN" = "1" ]; then
        echo "（DRY RUN，未执行）"
        exit 0
    fi

    if [ "$all" -ne 1 ]; then
        local ans=""
        printf "确认卸载以上全部测试盘（y/N）："
        IFS= read -r ans || true
        case "$ans" in
            y|Y) ;;
            *) echo "已取消"; exit 0 ;;
        esac
    fi

    mkdir -p "$(dirname "$MOUNT_LOG")" || { echo "无法创建日志目录：$(dirname "$MOUNT_LOG")"; exit 1; }
    for p in "${points[@]}"; do
        if run_log umount "$p"; then
            echo "已卸载：$p"
        else
            echo "卸载失败：$p（结果非 0，见 mount.log）"
        fi
    done
    echo "全部完成。挂载日志：$MOUNT_LOG"
}

# ---------- 子命令分发 ----------

CMD="${1:-}"
shift || true
case "$CMD" in
    list)   cmd_list ;;
    mount)  cmd_mount "$@" ;;
    umount) cmd_umount "$@" ;;
    *) usage; exit 1 ;;
esac
