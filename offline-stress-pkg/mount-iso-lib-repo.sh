
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
