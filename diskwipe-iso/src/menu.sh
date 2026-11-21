#!/bin/sh
# diskwipe-iso 交互菜单：列盘（编号/设备/容量/型号/类型）→ 默认全选、输入编号排除、
# 回车=全部 → 打印将清除清单 → 输入大写 YES 才执行（调 wipe.sh）→ 循环；0 退出。
# 清理日志（持久化落盘）：DW_LOG_MEDIA=usb 时生成 /diskwipe-log/diskwipe-<时间戳>.log
#   （一次启动会话一份，多轮清理追加；文件头=版本/会话开始/介质状态），关键行经
#   dw_log 落日志，wipe.sh 每盘结果经 tee 双写；0 退出写文件尾并尽力 umount。
#   DW_LOG_MEDIA=none 时仅屏幕提示，不阻断清理。
#
# 硬约束：
#   - POSIX/ash 兼容（initramfs 运行时只有 busybox ash；禁止 [[ ]]、数组、${var:0:3}
#     等 bash 专属语法），LF 行尾，中文注释。
#   - 屏幕与日志的全部用户可见行必须纯 ASCII（无 CJK）——IPMI 虚拟 KVM（VGA→Linux
#     vt console）无中文字体，中文必然乱码；中文仅保留在代码注释。
#   - 读 stdin 写 stdout；大写 YES 严格匹配才执行；非法输入忽略（1,2,x → 忽略 x）；
#     排除列表为空 = 默认全选；无盘可清（仅 usb+光驱）→ 提示"仅发现启动介质"并退出；
#     0 退出（打印可断电/重启提示）；清除后回到菜单（列表刷新）。
#   - 设备白名单/umount/wipefs/partprobe/验证全部由 lib.sh/wipe.sh 保证，本脚本不重复实现。

. "$(dirname "$0")/lib.sh"

WIPE_SH="$(dirname "$0")/wipe.sh"

# ---- 日志初始化（一次启动会话一份文件，会话内多轮清理追加；无介质仅屏幕不阻断）----
# init 已探测并导出 DW_LOG_MEDIA（usb/none）；直接运行 menu.sh 时默认 none。
# LOG_DIR 可经环境覆盖（生产固定 /diskwipe-log，测试指向临时目录）。
DW_LOG_MEDIA="${DW_LOG_MEDIA:-none}"
LOG_DIR="${LOG_DIR:-/diskwipe-log}"
LOG_FILE=""
if [ "$DW_LOG_MEDIA" = "usb" ]; then
    mkdir -p "$LOG_DIR" 2>/dev/null || :
    LOG_FILE="$LOG_DIR/diskwipe-$(date +%Y%m%d-%H%M%S).log"
    # 文件头：版本 / 会话开始 / 介质状态（日志行同为英文 ASCII，与屏幕一致）
    dw_log "=============================================="
    dw_log "  diskwipe-iso cleanup log"
    dw_log "  version: $(dw_version)"
    dw_log "  session start: $(date '+%Y-%m-%d %H:%M:%S')"
    dw_log "  log media: usb ($LOG_DIR)"
    dw_log "=============================================="
else
    echo "No writable log media found; log will be screen-only."
fi

# 会话收尾（0 退出路径）：写文件尾（会话结束时间）；有日志介质则打印日志路径并尽力
# 卸载 /diskwipe-log（卸载失败仅提示，不阻断退出）
dw_log_finish() {
    dw_log "== session end [$(date '+%Y-%m-%d %H:%M:%S')] =="
    if [ "$DW_LOG_MEDIA" = "usb" ]; then
        echo "Cleanup log saved: $LOG_FILE"
        "$UMOUNT_BIN" /diskwipe-log >/dev/null 2>&1 || echo "WARN: failed to unmount log media (you may unmount it manually later)"
    fi
}

# 从 dw_enum_disks 输出行提取展示字段，输出 "设备|容量|型号|TRAN大写"（| 分隔）。
# 行格式：设备 容量 型号[可含空格] TRAN[可空] 挂载点[可含空格]。
# 解析：从右往左定位挂载点起始（首个以 / 开头的字段），其前一个字段仅当属于已知
#       TRAN 集合（sata/sas/nvme/usb/spi/ata/scsi/virtio/pcie）才视为 TRAN；
#       否则（TRAN 为空）该字段是型号末词，并入型号。
disk_display_fields() {
    dline="$1"
    printf '%s\n' "$dline" | awk '
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
            print dev "|" size "|" model "|" tran "|" toupper(tran)
        }
    '
}

# 类型标注（dw_is_system_disk 返回：0=数据盘 1=系统盘 2=未知；显示 DATA/SYS/UNK，
# 仅提示不影响可勾选）
disk_type_label() {
    case "$1" in
    0) echo "DATA" ;;
    1) echo "SYS" ;;
    *) echo "UNK" ;;
    esac
}

while :; do
    # 枚举全部可清盘；启动 U 盘/光驱已在 lib.sh 排除，仍为空 = 仅启动介质
    ml="$(dw_enum_disks)"
    if [ -z "$ml" ]; then
        echo
        dw_log "Only boot media found (no wipable disks; boot USB/optical drive auto-excluded)"
        dw_log "You may power off or reboot safely."
        dw_log_finish
        exit 0
    fi

    echo "=============================================="
    dw_log "  DiskWipe Tool $(dw_version) - Reset disks to uninitialized"
    echo "=============================================="
    echo "  #     Device  Size  Model/Status  Type"
    echo "  ---------------------------------------------------"
    # 列盘（编号从 1 起；类型经 dw_is_system_disk 标注）
    mi=0
    while IFS= read -r mline; do
        [ -n "$mline" ] || continue
        mi=$((mi + 1))
        mfields="$(disk_display_fields "$mline")"
        mdev="${mfields%%|*}"
        mrest="${mfields#*|}"
        msize="${mrest%%|*}"
        mrest="${mrest#*|}"
        mmodel="${mrest%%|*}"
        mrest="${mrest#*|}"
        mtran_up="${mrest#*|}"
        if [ -n "$mtran_up" ]; then
            mshow="$mmodel ($mtran_up)"
        else
            mshow="$mmodel"
        fi
        mtype="$(disk_type_label "$(dw_is_system_disk "$mdev")")"
        printf '  %d    /dev/%s  %s   %s  %s\n' "$mi" "$mdev" "$msize" "$mshow" "$mtype"
    done <<EOF
$ml
EOF
    echo "  ---------------------------------------------------"
    echo "  Default: all selected. Enter exclusions (e.g. 1,2; empty = all)"
    echo "  0 = exit (power off or reboot after done)"
    printf '> '
    IFS= read -r mex || { echo; dw_log "Input ended, exiting (you may power off or reboot)."; dw_log_finish; exit 0; }

    # 0 = 退出（打印可断电/重启提示，写文件尾并卸载日志介质）
    case "$mex" in
    0)
        echo
        echo "Exited. You may power off or reboot after done."
        dw_log_finish
        exit 0
        ;;
    esac

    # 解析排除编号：逗号/空格分隔；非法（非数字）与越界忽略；去重
    mexcl=""
    mifs_old="$IFS"
    IFS=", "
    for mtok in $mex; do
        [ -n "$mtok" ] || continue
        case "$mtok" in
        *[!0-9]*) continue ;;
        esac
        [ "$mtok" -ge 1 ] 2>/dev/null && [ "$mtok" -le "$mi" ] 2>/dev/null || continue
        case " $mexcl " in
        *" $mtok "*) ;;
        *) mexcl="$mexcl $mtok" ;;
        esac
    done
    IFS="$mifs_old"
    # 排除记录（落日志；无排除则默认全选，不记录）
    if [ -n "$mexcl" ]; then
        dw_log "Excluded: $mexcl"
    fi

    # 构造选中盘列表（排除列表为空 = 默认全选）
    msel=""
    mcnt=0
    mi=0
    while IFS= read -r mline; do
        [ -n "$mline" ] || continue
        mi=$((mi + 1))
        case " $mexcl " in
        *" $mi "*) continue ;;
        esac
        mfields="$(disk_display_fields "$mline")"
        mdev="${mfields%%|*}"
        msel="${msel:+$msel }$mdev"
        mcnt=$((mcnt + 1))
    done <<EOF
$ml
EOF
    if [ -z "$msel" ]; then
        dw_log "No disks selected, please choose again."
        continue
    fi

    # 二次确认清单（逐盘列出将清除的盘；同时落日志作为本轮的盘清单）
    echo
    dw_log "Will wipe the following $mcnt disks (irreversible!). Type YES to confirm:"
    mi=0
    while IFS= read -r mline; do
        [ -n "$mline" ] || continue
        mi=$((mi + 1))
        case " $mexcl " in
        *" $mi "*) continue ;;
        esac
        mfields="$(disk_display_fields "$mline")"
        mdev="${mfields%%|*}"
        mrest="${mfields#*|}"
        msize="${mrest%%|*}"
        mrest="${mrest#*|}"
        mmodel="${mrest%%|*}"
        mrest="${mrest#*|}"
        mtran_up="${mrest#*|}"
        if [ -n "$mtran_up" ]; then
            mshow="$mmodel ($mtran_up)"
        else
            mshow="$mmodel"
        fi
        dw_log "  /dev/$mdev  $msize  $mshow"
    done <<EOF
$ml
EOF
    printf '> '
    IFS= read -r myn || { echo; dw_log "Cancelled (YES not entered)."; continue; }
    if [ "$myn" = "YES" ]; then
        echo
        dw_log "Wiping: umount -> wipefs -a -> partprobe -> wipefs -n verify..."
        # 每盘结果（OK/FAIL）经 stdout 由 tee 同时落到屏幕与日志文件
        "$WIPE_SH" $msel 2>&1 | tee -a "${LOG_FILE:-/dev/null}"
        echo
        continue
    fi
    dw_log "Cancelled (nothing wiped)."
done
