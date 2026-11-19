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

