
# ---------- 日志（每步写 MOUNT_LOG，格式与 mount-iso.sh 一致） ----------

# 执行命令：stdout/stderr 实时打到控制台并写日志，末尾追加结果行；退出码取命令自身
# 日志不可写只告警，不阻止命令执行（避免日志问题被误报成 umount 失败）
run_log() {
    local rc
    if [ "$DRY_RUN" = "1" ]; then
        echo "（DRY RUN）$*"
        return 0
    fi
    if ! mkdir -p "$(dirname "$MOUNT_LOG")" 2>/dev/null || ! : >> "$MOUNT_LOG" 2>/dev/null; then
        echo "警告：日志不可写（$MOUNT_LOG），本次操作继续执行但不记录日志" >&2
        "$@"
        return $?
    fi
    "$@" 2>&1 | tee -a "$MOUNT_LOG"
    rc=${PIPESTATUS[0]}
    echo "[$(now)] cmd: $* 结果:$rc" >> "$MOUNT_LOG" 2>/dev/null
    return "$rc"
}

# 手工记录一行命令日志（非外部命令类操作）
log_cmd() {
    local desc="$1" rc="${2:-0}"
    [ "$DRY_RUN" = "1" ] && return 0
    mkdir -p "$(dirname "$MOUNT_LOG")" 2>/dev/null
    echo "[$(now)] cmd: $desc 结果:$rc" >> "$MOUNT_LOG" 2>/dev/null
}

# ---------- 系统盘识别（df / 的底层设备，任何分支硬排除） ----------

# 收集 / 所在盘链路（lsblk -s）上所有 TYPE=disk 的整盘名（每行一个），
# 覆盖 LVM/mapper/多路径。解析失败由调用方 fail-closed（拒绝自动选择）。
sys_disk_list_all() {
    local dev base
    dev=$(findmnt -no SOURCE / 2>/dev/null | head -1)
    [ -n "$dev" ] || dev=$(df / 2>/dev/null | awk 'NR==2{print $1}')
    [ -n "$dev" ] || return 0
    base=$("$LSBLK_BIN" -s -P -o NAME,TYPE "$dev" 2>/dev/null | awk '
        function v(line, key,   re, s) {
            re = key "=\""
            if (match(line, re)) {
                s = substr(line, RSTART + length(re))
                return substr(s, 1, index(s, "\"") - 1)
            }
            return ""
        }
        { if (v($0,"TYPE")=="disk" && v($0,"NAME")!="") print v($0,"NAME") }')
    # 非法基名（空/含异常字符）不采纳，由调用方 fail-closed
    printf '%s\n' "$base" | grep -E '^[A-Za-z0-9._-]+$' || true
}

# 是否系统盘（或其中任一整盘）；SYS_DISKS 为空时返回 1（由调用方 fail-closed）
is_sys_disk() {
    local d="$1" s
    [ -n "$SYS_DISKS" ] || return 1
    while IFS= read -r s; do
        [ -n "$s" ] || continue
        [ "$s" = "$d" ] && return 0
    done <<< "$SYS_DISKS"
    return 1
}

# 是否为系统盘（SYS_DISKS 中的任一整盘；识别失败时返回 1，由调用方 fail-closed）
is_sys_disk() {
    local d="$1" s
    [ -n "$SYS_DISKS" ] || return 1
    while IFS= read -r s; do
        [ -n "$s" ] || continue
        [ "$s" = "$d" ] && return 0
    done <<< "$SYS_DISKS"
    return 1
}

# ---------- lsblk -P 键值查询（不依赖列号；空列不会左移） ----------

# 列出全部 USB 整盘：每行 "盘名<TAB>容量<TAB>整盘挂载点"
usb_disk_list() {
    "$LSBLK_BIN" -P -o NAME,SIZE,TYPE,TRAN,MOUNTPOINT 2>/dev/null | awk '
        function v(line, key,   re, s) {
            re = key "=\""
            if (match(line, re)) {
                s = substr(line, RSTART + length(re))
                return substr(s, 1, index(s, "\"") - 1)
            }
            return ""
        }
        {
            if (v($0,"TYPE")=="disk" && v($0,"TRAN")=="usb" && v($0,"NAME")!="")
                print v($0,"NAME") "\t" v($0,"SIZE") "\t" v($0,"MOUNTPOINT")
        }'
}

# 打印该盘所有非空挂载点（去重）；scope: all=整盘+子分区，part=仅子分区，disk=仅整盘
disk_mps() {
    local disk="$1" scope="${2:-all}"
    "$LSBLK_BIN" -P -no NAME,MOUNTPOINT "/dev/$disk" 2>/dev/null | awk -v d="$disk" -v sc="$scope" '
        function v(line, key,   re, s) {
            re = key "=\""
            if (match(line, re)) {
                s = substr(line, RSTART + length(re))
                return substr(s, 1, index(s, "\"") - 1)
            }
            return ""
        }
        {
            mp = v($0,"MOUNTPOINT")
            n = v($0,"NAME")
            if (mp == "") next
            if (mp ~ /^\[.*\]$/) next
            if (sc == "part" && n == d) next
            if (sc == "disk" && n != d) next
            if (seen[mp]++) next
            print mp
        }'
}

# 列出该盘上的 swap 分区（FSTYPE=swap 或 MOUNTPOINT="[SWAP]"），每行一个设备名
disk_swap_devs() {
    local disk="$1"
    "$LSBLK_BIN" -P -no NAME,FSTYPE,MOUNTPOINT "/dev/$disk" 2>/dev/null | awk '
        function v(line, key,   re, s) {
            re = key "=\""
            if (match(line, re)) {
                s = substr(line, RSTART + length(re))
                return substr(s, 1, index(s, "\"") - 1)
            }
            return ""
        }
        {
            n = v($0,"NAME"); fs = v($0,"FSTYPE"); mp = v($0,"MOUNTPOINT")
            if (n == "") next
            if (fs == "swap" || mp == "[SWAP]") print n
        }'
}

# 挂载点列表拼接成一行（多个用 ", " 分隔；无则输出空）
join_mps() {
    awk '{printf "%s%s", (NR > 1 ? ", " : ""), $0} END {if (NR > 0) print ""}'
}

# 占用排查提示（命令不存在则跳过该行）
busy_hints() {
    local mp="$1"
    if command -v fuser >/dev/null 2>&1; then
        echo "  查看占用进程：fuser -vm $mp" >&2
    fi
    if command -v lsof >/dev/null 2>&1; then
        echo "  查看占用进程：lsof +f -- $mp" >&2
    fi
}

# ---------- 卸载 / 断电 ----------

# 卸载单个挂载点；失败打印挂载点与占用排查提示并返回 1
umount_one() {
    local mp="$1"
    echo "卸载挂载点：$mp"
    if [ "$DRY_RUN" = "1" ]; then
        echo "（DRY RUN）umount $mp"
        return 0
    fi
    if run_log umount "$mp"; then
        echo "已卸载：$mp"
        return 0
    fi
    echo "卸载失败：$mp（可能仍被进程或当前目录占用）" >&2
    busy_hints "$mp"
    echo "  可先执行 cd / 离开挂载点，或结束占用进程后重试" >&2
    log_cmd "umount failed: $mp (busy?)" 1
    return 1
}

# 卸载该盘全部挂载点（先子分区后整盘）并校验；单点失败不中断，统一汇总后返回 1
unmount_disk() {
    local disk="$1" part mps left sw mp f
    local -a failed=() swap_devs=()
    part=$(disk_mps "$disk" part)
    mps=$(disk_mps "$disk" disk)

    if [ "$DRY_RUN" = "1" ]; then
        local had=0
        while IFS= read -r mp; do
            [ -n "$mp" ] || continue
            had=1
            echo "（DRY RUN）umount $mp"
        done <<< "$part"
        while IFS= read -r mp; do
            [ -n "$mp" ] || continue
            had=1
            echo "（DRY RUN）umount $mp"
        done <<< "$mps"
        [ "$had" = "1" ] || echo "（DRY RUN）/dev/$disk 当前没有挂载点，无需 umount"
        echo "（DRY RUN）重新读取 /dev/$disk 的 MOUNTPOINT 校验卸载结果"
        return 0
    fi

    while IFS= read -r sw; do
        [ -n "$sw" ] || continue
        swap_devs+=("$sw")
        echo "该分区为 swap：/dev/$sw，请先执行 swapoff /dev/$sw" >&2
        log_cmd "swap detected: /dev/$sw（需先 swapoff）" 1
    done <<< "$(disk_swap_devs "$disk")"

    if [ -z "$part" ] && [ -z "$mps" ]; then
        echo "U 盘 /dev/$disk 当前没有挂载点（无需卸载）"
    fi
    while IFS= read -r mp; do
        [ -n "$mp" ] || continue
        umount_one "$mp" || failed+=("$mp")
    done <<< "$part"
    while IFS= read -r mp; do
        [ -n "$mp" ] || continue
        umount_one "$mp" || failed+=("$mp")
    done <<< "$mps"

    left=$(disk_mps "$disk" all)
    if [ -n "$left" ] || [ "${#failed[@]}" -gt 0 ] || [ "${#swap_devs[@]}" -gt 0 ]; then
        echo "卸载未完成：/dev/$disk 仍有挂载点未卸载或存在需先处理的 swap 分区：" >&2
        if [ -n "$left" ]; then
            while IFS= read -r mp; do
                [ -n "$mp" ] || continue
                echo "  $mp（仍挂载）" >&2
                busy_hints "$mp"
            done <<< "$left"
        fi
        for f in "${failed[@]}"; do
            if ! grep -qxF -- "$f" <<< "$left"; then
                echo "  $f（umount 失败）" >&2
            fi
        done
        for f in "${swap_devs[@]}"; do
            echo "  /dev/$f（swap，请先 swapoff /dev/$f）" >&2
        done
        log_cmd "verify failed: /dev/$disk 仍有挂载点或 swap 未处理" 1
        return 1
    fi
    log_cmd "verify: /dev/$disk 所有挂载点已清空"
    echo "U 盘 /dev/$disk 已卸载，可安全拔出"
    return 0
}

# 断电弹出：$POWEROFF_BIN 失败回退 eject，均失败仅警告（卸载已完成）
poweroff_disk() {
    local disk="$1"
    if [ "$DRY_RUN" = "1" ]; then
        echo "（DRY RUN）$POWEROFF_BIN power-off -b /dev/$disk"
        return 0
    fi
    echo "==== 断电弹出 /dev/$disk ===="
    if run_log "$POWEROFF_BIN" power-off -b "/dev/$disk"; then
        echo "已断电：/dev/$disk（可安全拔出）"
        return 0
    fi
    echo "$POWEROFF_BIN 断电失败，尝试 eject /dev/$disk"
    if command -v eject >/dev/null 2>&1; then
        if run_log eject "/dev/$disk"; then
            echo "eject 断电成功：/dev/$disk（可安全拔出）"
            return 0
        fi
    else
        echo "未找到 eject，跳过回退"
    fi
    echo "警告：断电失败，但已卸载，可安全拔出"
    log_cmd "poweroff failed: /dev/$disk（已卸载，可安全拔出）" 1
    return 0
}
