#!/bin/bash
# usb-eject.sh —— U 盘安全弹出脚本（卸载该盘全部挂载点，可选断电弹出）
# 用法：
#   bash usb-eject.sh                 # 自动检测 U 盘（单盘直卸；多盘交互选择），仅卸载
#   bash usb-eject.sh --poweroff      # 卸载后断电弹出
#   bash usb-eject.sh --disk sdb      # 直接指定 U 盘整盘名（非交互环境用）
# 环境变量（测试接缝）：
#   DRY_RUN=1          只打印执行计划，不执行 umount/poweroff/eject（不读交互）
#   SKIP_ROOT_CHECK=1  跳过 root 检查（仅本地测试用）
#   LSBLK_BIN          块设备查询命令（默认 lsblk，测试可用伪造输出）
#   MOUNT_LOG          操作日志路径（默认 /root/stress-test/mount.log）
#   POWEROFF_BIN       断电命令（默认 udisksctl，测试可用伪造）
# 退出码：0=已卸载（含 DRY_RUN、断电失败但卸载成功）；1=用法错误/未检测到 USB 盘/非 USB 盘/卸载失败
# 说明：全程不 set -e；只处理 TYPE=disk 且 TRAN=usb 的设备；系统盘（df / 所在盘）一律拒绝；
#       lsblk 输出统一用 -P 键值解析（不依赖列号）；每步操作写 MOUNT_LOG。

DRY_RUN="${DRY_RUN:-0}"
SKIP_ROOT_CHECK="${SKIP_ROOT_CHECK:-0}"
MOUNT_LOG="${MOUNT_LOG:-/root/stress-test/mount.log}"
LSBLK_BIN="${LSBLK_BIN:-lsblk}"
POWEROFF_BIN="${POWEROFF_BIN:-udisksctl}"

now() { date '+%Y-%m-%d %H:%M:%S'; }

usage() {
    cat <<EOF
用法:
  bash usb-eject.sh                 # 自动检测 U 盘（单盘直卸；多盘交互选择），仅卸载
  bash usb-eject.sh --poweroff      # 卸载后断电弹出（udisksctl power-off，失败回退 eject）
  bash usb-eject.sh --disk sdb      # 直接指定 U 盘整盘名（非交互环境用，如脚本/远程执行）
  bash usb-eject.sh -h|--help       # 显示本帮助

说明:
  只处理 TYPE=disk 且 TRAN=usb 的设备；系统盘（df / 所在盘）一律拒绝。
  卸载范围为该盘及其全部子分区的所有挂载点（含桌面自动挂载的 /run/media/...）。

测试接缝（本地测试用）:
  DRY_RUN=1           只打印计划不执行（不读交互）
  SKIP_ROOT_CHECK=1   跳过 root 检查
  LSBLK_BIN           块设备查询命令（默认 lsblk，测试可伪造）
  MOUNT_LOG           操作日志路径（默认 /root/stress-test/mount.log）
  POWEROFF_BIN        断电命令（默认 udisksctl，测试可伪造）
EOF
}

root_check() {
    if [ "$SKIP_ROOT_CHECK" != "1" ] && [ "$(id -u)" -ne 0 ]; then
        echo "请以 root 运行：sudo bash usb-eject.sh"
        exit 1
    fi
}
PKG_DIR="$(cd "$(dirname "$0")" && pwd)"
for _lib in usb-eject-lib; do
    if [ -f "$PKG_DIR/$_lib.sh" ]; then
        source "$PKG_DIR/$_lib.sh"
    else
        echo "缺少模块文件：$PKG_DIR/$_lib.sh"; exit 1
    fi
done

# ---------- 选盘 / 主流程 ----------

main() {
    local poweroff=0 disk="" n sz mp ans i=0
    local -a names=() sizes=()

    while [ $# -gt 0 ]; do
        case "$1" in
            --poweroff) poweroff=1; shift ;;
            --disk)
                if [ $# -lt 2 ] || [ -z "$2" ]; then echo "--disk 缺少盘名参数"; usage; exit 1; fi
                disk="${2#/dev/}"; shift 2 ;;
            -h|--help) usage; exit 0 ;;
            *) echo "未知参数：$1"; usage; exit 1 ;;
        esac
    done

    root_check

    # 系统盘识别（收集全部 TYPE=disk）；解析失败时 fail-closed，只允许 --disk 显式指定
    SYS_DISKS="$(sys_disk_list_all)"
    SYS_DETECT_OK=0
    [ -n "$SYS_DISKS" ] && SYS_DETECT_OK=1
    if [ "$SYS_DETECT_OK" != "1" ]; then
        if [ -z "$disk" ]; then
            echo "警告：无法解析系统盘（df / 所在盘），为安全起见拒绝自动选择；请用 --disk <盘名> 显式指定 U 盘" >&2
            exit 1
        fi
        echo "警告：无法解析系统盘（df / 所在盘），已跳过系统盘校验（/dev/$disk 由 --disk 显式指定）" >&2
    fi

    while IFS=$'\t' read -r n sz mp; do
        [ -n "$n" ] || continue
        is_sys_disk "$n" && continue
        names+=("$n"); sizes+=("$sz")
    done <<< "$(usb_disk_list)"

    if [ "${#names[@]}" -eq 0 ]; then
        echo "未检测到 USB 盘（lsblk 中 TYPE=disk 且 TRAN=usb 的设备，已排除系统盘）" >&2
        exit 1
    fi
    log_cmd "detect usb disks: ${names[*]}"

    if [ -n "$disk" ]; then
        if is_sys_disk "$disk"; then
            echo "拒绝操作：/dev/$disk 是系统盘（df / 所在盘）" >&2
            exit 1
        fi
        local found=0
        for n in "${names[@]}"; do
            [ "$n" = "$disk" ] && found=1
        done
        if [ "$found" != "1" ]; then
            echo "拒绝操作：/dev/$disk 不存在或不是 USB 盘（需 TYPE=disk 且 TRAN=usb）" >&2
            exit 1
        fi
    elif [ "${#names[@]}" -eq 1 ]; then
        disk="${names[0]}"
        echo "检测到 U 盘：/dev/$disk（${sizes[0]}）"
    else
        echo "检测到多块 USB 盘："
        for n in "${names[@]}"; do
            i=$((i + 1))
            mp=$(disk_mps "$n" all | join_mps)
            echo "  $i) $n  ${sizes[$((i - 1))]}  当前挂载：${mp:-（无）}"
        done
        if [ "$DRY_RUN" = "1" ]; then
            echo "（DRY RUN）正式执行时将提示选择序号或盘名；非交互场景请用 --disk <盘名>"
            exit 0
        fi
        if [ ! -t 0 ]; then
            echo "非交互环境，请用 --disk 指定盘名（如 --disk ${names[0]}）" >&2
            exit 1
        fi
        printf "请选择要弹出的 U 盘（输入序号或盘名）："
        if ! IFS= read -r -t 30 ans; then
            echo
            echo "非交互环境（stdin 无输入或等待超时），请用 --disk 指定盘名" >&2
            exit 1
        fi
        ans="${ans#/dev/}"
        ans="${ans//[[:space:]]/}"
        if [[ "$ans" =~ ^[0-9]+$ ]]; then
            if [ "$ans" -lt 1 ] || [ "$ans" -gt "${#names[@]}" ]; then
                echo "选择无效：$ans（范围 1-${#names[@]}）" >&2
                exit 1
            fi
            disk="${names[$((ans - 1))]}"
        else
            local hit=0
            for n in "${names[@]}"; do
                [ "$n" = "$ans" ] && hit=1
            done
            if [ "$hit" != "1" ]; then
                echo "选择无效：$ans（不是已检测到的 USB 盘名）" >&2
                exit 1
            fi
            disk="$ans"
        fi
    fi

    echo "==== 弹出 U 盘 /dev/$disk ===="
    log_cmd "select disk: /dev/$disk"
    if ! unmount_disk "$disk"; then
        echo "卸载未完成：/dev/$disk，请按提示排查后重试（操作日志：$MOUNT_LOG）" >&2
        exit 1
    fi
    if [ "$DRY_RUN" = "1" ]; then
        [ "$poweroff" = "1" ] && poweroff_disk "$disk"
        exit 0
    fi
    [ "$poweroff" = "1" ] && poweroff_disk "$disk"
    exit 0
}

main "$@"
