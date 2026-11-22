#!/bin/sh
# diskwipe-iso 共享库：盘枚举 / 白名单校验 / 子树挂载点 / OS 迹象标注 / 单盘清除
#
# 硬约束：
#   - POSIX/ash 兼容（initramfs 运行时只有 busybox ash；禁止 [[ ]]、数组、${var:0:3} 等
#     bash 专属语法），LF 行尾，中文注释。
#   - 设备白名单：sd[a-z]/sd[a-z][a-z] / nvme[0-9]*n[0-9]* / vd[a-z] /
#     mmcblk[0-9]*；排除 TRAN=usb（启动 U 盘）与 sr* / loop* / ram*（光驱/循环/内存盘）。
#   - 接缝变量：LSBLK_BIN / BLKID_BIN / WIPEFS_BIN / UMOUNT_BIN / PARTPROBE_BIN / TIMEOUT_BIN
#     （默认系统命令，测试经 PATH 假件注入，绝不触碰真实块设备）。
#     全部只读探测（枚举/批量类型/挂载点/退出写 U 盘枚举）统一包 "$TIMEOUT_BIN" 3 兜底超时；
#     清除操作（umount/wipefs/partprobe）不加 timeout（破坏性操作不能半途超时中断）。
#
# 接口（后续任务依赖的签名）：
#   dw_dev_ok <dev>            0=合法白名单设备 / 1=拒绝（支持带或不带 /dev/ 前缀）
#   dw_enum_disks              无参；stdout 每行「设备 容量 型号 TRAN 挂载点」，
#                             挂载点为该盘子树挂载点逗号拼接；仅 TYPE=disk + 白名单 + 非 usb；
#                             lsblk 超时/失败 → 返回 1 且无输出（menu 据此降级重试，
#                             不误判"仅启动介质"）
#   dw_scan_system_disks       无参；stdout 每行「设备|类型码」0=数据盘 1=系统盘 2=未知；
#                             批量一次 lsblk（含 PARTTYPENAME/PARTFLAGS 列）+ 一次 blkid
#                             （-c /dev/null -o full 带设备名输出，awk 归并到父盘）；
#                             任一次超时/失败 → 返回 1 且无输出（调用方将全部盘标 UNK）
#   dw_format_disk_lines [码表]  stdin 枚举行 → stdout 每行「设备|容量|型号|TRAN大写|类型码」；
#                             码表为 dw_scan_system_disks 输出（设备|类型码 逐行），缺失/空 →
#                             全部盘标 UNK；供 menu 列盘查表（循环内零外部命令）
#   dw_disk_mountpoints <dev>  stdout 每行一个该盘子树挂载点（无挂载输出空）；超时/失败返回 1
#   dw_is_system_disk <dev>    echo 0=数据盘 / 1=系统盘 / 2=未知（OS 迹象判定；保留供
#                             dw_scan_system_disks 的查表口径对照，menu 不再逐盘调用）
#   dw_wipe_disk <dev>         0=OK（umount 全部→wipefs -a→partprobe→wipefs -n 验证）/
#                             非0=失败（输出 FAIL 行 + 英文 reason）
#   dw_version                 echo 版本号（读 /diskwipe.version，缺失回退 unknown）
#   dw_log <msg>               echo "$msg" | tee -a "${LOG_FILE:-/dev/null}"（屏幕+文件双写）
#   dw_save_log_to_usb <file>  会话收尾尽力把日志文件写到 U 盘可写分区（跳过 VTOYEFI）；
#                             0=已保存 / 1=无候选或全部失败（调用方打印降级提示，不阻断）

# ---------- 接缝变量（默认系统命令，测试可覆盖） ----------
LSBLK_BIN="${LSBLK_BIN:-lsblk}"
BLKID_BIN="${BLKID_BIN:-blkid}"
WIPEFS_BIN="${WIPEFS_BIN:-wipefs}"
UMOUNT_BIN="${UMOUNT_BIN:-umount}"
PARTPROBE_BIN="${PARTPROBE_BIN:-partprobe}"
# 只读探测超时兜底接缝（busybox 已含 timeout applet；测试经 PATH 假件注入/覆写）
TIMEOUT_BIN="${TIMEOUT_BIN:-timeout}"
# 版本文件路径（构建期拷入 rootfs；测试可覆盖指向临时文件）
DW_VERSION_FILE="${DW_VERSION_FILE:-/diskwipe.version}"

# 设备名白名单校验（代码层护栏，从源头杜绝误操作）
dw_dev_ok() {
    ddev="$1"
    case "$ddev" in
    /dev/*) ddev="${ddev#/dev/}" ;;
    esac
    case "$ddev" in
    sd[a-z]|sd[a-z][a-z]|nvme[0-9]*n[0-9]*|vd[a-z]|mmcblk[0-9]*) return 0 ;;
    *) return 1 ;;
    esac
}

# 枚举全部可清盘。lsblk 列解析用 awk：
#   按 NAME/SIZE/TYPE 三列定位；MODEL 可含空格，从右往左解析——
#   末字段以 / 开头为挂载点，其前一 token 为 TRAN，TYPE 之后到 TRAN 之前为 MODEL 原文；
#   分区挂载点按父盘推导（nvme0n1p1/mmcblk0p1 去 p+数字、sda1 去尾部数字）归并（逗号拼接）。
# lsblk 包 "$TIMEOUT_BIN" 3 兜底（单次挂起 3s 返回非 0 → 本函数返回 1 且无输出，
# menu 据此打印错误并重试一次，不误判"仅启动介质"）。
dw_enum_disks() {
    dwraw="$("$TIMEOUT_BIN" 3 "$LSBLK_BIN" -o NAME,SIZE,TYPE,MODEL,TRAN,MOUNTPOINT 2>/dev/null)"
    [ "$?" -eq 0 ] || return 1
    printf '%s\n' "$dwraw" | awk '
        NR==1 { next }
        $3 != "disk" && $3 != "part" { next }
        $3 == "disk" {
            # 白名单 + 双保险排除 sr*/loop*/ram*
            if ($1 ~ /^(sr|loop|ram)[0-9]/) next
            if (!($1 ~ /^sd[a-z]$/ || $1 ~ /^sd[a-z][a-z]$/ || $1 ~ /^nvme[0-9][0-9]*n[0-9][0-9]*$/ || $1 ~ /^vd[a-z]$/ || $1 ~ /^mmcblk[0-9][0-9]*$/)) next
            name=$1; size=$2
            mps=""; t=NF
            if ($NF ~ /^\//) { mps=$NF; t=NF-1 }
            # TRAN 为空时挂载点前一字段实为型号末词——仅当该字段属于已知 TRAN 集合
            # （sata/sas/nvme/usb/spi/ata/scsi/virtio/pcie）才视为 TRAN，否则并入型号
            tran=""; mend=t
            if (t > 3) {
                if ($t ~ /^(sata|sas|nvme|usb|spi|ata|scsi|virtio|pcie)$/) tran=$t
                else mend=t+1   # 该字段属型号（TRAN 为空），型号区间延伸到它（含）
            }
            if (tran == "usb") next          # 排除启动 U 盘
            model=""
            for (i=4; i<mend; i++) { if (model != "") model = model " "; model = model $i }
            if (model == "") model = "unknown"
            accmp(name, mps)
            names[++nd]=name; sizes[nd]=size; models[nd]=model; trans[nd]=tran
        }
        $3 == "part" {
            mp=""; if ($NF ~ /^\//) mp=$NF
            pk=$1
            if (pk ~ /p[0-9]+$/) sub(/p[0-9]+$/, "", pk)   # nvme0n1p1/mmcblk0p1 → 父盘
            else while (pk ~ /[0-9]$/) pk=substr(pk,1,length(pk)-1)   # sda1 → sda
            accmp(pk, mp)
        }
        function accmp(pk, mp,  s) {
            if (mp == "") return
            if (pk in mpacc) mpacc[pk] = mpacc[pk] "," mp
            else mpacc[pk] = mp
        }
        END {
            for (i=1; i<=nd; i++) {
                mp = (names[i] in mpacc) ? mpacc[names[i]] : ""
                printf "%s %s %s %s %s\n", names[i], sizes[i], models[i], trans[i], mp
            }
        }
    '
}

# 输出该盘子树全部挂载点（盘自身 + 其分区），每行一个；无挂载输出空。
# 挂载点可能含空格：取「首个 / 开头字段起至行尾」，再按末字段是否为设备名（PKNAME）
# 形态决定去留——分区行 PKNAME 恒为末列去掉；整盘挂载行无 PKNAME 保留全文（不拆词）。
dw_disk_mountpoints() {
    ddev="$1"
    case "$ddev" in /dev/*) ddev="${ddev#/dev/}" ;; esac
    [ -n "$ddev" ] || return 0
    dwraw="$("$TIMEOUT_BIN" 3 "$LSBLK_BIN" -o NAME,TYPE,MOUNTPOINT,PKNAME "/dev/$ddev" 2>/dev/null)"
    [ "$?" -eq 0 ] || return 1
    printf '%s\n' "$dwraw" | awk '
        NR==1 { next }
        {
            mpstart=0
            for (i=3; i<=NF; i++) if ($i ~ /^\//) { mpstart=i; break }
            if (mpstart == 0) next
            dmp=$mpstart
            for (j=mpstart+1; j<=NF; j++) dmp=dmp " " $j
            # 去掉尾部 PKNAME（恒为末列、设备名形态；整盘挂载行无 PKNAME 则保留全文）
            if ($NF ~ /^(sd[a-z][0-9]*|sd[a-z][a-z][0-9]*|nvme[0-9]+n[0-9]+p?[0-9]*|vd[a-z][0-9]*|mmcblk[0-9]+p?[0-9]*|dm-[0-9]+|md[0-9]+|loop[0-9]+|sr[0-9]+)$/) {
                sub(/ [^ ]+$/, "", dmp)
            }
            print dmp
        }
    '
}

# OS 迹象判定（真实可命中的探测口径）：
#   - GPT ESP：lsblk PARTTYPENAME 含 "EFI System"（MBR 0xef EFI 分区名同样含 "EFI"，一并命中）
#   - MBR 活动分区：lsblk PARTFLAGS == 0x80（MBR 引导标志；GPT 无此概念）
#   - Windows 系统分区：ntfs
#   - blkid 探测不到任何类型 → 2 未知；无 OS 迹象且全部类型已知 → 0 数据盘。
# 返回值 0/1/2 由 menu.sh 映射显示为 DATA/SYS/UNK（仅提示用，不影响可勾选）。
dw_is_system_disk() {
    ddev="$1"
    case "$ddev" in /dev/*) ddev="${ddev#/dev/}" ;; esac
    dparts=$("$LSBLK_BIN" -o NAME,TYPE,MOUNTPOINT,PKNAME "/dev/$ddev" 2>/dev/null | awk -v d="$ddev" '
        NR==1 { next }
        $2 == "part" && $NF == d { print $1 }   # PKNAME 恒为末列（挂载点含空格也不移位）
    ')
    [ -n "$dparts" ] || { echo 0; return 0; }   # 无分区 → 数据盘
    dunknown=0
    for dpart in $dparts; do
        dfstype=$("$BLKID_BIN" -s TYPE -o value "/dev/$dpart" 2>/dev/null)
        dbrc=$?
        if [ -z "$dfstype" ] || [ "$dbrc" -ne 0 ]; then dunknown=1; continue; fi
        case "$dfstype" in
        vfat)
            dptname=$("$LSBLK_BIN" -no PARTTYPENAME "/dev/$dpart" 2>/dev/null)
            dflags=$("$LSBLK_BIN" -no PARTFLAGS "/dev/$dpart" 2>/dev/null)
            # GPT ESP（PARTTYPENAME="EFI System"）/ MBR EFI 分区（0xef 名含 EFI）；
            # 部分 MBR ESP 另置 0x80 活动标志，一并命中
            if printf '%s\n' "$dptname" | grep -qi 'EFI'; then echo 1; return 0; fi
            case "$dflags" in *0x80*) echo 1; return 0 ;; esac
            ;;
        ntfs)
            echo 1; return 0
            ;;
        ext4|xfs|btrfs)
            dflags=$("$LSBLK_BIN" -no PARTFLAGS "/dev/$dpart" 2>/dev/null)
            # MBR 活动分区标志 0x80（GPT 根分区无引导标志，按设计 §8 口径不判系统）
            case "$dflags" in *0x80*) echo 1; return 0 ;; esac
            ;;
        esac
    done
    [ "$dunknown" -eq 1 ] && { echo 2; return 0; }
    echo 0
}

# 批量类型探测（替代 menu 逐盘 dw_is_system_disk，列盘循环零外部命令）：
#   - 一次 lsblk 全盘表（NAME,TYPE,MOUNTPOINT,PKNAME,PARTTYPENAME,PARTFLAGS——树形前缀剥离、
#     从右往左识别 PARTFLAGS(0x..)/PKNAME（设备名形态），其余非挂载点字段并入类型名）+ 一次
#     blkid -c /dev/null -o full（带设备名输出「设备: TYPE="xxx"」，awk 归并到父盘）。
#   - 探测口径与 dw_is_system_disk 一致：GPT/MBR ESP（类型名含 EFI，tolower 匹配）、
#     MBR 活动 0x80、ntfs → 系统盘(1)；无 OS 迹象且全部已知 → 数据盘(0)；
#     存在探测不到（blkid 无该分区条目）→ 未知(2)；无分区 → 数据盘(0)。
#   - 两个外部调用均包 "$TIMEOUT_BIN" 3；任一次超时/失败 → 返回 1 且无输出，
#     调用方（menu）将全部盘标 UNK（类型仅提示，不影响清除）。
#   - 批量表无 TRAN 列，无法排除 usb 盘——但本函数输出仅按设备名被 menu 查表引用，
#     usb 盘不在枚举结果中，其类型码自然不被使用。
dw_scan_system_disks() {
    dwsblk="$("$TIMEOUT_BIN" 3 "$LSBLK_BIN" -o NAME,TYPE,MOUNTPOINT,PKNAME,PARTTYPENAME,PARTFLAGS 2>/dev/null)"
    [ "$?" -eq 0 ] || return 1
    dwsfs="$("$TIMEOUT_BIN" 3 "$BLKID_BIN" -c /dev/null -o full 2>/dev/null)"
    [ "$?" -eq 0 ] || return 1
    printf '%s\n__DWS_END__\n%s\n' "$dwsfs" "$dwsblk" | awk '
        $0 == "__DWS_END__" { dsec=1; next }
        dsec != 1 {
            # 第一段：blkid -o full 输出（每行 设备: TYPE="xxx" [其它属性]）
            if (match($0, /^\/dev\/[^ :]+/)) {
                dv=substr($0, RSTART+5, RLENGTH-5)
                if (match($0, /TYPE="[^"]*"/)) fstype[dv]=substr($0, RSTART+6, RLENGTH-7)
            }
            next
        }
        {
            # 第二段：lsblk 批量表（NAME TYPE MOUNTPOINT PKNAME PARTTYPENAME PARTFLAGS）
            name=$1; sub(/^[^a-z0-9]+/, "", name)   # 剥树形前缀（├─/└─/│，按字节，locale 安全）
            type=$2
            if (type == "disk") {
                if (name ~ /^(sr|loop|ram)[0-9]/) next
                if (!(name ~ /^sd[a-z]$/ || name ~ /^sd[a-z][a-z]$/ || name ~ /^nvme[0-9][0-9]*n[0-9][0-9]*$/ || name ~ /^vd[a-z]$/ || name ~ /^mmcblk[0-9][0-9]*$/)) next
                disklist[++nd]=name
                next
            }
            if (type != "part") next
            flags=""; pk=""; ptn=""
            for (i=NF; i>=3; i--) {
                if (flags == "" && $i ~ /^0x[0-9a-fA-F]+$/) { flags=$i; continue }
                if (pk == "" && $i ~ /^(sd[a-z]+[0-9]*|sd[a-z][a-z]+[0-9]*|nvme[0-9]+n[0-9]+p[0-9]*|vd[a-z][0-9]*|mmcblk[0-9]+p[0-9]*)$/) { pk=$i; continue }
                if ($i ~ /^\//) continue    # 挂载点不并入类型名（口径同 dw_is_system_disk 只查 PARTTYPENAME）
                ptn=ptn " " $i
            }
            if (pk == "") {
                pk=name
                if (pk ~ /p[0-9]+$/) sub(/p[0-9]+$/, "", pk)
                else while (pk ~ /[0-9]$/) pk=substr(pk,1,length(pk)-1)
            }
            parts[++np]=name
            partparent[name]=pk
            partflags[name]=flags
            partefi[name]=(tolower(ptn) ~ /efi/) ? 1 : 0
        }
        END {
            for (i=1; i<=nd; i++) {
                d=disklist[i]
                sys=0; unk=0
                for (j=1; j<=np; j++) {
                    p=parts[j]
                    if (partparent[p] != d) continue
                    ft=fstype[p]
                    if (ft == "") { unk=1; continue }
                    if (ft == "vfat") {
                        if (partefi[p] || partflags[p] ~ /0x80/) sys=1
                    } else if (ft == "ntfs") {
                        sys=1
                    } else if (ft == "ext4" || ft == "xfs" || ft == "btrfs") {
                        if (partflags[p] ~ /0x80/) sys=1
                    }
                }
                if (sys) print d "|1"
                else if (unk) print d "|2"
                else print d "|0"
            }
        }
    '
}

# 列盘字段批量格式化：stdin 读全部枚举行，stdout 输出全部「设备|容量|型号|TRAN大写|类型码」行。
# $1 = 类型码表（dw_scan_system_disks 输出，每行 设备|类型码）；缺失/空 → 全部盘标 UNK(2)。
# 一次 awk 处理全部行（型号含空格、TRAN 可空的从右往左解析同旧 disk_display_fields），
# menu 列盘循环只做 shell 字符串切分（${var%%|*}），循环内零外部命令。
dw_format_disk_lines() {
    dtabs="${1:-}"
    dlookup=""
    while IFS= read -r dtline; do
        [ -n "$dtline" ] || continue
        dlookup="${dlookup:+$dlookup }${dtline}"
    done <<EOF
$dtabs
EOF
    awk -v lookup="$dlookup" '
        BEGIN { n=split(lookup, items, " "); for (i=1; i<=n; i++) { split(items[i], kv, "|"); code[kv[1]] = kv[2] } }
        {
            dev=$1; size=$2
            mpstart=0
            for (i=NF; i>=3; i--) if ($i ~ /^\//) { mpstart=i; break }
            model=""; tran=""
            if (mpstart == 0) {
                if (NF == 3) {
                    model=$3
                } else if ($NF ~ /^(sata|sas|nvme|usb|spi|ata|scsi|virtio|pcie)$/) {
                    tran=$NF
                    for (i=3; i<NF; i++) model=model " " $i
                } else {
                    for (i=3; i<=NF; i++) model=model " " $i
                }
                model=substr(model,2)
            } else {
                pre=$(mpstart-1)
                if (pre ~ /^(sata|sas|nvme|usb|spi|ata|scsi|virtio|pcie)$/) {
                    tran=pre
                    for (i=3; i<mpstart-1; i++) model=model " " $i
                } else {
                    for (i=3; i<mpstart; i++) model=model " " $i
                }
                model=substr(model,2)
            }
            tcode = (code[dev] != "") ? code[dev] : 2
            print dev "|" size "|" model "|" toupper(tran) "|" tcode
        }
    '
}

# 单盘清除：umount 全部子树挂载点 → wipefs -a 整盘 → partprobe 刷新内核分区视图
# （wipefs -a 成功后立即执行，无论后续验证结果；失败仅警告）→ wipefs -n 验证（输出空=
# 未初始化）。任一失败该盘标失败（不误报成功）；每盘打印一行结果：
#   OK /dev/<dev> reset to uninitialized
#   FAIL /dev/<dev>: <english reason>（umount failed: <mp> / wipefs -a failed /
#                                     wipefs -n failed / signatures remain / not whitelisted）
# 注意：POSIX 无 local，函数内部变量统一 dw_ 前缀，避免覆盖调用方同名变量。
dw_wipe_disk() {
    ddev="$1"
    case "$ddev" in /dev/*) ddev="${ddev#/dev/}" ;; esac
    if ! dw_dev_ok "$ddev"; then
        echo "FAIL /dev/$ddev: not whitelisted"
        return 1
    fi
    # 1) 卸载该盘全部子树挂载点（失败即中止该盘，不 wipefs）
    #    逐行读取（IFS= read -r）避免挂载点含空格被拆词；heredoc 而非管道，
    #    避免 return 在管道子 shell 中失效
    dwmps=$(dw_disk_mountpoints "$ddev")
    while IFS= read -r dmp; do
        [ -n "$dmp" ] || continue
        if ! "$UMOUNT_BIN" "$dmp" >/dev/null 2>&1; then
            echo "FAIL /dev/$ddev: umount failed: $dmp"
            return 1
        fi
    done <<EOF
$dwmps
EOF
    # 2) wipefs -a 整盘（清分区表 + 盘内全部 fs/raid/PV 签名）
    if ! "$WIPEFS_BIN" -a "/dev/$ddev" >/dev/null 2>&1; then
        echo "FAIL /dev/$ddev: wipefs -a failed"
        return 1
    fi
    # 2.5) partprobe 刷新内核分区视图：wipefs -a 成功后立即执行（无论后续验证结果），
    #     消除"未重启看旧分区视图"的误导路径；失败仅警告、不影响该盘结论
    "$PARTPROBE_BIN" "/dev/$ddev" >/dev/null 2>&1 \
        || echo "WARN: partprobe failed (kernel partition view may be stale; effective after reboot)"
    # 3) wipefs -n 验证：命令成功且输出为空 = 未初始化；命令失败与签名残留分开提示
    if ! dsigs=$("$WIPEFS_BIN" -n "/dev/$ddev" 2>/dev/null); then
        echo "FAIL /dev/$ddev: wipefs -n failed"
        return 1
    fi
    if [ -n "$dsigs" ]; then
        echo "FAIL /dev/$ddev: signatures remain"
        return 1
    fi
    echo "OK /dev/$ddev reset to uninitialized"
    return 0
}

# ---------- 日志功能（清理日志持久化落盘） ----------

# 版本号：echo 到 stdout。读构建期拷入 rootfs 的 /diskwipe.version；缺失/为空回退 unknown。
# 测试经 DW_VERSION_FILE 接缝覆盖（默认 /diskwipe.version）。
dw_version() {
    if [ -s "$DW_VERSION_FILE" ]; then
        cat "$DW_VERSION_FILE"
    else
        echo "unknown"
    fi
}

# 日志双写：屏幕 + 追加到日志文件（LOG_FILE 未设置/为空 → tee 到 /dev/null，仅屏幕）。
# tee 写失败仅提示、不阻断调用方（清理逻辑不因日志失败受影响）。
# v1.3.2：日志文件位于内存（menu 用 LOG_DIR=/tmp/diskwipe-log，initramfs rootfs 即
#   tmpfs），tee 写内存几乎不可能阻塞——包 timeout 2 仅为防御（LOG_DEGRADED 兜底保留：
#   写失败后后续 dw_log 仅屏幕 + 一次性 WARN 提示，绝不拖住菜单/清理）。
dw_log() {
    if [ "${LOG_DEGRADED:-0}" = "1" ]; then
        echo "$1"
        return 0
    fi
    echo "$1" | "$TIMEOUT_BIN" 2 tee -a "${LOG_FILE:-/dev/null}"
    if [ "$?" -ne 0 ]; then
        LOG_DEGRADED=1
        echo "WARN: cleanup log file write failed; log is screen-only." >&2
    fi
}

# 会话收尾尽力把日志文件写到 U 盘（v1.3.2：init/menu 全程零 U 盘 I/O，仅退出时一次尽力写）：
#   - 枚举 TRAN=usb 的 TYPE=part 分区（父盘即 U 盘；lsblk -o NAME,TYPE,TRAN,PKNAME -l）
#   - 过滤可写文件系统（blkid TYPE ∈ vfat|exfat|ntfs）
#   - 跳过卷标 VTOYEFI（Ventoy 32MB 启动分区，优先数据区）
#   - 逐个 "$TIMEOUT_BIN" 3 mount 到 /diskwipe-log → cp 日志文件 → umount（失败仅提示）
#   - 首个成功返回 0；全败/无候选返回 1（调用方打印降级提示，不阻断退出）
# 全部只读探测（lsblk/blkid）与 mount 均包 "$TIMEOUT_BIN" 3 兜底；若 U 盘 I/O 阻塞
# （内核 D 状态不可中断，timeout 亦会挂起）导致卡住——此时清理已完成，属可接受：
# 提示可抄录日志后断电。
dw_save_log_to_usb() {
    dwlogf="$1"
    [ -n "$dwlogf" ] && [ -f "$dwlogf" ] || return 1
    # 1) 枚举 U 盘可写分区候选（分区名，逐行）。真实 lsblk 的 TRAN 只出现在整盘行、
    #    分区行 TRAN 恒空（字段右移）——先收集 TRAN=usb 的整盘，再收其分区
    #    （PKNAME 恒为末列；-l 列表模式免树形前缀）。卷标经 blkid LABEL 逐分区读
    dwraw="$("$TIMEOUT_BIN" 3 "$LSBLK_BIN" -o NAME,TYPE,TRAN,PKNAME -l 2>/dev/null)"
    [ "$?" -eq 0 ] || return 1
    dwcands="$(printf '%s\n' "$dwraw" | awk '
        NR==1 { next }
        $2 == "disk" && $3 == "usb" { isusb[$1] = 1; next }
        $2 == "part" && ($NF in isusb) { print $1 }
    ')"
    [ -n "$dwcands" ] || return 1
    # 挂载点不存在则创建（失败不阻断：mount 会失败，由循环降级返回 1）
    mkdir -p /diskwipe-log 2>/dev/null || :
    # 2) 逐候选：可写文件系统过滤（blkid TYPE ∈ vfat|exfat|ntfs）→ 跳过卷标 VTOYEFI
    #    （blkid LABEL）→ timeout 3 mount → cp 日志文件 → umount；失败卸载换下一个
    #    （POSIX 无 local，函数内部变量统一 dw_ 前缀）
    while IFS= read -r dwpart; do
        [ -n "$dwpart" ] || continue
        dwtype="$("$TIMEOUT_BIN" 3 "$BLKID_BIN" -s TYPE -o value "/dev/$dwpart" 2>/dev/null)"
        case "$dwtype" in
        vfat|exfat|ntfs) ;;
        *) continue ;;
        esac
        dwlab="$("$TIMEOUT_BIN" 3 "$BLKID_BIN" -s LABEL -o value "/dev/$dwpart" 2>/dev/null)"
        [ "$dwlab" != "VTOYEFI" ] || continue
        if ! "$TIMEOUT_BIN" 3 mount "/dev/$dwpart" /diskwipe-log >/dev/null 2>&1; then
            continue
        fi
        if cp "$dwlogf" /diskwipe-log/ >/dev/null 2>&1; then
            "$UMOUNT_BIN" /diskwipe-log >/dev/null 2>&1 \
                || echo "WARN: failed to unmount USB after log save (unmount later manually)"
            return 0
        fi
        "$UMOUNT_BIN" /diskwipe-log >/dev/null 2>&1
    done <<EOF
$dwcands
EOF
    return 1
}
