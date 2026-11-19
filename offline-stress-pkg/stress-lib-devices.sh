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

