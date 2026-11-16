#!/bin/bash
# disk-mount.sh —— 挂载辅助脚本（Kylin V10 SP3，硬盘压测前挂载测试盘）
# 用法：
#   bash disk-mount.sh list                     # 列出块设备，标出系统盘与分区/挂载状态
#   bash disk-mount.sh mount [--disks sdb,sdc] [--yes] [--rebuild] [--dry-run]
#                                               # 逐盘选择→计划确认→挂载到 /mnt/HDDxx（--yes 跳过 y 确认）
#   bash disk-mount.sh umount [--all]           # 卸载全部已挂载测试盘（--all 跳过确认）
# 环境变量（测试接缝）：
#   DRY_RUN=1          只打印执行计划，不执行任何写操作（含不写 mount.log）
#   SKIP_ROOT_CHECK=1  跳过 root 检查（仅本地测试用）
#   MOUNT_LOG          挂载日志路径（默认 /root/stress-test/mount.log）
#   LSBLK_BIN          块设备查询命令（默认 lsblk，测试可用伪造输出）
#   BLKID_BIN          文件系统探测命令（默认 blkid，测试可用伪造输出）
#   PARTED_BIN/PARTPROBE_BIN/UDEVADM_BIN/MKFS_BIN/MOUNT_BIN/UMOUNT_BIN/DF_BIN
#                      写操作与 df 命令接缝（默认同名系统命令）
# 退出码：0=全部成功（含取消/无需操作）；1=用法/前置错误、含系统盘、存在跳过或失败盘
# 说明：全程不 set -e；系统盘（df / 所在盘）任何分支硬跳过；每步操作写 mount.log。
#       默认模式不清盘：有分区→测首个分区；无分区→测整盘；仅 --rebuild 才重建分区表。

DRY_RUN="${DRY_RUN:-0}"
SKIP_ROOT_CHECK="${SKIP_ROOT_CHECK:-0}"
MOUNT_LOG="${MOUNT_LOG:-/root/stress-test/mount.log}"
LSBLK_BIN="${LSBLK_BIN:-lsblk}"
BLKID_BIN="${BLKID_BIN:-blkid}"
PARTED_BIN="${PARTED_BIN:-parted}"
PARTPROBE_BIN="${PARTPROBE_BIN:-partprobe}"
UDEVADM_BIN="${UDEVADM_BIN:-udevadm}"
MKFS_BIN="${MKFS_BIN:-mkfs.ext4}"
MOUNT_BIN="${MOUNT_BIN:-mount}"
UMOUNT_BIN="${UMOUNT_BIN:-umount}"
DF_BIN="${DF_BIN:-df}"

REBUILD=0

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

# 沿 lsblk 树向上解析：从 df / 的底层设备出发，逐层取父设备（pkname），
# 直到解析到 TYPE=disk 的整盘为止。覆盖 LVM/mapper 布局：
#   /dev/mapper/vg00-lv_root（lvm）→ PV 分区 sda2（part）→ 整盘 sda（disk）
# 可靠性标记 SYS_ID_OK（fail-closed）：
#   df / 不是 /dev/* 设备（overlay、UUID= 等）、lsblk 不认识该设备（/dev/root）、
#   pkname 输出多于 1 行（RAID/多 PV）、上溯超限、最终设备不是 TYPE=disk → 0。
#   SYS_ID_OK=0 时 SYS_BASE 仅供 list 展示，mount 流程不得执行任何写操作。
SYS_BASE=""
SYS_ID_OK=0

sys_disk_base() {
    local dev tgt type pks pk i base
    dev=$($DF_BIN / 2>/dev/null | awk 'NR==2{print $1}')
    [ -n "$dev" ] || return 1
    case "$dev" in
        /dev/*) ;;
        *) return 1 ;;
    esac
    tgt="$dev"
    i=0
    while [ "$i" -lt 20 ]; do
        type=$($LSBLK_BIN -no TYPE "$tgt" 2>/dev/null | head -1)
        if [ "$type" = "disk" ]; then
            base="${tgt#/dev/}"
            [ -n "$base" ] || return 1
            SYS_BASE="$base"
            SYS_ID_OK=1
            return 0
        fi
        [ -n "$type" ] || break   # lsblk 不认识该设备（/dev/root 等）
        pks=$($LSBLK_BIN -no pkname "$tgt" 2>/dev/null)
        pk=$(printf '%s\n' "$pks" | awk 'NF{print; exit}')
        [ -n "$pk" ] || break
        # 多行 pkname（RAID/多 PV）无法确定唯一物理盘 → 视为不可靠
        [ "$(printf '%s\n' "$pks" | awk 'NF' | wc -l)" -eq 1 ] || return 1
        case "$pk" in
            /dev/*) tgt="$pk" ;;
            *) tgt="/dev/$pk" ;;
        esac
        i=$((i + 1))
    done
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

# ---------- 挂载点编号（已占用编号不复用） ----------

# 已占用编号：df -P ∪ lsblk 中挂载点匹配 ^/mnt/HDD[0-9][0-9]*$ 的数字（去前导 0）
used_mount_numbers() {
    {
        $DF_BIN -P 2>/dev/null | awk 'NF>=6 {print $6}'
        $LSBLK_BIN -o NAME,SIZE,TYPE,MOUNTPOINT -l 2>/dev/null | awk 'NF>=4 {print $4}'
    } | awk '$1 ~ /^\/mnt\/HDD[0-9][0-9]*$/ { n=$1; sub(/^\/mnt\/HDD/, "", n); print n + 0 }' | sort -n -u
}

# 挂载点对应编号：/mnt/HDD01 → 1（无数字/非纯数字返回 1）
mount_number_of() {
    local mp="$1" n
    case "$mp" in
        /mnt/HDD[0-9]*) n="${mp#/mnt/HDD}" ;;
        *) return 1 ;;
    esac
    case "$n" in
        ""|*[!0-9]*) return 1 ;;
    esac
    echo "$((10#$n))"
}

USED_NUMS=()

in_used_nums() {
    local u
    for u in "${USED_NUMS[@]}"; do
        [ "$u" = "$1" ] && return 0
    done
    return 1
}

# 分配最小可用编号（分配后计入占用）。结果写入 ALLOC_NUM：
# 不能用 $(...) 取（子 shell 中的占用变更不会回传，会导致编号重复）。
ALLOC_NUM=""

alloc_mount_number() {
    local n=1
    while in_used_nums "$n"; do
        n=$((n + 1))
    done
    USED_NUMS+=("$n")
    ALLOC_NUM="$n"
    return 0
}

# ---------- 计划数组（打印与执行共用同一份计划，编号只算一次） ----------

PLAN_DISK=() PLAN_MNT=() PLAN_ACT=() PLAN_REASON=() PLAN_SRC=() PLAN_NOTE=() PLAN_FAIL=()

add_plan() {  # 盘 挂载点 动作 跳过原因 源设备 提示 是否计失败(0/1)
    PLAN_DISK+=("$1"); PLAN_MNT+=("$2"); PLAN_ACT+=("$3"); PLAN_REASON+=("$4"); PLAN_SRC+=("$5"); PLAN_NOTE+=("$6"); PLAN_FAIL+=("${7:-0}")
}

# 生成计划：默认模式按设计 5.5 决策树；--rebuild 按 5.6 步骤规划
build_plan() {
    local c dev mp badmp fpart fpsz src note rc num nparts mib u
    PLAN_DISK=() PLAN_MNT=() PLAN_ACT=() PLAN_REASON=() PLAN_SRC=() PLAN_NOTE=() PLAN_FAIL=()
    USED_NUMS=()
    while IFS= read -r u; do
        [ -n "$u" ] && USED_NUMS+=("$u")
    done < <(used_mount_numbers)

    for c in "${chosen[@]}"; do
        dev="/dev/$c"
        if [ "$REBUILD" = "1" ]; then
            # 只要存在非测试挂载点（业务数据），整盘跳过，绝不重建
            badmp=$(disk_non_test_mountpoints "$c" | head -1)
            if [ -n "$badmp" ]; then
                add_plan "$c" "" "skip" "存在非 /mnt/HDD* 挂载点（$badmp），不重建" "" "" 1
                continue
            fi
            # 已在 /mnt/HDD* 挂载：卸载后原挂载点重建
            mp=$(disk_mountpoints "$c" | grep -m1 '^/mnt/HDD[0-9][0-9]*$' || true)
            if [ -n "$mp" ] && num=$(mount_number_of "$mp"); then
                in_used_nums "$num" || USED_NUMS+=("$num")
                add_plan "$c" "$mp" "rebuild" "" "" "先卸载 $mp 再重建" 0
                continue
            fi
            alloc_mount_number; num=$ALLOC_NUM
            add_plan "$c" "$(printf '/mnt/HDD%02d' "$num")" "rebuild" "" "" "" 0
            continue
        fi

        if [ "$(disk_mounted_flag "$c")" = "1" ]; then
            # 默认模式：只要子树有挂载点（含 LVM/RAID 后代）就跳过；非测试挂载显式提示
            badmp=$(disk_non_test_mountpoints "$c" | head -1)
            if [ -n "$badmp" ]; then
                add_plan "$c" "" "skip" "存在非测试挂载点挂载（$badmp），跳过" "" "" 0
            else
                add_plan "$c" "" "skip" "已挂载（跳过）" "" "" 0
            fi
            continue
        fi

        nparts=$(disk_nparts "$c")
        fpart=$(disk_fpart "$c")
        # 全是扩展分区容器（无可用首分区）→ 跳过，绝不格式化容器
        if [ "$nparts" -gt 0 ] && [ -z "$fpart" ]; then
            add_plan "$c" "" "skip" "仅发现扩展分区，无可用分区，不自动格式化（需要重建请用 --rebuild）" "" "" 1
            continue
        fi
        # 有分区表却解析不到任何分区 → 跳过，避免整盘 mkfs 覆盖分区表
        if [ "$nparts" -eq 0 ] && [ -n "$(pt_type "$c")" ]; then
            add_plan "$c" "" "skip" "存在分区表但未发现可用分区，不自动格式化（需要重建请用 --rebuild）" "" "" 1
            continue
        fi
        note=""
        if [ "$nparts" -gt 0 ]; then
            fpsz=$(disk_fpartsz "$c")
            src="/dev/$fpart"
            if [ "$nparts" -gt 1 ]; then
                note="本盘有 $nparts 个分区，默认仅测第一个（$fpart，${fpsz:-未知}）；需要整盘覆盖请用 --rebuild"
            fi
        else
            fpsz=""
            src="$dev"
        fi
        # 探测在计划阶段完成，结果决定动作；执行阶段不再二次探测
        probe_fs_retry "$src"
        rc=$?
        if [ "$rc" -eq 2 ]; then
            add_plan "$c" "" "skip" "blkid 探测失败（5 次均失败，未格式化）" "" "" 1
            continue
        fi
        if [ -n "$fpsz" ]; then
            mib=$(size_to_mib "$fpsz" || true)
            if [ -n "$mib" ] && [ "$mib" -lt 10240 ]; then
                note="${note:+$note；}首分区容量可能不足以写入 10G，可能 ENOSPC"
            fi
        fi
        alloc_mount_number; num=$ALLOC_NUM
        mp=$(printf '/mnt/HDD%02d' "$num")
        if [ "$rc" -eq 0 ]; then
            add_plan "$c" "$mp" "mount" "" "$src" "$note" 0
        else
            add_plan "$c" "$mp" "mkfs_mount" "" "$src" "$note" 0
        fi
    done
}

print_plan() {
    local i n=0 desc
    echo "==== 挂载执行计划 ===="
    for i in "${!PLAN_DISK[@]}"; do
        if [ "${PLAN_ACT[$i]}" = "skip" ]; then
            echo "  跳过  /dev/${PLAN_DISK[$i]}  $(disk_size "${PLAN_DISK[$i]}")  ${PLAN_REASON[$i]}"
            continue
        fi
        n=$((n + 1))
        case "${PLAN_ACT[$i]}" in
            mount)
                if [ "${PLAN_SRC[$i]}" = "/dev/${PLAN_DISK[$i]}" ]; then
                    desc="已有文件系统：直接挂载 ${PLAN_SRC[$i]} → ${PLAN_MNT[$i]}（不重新格式化）"
                else
                    desc="有分区：直接挂载 ${PLAN_SRC[$i]} → ${PLAN_MNT[$i]}"
                fi
                ;;
            mkfs_mount)
                if [ "${PLAN_SRC[$i]}" = "/dev/${PLAN_DISK[$i]}" ]; then
                    desc="无分区空盘：mkfs.ext4 -m 0 ${PLAN_SRC[$i]} 后挂载 → ${PLAN_MNT[$i]}"
                else
                    desc="分区无文件系统：mkfs.ext4 -m 0 ${PLAN_SRC[$i]} 后挂载 → ${PLAN_MNT[$i]}"
                fi
                ;;
            rebuild)
                desc="重建：清空分区表 → 建 1 分区 → mkfs.ext4 -m 0 $(expect_part_name "${PLAN_DISK[$i]}") → ${PLAN_MNT[$i]}"
                ;;
        esac
        echo "  $(printf "%02d" "$n")  /dev/${PLAN_DISK[$i]}  $(disk_size "${PLAN_DISK[$i]}")  $desc"
        [ -n "${PLAN_NOTE[$i]}" ] && echo "      ${PLAN_NOTE[$i]}"
    done
}

# 可执行（非跳过）计划项数量
plan_action_count() {
    local i n=0
    for i in "${!PLAN_DISK[@]}"; do
        [ "${PLAN_ACT[$i]}" = "skip" ] || n=$((n + 1))
    done
    echo "$n"
}

# 计划中标记为“计入失败”的跳过项数量
plan_fail_count() {
    local i n=0
    for i in "${!PLAN_DISK[@]}"; do
        [ "${PLAN_FAIL[$i]}" = "1" ] && n=$((n + 1))
    done
    echo "$n"
}

# 跳过/失败汇总：只列 PLAN_FAIL=1 的跳过项（执行期失败在挂载流程内另行汇总）
print_skip_summary() {
    local i
    echo "==== 跳过/失败汇总 ===="
    for i in "${!PLAN_DISK[@]}"; do
        [ "${PLAN_ACT[$i]}" = "skip" ] || continue
        [ "${PLAN_FAIL[$i]}" = "1" ] || continue
        case "${PLAN_REASON[$i]}" in
            blkid*) echo "  因 blkid 失败跳过：${PLAN_DISK[$i]}（5 次探测均失败，未格式化）" ;;
            存在非*) echo "  因非测试挂载点跳过：${PLAN_DISK[$i]}（${PLAN_REASON[$i]}）" ;;
            *) echo "  重建失败跳过：${PLAN_DISK[$i]}（${PLAN_REASON[$i]}）" ;;
        esac
    done
}

# 记录编号分配：供事后追溯（每盘分配后一行）
assign_log() {  # 盘 挂载点 源设备
    local desc="整盘 $1"
    [ "$3" != "/dev/$1" ] && desc="分区 ${3#/dev/}"
    echo "[$(now)] assign: /dev/$1 -> $2（$desc）" >> "$MOUNT_LOG"
}

# ---------- 公共：执行并写 mount.log ----------

# 执行一条命令，输出经 tee 实时同时打到控制台与 MOUNT_LOG（长命令可见进度、交互提示可见），
# 末尾追加 "[时间] cmd: ... 结果:$?" 到 MOUNT_LOG；退出码取命令自身（PIPESTATUS[0]，非 tee 的）
run_log() {
    local rc
    "$@" 2>&1 | tee -a "$MOUNT_LOG"
    rc=${PIPESTATUS[0]}
    echo "[$(now)] cmd: $* 结果:$rc" >> "$MOUNT_LOG"
    return "$rc"
}

# ---------- 重建（--rebuild）单盘步骤：严格按设计 5.6 顺序，任一步失败只跳过该盘 ----------

REBUILD_ERR=""

do_rebuild() {  # 盘 挂载点
    local c="$1" mnt="$2" dev="/dev/$1" mp part
    REBUILD_ERR=""

    # 1) 卸载 /mnt/HDD* 旧挂载（其他位置的挂载在计划阶段已跳过）
    while IFS= read -r mp; do
        [ -n "$mp" ] || continue
        if ! run_log "$UMOUNT_BIN" "$mp"; then
            REBUILD_ERR="umount $mp 失败"
            echo "重建失败：$c（umount $mp 失败，跳过该盘）"
            return 1
        fi
    done < <(disk_mountpoints "$c" | grep '^/mnt/HDD[0-9][0-9]*$' || true)

    # 2) 清空分区表并建 1 个 GPT 分区（1MiB 起始，占满 100%）
    if ! run_log "$PARTED_BIN" -s "$dev" mklabel gpt; then
        REBUILD_ERR="parted mklabel 返回非 0"
        echo "重建失败：$c（mklabel gpt 失败，跳过该盘）"
        return 1
    fi
    if ! run_log "$PARTED_BIN" -s "$dev" mkpart primary ext4 1MiB 100%; then
        REBUILD_ERR="parted mkpart 返回非 0"
        echo "重建失败：$c（mkpart 失败，跳过该盘）"
        return 1
    fi
    if ! run_log "$PARTPROBE_BIN" "$dev"; then
        REBUILD_ERR="partprobe 返回非 0"
        echo "重建失败：$c（partprobe 失败，跳过该盘）"
        return 1
    fi
    if command -v "$UDEVADM_BIN" >/dev/null 2>&1; then
        run_log "$UDEVADM_BIN" settle || true
    else
        sleep 1
    fi

    # 3) 解析分区设备（不盲拼 "1"：NVMe/mmcblk 由 lsblk 实际名称决定）
    part=$(resolve_part "$dev")
    if [ -z "$part" ]; then
        REBUILD_ERR="lsblk 未解析到分区"
        echo "重建失败：$c（lsblk 未解析到分区，跳过该盘）"
        return 1
    fi
    if ! run_log "$MKFS_BIN" -m 0 "$part"; then
        REBUILD_ERR="mkfs.ext4 返回非 0"
        echo "重建失败：$c（格式化 $part 失败，跳过该盘）"
        return 1
    fi
    if ! run_log "$MOUNT_BIN" "$part" "$mnt"; then
        REBUILD_ERR="mount 返回非 0"
        echo "挂载失败：$c → $mnt（结果非 0，见 mount.log）"
        return 1
    fi
    echo "已挂载 $c → $mnt"
    return 0
}

# ---------- list ----------

cmd_list() {
    collect_non_sys_disks
    echo "==== 块设备一览（lsblk） ===="
    $LSBLK_BIN -o NAME,SIZE,TYPE,MOUNTPOINT 2>/dev/null | awk -v sys="$SYS_BASE" '
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
        echo "未发现非系统盘（无 /dev/sd*、/dev/nvme*、/dev/vd* 或 /dev/mmcblk* 块设备）"
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
    local disks_opt="" assume_yes=0
    while [ $# -gt 0 ]; do
        case "$1" in
            --disks) if [ $# -lt 2 ]; then echo "--disks 缺少参数"; usage; exit 1; fi; disks_opt="$2"; shift 2 ;;
            --yes) assume_yes=1; shift ;;
            --rebuild) REBUILD=1; shift ;;
            --dry-run) DRY_RUN=1; shift ;;
            *) echo "未知参数：$1"; usage; exit 1 ;;
        esac
    done

    root_check
    collect_non_sys_disks

    if [ "${#DISK_NAMES[@]}" -eq 0 ]; then
        echo "未发现非系统盘（无 /dev/sd*、/dev/nvme*、/dev/vd* 或 /dev/mmcblk* 块设备），无需挂载"
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

    # ---------- 前置：系统盘识别必须可靠（fail-closed）与 parted 可用性 ----------
    local dfdev
    dfdev=$($DF_BIN / 2>/dev/null | awk 'NR==2{print $1}')
    if [ "$SYS_ID_OK" != "1" ]; then
        if [ "$DRY_RUN" = "1" ]; then
            echo "警告：无法可靠识别系统盘（df / → ${dfdev:-未知}），DRY RUN 仅打印计划，不做任何校验性写操作"
        else
            echo "无法可靠识别系统盘（df / → ${dfdev:-未知}），已中止：不执行任何写操作"
            exit 1
        fi
    fi
    if [ "$REBUILD" = "1" ] && ! command -v "$PARTED_BIN" >/dev/null 2>&1; then
        if [ "$DRY_RUN" = "1" ]; then
            echo "警告：未找到 parted，DRY RUN 仅打印计划"
        else
            echo "未找到 parted，无法执行 --rebuild（离线包依赖系统自带 parted）"
            exit 1
        fi
    fi

    # ---------- 生成并打印完整执行计划（编号只在此处分配一次） ----------
    build_plan
    print_plan

    # ---------- DRY RUN：打印计划后按计划风险给出与真实执行一致的退出码 ----------
    if [ "$DRY_RUN" = "1" ]; then
        echo "（DRY RUN，未执行）"
        if [ "$(plan_fail_count)" -gt 0 ]; then
            echo
            print_skip_summary
            exit 1
        fi
        exit 0
    fi

    if [ "$(plan_action_count)" -eq 0 ]; then
        # 全部为跳过：仅“已挂载（跳过）”属良性，其余均计失败
        if [ "$(plan_fail_count)" -eq 0 ]; then
            echo "所选盘均已挂载，无需操作"
            exit 0
        fi
        echo
        print_skip_summary
        exit 1
    fi

    # ---------- 单个 y 确认（--yes 时跳过） ----------
    if [ "$assume_yes" -ne 1 ]; then
        local ans=""
        printf "请确认执行以上计划（y/N）："
        IFS= read -r ans || true
        case "$ans" in
            y|Y) ;;
            *) echo "已取消，未执行任何操作"; exit 0 ;;
        esac
    fi

    # ---------- 按计划执行 ----------
    mkdir -p "$(dirname "$MOUNT_LOG")" || { echo "无法创建日志目录：$(dirname "$MOUNT_LOG")"; exit 1; }
    local fails=() i c mntp act src
    for i in "${!PLAN_DISK[@]}"; do
        c="${PLAN_DISK[$i]}"; mntp="${PLAN_MNT[$i]}"; act="${PLAN_ACT[$i]}"; src="${PLAN_SRC[$i]}"
        case "$act" in
            skip)
                echo "跳过 /dev/$c：${PLAN_REASON[$i]}"
                case "${PLAN_REASON[$i]}" in
                    blkid*) fails+=("因 blkid 失败跳过：$c（5 次探测均失败，未格式化）") ;;
                    存在非*) fails+=("因非测试挂载点跳过：$c（${PLAN_REASON[$i]}）") ;;
                    *) [ "${PLAN_FAIL[$i]}" = "1" ] && fails+=("重建失败跳过：$c（${PLAN_REASON[$i]}）") ;;
                esac
                ;;
            mount)
                assign_log "$c" "$mntp" "$src"
                run_log mkdir -p "$mntp"
                if run_log "$MOUNT_BIN" "$src" "$mntp"; then
                    if [ "$src" = "/dev/$c" ]; then
                        echo "已挂载 $c → $mntp（已有文件系统，直接挂载）"
                    else
                        echo "已挂载 $c → $mntp"
                    fi
                else
                    echo "挂载失败：$c → $mntp（结果非 0，见 mount.log）"
                    fails+=("挂载失败：$c → $mntp（结果非 0，见 mount.log）")
                fi
                ;;
            mkfs_mount)
                assign_log "$c" "$mntp" "$src"
                run_log mkdir -p "$mntp"
                if run_log "$MKFS_BIN" -m 0 "$src"; then
                    if run_log "$MOUNT_BIN" "$src" "$mntp"; then
                        echo "已挂载 $c → $mntp"
                    else
                        echo "挂载失败：$c → $mntp（结果非 0，见 mount.log）"
                        fails+=("挂载失败：$c → $mntp（结果非 0，见 mount.log）")
                    fi
                else
                    echo "格式化失败：$c（结果非 0，跳过，见 mount.log）"
                    fails+=("格式化失败：$c（结果非 0，未挂载）")
                fi
                ;;
            rebuild)
                assign_log "$c" "$mntp" "$(expect_part_name "$c")"
                run_log mkdir -p "$mntp"
                if ! do_rebuild "$c" "$mntp"; then
                    fails+=("重建失败跳过：$c（${REBUILD_ERR}）")
                fi
                ;;
        esac
    done

    if [ "${#fails[@]}" -gt 0 ]; then
        echo
        echo "==== 跳过/失败汇总 ===="
        local f
        for f in "${fails[@]}"; do
            echo "  $f"
        done
        echo "全部完成（存在跳过/失败盘，未挂载的盘不参与压测）。挂载日志：$MOUNT_LOG"
        exit 1
    fi
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
    done < <($DF_BIN -P 2>/dev/null | awk 'NR>1 && $6 ~ /^\/mnt\/HDD[0-9][0-9]*$/ {print $6}')

    if [ "${#points[@]}" -eq 0 ]; then
        echo "没有已挂载的测试盘（/mnt/HDD*）"
        exit 0
    fi

    echo "==== 已挂载测试盘 ===="
    local i dev
    for i in "${!points[@]}"; do
        dev=$($DF_BIN -P "${points[$i]}" 2>/dev/null | awk 'NR==2{print $1}')
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
        if run_log "$UMOUNT_BIN" "$p"; then
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
