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

# ---------- 盘定位表（disk-map.txt）与 SN 采集 ----------

# 读整盘 SN（sysfs 零依赖，全部经 SYSFS_ROOT 读取；SYSFS_ROOT 默认 /sys，测试可注入）：
#   nvme*：readlink 定位 block 节点的 device 软链 → 取 nvmeX → 读 class/nvme/<nvmeX>/device/serial
#   sd*/mmcblk*：读 class/block/<dev>/device/serial（文件存在才读，否则空串）
#   dm- 等映射名/其他：输出空串
sn_of_dev() {
    local dev="$1" sysfs="${SYSFS_ROOT:-/sys}" ctrl="" serial_file=""
    case "$dev" in
        nvme*)
            ctrl=$(basename "$(readlink -f "$sysfs/class/block/$dev/device" 2>/dev/null)" 2>/dev/null)
            case "$ctrl" in
                nvme[0-9]*) serial_file="$sysfs/class/nvme/$ctrl/device/serial" ;;
                *) echo ""; return ;;
            esac
            ;;
        sd*|mmcblk*)
            serial_file="$sysfs/class/block/$dev/device/serial"
            ;;
        *)
            echo ""; return ;;
    esac
    [ -r "$serial_file" ] || { echo ""; return; }
    cat "$serial_file" 2>/dev/null
}

# 写盘定位基础表 disk-map.txt：全机数据盘（TYPE=disk）每行 "设备名 | SN | 挂载点"，
# SN 以 sn_of_dev 为准（sysfs 零依赖）；排除系统盘（根文件系统所在盘）与 dm-/md- 映射名；
# 覆盖全机数据盘（含未挂载盘，挂载点留空）；lsblk 不可用则 df 兜底（仅已挂载设备）；
# 输出为覆盖写，旧目录无此文件时优雅降级（不报错）
write_disk_map() {
    local out="$1"
    local sys_src="" sys_disk="" name type mp sn src seen=""
    # 系统盘口径：根文件系统所在整盘（LVM/RAID 根无法归到单一整盘时为空，即不排除）
    sys_src=$("${DF_BIN:-df}" -h / 2>/dev/null | awk 'NR==2 {print $1}')
    sys_disk=$(whole_disk_of "$(basename "$sys_src" 2>/dev/null)" 2>/dev/null)
    if "${LSBLK_BIN:-lsblk}" -o NAME,TYPE,MOUNTPOINT >/dev/null 2>&1; then
        while read -r name type mp; do
            [ "$type" = "disk" ] || continue
            case "$name" in dm-*|md*) continue ;; esac
            [ -n "$sys_disk" ] && [ "$name" = "$sys_disk" ] && continue
            sn=$(sn_of_dev "$name")
            printf '%s | %s | %s\n' "$name" "$sn" "$mp"
        done < <("${LSBLK_BIN:-lsblk}" -o NAME,TYPE,MOUNTPOINT 2>/dev/null | awk '$2=="disk" {print $1, $2, $3}')
    else
        # 兜底：df 枚举已挂载设备（未挂载盘无法枚举），挂载点取 df 第 6 列；按整盘去重。
        # 已是整盘名（df 可能直接挂整盘）则保留原名；分区才经 whole_disk_of 推导（该函数对整盘名会错误截尾）
        while read -r src mp; do
            [ -n "$src" ] || continue
            src=$(basename "$src")
            case "$src" in
                sd[a-z]|vd[a-z]|hd[a-z]|nvme[0-9]*n[0-9]*|mmcblk[0-9]*) name="$src" ;;
                *) name=$(whole_disk_of "$src") ;;
            esac
            [ -n "$name" ] || continue
            case "$name" in dm-*|md*) continue ;; esac
            [ -n "$sys_disk" ] && [ "$name" = "$sys_disk" ] && continue
            case " $seen " in *" $name "*) continue ;; esac
            seen="$seen $name"
            sn=$(sn_of_dev "$name")
            printf '%s | %s | %s\n' "$name" "$sn" "$mp"
        done < <("${DF_BIN:-df}" 2>/dev/null | awk 'NR>1 {print $1, $6}')
    fi > "$out"
}

