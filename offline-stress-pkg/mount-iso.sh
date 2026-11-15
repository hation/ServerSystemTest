#!/bin/bash
# mount-iso.sh —— U盘挂载 + yum 源构建/复制/配置 一键脚本（Kylin V10 SP3，无外网服务器）
# 用法：
#   bash mount-iso.sh build [--rpm-dir /path/to/rpms]   # 构建 yum 源（createrepo 生成 repodata）
#   bash mount-iso.sh mount                              # 一键：U盘挂载 → 复制源目录到 /opt/kylin-repo → 配置本地yum源
#   bash mount-iso.sh status                             # 查看挂载与本地源状态
#   bash mount-iso.sh umount                             # 卸载U盘（确认后执行；不影响已复制的本地源）
# 环境变量（测试接缝）：
#   DRY_RUN=1          只打印执行计划，不执行任何写操作（跳过交互确认）
#   SKIP_ROOT_CHECK=1  跳过 root 检查（仅本地测试用）
#   LSBLK_BIN          块设备查询命令（默认 lsblk，测试可用伪造输出）
#   CREATEREPO_BIN     createrepo 命令（默认 createrepo，测试可用伪造）
#   MOUNT_LOG          操作日志路径（默认 /root/stress-test/mount.log）
#   USB_MOUNT_POINT    U盘挂载点（默认 /mnt/usb）
#   REPO_DEST          源目录复制/构建目标（默认 /opt/kylin-repo）
#   YUM_REPO_FILE      本地源repo文件（默认 /etc/yum.repos.d/kylin-local.repo）
#   PKG_RPMS_DIR       包内RPM目录（默认脚本同目录 rpms/）
# 退出码：0=正常（含取消/DRY_RUN 计划）；1=用法错误/前置不满足/无 USB 盘/RPM 或 repodata 缺失
# 说明：全程不 set -e；系统盘（df / 所在盘）任何分支硬排除；每步操作写 MOUNT_LOG。

DRY_RUN="${DRY_RUN:-0}"
SKIP_ROOT_CHECK="${SKIP_ROOT_CHECK:-0}"
MOUNT_LOG="${MOUNT_LOG:-/root/stress-test/mount.log}"
LSBLK_BIN="${LSBLK_BIN:-lsblk}"
CREATEREPO_BIN="${CREATEREPO_BIN:-createrepo}"
USB_MOUNT_POINT="${USB_MOUNT_POINT:-/mnt/usb}"
REPO_DEST="${REPO_DEST:-/opt/kylin-repo}"
YUM_REPO_FILE="${YUM_REPO_FILE:-/etc/yum.repos.d/kylin-local.repo}"
PKG_RPMS_DIR="${PKG_RPMS_DIR:-$(dirname "$0")/rpms}"

now() { date '+%Y-%m-%d %H:%M:%S'; }

usage() {
    cat <<EOF
用法:
  bash mount-iso.sh build [--rpm-dir /path/to/rpms]   # 构建 yum 源（createrepo 生成 repodata）
  bash mount-iso.sh mount                              # 一键：U盘挂载 → 复制源目录到 $REPO_DEST → 配置本地yum源
  bash mount-iso.sh status                             # 查看挂载与本地源状态
  bash mount-iso.sh umount                             # 卸载U盘（确认后执行；不影响已复制的本地源）

build 的 RPM 来源优先级：U盘内（已挂载且含 *.rpm） > --rpm-dir > 包内 rpms/
复制目标：$REPO_DEST（默认 /opt/kylin-repo）；U 盘已挂载时另写一份 $USB_MOUNT_POINT/kylin-repo

测试接缝（本地测试用）:
  DRY_RUN=1           只打印计划不执行（跳过交互确认）
  SKIP_ROOT_CHECK=1   跳过 root 检查
  LSBLK_BIN           块设备查询命令（默认 lsblk，测试可伪造）
  CREATEREPO_BIN      createrepo 命令（默认 createrepo，测试可伪造）
  MOUNT_LOG           操作日志路径（默认 /root/stress-test/mount.log）
  USB_MOUNT_POINT     U盘挂载点（默认 /mnt/usb）
  REPO_DEST           源目录复制/构建目标（默认 /opt/kylin-repo）
  YUM_REPO_FILE       本地源repo文件（默认 /etc/yum.repos.d/kylin-local.repo）
  PKG_RPMS_DIR        包内RPM目录（默认脚本同目录 rpms/）
EOF
}

root_check() {
    if [ "$SKIP_ROOT_CHECK" != "1" ] && [ "$(id -u)" -ne 0 ]; then
        echo "请以 root 运行：sudo bash mount-iso.sh"
        exit 1
    fi
}

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

# ---------- 目录判定 / 定位 ----------

# 目录内是否含 *.rpm（maxdepth 2，兼容 rpms/ 子目录）
dir_has_rpm() {
    [ -d "$1" ] || return 1
    [ -n "$(find "$1" -maxdepth 2 -type f -name '*.rpm' 2>/dev/null | head -1)" ]
}

# 定位实际含 *.rpm 的目录：优先 <root>/rpms，其次 root 下 maxdepth 2 内首个 rpm 所在目录
# 找不到返回 1（stdout 只输出目录路径）
locate_rpm_dir() {
    local root="$1" f
    [ -d "$root" ] || return 1
    f=$(find "$root/rpms" -maxdepth 1 -type f -name '*.rpm' 2>/dev/null | head -1)
    if [ -n "$f" ]; then
        echo "$root/rpms"
        return 0
    fi
    f=$(find "$root" -maxdepth 2 -type f -name '*.rpm' 2>/dev/null | head -1)
    [ -n "$f" ] || return 1
    dirname "$f"
}

# 定位 $USB_MOUNT_POINT 内含 repodata 的目录（repodata 的父目录）；stdout 只输出路径，提示走 stderr
find_repodata_dir() {
    local d first="" n=0
    while IFS= read -r d; do
        [ -n "$d" ] || continue
        n=$((n + 1))
        [ -z "$first" ] && first="$(dirname "$d")"
    done < <(find "$USB_MOUNT_POINT" -maxdepth 3 -type d -name repodata 2>/dev/null)
    if [ -z "$first" ]; then
        echo "U 盘（$USB_MOUNT_POINT）内未发现含 repodata 的 yum 源目录（find -maxdepth 3 -type d -name repodata 无结果）" >&2
        return 1
    fi
    [ "$n" -gt 1 ] && echo "提示：发现 $n 个含 repodata 的目录，取第一个：$first" >&2
    echo "$first"
}

# createrepo 命令可用性（支持 CREATEREPO_BIN 为含空格的命令，如 "bash /path/fake"）
createrepo_ok() {
    local first
    set -- $CREATEREPO_BIN
    first="$1"
    [ -x "$first" ] && return 0
    command -v "$first" >/dev/null 2>&1
}

# ---------- 公共：复制与写 repo 文件 ----------

# 规范化路径（优先 realpath -m；不可用时折叠结尾 /）
norm_path() {
    local p="$1"
    [ -n "$p" ] || return 0
    if command -v realpath >/dev/null 2>&1; then
        realpath -m "$p" 2>/dev/null && return 0
    fi
    while [ "$p" != "/" ] && [ "${p%/}" != "$p" ]; do p="${p%/}"; done
    echo "$p"
}

# $1 是否位于 $2 目录内部（相等也视为内部），用于避免源/目标同一导致自我复制
is_path_inside() {
    local inner outer
    inner=$(norm_path "$1")
    outer=$(norm_path "$2")
    [ -n "$inner" ] && [ -n "$outer" ] || return 1
    [ "$inner" = "$outer" ] && return 0
    [ "$outer" = "/" ] && return 0
    case "$inner" in
        "$outer"/*) return 0 ;;
    esac
    return 1
}

# 源目录复制到目标（mkdir -p + cp -r 源/. 目标/）；目标已存在非空 → 交互询问覆盖合并/跳过
# 返回 0=成功（含用户选择跳过）；1=复制失败
copy_dir_into() {
    local src="$1" dst="$2" ans=""
    if [ -d "$dst" ] && [ -n "$(ls -A "$dst" 2>/dev/null)" ]; then
        echo "目标目录 $dst 已存在且非空"
        if [ "$DRY_RUN" = "1" ]; then
            echo "（DRY RUN）将询问覆盖合并/跳过：mkdir -p $dst && cp -r $src/. $dst/"
            return 0
        fi
        printf "目标已存在非空，覆盖合并（y）还是跳过（N）："
        IFS= read -r ans || true
        case "$ans" in
            y|Y) echo "覆盖合并到 $dst"; log_cmd "copy overwrite: $src -> $dst" ;;
            *) echo "跳过复制到 $dst（本地 $dst 保留现状）"; log_cmd "copy skip: $src -> $dst (target exists)"; return 0 ;;
        esac
    fi
    echo "复制 $src → $dst"
    if [ "$DRY_RUN" = "1" ]; then
        echo "（DRY RUN）mkdir -p $dst"
        echo "（DRY RUN）cp -r $src/. $dst/"
        return 0
    fi
    if run_log mkdir -p "$dst" && run_log cp -r "$src/." "$dst/"; then
        echo "复制完成：$src → $dst"
        return 0
    fi
    echo "复制失败：$src → $dst（结果非 0，见 mount.log）"
    return 1
}

# 写本地源 repo 文件；返回 0=新写入成功，2=已存在未修改，1=写入失败
write_repo_file() {
    local content
    if [ -f "$YUM_REPO_FILE" ]; then
        echo "repo 文件已存在：$YUM_REPO_FILE（跳过，不覆盖）"
        return 2
    fi
    echo "==== 配置本地 yum 源：$YUM_REPO_FILE ===="
    content="[kylin-local]
name=Kylin Local Repo
baseurl=file://$REPO_DEST
enabled=1
gpgcheck=0
"
    if [ "$DRY_RUN" = "1" ]; then
        echo "（DRY RUN）写入 $YUM_REPO_FILE："
        printf '%s' "$content"
        return 0
    fi
    if mkdir -p "$(dirname "$YUM_REPO_FILE")" && printf '%s' "$content" > "$YUM_REPO_FILE"; then
        echo "已写入 $YUM_REPO_FILE"
        log_cmd "write repo file: $YUM_REPO_FILE"
        return 0
    fi
    echo "写入 $YUM_REPO_FILE 失败"
    return 1
}

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

# ---------- 子命令分发 ----------

CMD="${1:-}"
shift || true
case "$CMD" in
    build)   cmd_build "$@" ;;
    mount)   cmd_mount "$@" ;;
    status)  cmd_status ;;
    umount)  cmd_umount ;;
    *) usage; exit 1 ;;
esac
