
# ---------- 系统盘识别（df / 的底层设备，任何分支硬排除；逻辑同 disk-mount.sh） ----------

sys_disk_base() {
    # 优先：用 findmnt 取 / 的实际设备，再对设备做反向解析（lsblk -s），
    # 取链路上第一个 TYPE=disk 的整盘，覆盖 LVM/mapper/多路径等布局。
    # 解析使用 -P 键值格式，避免空列导致字段错位。
    local dev base
    dev=$(findmnt -no SOURCE / 2>/dev/null | head -1)
    [ -n "$dev" ] || dev=$(df / 2>/dev/null | awk 'NR==2{print $1}')
    [ -n "$dev" ] || return 0
    base=$($LSBLK_BIN -s -P -o NAME,TYPE "$dev" 2>/dev/null | awk '
        function v(line, key,   re, s) {
            re = key "=\""
            if (match(line, re)) {
                s = substr(line, RSTART + length(re))
                return substr(s, 1, index(s, "\"") - 1)
            }
            return ""
        }
        { if (v($0,"TYPE")=="disk" && v($0,"NAME")!="") {print v($0,"NAME"); exit} }')
    if [ -n "$base" ]; then
        echo "$base"
        return 0
    fi
    # 兜底：正则去分区号（sd*/nvme* 等直连盘）；解析失败时明确告警，不静默
    echo "警告：无法通过 findmnt/lsblk 解析系统盘（/ = $dev），回退到设备名推断" >&2
    echo "$dev" | sed -E 's#^/dev/(sd[a-z]+)[0-9]*$#\1#; s#^/dev/(nvme[0-9]+n[0-9]+)p[0-9]+$#\1#; s#^/dev/(vd[a-z]+)[0-9]*$#\1#; s#^/dev/(mmcblk[0-9]+)p[0-9]+$#\1#; s#^/dev/##'
}

SYS_BASE="$(sys_disk_base)"

# 是否系统盘（或其分区）：基于 NAME / PKNAME 精确判定，避免 sdaa1、nvme0n10n1 前缀误判
is_sys_disk_or_part() {
    local n="$1" pk
    [ -n "$SYS_BASE" ] || return 1
    [ "$n" = "$SYS_BASE" ] && return 0
    pk=$($LSBLK_BIN -P -no NAME,PKNAME "/dev/$n" 2>/dev/null | awk -v nn="$n" '
        function v(line, key,   re, s) {
            re = key "=\""
            if (match(line, re)) {
                s = substr(line, RSTART + length(re))
                return substr(s, 1, index(s, "\"") - 1)
            }
            return ""
        }
        { if (v($0,"NAME")==nn) {print v($0,"PKNAME"); exit} }')
    [ -n "$pk" ] && [ "$pk" = "$SYS_BASE" ] && return 0
    return 1
}

# ---------- 日志（每步写 MOUNT_LOG，格式 [时间] cmd: ... 结果:$?） ----------

# 执行命令：stdout/stderr 实时打到控制台并写日志，末尾追加结果行；退出码取命令自身
run_log() {
    local rc
    if [ "$DRY_RUN" = "1" ]; then
        echo "（DRY RUN）$*"
        return 0
    fi
    mkdir -p "$(dirname "$MOUNT_LOG")" 2>/dev/null || { echo "无法创建日志目录：$(dirname "$MOUNT_LOG")"; return 1; }
    "$@" 2>&1 | tee -a "$MOUNT_LOG"
    rc=${PIPESTATUS[0]}
    echo "[$(now)] cmd: $* 结果:$rc" >> "$MOUNT_LOG"
    return "$rc"
}

# 手工记录一行命令日志（非外部命令类操作）
log_cmd() {
    local desc="$1" rc="${2:-0}"
    [ "$DRY_RUN" = "1" ] && return 0
    mkdir -p "$(dirname "$MOUNT_LOG")" 2>/dev/null
    echo "[$(now)] cmd: $desc 结果:$rc" >> "$MOUNT_LOG"
}

# ---------- U 盘检测 / 挂载 ----------

# 是否已挂载到 $USB_MOUNT_POINT：lsblk -P 键值解析（不依赖列号），再 findmnt / df 兜底
# 比较前统一 norm_path（去掉结尾 /），避免 /mnt/usb/ 与 /mnt/usb 被判为不同路径
usb_is_mounted() {
    local mp target
    target=$(norm_path "$USB_MOUNT_POINT")
    [ -n "$target" ] || return 1
    mp=$($LSBLK_BIN -P -o NAME,MOUNTPOINT 2>/dev/null | awk -v m="$target" '
        function v(line, key,   re, s) {
            re = key "=\""
            if (match(line, re)) {
                s = substr(line, RSTART + length(re))
                return substr(s, 1, index(s, "\"") - 1)
            }
            return ""
        }
        { if (v($0,"MOUNTPOINT")==m) {print m; exit} }')
    [ -n "$mp" ] && return 0
    if command -v findmnt >/dev/null 2>&1; then
        mp=$(findmnt -no TARGET "$USB_MOUNT_POINT" 2>/dev/null | head -1)
        [ -n "$mp" ] && [ "$(norm_path "$mp")" = "$target" ] && return 0
    fi
    df -P "$USB_MOUNT_POINT" 2>/dev/null | awk -v m="$target" 'NR==2 && $6==m {found=1} END {exit found?0:1}'
}

# 返回第一个 USB 整盘（TYPE=disk 且 TRAN=usb，硬排除系统盘）；-P 键值解析，空列不错位
usb_disk() {
    local d found=""
    while IFS= read -r d; do
        [ -n "$d" ] || continue
        is_sys_disk_or_part "$d" && continue
        found="$d"
        break
    done < <($LSBLK_BIN -P -o NAME,SIZE,TYPE,MOUNTPOINT,TRAN 2>/dev/null | awk '
        function v(line, key,   re, s) {
            re = key "=\""
            if (match(line, re)) {
                s = substr(line, RSTART + length(re))
                return substr(s, 1, index(s, "\"") - 1)
            }
            return ""
        }
        { if (v($0,"TYPE")=="disk" && v($0,"TRAN")=="usb") print v($0,"NAME") }')
    [ -n "$found" ] && echo "$found"
}

# 返回该盘第一个有效分区（PKNAME==盘名、TYPE=part 且 FSTYPE 非空，跳过扩展容器分区）；
# 无有效分区则返回整盘名（直接挂整盘）
usb_first_part() {
    local disk="$1" p
    p=$($LSBLK_BIN -P -no NAME,TYPE,PKNAME,FSTYPE "/dev/$disk" 2>/dev/null | awk -v d="$disk" '
        function v(line, key,   re, s) {
            re = key "=\""
            if (match(line, re)) {
                s = substr(line, RSTART + length(re))
                return substr(s, 1, index(s, "\"") - 1)
            }
            return ""
        }
        { if (v($0,"TYPE")=="part" && v($0,"PKNAME")==d && v($0,"FSTYPE")!="") {print v($0,"NAME"); exit} }')
    [ -n "$p" ] && { echo "$p"; return 0; }
    echo "$disk"
}

# 返回某设备当前的 MOUNTPOINT（未挂载则输出空）
usb_mountpoint_of() {
    local dev="$1"
    $LSBLK_BIN -P -no NAME,MOUNTPOINT "/dev/$dev" 2>/dev/null | awk -v d="$dev" '
        function v(line, key,   re, s) {
            re = key "=\""
            if (match(line, re)) {
                s = substr(line, RSTART + length(re))
                return substr(s, 1, index(s, "\"") - 1)
            }
            return ""
        }
        { if (v($0,"NAME")==d) {print v($0,"MOUNTPOINT"); exit} }'
}

# 返回设备的 TRAN（未知输出空）
dev_tran() {
    local dev="$1" name
    name=$(basename "$dev")
    $LSBLK_BIN -P -no NAME,TRAN "/dev/$name" 2>/dev/null | awk -v n="$name" '
        function v(line, key,   re, s) {
            re = key "=\""
            if (match(line, re)) {
                s = substr(line, RSTART + length(re))
                return substr(s, 1, index(s, "\"") - 1)
            }
            return ""
        }
        { if (v($0,"NAME")==n) {print v($0,"TRAN"); exit} }'
}

# 挂载 U 盘到 $USB_MOUNT_POINT（已挂载跳过）；无 USB 盘返回 1
mount_usb() {
    local disk part mp
    disk=$(usb_disk)
    if [ -z "$disk" ]; then
        echo "未检测到 USB 盘（lsblk 中 TYPE=disk 且 TRAN=usb 的设备，已排除系统盘）" >&2
        return 1
    fi
    if usb_is_mounted; then
        echo "U 盘已挂载到 $USB_MOUNT_POINT，跳过挂载"
        return 0
    fi
    part=$(usb_first_part "$disk")
    mp=$(usb_mountpoint_of "$part")
    if [ -n "$mp" ] && [ "$(norm_path "$mp")" != "$(norm_path "$USB_MOUNT_POINT")" ]; then
        echo "U 盘 /dev/$part 已挂载在 $mp，请先 umount 后重试" >&2
        return 1
    fi
    echo "检测到 U 盘：$disk（将挂载设备 /dev/$part → $USB_MOUNT_POINT）"
    if [ "$DRY_RUN" = "1" ]; then
        echo "（DRY RUN）mkdir -p $USB_MOUNT_POINT"
        echo "（DRY RUN）mount /dev/$part $USB_MOUNT_POINT"
        return 0
    fi
    if ! run_log mkdir -p "$USB_MOUNT_POINT"; then
        echo "创建挂载点失败：$USB_MOUNT_POINT"
        return 1
    fi
    if run_log mount "/dev/$part" "$USB_MOUNT_POINT"; then
        echo "已挂载 /dev/$part → $USB_MOUNT_POINT"
        return 0
    fi
    echo "挂载失败：/dev/$part → $USB_MOUNT_POINT（结果非 0，见 mount.log）"
    return 1
}
