#!/bin/sh
# diskwipe-iso WSL 内构建函数库（由 build.sh 经 `wsl -e bash -c` 加载执行）。
# 用法：. build-lib.sh && dw_build_iso <项目目录(/mnt/c 映射路径)>
#
# 流程（与设计 §10 一致）：
#   1) apt 安装构建依赖（幂等：已装自动跳过）
#   2) 组装 rootfs/：静态 busybox + 全部 applet 链接、util-linux 动态 wipefs/lsblk/blkid
#      （ldd 收集 .so 依赖按原路径布局拷入）、白名单驱动模块目录 + zstd 解压
#      （.ko.zst → .ko，busybox 无 zstd 解压）+ depmod、
#      src 四脚本（init 强制 chmod +x——内核要求 /init 可执行）+ VERSION → /diskwipe.version
#   3) cpio 打包 initrd.img（gzip）
#   4) 写 boot/grub/grub.cfg（linux /boot/vmlinuz console=tty0 console=ttyS0,115200n8
#      + initrd /boot/initrd.img），放置 vmlinuz/initrd.img 到 rootfs/boot/
#   5) grub-mkrescue 生成 BIOS+UEFI 双引导 iso → <proj>/output/diskwipe-v<版本>.iso
#   6) isoinfo 校验：三个关键文件存在 + grub.cfg 双 console 参数 +
#      initrd 内 /init 执行位 + src 四脚本 dash -n 语法 0 错误
#
# 安全：全部步骤只在 WSL 虚拟盘文件系统与 <proj>/output/ 内产生 iso 文件，
#       绝不写任何块设备（本机物理盘零接触）。
# 任何一步失败 → 打印「✗ ...」并返回非 0（不静默，残留构建目录供排查）。

# 模块白名单（与 src/init 的 DRIVE_MODULES 一致，见设计 §6.2）。
# usb_storage/uas：退出时日志写 U 盘需要（无 U 盘时加载亦无害；依赖 usbcore/scsi_mod/sd_mod 已在列）；
# nls_iso8859-1/exfat/ntfs3：vfat 挂载 iocharset / exfat、ntfs3（模块）退出写日志 U 盘需要
DW_MODULES="ahci libahci libata nvme nvme-core mpt3sas megaraid_sas virtio_blk virtio_pci xhci_pci sd_mod scsi_mod usb_storage uas nls_iso8859-1 exfat ntfs3"
# apt 构建依赖（幂等：已装自动跳过；grub-mkrescue 双引导需要 grub-pc-bin(BIOS) +
# grub-efi-amd64-bin(UEFI)，mtools 提供 mformat 生成 EFI 镜像；
# zstd：Ubuntu 24.04 generic 内核 CONFIG_MODULE_COMPRESS_ZSTD，模块全部 .ko.zst 压缩，
# busybox 静态版无 zstd 解压能力 → 构建期统一解压为 .ko，见 dw_assemble_rootfs 2.3 步）
# parted：提供 /usr/sbin/partprobe（wipefs -a 后刷新内核分区视图，见下 2.2 步）
DW_APT_PKGS="busybox-static xorriso mtools grub-pc-bin grub-efi-amd64-bin linux-image-generic zstd parted"

dw_fail() {
    echo "✗ $*" >&2
    return 1
}

# ---------- 1) 安装构建依赖（幂等） ----------
dw_build_deps() {
    echo "==> [1/7] 安装构建依赖（apt 幂等，已装自动跳过；首次需下载，耗时数分钟）"
    export DEBIAN_FRONTEND=noninteractive
    # root 直跑；非 root 走 sudo -n（需免密）。DW_SUDO 供 chroot/读 /boot 等特权操作复用
    if [ "$(id -u)" -ne 0 ]; then
        sudo -n true 2>/dev/null || { dw_fail "需要 root 或 sudo 免密（请配置 NOPASSWD，见 build.sh 安装指引）"; return 1; }
        DW_SUDO="sudo -n"
        DW_APT="sudo -n apt-get"
    else
        DW_SUDO=""
        DW_APT="apt-get"
    fi
    $DW_APT update || { dw_fail "apt-get update 失败（检查 WSL 网络/DNS）"; return 1; }
    $DW_APT install -y $DW_APT_PKGS || { dw_fail "apt-get install 失败：$DW_APT_PKGS"; return 1; }
    # isoinfo 由 genisoimage 提供（iso 校验必需）；缺失才补装，保持幂等
    command -v isoinfo >/dev/null 2>&1 || {
        echo "==> 未找到 isoinfo，补装 genisoimage（iso 校验用）"
        $DW_APT install -y genisoimage || { dw_fail "安装 genisoimage(isoinfo) 失败"; return 1; }
    }
    echo "     依赖就绪：busybox=$(command -v busybox) isoinfo=$(command -v isoinfo)"
}

# ---------- 2) 组装 initramfs rootfs ----------
dw_assemble_rootfs() {
    rootfs="$1"; proj="$2"; kver="$3"
    echo "==> [2/7] 组装 initramfs rootfs（内核 $kver）"
    mkdir -p "$rootfs"/bin "$rootfs"/sbin "$rootfs"/usr/bin "$rootfs"/usr/sbin \
             "$rootfs"/lib "$rootfs"/lib64 "$rootfs"/etc "$rootfs"/dev "$rootfs"/proc \
             "$rootfs"/sys "$rootfs"/tmp || { dw_fail "创建 rootfs 目录骨架失败"; return 1; }

    # 2.1 静态 busybox + 全部 applet 符号链接（lsblk 除外——用 util-linux 版，busybox 无 wipefs）
    cp /bin/busybox "$rootfs/bin/busybox" || { dw_fail "拷贝 busybox 失败"; return 1; }
    for a in $(/bin/busybox --list); do
        case "$a" in busybox|lsblk) continue ;; esac
        ln -sf busybox "$rootfs/bin/$a"
    done
    echo "     busybox applet 链接数：$(ls "$rootfs"/bin | wc -l)"

    # 2.2 util-linux 动态 wipefs/lsblk/blkid + parted 的 partprobe，统一 ldd 收集 .so
    #    依赖（按原绝对路径布局，动态 loader 运行）。
    # blkid：busybox-static 无 blkid applet（实测 --list 不含）——退出写 U 盘的可写分区
    #       过滤（dw_save_log_to_usb 的 vfat/exfat/ntfs）与系统盘判定（dw_is_system_disk）
    #       都依赖它，必须随 util-linux 拷入
    # partprobe：wipefs -a 后刷新内核分区视图（lib.sh dw_wipe_disk 调用）。注意它来自
    #       GNU parted 包（非 util-linux，实测 dpkg -L util-linux 无 partprobe），随
    #       DW_APT_PKGS 的 parted 安装；ldd 依赖（libparted/libdevmapper/libselinux/
    #       libudev 等）由下方通用 ldd 收集
    for bin in wipefs lsblk blkid partprobe; do
        src_bin="$(command -v "$bin")"
        [ -n "$src_bin" ] || { dw_fail "未找到 util-linux $bin（util-linux 未安装？）"; return 1; }
        case "$bin" in
        wipefs)    dst="$rootfs/usr/sbin/wipefs" ;;
        lsblk)     dst="$rootfs/usr/bin/lsblk" ;;
        blkid)     dst="$rootfs/usr/sbin/blkid" ;;
        partprobe) dst="$rootfs/usr/sbin/partprobe" ;;
        esac
        cp "$src_bin" "$dst" || { dw_fail "拷贝 $bin 失败"; return 1; }
        # ldd 解析：'libx => /abs/path (addr)' 取第 3 字段；'/abs/path (addr)'（如 ld-linux）取第 1 字段
        ldd "$src_bin" 2>/dev/null | awk '/\// { if (index($0,"=>")) p=$3; else p=$1; if (p ~ /^\//) print p }' \
        | while IFS= read -r so; do
            mkdir -p "$rootfs$(dirname "$so")" || { dw_fail "mkdir 失败：$so"; return 1; }
            cp -L "$so" "$rootfs$so" || { dw_fail "拷贝动态依赖 $so 失败"; return 1; }
        done || return 1
    done
    # chroot 实测动态二进制可运行（ldd 依赖完整性硬校验，缺库此处即报错）。
    # 注意：chroot 需要 CAP_SYS_CHROOT，非 root 必须经 sudo -n（实测 uid 1000 直接 chroot 报 EPERM）
    $DW_SUDO chroot "$rootfs" /usr/sbin/wipefs --version >/dev/null 2>&1 \
        || { dw_fail "wipefs 动态依赖不完整（chroot 运行失败）"; return 1; }
    $DW_SUDO chroot "$rootfs" /usr/bin/lsblk --version >/dev/null 2>&1 \
        || { dw_fail "lsblk 动态依赖不完整（chroot 运行失败）"; return 1; }
    $DW_SUDO chroot "$rootfs" /usr/sbin/blkid --version >/dev/null 2>&1 \
        || { dw_fail "blkid 动态依赖不完整（chroot 运行失败）"; return 1; }
    $DW_SUDO chroot "$rootfs" /usr/sbin/partprobe --version >/dev/null 2>&1 \
        || { dw_fail "partprobe 动态依赖不完整（chroot 运行失败）"; return 1; }
    echo "     wipefs/lsblk/blkid/partprobe 动态依赖完整（chroot 实测可运行）"

    # 2.3 内核模块白名单：拷贝驱动目录（含依赖）+ depmod 生成 modules.dep。
    # /lib/modules 下模块文件需 root 可读（/boot、部分模块 0600），统一走 $DW_SUDO
    mkdir -p "$rootfs/lib/modules/$kver/kernel/drivers" || return 1
    for d in ata nvme scsi virtio; do
        [ -d "/lib/modules/$kver/kernel/drivers/$d" ] || { dw_fail "内核模块目录 kernel/drivers/$d 不存在"; return 1; }
        $DW_SUDO cp -a "/lib/modules/$kver/kernel/drivers/$d" "$rootfs/lib/modules/$kver/kernel/drivers/" \
            || { dw_fail "拷贝驱动目录 $d 失败"; return 1; }
    done
    mkdir -p "$rootfs/lib/modules/$kver/kernel/drivers/block" || return 1
    # virtio_blk 在部分内核（如 6.8.0-151）为内建（CONFIG_VIRTIO_BLK=y），无 .ko 文件——跳过即可，
    # 运行时靠下方拷贝的 modules.builtin 使 busybox modprobe 判定「内建，无需加载」
    blk_mods=$(ls /lib/modules/"$kver"/kernel/drivers/block/virtio_blk.ko* 2>/dev/null)
    if [ -n "$blk_mods" ]; then
        $DW_SUDO cp -a $blk_mods "$rootfs/lib/modules/$kver/kernel/drivers/block/" \
            || { dw_fail "拷贝 virtio_blk.ko 失败"; return 1; }
    else
        echo "     virtio_blk 为内核内建（=y），无需模块文件"
    fi
    mkdir -p "$rootfs/lib/modules/$kver/kernel/drivers/usb" || return 1
    $DW_SUDO cp -a "/lib/modules/$kver/kernel/drivers/usb/host" "$rootfs/lib/modules/$kver/kernel/drivers/usb/" \
        || { dw_fail "拷贝 usb/host（xhci-pci）失败"; return 1; }
    # usb/storage：usb_storage/uas 驱动（退出写日志 U 盘需要；usbcore 通常内核内建无模块目录）
    [ -d "/lib/modules/$kver/kernel/drivers/usb/storage" ] || { dw_fail "内核模块目录 kernel/drivers/usb/storage 不存在"; return 1; }
    $DW_SUDO cp -a "/lib/modules/$kver/kernel/drivers/usb/storage" "$rootfs/lib/modules/$kver/kernel/drivers/usb/" \
        || { dw_fail "拷贝 usb/storage（usb_storage/uas）失败"; return 1; }
    # fs/nls + fs/exfat + fs/ntfs3：vfat 挂载需 iocharset 模块（CONFIG_NLS_ISO8859_1=m，
    #    缺失会报 "IO charset iso8859-1 not found" 导致退出写日志 mount 失败）；exfat/ntfs3
    #    为模块（Ventoy 数据区/Windows U 盘）。zstd 压缩由后续统一解压
    mkdir -p "$rootfs/lib/modules/$kver/kernel/fs" || return 1
    for fdir in nls exfat ntfs3; do
        [ -d "/lib/modules/$kver/kernel/fs/$fdir" ] || { dw_fail "内核模块目录 kernel/fs/$fdir 不存在"; return 1; }
        $DW_SUDO cp -a "/lib/modules/$kver/kernel/fs/$fdir" "$rootfs/lib/modules/$kver/kernel/fs/" \
            || { dw_fail "拷贝 fs/$fdir 失败"; return 1; }
    done
    # 拷贝内核安装期生成的 builtin/order 清单（modules.builtin 供 busybox modprobe 识别内建模块；
    # depmod 会重生成 modules.dep/alias/symbols，故先拷后跑）
    for mf in modules.builtin modules.builtin.modinfo modules.order modules.alias modules.symbols; do
        if [ -f "/lib/modules/$kver/$mf" ]; then
            cp "/lib/modules/$kver/$mf" "$rootfs/lib/modules/$kver/$mf" || { dw_fail "拷贝 $mf 失败"; return 1; }
        fi
    done
    # Ubuntu 24.04 generic 内核 CONFIG_MODULE_COMPRESS_ZSTD：模块文件为 .ko.zst；
    # busybox 静态版无 zstd 解压能力（modprobe 加载 .ko.zst 必失败）→ 构建期统一
    # 解压为 .ko。模块经 $DW_SUDO 拷入属主为 root，解压同样走 $DW_SUDO。
    nzst=$(find "$rootfs/lib/modules" -name '*.ko.zst' 2>/dev/null | wc -l)
    if [ "$nzst" -gt 0 ]; then
        $DW_SUDO find "$rootfs/lib/modules" -name '*.ko.zst' -exec zstd -d --rm {} + \
            || { dw_fail "解压 .ko.zst 内核模块失败（zstd 未安装？）"; return 1; }
        echo "     已把 $nzst 个 .ko.zst 模块解压为 .ko（busybox 无 zstd 解压能力）"
    fi
    depmod -b "$rootfs" "$kver" || { dw_fail "depmod 生成模块依赖失败"; return 1; }
    echo "     模块目录已拷入并生成 modules.dep：$(du -sh "$rootfs/lib/modules/$kver" | awk '{print $1}')"

    # 2.4 src 四脚本。关键交接项：src/init 当前 mode 100644，必须 chmod +x——
    #    内核要求 /init 可执行（cpio 打包的是 0755 权限位）
    for f in init menu.sh wipe.sh lib.sh; do
        [ -f "$proj/src/$f" ] || { dw_fail "缺少 src/$f（任务 1-3 未提交？）"; return 1; }
        cp "$proj/src/$f" "$rootfs/$f" || { dw_fail "拷贝 src/$f 失败"; return 1; }
        chmod +x "$rootfs/$f" || { dw_fail "chmod +x $rootfs/$f 失败"; return 1; }
    done
    echo "     src 四脚本已拷入并 chmod +x（/init 执行位满足内核要求）"

    # 2.5 版本文件：VERSION → rootfs /diskwipe.version。menu 横幅与日志文件头经 lib.sh
    #    dw_version 读取（缺失回退 unknown），消除硬编码漂移；幂等（每次覆盖同内容）
    cp "$proj/VERSION" "$rootfs/diskwipe.version" || { dw_fail "拷贝 VERSION → /diskwipe.version 失败"; return 1; }
    echo "     VERSION → /diskwipe.version（$(tr -d ' \r\n' < "$proj/VERSION")）"
}

# ---------- 3) cpio 打包 initrd.img ----------
# 注意：此时 rootfs 尚无 boot/（vmlinuz/initrd/grub 在打包后放入），避免内核/grub 混进 initrd
dw_pack_initrd() {
    rootfs="$1"; build_dir="$2"
    echo "==> [3/7] cpio 打包 initramfs → gzip 生成 initrd.img"
    ( cd "$rootfs" && find . -path ./boot -prune -o -print \
        | cpio -o -H newc 2>/dev/null | gzip -9 > "$build_dir/initrd.img" ) \
        || { dw_fail "cpio 打包 initrd 失败"; return 1; }
    echo "     initrd.img：$(ls -lh "$build_dir/initrd.img" | awk '{print $5}')"
    # 内核要求 /init 可执行——打包后复核权限位
    [ -x "$rootfs/init" ] || { dw_fail "rootfs/init 无执行位（内核要求 /init 可执行）"; return 1; }
}

# ---------- 4) 写 grub.cfg + 放置内核/initrd 到 rootfs/boot ----------
dw_write_bootfiles() {
    rootfs="$1"; build_dir="$2"; kver="$3"; version="$4"
    echo "==> [4/7] 写 boot/grub/grub.cfg + 放置 vmlinuz/initrd.img"
    mkdir -p "$rootfs/boot/grub" || { dw_fail "mkdir boot/grub 失败"; return 1; }
    # /boot/vmlinuz-* 仅 root 可读（Ubuntu 24.04 默认 0600），须经 $DW_SUDO 拷贝；
    # 拷贝后 chmod 0644（源 0600 会令后续 xorriso 以普通用户身份读取失败）
    $DW_SUDO cp "/boot/vmlinuz-$kver" "$rootfs/boot/vmlinuz" || { dw_fail "拷贝 vmlinuz-$kver 失败"; return 1; }
    $DW_SUDO chmod 0644 "$rootfs/boot/vmlinuz" || { dw_fail "chmod vmlinuz 失败"; return 1; }
    cp "$build_dir/initrd.img" "$rootfs/boot/initrd.img" || { dw_fail "拷贝 initrd.img 失败"; return 1; }
    cat > "$rootfs/boot/grub/grub.cfg" <<EOF
set timeout=3
set default=0
menuentry "DiskWipe v$version" {
    linux /boot/vmlinuz console=tty0 console=ttyS0,115200n8
    initrd /boot/initrd.img
}
EOF
    echo "     grub.cfg：linux /boot/vmlinuz console=tty0 console=ttyS0,115200n8 + initrd /boot/initrd.img"
}

# ---------- 5) grub-mkrescue 生成 BIOS+UEFI 双引导 iso ----------
dw_mkrescue() {
    rootfs="$1"; proj="$2"; iso="$3"
    echo "==> [5/7] grub-mkrescue 生成 BIOS+UEFI 双引导 iso → $iso"
    mkdir -p "$proj/output" || { dw_fail "创建 output/ 失败"; return 1; }
    rm -f "$iso" || { dw_fail "清理旧 iso 失败"; return 1; }
    # 注：Ubuntu 24.04 grub 2.12 下「-- -V DISKWIPE rootfs」形式会被 xorriso 当命令拒绝
    #（实测 "Not a known command"），正确写法是 -V 置于源目录之前
    grub-mkrescue -o "$iso" -V DISKWIPE "$rootfs" \
        || { dw_fail "grub-mkrescue 失败（见上方输出）"; return 1; }
    echo "     iso：$(ls -lh "$iso" | awk '{print $5}')"
}

# ---------- 6) isoinfo 校验 ----------
dw_verify_iso() {
    iso="$1"; build_dir="$2"; proj="$3"
    echo "==> [6/7] isoinfo 校验 iso"
    echo "     卷信息：$(isoinfo -i "$iso" -d 2>/dev/null | grep -i '^Volume id' | head -n 1)"

    # 6.1 三个关键文件。isoinfo -R -l 为树形输出（"Directory listing of /boot/grub/" 段下
    # 逐行列出文件名），按「目录段 + 文件名」两段式校验；再以 -x 从 iso 实际抽取实检
    il="$(isoinfo -R -i "$iso" -l 2>/dev/null)"
    for spec in "boot/grub/ grub.cfg" "boot/ vmlinuz" "boot/ initrd.img"; do
        set -- $spec
        ok=$(printf '%s\n' "$il" | awk -v d="/$1" -v f="$2" '
            /^Directory listing of / { insec = ($0 ~ ("of " d "$")); next }
            insec && $NF == f { found = 1 }
            END { print found + 0 }')
        [ "$ok" = "1" ] || { dw_fail "iso 缺少 $1$2（isoinfo -R -l 未列出）"; return 1; }
    done
    for p in /boot/grub/grub.cfg /boot/vmlinuz /boot/initrd.img; do
        isoinfo -R -i "$iso" -x "$p" > "$build_dir/x.out" 2>/dev/null || { dw_fail "iso 无法抽取 $p"; return 1; }
        [ -s "$build_dir/x.out" ] || { dw_fail "iso 抽取 $p 内容为空"; return 1; }
    done
    echo "     校验通过：boot/grub/grub.cfg、boot/vmlinuz、boot/initrd.img 均在 iso 中（-l 目录树 + -x 抽取实检）"

    # 6.2 grub.cfg 含双 console 参数
    gcfg="$(isoinfo -R -i "$iso" -x /boot/grub/grub.cfg 2>/dev/null)"
    printf '%s\n' "$gcfg" | grep -q 'console=tty0' || { dw_fail "grub.cfg 缺少 console=tty0"; return 1; }
    printf '%s\n' "$gcfg" | grep -q 'console=ttyS0,115200n8' || { dw_fail "grub.cfg 缺少 console=ttyS0,115200n8"; return 1; }
    echo "     校验通过：grub.cfg 含 console=tty0 与 console=ttyS0,115200n8"

    # 6.3 initrd 内 /init 执行位（解包实检）
    isoinfo -R -i "$iso" -x /boot/initrd.img > "$build_dir/initrd.check.img" 2>/dev/null \
        || { dw_fail "提取 initrd.img 失败"; return 1; }
    rm -rf "$build_dir/initrdx"; mkdir -p "$build_dir/initrdx" || return 1
    ( cd "$build_dir/initrdx" && gzip -dc "$build_dir/initrd.check.img" 2>/dev/null | cpio -id 2>/dev/null ) \
        || { dw_fail "解包 initrd.img 失败"; return 1; }
    [ -x "$build_dir/initrdx/init" ] || { dw_fail "initrd 内 /init 无执行位（内核要求可执行）"; return 1; }
    echo "     校验通过：initrd 内 /init 具执行位"
    # 6.3b 版本文件：initrd 内 /diskwipe.version 必须存在且整行等于 VERSION（menu 横幅/日志头来源）
    dwver="$(tr -d ' \r\n' < "$proj/VERSION")"
    if ! grep -qxF "$dwver" "$build_dir/initrdx/diskwipe.version" 2>/dev/null; then
        dw_fail "initrd 内 /diskwipe.version 缺失或内容错误（应整行含 $dwver）"; return 1
    fi
    echo "     校验通过：initrd 内 /diskwipe.version = $dwver"

    # 6.4 src 四脚本 dash -n 语法检查（WSL dash）
    for f in init menu.sh wipe.sh lib.sh; do
        dash -n "$proj/src/$f" || { dw_fail "dash -n 语法错误：src/$f"; return 1; }
    done
    echo "     校验通过：src 四脚本 dash -n 语法 0 错误"

    # 6.5 initrd 内模块必须为未压缩 .ko（busybox 无 zstd 解压，.ko.zst 加载必失败）
    if find "$build_dir/initrdx/lib/modules" -name '*.ko.zst' 2>/dev/null | grep -q .; then
        dw_fail "initrd 内仍有 .ko.zst 模块（busybox 无法解压加载）"; return 1
    fi
    nko=$(find "$build_dir/initrdx/lib/modules" -name '*.ko' 2>/dev/null | wc -l)
    [ "$nko" -gt 0 ] || { dw_fail "initrd 内无任何未压缩 .ko 模块"; return 1; }
    echo "     校验通过：initrd 内模块全部为未压缩 .ko（共 $nko 个，无 .ko.zst 残留）"
}

# ---------- 主入口 ----------
dw_build_iso() {
    proj="$1"
    [ -n "$proj" ] && [ -f "$proj/VERSION" ] || { dw_fail "项目目录无效：$proj（VERSION 不存在）"; return 1; }
    version="$(tr -d ' \r\n' < "$proj/VERSION")"
    [ -n "$version" ] || { dw_fail "VERSION 为空"; return 1; }
    iso="$proj/output/diskwipe-v$version.iso"

    build_dir="$(mktemp -d "${TMPDIR:-/tmp}/diskwipe-build.XXXXXX")" \
        || { dw_fail "创建临时构建目录失败"; return 1; }
    rootfs="$build_dir/rootfs"
    mkdir -p "$rootfs" || { dw_fail "创建 rootfs 失败"; return 1; }

    dw_build_deps       || { echo "✗ 构建中止。临时目录在 WSL /tmp 内（会话结束即失效，仅当次会话可排查）：$build_dir" >&2; return 1; }
    kver="$(ls /boot/vmlinuz-*-generic 2>/dev/null | sed 's/.*vmlinuz-//' | sort -V | tail -n 1)"
    [ -n "$kver" ] || { dw_fail "未找到 /boot/vmlinuz-*-generic（linux-image-generic 未安装？）"; rm -rf "$build_dir"; return 1; }
    echo "==> 使用内核：$kver"
    dw_assemble_rootfs "$rootfs" "$proj" "$kver" || { echo "✗ 构建中止。临时目录在 WSL /tmp 内（会话结束即失效）：$build_dir" >&2; return 1; }
    dw_pack_initrd      "$rootfs" "$build_dir" || { echo "✗ 构建中止。临时目录在 WSL /tmp 内（会话结束即失效）：$build_dir" >&2; return 1; }
    dw_write_bootfiles  "$rootfs" "$build_dir" "$kver" "$version" || { echo "✗ 构建中止。临时目录在 WSL /tmp 内（会话结束即失效）：$build_dir" >&2; return 1; }
    dw_mkrescue         "$rootfs" "$proj" "$iso" || { echo "✗ 构建中止。临时目录在 WSL /tmp 内（会话结束即失效）：$build_dir" >&2; return 1; }
    dw_verify_iso       "$iso" "$build_dir" "$proj" || { echo "✗ 构建中止。临时目录在 WSL /tmp 内（会话结束即失效）：$build_dir" >&2; return 1; }

    # 模块经 $DW_SUDO 拷贝后属主为 root，清理须同样走 sudo
    $DW_SUDO rm -rf "$build_dir"
    sz="$(ls -lh "$iso" | awk '{print $5}')"
    echo
    echo "======================================================"
    echo "  ✓ 构建成功：$iso（大小 $sz）"
    echo "  BIOS+UEFI 双引导 grub-mkrescue iso；isoinfo 校验全部通过"
    echo "  使用：将 iso 写入 U 盘（Ventoy/Rufus 等）后从 U 盘启动即可"
    echo "======================================================"
}
