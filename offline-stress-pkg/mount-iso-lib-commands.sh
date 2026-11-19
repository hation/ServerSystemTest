
# ---------- build ----------

cmd_build() {
    local rpm_dir=""
    while [ $# -gt 0 ]; do
        case "$1" in
            --rpm-dir)
                if [ $# -lt 2 ]; then echo "--rpm-dir 缺少参数"; usage; exit 1; fi
                rpm_dir="$2"; shift 2 ;;
            *) echo "未知参数：$1"; usage; exit 1 ;;
        esac
    done

    root_check

    # ---------- 1. 定位 RPM 包目录（优先级：U盘内 > --rpm-dir > 包内 rpms/） ----------
    local src=""
    if usb_is_mounted && dir_has_rpm "$USB_MOUNT_POINT"; then
        src=$(locate_rpm_dir "$USB_MOUNT_POINT")
        if [ -z "$src" ]; then
            echo "U 盘（$USB_MOUNT_POINT）内未定位到含 *.rpm 的目录"
            exit 1
        fi
        echo "RPM 来源：U 盘内（$src）"
    elif [ -n "$rpm_dir" ]; then
        if [ ! -d "$rpm_dir" ]; then echo "指定的 RPM 目录不存在：$rpm_dir"; exit 1; fi
        if ! dir_has_rpm "$rpm_dir"; then echo "指定的 RPM 目录不含 *.rpm：$rpm_dir"; exit 1; fi
        src="$rpm_dir"
        echo "RPM 来源：--rpm-dir 指定（$rpm_dir）"
    elif dir_has_rpm "$PKG_RPMS_DIR"; then
        src="$PKG_RPMS_DIR"
        echo "RPM 来源：包内 rpms/（$PKG_RPMS_DIR）"
    else
        echo "未找到任何 RPM 包：U 盘未挂载或无 *.rpm、未指定 --rpm-dir、包内 $PKG_RPMS_DIR 无 *.rpm"
        exit 1
    fi

    # ---------- 2. createrepo 构建（生成 repodata/） ----------
    if ! createrepo_ok; then
        if [ "$DRY_RUN" = "1" ]; then
            echo "（DRY RUN）createrepo 不可用，正式执行需先安装：yum install createrepo 或 dnf install createrepo_c"
        else
            echo "未找到 createrepo（$CREATEREPO_BIN），请先安装：yum install createrepo 或 dnf install createrepo_c"
            exit 1
        fi
    fi
    echo "==== 构建 yum 源元数据（repodata） ===="
    if [ "$DRY_RUN" = "1" ]; then
        echo "（DRY RUN）$CREATEREPO_BIN --update $src"
    elif run_log $CREATEREPO_BIN --update "$src"; then
        echo "createrepo 构建完成：$src（已生成 repodata/）"
    else
        echo "createrepo 构建失败（结果非 0，见 mount.log）"
        exit 1
    fi

    # ---------- 3. 落盘 $REPO_DEST ----------
    echo "==== 复制构建结果到 $REPO_DEST ===="
    if is_path_inside "$REPO_DEST" "$src"; then
        echo "目标 $REPO_DEST 位于源目录 $src 内，跳过复制（避免自我复制）"
    elif ! copy_dir_into "$src" "$REPO_DEST"; then
        echo "复制失败：$src → $REPO_DEST（结果非 0，见 $MOUNT_LOG）"
        exit 1
    fi

    # ---------- 4. 写入 U 盘一份 ----------
    if usb_is_mounted; then
        local usb_dst="$USB_MOUNT_POINT/kylin-repo"
        echo "==== 复制构建结果到 U 盘 $usb_dst ===="
        if is_path_inside "$usb_dst" "$src"; then
            echo "源已在 U 盘内，无需再复制（$usb_dst 位于源目录 $src 内）"
        elif ! copy_dir_into "$src" "$usb_dst"; then
            echo "复制失败：$src → $usb_dst（结果非 0，见 $MOUNT_LOG）"
            exit 1
        fi
    else
        echo "未发现已挂载的 U 盘（$USB_MOUNT_POINT 未挂载）：构建结果仅在本机 $REPO_DEST；"
        echo "可插上 U 盘后执行 bash mount-iso.sh mount 拷贝到系统并配置本地源"
    fi

    echo
    echo "构建完成。可用 bash mount-iso.sh mount 配置本地源（U 盘挂载→复制→写 repo 文件）"
}

# ---------- mount ----------

cmd_mount() {
    root_check

    echo "==== 1/4 检测并挂载 U 盘 ===="
    if ! mount_usb; then
        echo "请手动挂载 U 盘后重试，例如："
        echo "  mkdir -p $USB_MOUNT_POINT"
        echo "  mount /dev/sdX1 $USB_MOUNT_POINT    # sdX1 以 lsblk 实际设备为准"
        exit 1
    fi

    # DRY_RUN 且实际未挂载：挂载点内无内容可查，打印后续计划即可
    if [ "$DRY_RUN" = "1" ] && ! usb_is_mounted; then
        echo "（DRY RUN）后续将：挂载 U 盘 → 查找含 repodata 的目录 → 复制到 $REPO_DEST → 写 $YUM_REPO_FILE"
        return 0
    fi

    echo "==== 2/4 定位 U 盘内 yum 源目录（含 repodata） ===="
    local src=""
    if ! src=$(find_repodata_dir); then
        echo "可用 bash mount-iso.sh build 从 RPM 包构建源后再 mount"
        exit 1
    fi
    echo "找到 yum 源目录：$src"

    echo "==== 3/4 复制到系统 $REPO_DEST ===="
    if ! copy_dir_into "$src" "$REPO_DEST"; then
        echo "复制失败：$src → $REPO_DEST（结果非 0，见 $MOUNT_LOG），未配置本地源"
        exit 1
    fi

    echo "==== 4/4 配置本地 yum 源 ===="
    if [ "$DRY_RUN" = "1" ]; then
        echo "（DRY RUN）校验 $REPO_DEST/repodata（正式执行时缺失则不写 repo）"
    elif [ ! -d "$REPO_DEST/repodata" ]; then
        echo "$REPO_DEST 缺少 repodata，未配置 yum 源"
        exit 1
    fi
    local repo_rc=0 actual_baseurl=""
    write_repo_file || repo_rc=$?
    if [ "$repo_rc" -eq 1 ]; then
        echo "写入 repo 文件失败：$YUM_REPO_FILE，未完成本地源配置"
        exit 1
    fi
    if [ "$repo_rc" -eq 2 ]; then
        actual_baseurl=$(grep -E '^[[:space:]]*baseurl' "$YUM_REPO_FILE" 2>/dev/null | head -1 | sed 's/^[[:space:]]*//')
        echo "repo 文件已存在，未修改（实际 ${actual_baseurl:-baseurl 未识别}）"
    fi

    echo "==== 验证 ===="
    if [ "$DRY_RUN" = "1" ]; then
        echo "（DRY RUN）ls $REPO_DEST | head"
        echo "（DRY RUN）yum repolist"
        return 0
    fi
    echo "-- ls $REPO_DEST | head --"
    ls "$REPO_DEST" 2>/dev/null | head -20 || echo "（提示）ls $REPO_DEST 失败"
    log_cmd "verify: ls $REPO_DEST"
    echo "-- yum repolist --"
    yum repolist 2>&1 | tail -20 || echo "（提示）yum repolist 执行失败（不影响已完成的复制与配置）"
    log_cmd "verify: yum repolist"
    echo
    if [ "$repo_rc" -eq 2 ]; then
        echo "全部完成（repo 文件未修改）。操作日志：$MOUNT_LOG"
    else
        echo "全部完成。本地源已配置：$YUM_REPO_FILE（baseurl=file://$REPO_DEST）；操作日志：$MOUNT_LOG"
    fi
}

# ---------- status ----------

cmd_status() {
    local disk dev cnt mp
    echo "==== U 盘挂载状态 ===="
    disk=$(usb_disk)
    if [ -n "$disk" ]; then
        echo "检测到 USB 盘：$disk"
    else
        echo "未检测到 USB 盘（或已排除系统盘）"
    fi
    if usb_is_mounted; then
        dev=$(df -P "$USB_MOUNT_POINT" 2>/dev/null | awk 'NR==2{print $1}')
        echo "U 盘挂载点：$USB_MOUNT_POINT（已挂载，设备 ${dev:-未知}）"
    else
        mp=""
        [ -n "$disk" ] && mp=$(usb_mountpoint_of "$(usb_first_part "$disk")")
        if [ -n "$mp" ]; then
            echo "U 盘挂载点：$USB_MOUNT_POINT（未挂载）"
            echo "U 盘实际挂载在：$mp（非 $USB_MOUNT_POINT，请先 umount 后重试）"
        else
            echo "U 盘挂载点：$USB_MOUNT_POINT（未挂载）"
        fi
    fi

    echo
    echo "==== 本地源目录 $REPO_DEST ===="
    if [ -d "$REPO_DEST" ]; then
        cnt=$(ls -A "$REPO_DEST" 2>/dev/null | wc -l)
        echo "存在，条目数：$cnt"
        if [ -d "$REPO_DEST/repodata" ]; then
            echo "含 repodata：是"
        else
            echo "含 repodata：否"
        fi
    else
        echo "不存在"
    fi

    echo
    echo "==== 本地源 repo 文件 $YUM_REPO_FILE ===="
    if [ -f "$YUM_REPO_FILE" ]; then
        echo "存在"
        grep -E '^[[:space:]]*baseurl' "$YUM_REPO_FILE" 2>/dev/null | head -1 | sed 's/^/  /'
    else
        echo "不存在"
    fi

    echo
    echo "操作日志：$MOUNT_LOG"
}

# ---------- umount ----------

cmd_umount() {
    root_check

    if ! usb_is_mounted; then
        echo "$USB_MOUNT_POINT 未挂载，无需卸载"
        exit 0
    fi
    local dev tran
    dev=$(df -P "$USB_MOUNT_POINT" 2>/dev/null | awk -v m="$(norm_path "$USB_MOUNT_POINT")" 'NR==2 && $6==m {print $1}')
    if [ -n "$dev" ]; then
        tran=$(dev_tran "$dev")
        if [ "$tran" != "usb" ]; then
            echo "警告：$USB_MOUNT_POINT 上挂载的设备 $dev 不是 USB 设备（TRAN=${tran:-未知}），拒绝卸载" >&2
            exit 1
        fi
    fi
    echo "==== 将卸载 ===="
    echo "  $USB_MOUNT_POINT（${dev:-未知设备}）"

    if [ "$DRY_RUN" = "1" ]; then
        echo "（DRY RUN）umount $USB_MOUNT_POINT"
        echo "（DRY RUN）不删除 $REPO_DEST 与 $YUM_REPO_FILE（本地源独立于 U 盘）"
        exit 0
    fi

    local ans=""
    printf "确认卸载 U 盘（y/N）："
    IFS= read -r ans || true
    case "$ans" in
        y|Y) ;;
        *) echo "已取消"; exit 0 ;;
    esac

    if run_log umount "$USB_MOUNT_POINT"; then
        echo "已卸载：$USB_MOUNT_POINT"
    else
        echo "卸载失败：$USB_MOUNT_POINT（结果非 0，见 mount.log）"
        exit 1
    fi

    echo "本地源 $REPO_DEST 与 $YUM_REPO_FILE 未受影响（U 盘可拔）。"
    echo "如需清理本地源，手动执行："
    echo "  rm -rf $REPO_DEST"
    echo "  rm -f $YUM_REPO_FILE"
}
