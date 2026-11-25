#!/bin/sh
# diskwipe-iso 交互菜单：列盘（编号/设备/容量/型号/类型）→ 默认全选、输入编号排除、
# 回车=全部 → 打印将清除清单 → 输入大写 YES 才执行（调 wipe.sh）→ 循环；0 退出。
# 清理日志（v1.3.2 起全程写内存，零 U 盘 I/O）：LOG_DIR 默认 /tmp/diskwipe-log
#   （initramfs rootfs 即 tmpfs = 内存，不受 U 盘 I/O 阻塞影响），启动时无条件
#   mkdir -p + 创建 diskwipe-<时间戳>.log（一次启动会话一份，多轮清理追加；文件头=
#   版本/会话开始/介质状态），关键行经 dw_log 落日志，wipe.sh 每盘结果经 tee 双写；
#   0 退出写文件尾后由 dw_save_log_to_usb 尽力写 U 盘一次（成功打印 saved / 失败
#   打印 WARN + 内存路径，提示可抄录后断电），不阻断退出。
#
# 硬约束：
#   - POSIX/ash 兼容（initramfs 运行时只有 busybox ash；禁止 [[ ]]、数组、${var:0:3}
#     等 bash 专属语法），LF 行尾，中文注释。
#   - 屏幕与日志的全部用户可见行必须纯 ASCII（无 CJK）——IPMI 虚拟 KVM（VGA→Linux
#     vt console）无中文字体，中文必然乱码；中文仅保留在代码注释。
#   - 读 stdin 写 stdout；大写 YES 严格匹配才执行；非法输入忽略（1,2,x → 忽略 x）；
#     排除列表为空 = 默认全选；无盘可清（仅 usb+光驱）→ 无限重试枚举（每 5 秒重枚举，
#     v1.5.13：绝不自动关机/重启——真机 reboot -f 执行成关机、用户未及操作即断电，
#     安全第一：盘就绪即正常列盘，用户可随时断电；v1.5.10：避免 sda 迟就绪误判 +
#     避免 exit 致 PID1 退出内核 panic；v1.5.11：重试 3 → 6；v1.5.12：reboot -f +
#     fallthrough 保护（v1.5.13 起整体废弃）；
#     v1.5.14：等待改 read -t 5（sleep 真机严重失真 5s→~0.17s 致刷新疯狂）+ 重试消息
#     每 10 轮打一次（屏幕降噪）+ lsblk 原始输出 RAW lsblk 诊断行（定位 sda 未枚举根因）；
#     枚举原文经 kmsg 打 RAW enum 诊断行（定位设备名空/格式异常根因）；
#     勾选循环 mdev 为空时从 mtab 兜底补设备名）；
#     0 退出（打印可断电/重启提示）；清除后回到菜单（列表刷新）。
#   - 列盘循环零外部命令：枚举（dw_enum_disks）+ 批量类型探测（dw_scan_system_disks）+
#     批量格式化（dw_format_disk_lines）各一次预计算，循环内纯 shell 字符串切分查表；
#     枚举超时/失败 → 打印 ERROR 并重试一次（不误判"仅启动介质"）；清除操作无 timeout。
#   - 设备白名单/umount/wipefs/partprobe/验证全部由 lib.sh/wipe.sh 保证，本脚本不重复实现。

# v1.5.8：exec 后立即打点（不依赖 lib.sh 的 dw_progress，证明 menu 已被 exec 执行）
echo "diskwipe-init: menu.sh argv0=$0" > /dev/kmsg 2>/dev/null

. "$(dirname "$0")/lib.sh"

# v1.5.7：menu 入口 kmsg 进度（写 /dev/kmsg，与内核日志混排、屏幕最后几行可见；
# 万一 menu 内卡住，靠这些进度行定位卡点阶段）
dw_progress "menu.sh started"

WIPE_SH="$(dirname "$0")/wipe.sh"

# ---- 日志初始化（v1.3.2：无条件写内存；一次启动会话一份文件，会话内多轮清理追加）----
# LOG_DIR 默认 /tmp/diskwipe-log（initramfs rootfs 即 tmpfs = 内存，menu 启动不依赖
# U 盘探测/挂载——根治真机"init 挂 U 盘日志介质后 I/O 阻塞菜单进不去"）；测试可覆盖
# LOG_DIR 指向临时目录。
LOG_DIR="${LOG_DIR:-/tmp/diskwipe-log}"
LOG_FILE=""
mkdir -p "$LOG_DIR" 2>/dev/null || :
LOG_FILE="$LOG_DIR/diskwipe-$(date +%Y%m%d-%H%M%S).log"
# 文件头：版本 / 会话开始 / 介质状态（日志行同为英文 ASCII，与屏幕一致）
dw_log "=============================================="
dw_log "  diskwipe-iso cleanup log"
dw_log "  version: $(dw_version)"
dw_log "  session start: $(date '+%Y-%m-%d %H:%M:%S')"
dw_log "  log media: memory ($LOG_DIR)"
dw_log "=============================================="

# 会话收尾（全部退出路径）：写文件尾 → 打印内存日志路径 → 尽力写 U 盘一次
# （dw_save_log_to_usb 成功打印 saved；失败/无 U 盘打印 WARN + 内存路径，提示
# 可抄录后断电；U 盘 I/O 阻塞时 mount 可能卡住——清理已完成，属可接受，不阻断退出）
dw_log_finish() {
    dw_log "== session end [$(date '+%Y-%m-%d %H:%M:%S')] =="
    echo "Log kept in memory: $LOG_FILE"
    dw_progress "saving log to USB"
    if dw_save_log_to_usb "$LOG_FILE"; then
        echo "Cleanup log saved to USB"
    else
        echo "WARN: could not write log to USB (disk I/O blocked or no USB); log kept in memory: $LOG_FILE"
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

# v1.5.13：无盘重试计数（在 while : 前初始化；仅作日志——无盘时无限重试、永不自动
# 关机/重启；v1.5.11 起曾「重试 ≤6 轮 → 仍无盘 reboot」、v1.5.12 改 reboot -f，
# 真机 reboot -f 执行成关机 → v1.5.13 彻底废弃 reboot，安全第一）
dwnoretry=0

# v1.5.11：菜单输入重定向到 /dev/tty0（键盘/VT）——/dev/console 输入默认映射到最后一个
# console（ttyS0 串口），真机 KVM USB 键盘无效；tty0 不存在（无 VT）时 fallback 保持 stdin。
if [ -e /dev/tty0 ]; then
    exec 0< /dev/tty0
fi

while :; do
    # 枚举全部可清盘（lib.sh 内 lsblk 包 "$TIMEOUT_BIN" 3 兜底；超时/失败 → 返回 1 且输出空）。
    # 枚举失败（超时等）→ 打印错误并自动重试一次；仍失败 → 打印错误 + 可安全重启提示，
    # 绝不误判"仅启动介质"退出；枚举成功但为空（仅 usb+光驱）→ 走下方 v1.5.13 无盘路径：
    # 无限重试（每 5 秒重枚举（v1.5.14 起 read -t 5 等待，sleep 真机失真）+ continue，永不
    # 自动关机/重启——真机 reboot -f 执行成关机、用户未及操作即断电；盘就绪即正常列盘）。
    # 交互逻辑其余不变。
    dw_progress "enumerating disks (lsblk)"
    # v1.5.15：枚举前强制 SCSI 重扫描兜底——盘可能晚就绪，每次枚举前 rescan 一次，
    # 就绪的盘下次枚举即出现（与无限重试配合）。
    for sh in /sys/class/scsi_host/host*/scan; do
        [ -w "$sh" ] && echo "- - -" > "$sh" 2>/dev/null || true
    done
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
    # v1.5.12：枚举原文诊断（kmsg 输出枚举原文——真机屏幕可见，定位设备名空/格式异常的根因；
    # 例：无盘时显示 "RAW enum ml=[]" 即可确认枚举结果本身为空、而非设备名提取失败）
    # v1.5.14：RAW lsblk 原始输出诊断（在 RAW enum 前——定位真机 sda 一直未被枚举：
    # 区分「sda 设备未就绪/不存在」vs「lsblk 有输出但 dw_enum_disks 的 awk 解析过滤掉」；
    # tr '\n' '|' 把多行压成一行进 kmsg；2>&1 捕获错误）
    dw_progress "RAW lsblk: $(lsblk -o NAME,SIZE,TYPE,MODEL,TRAN,MOUNTPOINT 2>&1 | tr '\n' '|')"
    dw_progress "RAW enum ml=[$ml]"
    if [ -z "$ml" ]; then
        # v1.5.13：无盘无限重试——每 5 秒重枚举，盘就绪即正常；绝不自动关机/重启
        # （安全第一：真机 reboot -f 执行成关机，用户还没看到菜单就被断电；宁可一直
        # 等待、用户可随时断电）。dwnoretry 仅作日志计数（v1.5.10 起为避免 sda 迟就绪
        # 误判与 exit 致 PID1 内核 panic；v1.5.11/1.5.12 曾重试 ≤6 轮后 reboot，
        # v1.5.13 起废弃 reboot/sleep 10/fallthrough）。重试消息经 dw_log/dw_progress
        # 双通道（屏幕 + kmsg 可见）。
        dwnoretry=$((dwnoretry + 1))
        # v1.5.14：重试消息每 10 轮打一次（其余轮仅计数不刷屏幕，噪音大减；枚举每轮仍进行）
        if [ $((dwnoretry % 10)) -eq 1 ]; then
            dw_log "No wipable disks found yet (retry $dwnoretry). Retrying... (you may power off anytime)"
            dw_progress "no disks, retry $dwnoretry (never auto poweroff/reboot)"
        fi
        # v1.5.14：sleep 在真机严重失真（5s 实际 ~0.17s → 刷新疯狂）；read -t 用 select 超时，
        # 若时钟正常则 5s 真实等待（等待期间用户按键可提前跳过——tty0 已重定向）。
        read -t 5 dummy < /dev/tty0 2>/dev/null || true
        continue
    fi

    echo "=============================================="
    # v1.5.8 界面双通道：关键界面行 echo 到 console + dw_progress 镜像到 kmsg
    # （真机 /dev/console（tty0）输出不可见时 kmsg 通道保证屏幕可读可操作）
    dw_progress "=============================================="
    dw_log "  DiskWipe Tool $(dw_version) - Reset disks to uninitialized"
    echo "=============================================="
    dw_progress "=============================================="
    # 批量类型探测 + 列盘字段预计算（一次 lsblk + 一次 blkid，均包 timeout；批量超时 →
    # 全部盘标 UNK，类型仅提示不影响清除）。先打印进度提示，批量探测耗时用户可见而非假死。
    echo "Scanning disks... (please wait)"
    dw_progress "scanning disk types (blkid)"
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
    dw_progress "  #     Device  Size  Model/Status  Type"
    echo "  ---------------------------------------------------"
    dw_progress "  ---------------------------------------------------"
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
        dw_progress "  $mi    /dev/$mdev  $msize   $mshow  $mtype"
    done <<EOF
$mtab
EOF
    echo "  ---------------------------------------------------"
    dw_progress "  ---------------------------------------------------"
    echo "  Default: all selected. Enter exclusions (e.g. 1,2; empty = all)"
    dw_progress "  Default: all selected. Enter exclusions (e.g. 1,2; empty = all)"
    echo "  0 = exit (power off or reboot after done)"
    dw_progress "  0 = exit (power off or reboot after done)"
    printf '> '
    dw_progress "> "
    IFS= read -r mex || { echo; dw_log "Input ended, exiting (you may power off or reboot)."; dw_log_finish; exit 0; }

    # 0 = 退出（打印可断电/重启提示，写文件尾并尽力写 U 盘）
    case "$mex" in
    0)
        echo
        echo "Exited. You may power off or reboot after done."
        dw_progress "Exited. You may power off or reboot after done."
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
        # v1.5.12 兜底：枚举行设备字段异常为空时（真机 Disks found: 1 () + /dev/ 空），
        # 从格式化行（mtab 第 mi 行，| 分隔首字段）补设备名——格式化经 awk 字段切分，
        # 对前导空白等异常更鲁棒；仍为空则该行放弃（不塞空设备名进选中清单）
        if [ -z "$mdev" ]; then
            mtabline="$(printf '%s\n' "$mtab" | sed -n "${mi}p")"
            mdev="${mtabline%%|*}"
        fi
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
    dw_progress "> "
    IFS= read -r myn || { echo; dw_log "Cancelled (YES not entered)."; continue; }
    if [ "$myn" = "YES" ]; then
        echo
        dw_log "Wiping: umount -> wipefs -a -> partprobe -> wipefs -n verify..."
        dw_progress "wiping disks"
        # 每盘结果（OK/FAIL）经 stdout 由 tee 同时落到屏幕与日志文件；日志写已降级
        # （LOG_DEGRADED）时仅屏幕显示、不写盘（tee 不包 timeout——写管道超时可能
        # SIGPIPE 中断 wipe.sh，故降级检查代替超时；dw_log 前置写入失败即触发降级）
        # v1.5.8：每盘结果行加 kmsg 镜像（console 不可见时 kmsg 通道可读；逐行读改写，
        # 屏幕顺序不变，交互逻辑零改动）
        if [ "${LOG_DEGRADED:-0}" = "1" ]; then
            "$WIPE_SH" $msel 2>&1
        else
            "$WIPE_SH" $msel 2>&1 | tee -a "${LOG_FILE:-/dev/null}"
        fi | while IFS= read -r wline; do
            echo "diskwipe-init: $wline" > /dev/kmsg 2>/dev/null
            printf '%s\n' "$wline"
        done
        echo
        continue
    fi
    dw_log "Cancelled (nothing wiped)."
done
