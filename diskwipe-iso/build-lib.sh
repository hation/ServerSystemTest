#!/bin/sh
# diskwipe-iso WSL 内构建函数库（由 build.sh 经 `wsl -e bash -c` 加载执行）。
# 用法：. build-lib.sh && dw_build_iso <项目目录(/mnt/c 映射路径)>
#
# v1.4.0 内核双模式：
#   - ubuntu 模式（默认）：内核/模块取自 WSL Ubuntu generic 内核（/boot/vmlinuz-*-generic +
#     /lib/modules/<kver>），模块 .ko.zst 构建期解压为 .ko，depmod 生成 modules.dep。
#   - kylin 模式：内核/模块取自 <proj>/kylin-src/（从目标 Kylin 服务器提取的材料）——
#     解决 Ubuntu 内核 xhci/USB 与该海光服务器 Microchip hub 不兼容（dmesg
#     `hub_event hogged CPU`）导致启动卡死；Kylin 4.19 内核 USB 栈内建、正常。
#     模块按 src/init 白名单 + modules.dep 依赖链从 kylin-src/modules/<kver> 提取，
#     .ko.xz 解压为 .ko（busybox modprobe 不支持 xz），modules.dep/modules.alias 等
#     清单拷入并 sed 改后缀；固件仅拷 amd-ucode（CPU 微码，缺失不阻塞）。
#     自动检测：kylin-src/boot/vmlinuz-4.19* 存在即用 Kylin 内核；或 DW_KERNEL_MODE
#     （auto|ubuntu|kylin，build.sh 可透传）显式指定。
# v1.5.0 引导方式重构（BIOS → ISOLINUX + UEFI → 精简 GRUB），根治两个真机问题：
#   - 问题1（GRUB 视频模式盲模式卡死）：grub-mkrescue 的 GRUB 2.12 core 内嵌 gfxterm，
#     在该海光服务器无合适视频模式 → "error: no suitable video mode found. Booting in
#     blind mode" → 盲模式 boot 卡死（黑屏）。v1.5.0 起 BIOS 引导不再经 GRUB，改
#     ISOLINUX（syslinux，纯文本 VGA，无视频模式概念）；UEFI 引导用 grub-mkimage
#     手动打包的精简 GRUB（剔除 gfxterm/video/video_fb/efi_gop/efi_uga 模块，纯文本终端）。
#   - 问题2（initrd 传递）：Ventoy「grub2 mode」（Ventoy 自己的 grub 2.04）执行我们的
#     grub.cfg 时打印 loading initrd 但内核未收到 initramfs（无 Unpacking initramfs/
#     Run /init），卡在无 initramfs + 无 root= 挂 root。initrd 本身完全正常（/init 755、
#     busybox 静态 x86-64、gzip 格式 Kylin 4.19 支持）。v1.5.0 起 BIOS 路径 initrd 加载
#     走 syslinux 成熟路径（isolinux.cfg 的 KERNEL + APPEND initrd=）。
#   iso 生成由 grub-mkrescue 改为 xorriso 手动打包（见 dw_mkiso）：
#     isohdpfx.bin 作混合 MBR + El Torito BIOS 项 isolinux/isolinux.bin +
#     El Torito UEFI 项 EFI/BOOT/BOOTX64.EFI（embedded 配置 search -f /boot/grub/grub.cfg
#     + terminal_output console 文本终端）+ -isohybrid-gpt-basdat。
#
# 流程（与设计 §10 一致）：
#   1) apt 安装构建依赖（幂等：已装自动跳过）
#   2) 组装 rootfs/：静态 busybox + 全部 applet 链接、util-linux 动态 wipefs/lsblk/blkid
#      （ldd 收集 .so 依赖按原路径布局拷入）、白名单驱动模块目录（ubuntu：整目录 +
#      zstd 解压 .ko.zst → .ko + depmod；kylin：白名单 + 依赖链提取 .ko.xz → xz 解压 +
#      manifest sed 改后缀）+ src 四脚本（init 强制 chmod +x——内核要求 /init 可执行）
#      + VERSION → /diskwipe.version
#   3) cpio 打包 initrd.img（gzip）
#   4) 写引导文件 + 放置 vmlinuz/initrd.img 到 rootfs/boot/：
#      boot/grub/grub.cfg（UEFI 精简 GRUB 用，文本终端 terminal_output console +
#      gfxmode/gfxpayload=text，linux /boot/vmlinuz console=tty0 console=ttyS0,115200n8
#      + initrd）、isolinux/isolinux.bin + isolinux.cfg（BIOS 用，KERNEL /boot/vmlinuz +
#      APPEND console=tty0 console=ttyS0,115200n8 initrd=/boot/initrd.img）、
#      EFI/BOOT/BOOTX64.EFI（grub-mkimage 精简版，无 gfxterm/video 模块）
#   5) xorriso 手动打包 BIOS(ISOLINUX)+UEFI(精简 GRUB) 双引导 iso →
#      <proj>/output/diskwipe-v<版本>.iso（替代 grub-mkrescue）
#   6) isoinfo 校验：isolinux.bin/isolinux.cfg、EFI/BOOT/BOOTX64.EFI、boot/grub/grub.cfg、
#      boot/vmlinuz、boot/initrd.img 存在 + isolinux.cfg/grub.cfg 双 console 参数 +
#      initrd 内 /init 执行位 + src 四脚本 dash -n 语法 0 错误 +
#      kylin 模式追加：vmlinuz 为 Kylin 4.19（strings 版本串）+ 关键模块未压缩 .ko
#
# 安全：全部步骤只在 WSL 虚拟盘文件系统与 <proj>/output/ 内产生 iso 文件，
#       绝不写任何块设备（本机物理盘零接触）。
# 任何一步失败 → 打印「✗ ...」并返回非 0（不静默，残留构建目录供排查）。

# 模块白名单（与 src/init 的 DRIVE_MODULES 一致，见设计 §6.2）。
# usb_storage/uas：退出时日志写 U 盘需要（无 U 盘时加载亦无害；依赖 usbcore/scsi_mod/sd_mod 已在列）；
# nls_iso8859-1/exfat/ntfs3：vfat 挂载 iocharset / exfat、ntfs3（模块）退出写日志 U 盘需要
# v1.5.19：megaraid_sas 已去掉——与 mpt3sas 竞争同一 LSI SAS 控制器（联网确认 Broadcom/
# Proxmox/Dell 已知问题，需禁用其一）；v1.5.6 唯一 sda 识别成功盘在 mpt3sas 无需
# megaraid_sas，只留 mpt3sas 独占控制器（与 src/init 白名单同步）
DW_MODULES="ahci libahci libata nvme nvme-core mpt3sas virtio_blk virtio_pci xhci_pci sd_mod scsi_mod usb_storage uas nls_iso8859-1 exfat ntfs3"
# Kylin 4.19 白名单（文件名形态，与 src/init 的 Kylin DRIVE_MODULES 一致，见设计 §6.2）：
# 与 Ubuntu 差异：xhci_pci/scsi_mod/virtio_pci/virtio/usbcore/ehci/ohci 为内核内建
# （modules.builtin，无模块文件）；exfat/ntfs3 无模块（Kylin 4.19 未引入）；
# usb-storage 为文件名（非 usb_storage）；vfat/fat 为模块（Kylin 退出写日志 U 盘 vfat
# 挂载需要）。依赖链（ahci→libahci→libata、nvme→nvme-core→nvme-common、
# mpt3sas→raid_class+scsi_transport_sas、usb-storage→scsi_mod、vfat→fat）
# 由 dw_modules_kylin 按 modules.dep 解析
# v1.5.17 恢复 usb-storage + uas（v1.5.6 唯一 sda 识别成功的配置：usb-storage 加载触发
# SCSI 扫描带出 SAS 盘；v1.5.8 曾去掉 uas（UAS 绑定 ASolid U 盘协议异常 D 状态卡死）、
# v1.5.9 曾去掉 usb-storage（U 盘绑定读盘触发内核 I/O 阻塞）——v1.5.17 以 init 内
# 「就绪后 rmmod 卸载」化解（SAS 盘带出后卸载防 U 盘卡死）；initrd 重新打包 usb-storage/uas
# v1.5.19：megaraid_sas 已去掉——与 mpt3sas 竞争同一 LSI SAS 控制器（联网确认
# Broadcom/Proxmox/Dell 已知问题；v1.5.6 盘在 mpt3sas、无需 megaraid_sas），只留
# mpt3sas 独占控制器带出 SAS 盘（与 src/init Kylin 白名单同步）
DW_KYLIN_MODULES="ahci libahci libata nvme nvme-core mpt3sas virtio_blk sd_mod usb-storage uas nls_iso8859-1 vfat fat ast"
# v1.5.6 显卡种子只保留 ast（Kylin 模式）：真机为 AST2500；mgag200/smifb/bochs-drm/cirrus/
# virtio-gpu 在无对应硬件时 modprobe 可能内核 D 状态挂起（用户态 timeout 无效）导致 init
# 卡死（真机实证 sdb 枚举后无输出）——initrd 不再打包这些模块（构建体积减小、init 无法
# 加载它们），需要时按机器单独加入。依赖链（ttm、i2c-algo-bit、drm_kms_helper、drm、
# fb_sys_fops、syscopyarea、sysfillrect、sysimgblt）由 dw_modules_kylin 按 modules.dep
# 自动解析提取；无对应显卡的机型加载失败亦无害（src/init 静默跳过）。
# apt 构建依赖（幂等：已装自动跳过）。
# isolinux：提供 /usr/lib/ISOLINUX/isolinux.bin + isohdpfx.bin（v1.5.0 BIOS ISOLINUX
#   引导与混合 MBR 必需；syslinux 为其依赖包，一并安装）
# grub-efi-amd64-bin：提供 grub-mkimage 的 x86_64-efi 模块（v1.5.0 UEFI 精简 GRUB
#   BOOTX64.EFI 打包必需）
# grub-pc-bin/mtools：旧 grub-mkrescue 依赖（v1.5.0 不再使用 grub-mkrescue；保留安装
#   无副作用，幂等跳过）；mtools 的 mcopy/mmd 现用于封 FAT efi.img（UEFI 引导镜像）
# dosfstools：提供 mkfs.vfat（格式化 efi.img 用，v1.5.0 UEFI 引导镜像必需）
# zstd：Ubuntu 24.04 generic 内核 CONFIG_MODULE_COMPRESS_ZSTD，模块全部 .ko.zst 压缩，
# busybox 静态版无 zstd 解压能力 → 构建期统一解压为 .ko，见 dw_assemble_rootfs 2.3 步）
# xz-utils：Kylin 4.19 模块为 .ko.xz 压缩（CONFIG_MODULE_COMPRESS_XZ），busybox 无 xz
# 解压能力 → dw_modules_kylin 构建期统一 xz -d 解压为 .ko（xz-utils 提供 xz 命令）
# parted：提供 /usr/sbin/partprobe（wipefs -a 后刷新内核分区视图，见下 2.2 步）
DW_APT_PKGS="busybox-static xorriso mtools grub-pc-bin grub-efi-amd64-bin linux-image-generic zstd xz-utils parted isolinux dosfstools"

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

# ---------- 2.3k) Kylin 内核模块：按白名单 + modules.dep 依赖链提取（.ko.xz → .ko） ----------
# v1.4.0 Kylin 模式专用。材料源：<proj>/kylin-src/modules/<kver>/（从目标 Kylin 服务器
# 提取，与 /lib/modules/<kver> 同布局）。步骤：
#   1) 按 DW_KYLIN_MODULES 白名单在 kylin-src/modules/<kver>/kernel/ 下定位 .ko.xz
#      （缺失模块跳过、不中断——如个别白名单模块该内核无文件）；
#   2) 一次 awk 读 modules.dep 建依赖图 + DFS 递归解析依赖链（ahci→libahci→libata、
#      nvme→nvme-core→nvme-common、mpt3sas→raid_class+scsi_transport_sas、vfat→fat），
#      输出全部 .ko.xz 相对路径；
#   3) 按相对路径拷入 rootfs/lib/modules/<kver>/（保持原布局，busybox modprobe 按
#      modules.dep 路径解析）；
#   4) 统一 xz -d 解压为 .ko（busybox 无 xz 解压能力，.ko.xz 加载必失败）；
#   5) modules.dep/modules.alias/modules.builtin/modules.order/modules.symbols 等清单
#      从 kylin-src/modules/<kver>/ 拷贝并 sed 's/\.ko\.xz/.ko/' 改后缀
#      （busybox modprobe 依赖这些文本清单定位模块与依赖）；
#   6) 固件：仅拷 amd-ucode（CPU 微码）到 rootfs/lib/firmware/（磁盘/网卡驱动所需
#      固件缺失不阻塞——目标驱动已在 Kylin 服务器确认可用）。
# 全部拷贝源为 /mnt/c 上世界可读文件，无需 sudo；kylin-src/ 不入库（git 忽略），
# 由 kylin-kernel-export.sh 在 Kylin 服务器提取、kylin-src-<日期>.tar.gz 传回解压。
dw_modules_kylin() {
    rootfs="$1"; proj="$2"; kver="$3"
    ksrc="$proj/kylin-src/modules/$kver"
    [ -d "$ksrc/kernel" ] || { dw_fail "kylin-src 模块目录不存在：$ksrc/kernel（kylin-src 未解压/不完整？）"; return 1; }
    [ -f "$ksrc/modules.dep" ] || { dw_fail "kylin-src 缺 modules.dep（Kylin 材料不完整？）"; return 1; }

    # 1) 白名单定位 .ko.xz（find 全树按文件名匹配；缺失跳过不中断）
    seeds=""
    for m in $DW_KYLIN_MODULES; do
        p=$(find "$ksrc/kernel" -name "$m.ko.xz" 2>/dev/null | head -n 1)
        if [ -n "$p" ]; then
            seeds="${seeds:+$seeds }${p#$ksrc/}"
        else
            echo "     Kylin 模块 $m 无 .ko.xz（该内核未提供，跳过；缺失不中断）"
        fi
    done
    [ -n "$seeds" ] || { dw_fail "Kylin 白名单模块全部缺失（kylin-src 无效？）"; return 1; }

    # 2) 依赖链解析（一次 awk：读 modules.dep 建「模块路径→依赖路径列表」图，DFS 收集
    #    全部被引用模块；SEEDS 为白名单初始路径（经 -v 传入——gawk 管道 stdin 模式
    #    下命令行 VAR=value 赋值不生效，实测为空）
    mods="$(printf '%s\n' "$seeds" | awk -v depfile="$ksrc/modules.dep" -v SEEDS="$seeds" '
        BEGIN {
            while ((getline line < depfile) > 0) {
                key = line
                sub(/:.*/, "", key)
                sub(/^[^:]*: ?/, "", line)
                deps[key] = line
            }
            n = split(SEEDS, arr, " ")
            for (i = 1; i <= n; i++) if (arr[i] != "") push(arr[i])
            while (sp > 0) {
                p = stack[sp--]
                if (seen[p]) continue
                seen[p] = 1
                out[++o] = p
                ds = deps[p]
                m = split(ds, darr, " ")
                for (i = 1; i <= m; i++) if (darr[i] != "") push(darr[i])
            }
            for (i = 1; i <= o; i++) print out[i]
        }
        function push(x) { stack[++sp] = x }
    ')"
    [ -n "$mods" ] || { dw_fail "Kylin 依赖链解析为空（modules.dep 无效？）"; return 1; }
    echo "     Kylin 模块提取：白名单 + 依赖链共 $(printf '%s\n' "$mods" | wc -l) 个 .ko.xz"

    # 3) 按相对路径拷入（保持原布局）
    while IFS= read -r p; do
        [ -n "$p" ] || continue
        mkdir -p "$rootfs/lib/modules/$kver/$(dirname "$p")" || { dw_fail "mkdir 失败：$p"; return 1; }
        cp "$ksrc/$p" "$rootfs/lib/modules/$kver/$p" || { dw_fail "拷贝 Kylin 模块 $p 失败"; return 1; }
    done <<EOF
$mods
EOF

    # 4) .ko.xz → .ko（xz -d 成功后默认删除源文件；busybox 无 xz 解压能力）
    nxz=$(find "$rootfs/lib/modules/$kver" -name '*.ko.xz' 2>/dev/null | wc -l)
    if [ "$nxz" -gt 0 ]; then
        find "$rootfs/lib/modules/$kver" -name '*.ko.xz' -exec xz -d {} + \
            || { dw_fail "解压 .ko.xz 内核模块失败（xz-utils 未安装？）"; return 1; }
        echo "     已把 $nxz 个 .ko.xz 模块解压为 .ko（busybox 无 xz 解压能力）"
    fi

    # 5) manifest 清单：拷贝并 sed 改后缀（modules.dep/alias/symbols 引用 .ko.xz →
    #    .ko，与解压后文件一致；modules.builtin 本身为 .ko 形态，sed 无影响）
    for mf in modules.dep modules.alias modules.builtin modules.builtin.modinfo modules.order modules.symbols modules.softdep modules.devname; do
        if [ -f "$ksrc/$mf" ]; then
            sed 's/\.ko\.xz/.ko/g' "$ksrc/$mf" > "$rootfs/lib/modules/$kver/$mf" \
                || { dw_fail "改写 Kylin $mf 失败"; return 1; }
        fi
    done
    echo "     modules.dep/modules.alias 等已拷入并 sed 改后缀（.ko.xz → .ko）"

    # 6) 固件：amd-ucode（CPU 微码，Kylin/海光 CPU 必要；体积小）；其余驱动固件
    #    （amdgpu 等）不拷——initramfs 体积控制，缺失不阻塞已确认驱动
    if [ -d "$proj/kylin-src/firmware/amd-ucode" ]; then
        mkdir -p "$rootfs/lib/firmware" || return 1
        cp -a "$proj/kylin-src/firmware/amd-ucode" "$rootfs/lib/firmware/" \
            || { dw_fail "拷贝 amd-ucode 固件失败"; return 1; }
        echo "     固件：amd-ucode CPU 微码已拷入 lib/firmware（$(du -sh "$rootfs/lib/firmware" | awk '{print $1}')）"
    else
        echo "     kylin-src 无 firmware/amd-ucode，跳过固件（微码缺失不阻塞已确认驱动）"
    fi
    echo "     Kylin 模块目录：$(du -sh "$rootfs/lib/modules/$kver" | awk '{print $1}')"
}

# ---------- 2) 组装 initramfs rootfs ----------
dw_assemble_rootfs() {
    rootfs="$1"; proj="$2"; kver="$3"; mode="${4:-ubuntu}"
    echo "==> [2/7] 组装 initramfs rootfs（内核 $kver，模式 $mode）"
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

    # 2.3 内核模块白名单（Ubuntu/Kylin 两模式，见 dw_modules_kylin 注释）：
    #   Ubuntu：从 WSL /lib/modules/<kver> 整目录拷贝白名单驱动族 + zstd 解压 + depmod；
    #   Kylin：从 kylin-src/modules/<kver> 按白名单 + modules.dep 依赖链提取 .ko.xz →
    #     xz 解压 → manifest 拷入并 sed 改后缀（无 depmod，直接用改写后的 modules.dep）。
    if [ "$mode" = "kylin" ]; then
        dw_modules_kylin "$rootfs" "$proj" "$kver" || return 1
    else
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
    fi

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

# ---------- 4) 写引导文件（grub.cfg + isolinux.cfg + 精简 GRUB EFI）+ 放置内核/initrd ----------
# v1.5.0 引导重构：BIOS → ISOLINUX（syslinux，纯文本 VGA，无视频模式概念；initrd 加载走
# syslinux 成熟路径——根治 grub-mkrescue GRUB 2.12 core 在无合适视频模式服务器上
# "error: no suitable video mode found. Booting in blind mode" 盲模式卡死，与 Ventoy
# grub2 mode 下 initrd 传递丢失）；UEFI → 精简 GRUB（grub-mkimage 手动打包 BOOTX64.EFI，
# 剔除 gfxterm/video/video_fb/efi_gop/efi_uga 模块，纯文本终端，无视频模式概念）。
dw_write_bootfiles() {
    rootfs="$1"; build_dir="$2"; kver="$3"; version="$4"; proj="$5"; mode="${6:-ubuntu}"
    echo "==> [4/7] 写引导文件（isolinux.cfg/grub.cfg/BOOTX64.EFI）+ 放置 vmlinuz/initrd.img（模式 $mode）"
    mkdir -p "$rootfs/boot/grub" || { dw_fail "mkdir boot/grub 失败"; return 1; }
    if [ "$mode" = "kylin" ]; then
        # Kylin 模式：vmlinuz 取自 kylin-src/boot/vmlinuz-<kver>（/mnt/c 上世界可读，无需 sudo）；
        # 拷贝后 chmod 0644（与 ubuntu 模式一致，避免后续 xorriso 读取失败）
        vmlinuz_src="$proj/kylin-src/boot/vmlinuz-$kver"
        [ -f "$vmlinuz_src" ] || { dw_fail "kylin-src 缺 vmlinuz-$kver（Kylin 材料不完整？）"; return 1; }
        cp "$vmlinuz_src" "$rootfs/boot/vmlinuz" || { dw_fail "拷贝 Kylin vmlinuz 失败"; return 1; }
        chmod 0644 "$rootfs/boot/vmlinuz" || { dw_fail "chmod vmlinuz 失败"; return 1; }
        echo "     vmlinuz：kylin-src/boot/vmlinuz-$kver（Kylin 4.19）"
    else
    # /boot/vmlinuz-* 仅 root 可读（Ubuntu 24.04 默认 0600），须经 $DW_SUDO 拷贝；
    # 拷贝后 chmod 0644（源 0600 会令后续 xorriso 以普通用户身份读取失败）
    $DW_SUDO cp "/boot/vmlinuz-$kver" "$rootfs/boot/vmlinuz" || { dw_fail "拷贝 vmlinuz-$kver 失败"; return 1; }
    $DW_SUDO chmod 0644 "$rootfs/boot/vmlinuz" || { dw_fail "chmod vmlinuz 失败"; return 1; }
    fi
    cp "$build_dir/initrd.img" "$rootfs/boot/initrd.img" || { dw_fail "拷贝 initrd.img 失败"; return 1; }

    # 4.1 UEFI 精简 GRUB 的 grub.cfg（无菜单直启——v1.5.3：不渲染菜单、无 timeout 倒计时，
    #     加 serial 终端兜底（insmod serial + serial --unit=0 初始化 + terminal_output/input
    #     serial console）——盲模式（无任何可用终端）下 GRUB 因 serial 至少有一个可用终端
    #     而不会进入盲模式，照常执行 linux/initrd/boot，根治真机 UEFI+Ventoy+KVM VGA
    #     盲模式卡死、内核未启动的问题。serial 行兼容 Ventoy grub（其 core 已含 serial 模块，
    #     insmod 幂等；本 iso 的 BOOTX64.EFI core 亦内嵌 serial/terminal 模块）。
    #     无 gfxterm/video 模块、无 gfxpayload=text（内核跳过 efifb 直接 fallback）
    cat > "$rootfs/boot/grub/grub.cfg" <<EOF
# v1.5.3 UEFI 直启 + serial 终端兜底（消除盲模式卡死；无 gfxterm/video/gfxpayload）
# 无菜单渲染：不等待终端、不渲染 menuentry；serial 保证至少一个可用终端 → 不进入盲模式
# （v1.5.0 起 BIOS 走 ISOLINUX 不再经 GRUB，此配置仅 UEFI 路径使用）
insmod serial
serial --unit=0 --speed=115200 --word=8 --parity=no --stop=1
terminal_output serial console
terminal_input serial console
linux /boot/vmlinuz console=tty0 console=ttyS0,115200n8 rdinit=/init
initrd /boot/initrd.img
boot
EOF

    # 4.2 BIOS ISOLINUX（isolinux.bin 来自 isolinux 包 /usr/lib/ISOLINUX/；KERNEL/APPEND
    #     路径相对 iso 根；APPEND initrd= 走 syslinux 成熟 initrd 加载路径——根治 Ventoy
    #     grub2 mode 下 initrd 传递丢失；PROMPT 1 + TIMEOUT 30(3s) 超时自动引导 DEFAULT。
    #     syslinux 6.x 的核心代码在 ldlinux.c32（/usr/lib/syslinux/modules/bios/，来自
    #     syslinux-common 包），必须与 isolinux.bin 同目录，否则 isolinux 报
    #     "Failed to load ldlinux.c32"）
    mkdir -p "$rootfs/isolinux" || { dw_fail "mkdir isolinux 失败"; return 1; }
    cp /usr/lib/ISOLINUX/isolinux.bin "$rootfs/isolinux/isolinux.bin" \
        || { dw_fail "拷贝 isolinux.bin 失败（isolinux 包未安装？）"; return 1; }
    cp /usr/lib/syslinux/modules/bios/ldlinux.c32 "$rootfs/isolinux/ldlinux.c32" \
        || { dw_fail "拷贝 ldlinux.c32 失败（syslinux-common 未安装？）"; return 1; }
    cat > "$rootfs/isolinux/isolinux.cfg" <<EOF
DEFAULT linux
LABEL linux
KERNEL /boot/vmlinuz
APPEND console=tty0 console=ttyS0,115200n8 initrd=/boot/initrd.img
TIMEOUT 30
PROMPT 1
EOF

    # 4.3 UEFI 精简 GRUB 核心（grub-mkimage 手动打包 BOOTX64.EFI，模块列表剔除
    #     gfxterm/video/video_fb/efi_gop/efi_uga；embedded 配置先 insmod serial 再
    #     search 定位 iso 根、serial --unit=0 初始化、terminal_output/input serial console
    #     双终端（serial 优先——盲模式兜底：真机无视频模式时 serial 是唯一可用终端，
    #     console 保留 OVMF ConOut/serial 输出兼容）再加载 grub.cfg；iso9660 供 iso 内
    #     读文件，part_gpt/part_msdos/fat/ext2 兜底 Ventoy/分区形态，memdisk 常规保留。
    #     注：GRUB 2.12 的 initrd 命令已内建（无 initrd.mod），linux/initrd 命令随
    #     linux 模块与 core 提供，无需单独模块；serial/terminal 模块内嵌于 core
    #     （grub-mkimage 启动时自动加载，insmod serial 幂等，无需 iso 内 serial.mod）
    #     El Torito EFI 引导镜像必须是 FAT 卷（内含 EFI/BOOT/BOOTX64.EFI）——OVMF/主流
    #     固件对裸 PE 文件作 EFI 条目的 El Torito 引导实测报 "failed to load ... Not
    #     Found"（grub-mkrescue 亦用此 FAT 镜像方案；真机 v1.4.x UEFI 引导正常即基于此）
    mkdir -p "$rootfs/EFI/BOOT" || { dw_fail "mkdir EFI/BOOT 失败"; return 1; }
    cat > "$build_dir/embedded-efi.cfg" <<EOF
insmod serial
search --no-floppy --set=root -f /boot/grub/grub.cfg
set prefix=(\$root)/boot/grub
serial --unit=0 --speed=115200 --word=8 --parity=no --stop=1
terminal_output serial console
terminal_input serial console
configfile /boot/grub/grub.cfg
EOF
    grub-mkimage -o "$rootfs/EFI/BOOT/BOOTX64.EFI" -O x86_64-efi -p /boot/grub \
        -c "$build_dir/embedded-efi.cfg" \
        iso9660 linux normal search search_fs_file configfile part_gpt part_msdos fat ext2 boot fshelp memdisk serial terminal \
        || { dw_fail "grub-mkimage 生成 BOOTX64.EFI 失败（grub-efi-amd64-bin 未安装？）"; return 1; }
    # 封入 FAT efi.img（El Torito EFI 引导镜像；mtools 的 mcopy 不自动建目录，先 mmd 建
    # ::/EFI/BOOT；BOOTX64.EFI 源为刚生成的 rootfs 内文件）
    truncate -s 8M "$build_dir/efi.img" || { dw_fail "创建 efi.img 失败"; return 1; }
    mkfs.vfat -n DWEFI "$build_dir/efi.img" >/dev/null 2>&1 \
        || { dw_fail "mkfs.vfat 格式化 efi.img 失败（dosfstools 未安装？）"; return 1; }
    mmd -i "$build_dir/efi.img" ::/EFI >/dev/null 2>&1 || { dw_fail "mmd 建 ::/EFI 目录失败"; return 1; }
    mmd -i "$build_dir/efi.img" ::/EFI/BOOT >/dev/null 2>&1 || { dw_fail "mmd 建 ::/EFI/BOOT 目录失败"; return 1; }
    mcopy -i "$build_dir/efi.img" "$rootfs/EFI/BOOT/BOOTX64.EFI" ::/EFI/BOOT/BOOTX64.EFI \
        || { dw_fail "mcopy BOOTX64.EFI 封入 efi.img 失败"; return 1; }
    cp "$build_dir/efi.img" "$rootfs/EFI/BOOT/efi.img" || { dw_fail "拷贝 efi.img 到 rootfs 失败"; return 1; }
    echo "     grub.cfg（UEFI）：文本终端 terminal_output console，linux /boot/vmlinuz console=tty0 console=ttyS0,115200n8 + initrd"
    echo "     isolinux（BIOS）：isolinux.bin + isolinux.cfg（DEFAULT linux，KERNEL /boot/vmlinuz + initrd= 双 console）"
    echo "     BOOTX64.EFI（UEFI）：精简 GRUB $(ls -lh "$rootfs/EFI/BOOT/BOOTX64.EFI" | awk '{print $5}')（无 gfxterm/video 模块）"
    echo "     efi.img（El Torito UEFI 引导镜像）：FAT 卷内含 EFI/BOOT/BOOTX64.EFI（OVMF/主流固件兼容）"
}

# ---------- 5) xorriso 手动打包 BIOS(ISOLINUX)+UEFI(精简 GRUB) 双引导 iso ----------
# v1.5.0：不再用 grub-mkrescue（其 GRUB 2.12 core 内嵌 gfxterm，在无合适视频模式服务器上
# 报 "error: no suitable video mode found. Booting in blind mode" 盲模式卡死）。改 xorriso
# 手动打包：isohdpfx.bin 作混合 MBR + El Torito BIOS 项 isolinux/isolinux.bin
# （-boot-info-table 由 mkisofs 补丁）+ El Torito UEFI 项 EFI/BOOT/efi.img
# （FAT 卷内含 EFI/BOOT/BOOTX64.EFI 精简 GRUB）。-isohybrid-gpt-basdat 使 GPT 分区表
# 指向与 MBR 相同的数据块（混合 MBR/GPT，U 盘/真机引导兼容）。
dw_mkiso() {
    rootfs="$1"; proj="$2"; iso="$3"; build_dir="$4"
    echo "==> [5/7] xorriso 打包 BIOS(ISOLINUX)+UEFI(精简 GRUB) 双引导 iso → $iso"
    mkdir -p "$proj/output" || { dw_fail "创建 output/ 失败"; return 1; }
    rm -f "$iso" || { dw_fail "清理旧 iso 失败"; return 1; }
    # -R：Rock Ridge（isoinfo -R 校验需要）；-V 置于源目录之前（xorriso mkisofs 仿真）
    xorriso -as mkisofs \
        -R \
        -o "$iso" -V DISKWIPE \
        -isohybrid-mbr /usr/lib/ISOLINUX/isohdpfx.bin \
        -b isolinux/isolinux.bin -c isolinux/boot.cat \
        -no-emul-boot -boot-load-size 4 -boot-info-table \
        -eltorito-alt-boot -e EFI/BOOT/efi.img -no-emul-boot \
        -isohybrid-gpt-basdat "$rootfs" \
        || { dw_fail "xorriso 打包 iso 失败（见上方输出）"; return 1; }
    echo "     iso：$(ls -lh "$iso" | awk '{print $5}')"
}

# ---------- 6) isoinfo 校验 ----------
dw_verify_iso() {
    iso="$1"; build_dir="$2"; proj="$3"; mode="${4:-ubuntu}"
    echo "==> [6/7] isoinfo 校验 iso（模式 $mode）"
    echo "     卷信息：$(isoinfo -i "$iso" -d 2>/dev/null | grep -i '^Volume id' | head -n 1)"

    # 6.1 关键文件（v1.5.0：isolinux/isolinux.bin、isolinux/ldlinux.c32、isolinux/isolinux.cfg、
    #     EFI/BOOT/BOOTX64.EFI、EFI/BOOT/efi.img + boot/grub/grub.cfg、boot/vmlinuz、
    #     boot/initrd.img）。isoinfo -R -l 为树形输出（"Directory listing of /boot/grub/" 段下
    #     逐行列出文件名），按「目录段 + 文件名」两段式校验；再以 -x 从 iso 实际抽取实检
    il="$(isoinfo -R -i "$iso" -l 2>/dev/null)"
    for spec in "isolinux/ isolinux.bin" "isolinux/ ldlinux.c32" "isolinux/ isolinux.cfg" "EFI/BOOT/ BOOTX64.EFI" "EFI/BOOT/ efi.img" "boot/grub/ grub.cfg" "boot/ vmlinuz" "boot/ initrd.img"; do
        set -- $spec
        ok=$(printf '%s\n' "$il" | awk -v d="/$1" -v f="$2" '
            /^Directory listing of / { insec = ($0 ~ ("of " d "$")); next }
            insec && $NF == f { found = 1 }
            END { print found + 0 }')
        [ "$ok" = "1" ] || { dw_fail "iso 缺少 $1$2（isoinfo -R -l 未列出）"; return 1; }
    done
    for p in /isolinux/isolinux.bin /isolinux/ldlinux.c32 /isolinux/isolinux.cfg /EFI/BOOT/BOOTX64.EFI /EFI/BOOT/efi.img /boot/grub/grub.cfg /boot/vmlinuz /boot/initrd.img; do
        isoinfo -R -i "$iso" -x "$p" > "$build_dir/x.out" 2>/dev/null || { dw_fail "iso 无法抽取 $p"; return 1; }
        [ -s "$build_dir/x.out" ] || { dw_fail "iso 抽取 $p 内容为空"; return 1; }
    done
    echo "     校验通过：isolinux.bin/ldlinux.c32/isolinux.cfg、EFI/BOOT/BOOTX64.EFI + efi.img、boot/grub/grub.cfg、boot/vmlinuz、boot/initrd.img 均在 iso 中（-l 目录树 + -x 抽取实检）"

    # 6.2a isolinux.cfg（BIOS 路径内核参数来源）含 KERNEL /boot/vmlinuz、initrd=、双 console
    icfg="$(isoinfo -R -i "$iso" -x /isolinux/isolinux.cfg 2>/dev/null)"
    printf '%s\n' "$icfg" | grep -q 'KERNEL /boot/vmlinuz' || { dw_fail "isolinux.cfg 缺少 KERNEL /boot/vmlinuz"; return 1; }
    printf '%s\n' "$icfg" | grep -q 'initrd=/boot/initrd.img' || { dw_fail "isolinux.cfg 缺少 initrd=/boot/initrd.img"; return 1; }
    printf '%s\n' "$icfg" | grep -q 'console=tty0' || { dw_fail "isolinux.cfg 缺少 console=tty0"; return 1; }
    printf '%s\n' "$icfg" | grep -q 'console=ttyS0,115200n8' || { dw_fail "isolinux.cfg 缺少 console=ttyS0,115200n8"; return 1; }
    echo "     校验通过：isolinux.cfg 含 KERNEL /boot/vmlinuz + initrd=/boot/initrd.img + console=tty0/ttyS0,115200n8"

    # 6.2b grub.cfg（UEFI 路径）含双 console 参数，且无诊断残留（debug loglevel / 诊断 echo）
    gcfg="$(isoinfo -R -i "$iso" -x /boot/grub/grub.cfg 2>/dev/null)"
    printf '%s\n' "$gcfg" | grep -q 'console=tty0' || { dw_fail "grub.cfg 缺少 console=tty0"; return 1; }
    printf '%s\n' "$gcfg" | grep -q 'console=ttyS0,115200n8' || { dw_fail "grub.cfg 缺少 console=ttyS0,115200n8"; return 1; }
    if printf '%s\n' "$gcfg" | grep -q 'debug loglevel'; then dw_fail "grub.cfg 残留诊断参数 debug loglevel（应已清理）"; return 1; fi
    if printf '%s\n' "$gcfg" | grep -q 'GRUB: loading'; then dw_fail "grub.cfg 残留诊断 echo 行（应已清理）"; return 1; fi
    echo "     校验通过：grub.cfg 含双 console 参数且无诊断残留（debug loglevel/echo 已清理）"

    # 6.2c BOOTX64.EFI 精简性：PE 头（MZ 魔数）+ 无 gfxterm/video_fb/efi_gop/efi_uga
    #     模块（grub-mkimage 模块列表已剔除——诊断回归防护：若 gfxterm 模块被打包回 core，
    #     真机盲模式卡死会复发）。注意：
    #     - GRUB 2.12 内核/normal 模块代码本身含字符串 "gfxterm"（如 normal 的错误消息
    #       "module `gfxterm' isn't loaded"），未内嵌时恰好 1 处；gfxterm.mod 内嵌则
    #       其模块头/依赖表再增 ≥1 处 → 以出现次数 ≤1 判定未内嵌（实测精简版 =1）。
    #     - video 模块会被 linux.mod 依赖自动带入（linux: boot mmap relocator video），
    #       无害（gfxterm 才是触发 "no suitable video mode found" 盲模式的模块），不判失败。
    isoinfo -R -i "$iso" -x /EFI/BOOT/BOOTX64.EFI > "$build_dir/bootx64.check" 2>/dev/null \
        || { dw_fail "抽取 BOOTX64.EFI 失败（PE 校验）"; return 1; }
    head -c 2 "$build_dir/bootx64.check" | grep -q 'MZ' || { dw_fail "BOOTX64.EFI 非有效 PE 文件（缺 MZ 头）"; return 1; }
    ngfx="$(grep -ao 'gfxterm' "$build_dir/bootx64.check" | wc -l)"
    [ "$ngfx" -le 1 ] || { dw_fail "BOOTX64.EFI 含 gfxterm 模块（gfxterm 出现 $ngfx 处 > 1，精简 GRUB 打包失败）"; return 1; }
    for m in video_fb efi_gop efi_uga; do
        if grep -aq "$m" "$build_dir/bootx64.check"; then
            dw_fail "BOOTX64.EFI 含 $m 模块（精简 GRUB 打包失败）"; return 1
        fi
    done
    echo "     校验通过：BOOTX64.EFI 为有效 PE（MZ 头）且未内嵌 gfxterm/video_fb/efi_gop/efi_uga 模块（精简 GRUB 无视频模式依赖）"

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
    # 6.5b Kylin 模式：.ko.xz 同样不可被 busybox 加载，必须已全部解压为 .ko
    if find "$build_dir/initrdx/lib/modules" -name '*.ko.xz' 2>/dev/null | grep -q .; then
        dw_fail "initrd 内仍有 .ko.xz 模块（busybox 无法解压加载）"; return 1
    fi
    nko=$(find "$build_dir/initrdx/lib/modules" -name '*.ko' 2>/dev/null | wc -l)
    [ "$nko" -gt 0 ] || { dw_fail "initrd 内无任何未压缩 .ko 模块"; return 1; }
    echo "     校验通过：initrd 内模块全部为未压缩 .ko（共 $nko 个，无 .ko.zst/.ko.xz 残留）"

    # 6.6 Kylin 模式追加校验：iso 内 boot/vmlinuz 为 Kylin 4.19 内核（strings 版本串
    #     4.19.90，bzImage 明文段含 "4.19.90-89.11.v2401.ky10.x86_64"）；initrd 内
    #     关键模块（ahci/nvme）存在且为 .ko（非压缩后缀）；usb-storage 反向断言——
    #     v1.5.9 起不再打包（U 盘不绑定根治真机系统停滞）
    if [ "$mode" = "kylin" ]; then
        isoinfo -R -i "$iso" -x /boot/vmlinuz > "$build_dir/vmlinuz.check" 2>/dev/null \
            || { dw_fail "抽取 boot/vmlinuz 失败（Kylin 校验）"; return 1; }
        if ! strings "$build_dir/vmlinuz.check" 2>/dev/null | grep -q '4.19.90'; then
            dw_fail "boot/vmlinuz 非 Kylin 4.19 内核（strings 未见 4.19.90 版本串）"; return 1
        fi
        echo "     校验通过：boot/vmlinuz 为 Kylin 4.19 内核（strings 检出 4.19.90 版本串）"
        for m in ahci nvme; do
            if ! find "$build_dir/initrdx/lib/modules" -name "$m.ko" 2>/dev/null | grep -q .; then
                dw_fail "initrd 内缺少关键 Kylin 模块 $m.ko（应为未压缩 .ko）"; return 1
            fi
        done
        echo "     校验通过：initrd 内关键模块 ahci/nvme 均为未压缩 .ko"
        for m in usb-storage uas; do
            if ! find "$build_dir/initrdx/lib/modules" -name "$m.ko" 2>/dev/null | grep -q .; then
                dw_fail "initrd 内缺少 Kylin 模块 $m.ko（v1.5.17 恢复 usb-storage/uas 触发 SCSI 扫描带出 SAS 盘，必须打包）"; return 1
            fi
        done
        echo "     校验通过：initrd 内关键模块 usb-storage/uas 均为未压缩 .ko（v1.5.17 恢复）"
    fi
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
    # 内核模式：auto（默认）——kylin-src/boot/vmlinuz-4.19* 存在即自动用 Kylin 内核
    # （替换 WSL Ubuntu generic 内核）；显式 DW_KERNEL_MODE=ubuntu|kylin 可覆盖
    # （build.sh 可选参数透传，见 build.sh）。
    mode="${DW_KERNEL_MODE:-auto}"
    case "$mode" in
    auto)
        if ls "$proj"/kylin-src/boot/vmlinuz-4.19* >/dev/null 2>&1; then
            mode=kylin
        else
            mode=ubuntu
        fi
        ;;
    ubuntu|kylin) ;;
    *) dw_fail "DW_KERNEL_MODE 取值非法：$mode（应为 auto|ubuntu|kylin）"; rm -rf "$build_dir"; return 1 ;;
    esac
    echo "==> 内核模式：$mode（kylin = 使用 kylin-src 提取的 Kylin 4.19 内核，解决 Ubuntu 内核 USB 不兼容启动卡死）"
    if [ "$mode" = "kylin" ]; then
        # kylin-src/boot/vmlinuz-4.19.90-89.11.v2401.ky10.x86_64 → 推导 kver
        kver="$(ls "$proj"/kylin-src/boot/vmlinuz-4.19* 2>/dev/null | sed 's/.*vmlinuz-//' | head -n 1)"
        [ -n "$kver" ] || { dw_fail "无法从 kylin-src/boot/vmlinuz-4.19* 推导内核版本"; rm -rf "$build_dir"; return 1; }
    else
        kver="$(ls /boot/vmlinuz-*-generic 2>/dev/null | sed 's/.*vmlinuz-//' | sort -V | tail -n 1)"
        [ -n "$kver" ] || { dw_fail "未找到 /boot/vmlinuz-*-generic（linux-image-generic 未安装？）"; rm -rf "$build_dir"; return 1; }
    fi
    echo "==> 使用内核：$kver"
    dw_assemble_rootfs "$rootfs" "$proj" "$kver" "$mode" || { echo "✗ 构建中止。临时目录在 WSL /tmp 内（会话结束即失效）：$build_dir" >&2; return 1; }
    dw_pack_initrd      "$rootfs" "$build_dir" || { echo "✗ 构建中止。临时目录在 WSL /tmp 内（会话结束即失效）：$build_dir" >&2; return 1; }
    dw_write_bootfiles  "$rootfs" "$build_dir" "$kver" "$version" "$proj" "$mode" || { echo "✗ 构建中止。临时目录在 WSL /tmp 内（会话结束即失效）：$build_dir" >&2; return 1; }
    dw_mkiso            "$rootfs" "$proj" "$iso" "$build_dir" || { echo "✗ 构建中止。临时目录在 WSL /tmp 内（会话结束即失效）：$build_dir" >&2; return 1; }
    dw_verify_iso       "$iso" "$build_dir" "$proj" "$mode" || { echo "✗ 构建中止。临时目录在 WSL /tmp 内（会话结束即失效）：$build_dir" >&2; return 1; }

    # 模块经 $DW_SUDO 拷贝后属主为 root，清理须同样走 sudo
    $DW_SUDO rm -rf "$build_dir"
    sz="$(ls -lh "$iso" | awk '{print $5}')"
    echo
    echo "======================================================"
    echo "  ✓ 构建成功：$iso（大小 $sz）"
    echo "  BIOS(ISOLINUX)+UEFI(精简 GRUB) 双引导 iso（xorriso 打包）；isoinfo 校验全部通过"
    echo "  使用：将 iso 写入 U 盘（Ventoy/Rufus 等）后从 U 盘启动即可"
    echo "======================================================"
}
