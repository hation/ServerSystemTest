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
#   - 列盘循环零外部命令：枚举（dw_enum_disks）+ 批量类型探测（dw_scan_system_disks）+
#     批量格式化（dw_format_disk_lines）各一次预计算，循环内纯 shell 字符串切分查表；
#     枚举超时/失败 → 打印 ERROR 并重试一次（不误判"仅启动介质"）；清除操作无 timeout。
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

# 类型标注（类型码：0=数据盘 1=系统盘 2=未知；显示 DATA/SYS/UNK，仅提示不影响可勾选）。
# 类型码来自批量探测 dw_scan_system_disks（经 dw_format_disk_lines 预计算进列盘行），
# 本函数为纯 shell case（列盘循环内零外部命令）。
disk_type_label() {
    case "$1" in
    0) echo "DATA" ;;
    1) echo "SYS" ;;
    *) echo "UNK" ;;
    esac
}

while :; do
    # 枚举全部可清盘（lib.sh 内 lsblk 包 "$TIMEOUT_BIN" 3 兜底；超时/失败 → 返回 1 且输出空）。
    # 枚举失败（超时等）→ 打印错误并自动重试一次；仍失败 → 打印错误 + 可安全重启提示，
    # 绝不误判"仅启动介质"退出；枚举成功但为空（仅 usb+光驱）才走"仅启动介质"路径。
    ml="$(dw_enum_disks)"
    if [ "$?" -ne 0 ]; then
        echo "ERROR: disk scan timed out or failed"
        ml="$(dw_enum_disks)"
        if [ "$?" -ne 0 ]; then
            echo "ERROR: disk scan failed. You may power off or reboot safely."
            dw_log_finish
            exit 1
        fi
    fi
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
    # 批量类型探测 + 列盘字段预计算（一次 lsblk + 一次 blkid，均包 timeout；批量超时 →
    # 全部盘标 UNK，类型仅提示不影响清除）。先打印进度提示，批量探测耗时用户可见而非假死。
    echo "Scanning disks... (please wait)"
    mcodes="$(dw_scan_system_disks)"
    mtab="$(printf '%s\n' "$ml" | dw_format_disk_lines "$mcodes")"
    # 枚举结果落日志（数量 + 设备清单；一次 dw_log，不进列盘循环）
    msum=""
    mi=0
    while IFS= read -r mline; do
        [ -n "$mline" ] || continue
        mi=$((mi + 1))
        mdev="${mline%%|*}"
        msum="${msum:+$msum }$mdev"
    done <<EOF
$mtab
EOF
    dw_log "Disks found: $mi ($msum)"
    echo "  #     Device  Size  Model/Status  Type"
    echo "  ---------------------------------------------------"
    # 列盘（编号从 1 起；类型码来自预计算查表行「设备|容量|型号|TRAN大写|类型码」，
    # 循环内仅 shell 字符串切分 + disk_type_label 纯 shell case —— 零外部命令）
    mi=0
    while IFS= read -r mline; do
        [ -n "$mline" ] || continue
        mi=$((mi + 1))
        mdev="${mline%%|*}"
        mrest="${mline#*|}"
        msize="${mrest%%|*}"
        mrest="${mrest#*|}"
        mmodel="${mrest%%|*}"
        mrest="${mrest#*|}"
        mtran_up="${mrest%%|*}"
        mrest="${mrest#*|}"
        mtcode="${mrest%%|*}"
        if [ -n "$mtran_up" ]; then
            mshow="$mmodel ($mtran_up)"
        else
            mshow="$mmodel"
        fi
        mtype="$(disk_type_label "$mtcode")"
        printf '  %d    /dev/%s  %s   %s  %s\n' "$mi" "$mdev" "$msize" "$mshow" "$mtype"
    done <<EOF
$mtab
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

    # 构造选中盘列表（排除列表为空 = 默认全选）。
    # 枚举行首个字段即设备名（无空格），${mline%% *} 纯 shell 提取——零外部命令
    msel=""
    mcnt=0
    mi=0
    while IFS= read -r mline; do
        [ -n "$mline" ] || continue
        mi=$((mi + 1))
        case " $mexcl " in
        *" $mi "*) continue ;;
        esac
        mdev="${mline%% *}"
        msel="${msel:+$msel }$mdev"
        mcnt=$((mcnt + 1))
    done <<EOF
$ml
EOF
    if [ -z "$msel" ]; then
        dw_log "No disks selected, please choose again."
        continue
    fi

    # 二次确认清单（逐盘列出将清除的盘；同时落日志作为本轮的盘清单）。
    # 直接遍历预计算查表行（$mtab）纯 shell 切分——零外部命令
    echo
    dw_log "Will wipe the following $mcnt disks (irreversible!). Type YES to confirm:"
    mi=0
    while IFS= read -r mline; do
        [ -n "$mline" ] || continue
        mi=$((mi + 1))
        case " $mexcl " in
        *" $mi "*) continue ;;
        esac
        mdev="${mline%%|*}"
        mrest="${mline#*|}"
        msize="${mrest%%|*}"
        mrest="${mrest#*|}"
        mmodel="${mrest%%|*}"
        mrest="${mrest#*|}"
        mtran_up="${mrest%%|*}"
        if [ -n "$mtran_up" ]; then
            mshow="$mmodel ($mtran_up)"
        else
            mshow="$mmodel"
        fi
        dw_log "  /dev/$mdev  $msize  $mshow"
    done <<EOF
$mtab
EOF
    printf '> '
    IFS= read -r myn || { echo; dw_log "Cancelled (YES not entered)."; continue; }
    if [ "$myn" = "YES" ]; then
        echo
        dw_log "Wiping: umount -> wipefs -a -> partprobe -> wipefs -n verify..."
        # 每盘结果（OK/FAIL）经 stdout 由 tee 同时落到屏幕与日志文件；日志介质已降级
        # （LOG_DEGRADED）时仅屏幕显示、不写盘（tee 不包 timeout——写管道超时可能
        # SIGPIPE 中断 wipe.sh，故降级检查代替超时；dw_log 前置写入失败即触发降级）
        if [ "${LOG_DEGRADED:-0}" = "1" ]; then
            "$WIPE_SH" $msel 2>&1
        else
            "$WIPE_SH" $msel 2>&1 | tee -a "${LOG_FILE:-/dev/null}"
        fi
        echo
        continue
    fi
    dw_log "Cancelled (nothing wiped)."
done
