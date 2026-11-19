now() { date '+%Y-%m-%d %H:%M:%S'; }

usage() {
    cat <<'EOF'
用法:
  bash disk-mount.sh list
  bash disk-mount.sh mount [--disks sdb,sdc] [--yes] [--rebuild] [--dry-run]
  bash disk-mount.sh umount [--all]

说明:
  list    列出全部块设备，标出系统盘（永不测试）、分区状态与挂载点
  mount   收集非系统盘 → 交互选择或 --disks（all=全部）→ 打印完整执行计划
           → 单个 y 确认后执行：挂载到 /mnt/HDDxx
           默认模式（不清盘）：有分区→测首个分区（有文件系统直接挂载，无文件系统先
             mkfs.ext4 -m 0 该分区）；无分区→有文件系统直接挂载整盘，空盘整盘 mkfs。
             已挂载的盘跳过；blkid 重试 5 次仍失败则跳过该盘且绝不格式化
           --rebuild  重建模式：卸载 /mnt/HDD* 旧挂载 → 清空分区表 → 建 1 个 GPT 分区
                      → mkfs.ext4 -m 0 该分区 → 挂载该分区（会清空数据盘）
           --dry-run  只打印计划，不执行任何写操作（等价 DRY_RUN=1）
           --yes      跳过 y 确认，供 oneclick.sh 调用（仍须指定 --disks，系统盘校验不变）
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

# 反向依赖链解析（lsblk -s）：从 df / 的底层设备出发，沿链收集所有 TYPE=disk
# 的整盘名（-P 键值格式，避免空列错位）。覆盖 LVM/mapper 布局：
#   /dev/mapper/vg00-lv_root（lvm）→ PV 分区 sda2（part）→ 整盘 sda（disk）
# 可靠性标记 SYS_ID_OK（fail-closed）：
#   df / 不是 /dev/* 设备（overlay、UUID= 等）、链路上 0 个整盘（lsblk 不认识
#   /dev/root 等）、>1 个整盘（RAID/多 PV）、兜底后最终设备不是 TYPE=disk → 0。
#   SYS_ID_OK=0 时 SYS_BASE 仅供 list 展示，mount 流程不得执行任何写操作。
SYS_BASE=""
SYS_ID_OK=0

sys_disk_base() {
    local dev base disks n
    dev=$($DF_BIN / 2>/dev/null | awk 'NR==2{print $1}')
    [ -n "$dev" ] || return 1
    case "$dev" in
        /dev/*) ;;
        *) return 1 ;;
    esac
    # lsblk -s 反转依赖链（叶→根），收集链路上所有 TYPE=disk 且 NAME 非空的整盘名
    # （-P 键值输出，避免空列错位）。恰好 1 个整盘 → 可靠；0 个整盘（lsblk 不认识
    # /dev/root 等）或 >1 个整盘（RAID/多 PV）→ 落入下方兜底，保持 fail-closed。
    disks=$($LSBLK_BIN -s -P -o NAME,TYPE "$dev" 2>/dev/null | awk '
        function v(line, key,   re, s) {
            re = key "=\""
            if (match(line, re)) {
                s = substr(line, RSTART + length(re))
                return substr(s, 1, index(s, "\"") - 1)
            }
            return ""
        }
        { if (v($0,"TYPE")=="disk" && v($0,"NAME")!="") print v($0,"NAME") }')
    n=$(printf '%s\n' "$disks" | awk 'NF' | wc -l)
    if [ "$n" -eq 1 ]; then
        base=$(printf '%s\n' "$disks" | awk 'NF{print; exit}')
        [ -n "$base" ] || return 1
        SYS_BASE="$base"
        SYS_ID_OK=1
        return 0
    fi
    # 兜底：正则去分区号（仅用于展示；是否可靠由 SYS_ID_OK 表示）
    base=$(echo "$dev" | sed -E 's#^/dev/(sd[a-z]+)[0-9]*$#\1#; s#^/dev/(nvme[0-9]+n[0-9]+)p[0-9]+$#\1#; s#^/dev/(vd[a-z]+)[0-9]*$#\1#; s#^/dev/(mmcblk[0-9]+)p[0-9]+$#\1#; s#^/dev/##')
    SYS_BASE="$base"
    if [ -n "$base" ] && [ "$($LSBLK_BIN -no TYPE "/dev/$base" 2>/dev/null | head -1)" = "disk" ]; then
        SYS_ID_OK=1
    fi
    return 0
}

sys_disk_base

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

# 读取块设备（TYPE=disk 的 sd*/nvme*/vd*/mmcblk*）。
# 输出行：盘符 容量 分区数 已挂载 首分区 首分区容量 首分区PARTTYPE
# 首分区 = 第一个“非扩展分区”（排除 msdos 扩展容器 0x5/0xf/0x85，其本身无文件系统）。
# PARTTYPE 放在 MOUNTPOINT 之前：空挂载点时 lsblk 空格分列会错位，避免 PARTTYPE 缺失。
# 兼容：优先带 PARTTYPE 列；若 lsblk 报错/无输出（旧假件只认 4 列）则退回 4 列重试。
disk_lines() {
    local out
    out=$($LSBLK_BIN -o NAME,SIZE,TYPE,PARTTYPE,MOUNTPOINT -l 2>/dev/null)
    [ -n "$out" ] || out=$($LSBLK_BIN -o NAME,SIZE,TYPE,MOUNTPOINT -l 2>/dev/null)
    printf '%s\n' "$out" | awk '
        function is_ext(t, x) {
            if (t=="") return 0
            x=tolower(t); sub(/^0x/, "", x)
            return (x=="5" || x=="f" || x=="85")
        }
        $3=="disk" && ($1 ~ /^sd[a-z]+$/ || $1 ~ /^nvme[0-9]+n[0-9]+$/ || $1 ~ /^vd[a-z]+$/ || $1 ~ /^mmcblk[0-9]+$/) {
            if (d!="") print d, sz, np, mnt, fp, fpsz, fpt
            d=$1; sz=$2; np=0; mnt=($5!="" ? 1 : 0); fp=""; fpsz=""; fpt=""; next
        }
        $3=="part" && d!="" && substr($1,1,length(d))==d {
            np++
            if (fp=="" && !is_ext($4)) { fp=$1; fpsz=$2; fpt=$4 }
            if ($5!="") mnt=1
            next
        }
        END { if (d!="") print d, sz, np, mnt, fp, fpsz, fpt }
    '
}

DISK_NAMES=() DISK_SIZES=() DISK_NPARTS=() DISK_MOUNTED=() DISK_FPARTS=() DISK_FPARTSZ=() DISK_FPARTTYPE=()

collect_non_sys_disks() {
    local line n
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        set -- $line
        n="$1"
        is_sys_disk_or_part "$n" && continue   # 系统盘硬跳过
        DISK_NAMES+=("$n"); DISK_SIZES+=("$2"); DISK_NPARTS+=("$3"); DISK_MOUNTED+=("$4"); DISK_FPARTS+=("$5"); DISK_FPARTSZ+=("$6"); DISK_FPARTTYPE+=("$7")
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
    [ "$(disk_mounted_flag "$1")" = "1" ]
}

# 该盘（含全部分区/LVM/RAID 后代设备）是否已挂载（1/0）
disk_mounted_flag() {
    if [ -n "$(disk_mountpoints "$1")" ]; then echo 1; else echo 0; fi
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

disk_fpartsz() {
    local i
    for i in "${!DISK_NAMES[@]}"; do
        [ "${DISK_NAMES[$i]}" = "$1" ] && { echo "${DISK_FPARTSZ[$i]}"; return 0; }
    done
}

# 该盘分区表类型（gpt/dos/空）
pt_type() {
    $LSBLK_BIN -no PTTYPE "/dev/$1" 2>/dev/null | awk 'NF{print; exit}'
}

disk_nparts() {
    local i
    for i in "${!DISK_NAMES[@]}"; do
        [ "${DISK_NAMES[$i]}" = "$1" ] && { echo "${DISK_NPARTS[$i]}"; return 0; }
    done
    echo 0
}

# 该盘及其全部后代设备（分区/LVM/crypt/RAID 成员）当前的挂载点，每行一个。
# 用 lsblk 的子树输出（默认会列出子孙设备），不自行解析表格，避免漏掉 LVM/RAID 挂载。
disk_mountpoints() {
    $LSBLK_BIN -ln -o MOUNTPOINT "/dev/$1" 2>/dev/null | awk 'NF{print}'
}

# 该盘的非测试挂载点（不匹配 ^/mnt/HDD[0-9][0-9]*$），每行一个
disk_non_test_mountpoints() {
    disk_mountpoints "$1" | awk '$0 !~ /^\/mnt\/HDD[0-9][0-9]*$/'
}

# 整盘是否已有文件系统（blkid 探测）。上一轮已格式化过的盘无分区但带 ext4，
# 直接挂载即可；只有真正无文件系统的空盘才需要 mkfs（避免 mkfs 二次格式化提示/挂起）。
disk_has_fs() {
    local dev="$1"
    [ -n "$($BLKID_BIN -s TYPE -o value "$dev" 2>/dev/null)" ]
}

# 文件系统探测三态：0=有文件系统（stdout 为类型）；1=确认无文件系统；2=探测失败
# 契约：stdout 非空→0；输出为空且结果码 0/2 且 stderr 为空→1；其余（结果码非 0/2、
# stderr 非空、命令不可用）→2。调用形式固定为 -s TYPE -o value <dev>（既有假件依赖）。
probe_fs() {
    local dev="$1" out err rc errf
    errf=$(mktemp "${TMPDIR:-/tmp}/dm-probe.XXXXXX") || return 2
    out=$($BLKID_BIN -s TYPE -o value "$dev" 2>"$errf")
    rc=$?
    err=$(cat "$errf" 2>/dev/null)
    rm -f "$errf"
    if [ -n "$out" ]; then
        return 0
    fi
    if [ "$rc" -eq 0 ] || [ "$rc" -eq 2 ]; then
        [ -z "$err" ] && return 1
    fi
    return 2
}

# 探测重试：最多 5 次尝试，间隔 1 秒；每次失败后若 udevadm 可用则先 settle。
# 仍失败返回 2（调用方据此跳过该盘，绝不格式化）。
probe_fs_retry() {
    local dev="$1" i=0 rc
    while [ "$i" -lt 5 ]; do
        probe_fs "$dev"
        rc=$?
        [ "$rc" -ne 2 ] && return "$rc"
        i=$((i + 1))
        [ "$i" -lt 5 ] || break
        if command -v "$UDEVADM_BIN" >/dev/null 2>&1; then
            "$UDEVADM_BIN" settle >/dev/null 2>&1 || true
        fi
        sleep 1
    done
    return 2
}

# 重建后解析分区设备：lsblk -ln -o NAME,TYPE 中第一个 TYPE=part，最多 5 次、间隔 1 秒。
# 不盲拼 "1"：NVMe 为 nvme0n1p1、mmcblk 为 mmcblk0p1，均按实际名称返回。
resolve_part() {
    local dev="$1" i=0 name
    while [ "$i" -lt 5 ]; do
        name=$($LSBLK_BIN -ln -o NAME,TYPE "$dev" 2>/dev/null | awk '$2=="part"{print $1; exit}')
        if [ -n "$name" ]; then
            echo "/dev/$name"
            return 0
        fi
        i=$((i + 1))
        [ "$i" -lt 5 ] && sleep 1
    done
    return 1
}

# 计划展示用的预期分区名（仅用于打印，实际设备由 resolve_part 解析）
expect_part_name() {
    case "$1" in
        nvme*|mmcblk*) echo "/dev/${1}p1" ;;
        *) echo "/dev/${1}1" ;;
    esac
}

# 容量换算为 MiB（支持 K/M/G/T 及 *iB 后缀）；无法换算返回 1
size_to_mib() {
    local s="$1" num unit
    num="${s%%[!0-9.]*}"
    unit="${s#"$num"}"
    [ -n "$num" ] || return 1
    case "$unit" in
        ""|B|b) awk -v n="$num" 'BEGIN{printf "%d", n/1048576}' ;;
        K|k|Ki|KiB) awk -v n="$num" 'BEGIN{printf "%d", n/1024}' ;;
        M|m|Mi|MiB) awk -v n="$num" 'BEGIN{printf "%d", n}' ;;
        G|g|Gi|GiB) awk -v n="$num" 'BEGIN{printf "%d", n*1024}' ;;
        T|t|Ti|TiB) awk -v n="$num" 'BEGIN{printf "%d", n*1048576}' ;;
        *) return 1 ;;
    esac
}

disk_status() {
    local i
    for i in "${!DISK_NAMES[@]}"; do
        [ "${DISK_NAMES[$i]}" = "$1" ] || continue
        if [ "$(disk_mounted_flag "${DISK_NAMES[$i]}")" = "1" ]; then echo "已挂载（跳过）"
        elif [ "${DISK_NPARTS[$i]}" -gt 0 ]; then echo "有分区 ${DISK_FPARTS[$i]}（默认测首个分区）"
        elif disk_has_fs "/dev/${DISK_NAMES[$i]}"; then echo "未分区但已有文件系统（将直接挂载，不重新格式化）"
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

