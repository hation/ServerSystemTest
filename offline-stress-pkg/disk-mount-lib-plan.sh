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

