#!/bin/bash
# ============================================================
# check-nvme-health.sh — 故障盘一键健康检查（多盘通用版，只读）
# 适用：Kylin/KySec（麒麟）服务器，root 或 sudo 直接执行
# 用法：bash check-nvme-health.sh                 # 无参数：自动枚举全部物理盘
#       bash check-nvme-health.sh nvme0n1 nvme2n1 # 指定设备（纯数字自动补 nvme 前缀）
# 说明：本脚本只做只读检查，不执行修复/卸载/格式化；
#       fsck、短自检（smartctl -t short）仅给出提示，不自动执行。
# ============================================================
set -u

# ---------- 颜色（非 tty 自动禁用） ----------
if [ -t 1 ]; then
    C_GREEN=$'\033[32m'
    C_RED=$'\033[31m'
    C_YELLOW=$'\033[33m'
    C_RESET=$'\033[0m'
else
    C_GREEN=''; C_RED=''; C_YELLOW=''; C_RESET=''
fi

# ---------- 工具可用性检测 ----------
have() { command -v "$1" >/dev/null 2>&1; }
HAS_SMARTCTL=0; HAS_NVME=0; HAS_DMESG=0
have smartctl && HAS_SMARTCTL=1
have nvme && HAS_NVME=1
have dmesg && HAS_DMESG=1

# ---------- 逐盘结论记录（全局数组，供 summary 汇总） ----------
declare -A res_status
declare -A res_summary

# ---------- 提取 smartctl 字段数值 ----------
# $1: smartctl 输出行；返回十进制数值（0x 转十进制、去 % 与千分位逗号，非数字回 0）
field_val() {
    local v
    v=$(printf '%s\n' "$1" | sed -n 's/^[^:]*:[[:space:]]*//p')
    case "$v" in
        *%*) v=${v%\%} ;;
    esac
    case "$v" in
        0[xX][0-9a-fA-F]*) v=$((v)) ;;
    esac
    v=$(printf '%s' "$v" | tr -d ',')
    case "$v" in
        ''|*[!0-9]*) v=0 ;;
    esac
    echo "$v"
}

# ---------- 物理盘枚举：lsblk type=disk 优先，回退 /sys/block ----------
# 枚举目录可用环境变量 SYS_BLOCK_DIR 覆盖（默认 /sys/block，便于桩测试）
list_disks() {
    local devs=""
    if have lsblk; then
        devs=$(lsblk -d -n -o NAME,TYPE 2>/dev/null | awk '$2=="disk" && $1 ~ /^(nvme|sd|vd|hd)[a-z0-9]+$/ {print $1}')
    fi
    if [ -z "$devs" ]; then
        local sysblk="${SYS_BLOCK_DIR:-/sys/block}"
        for b in "$sysblk"/*; do
            local name
            name=$(basename "$b")
            case "$name" in nvme*|sd[a-z]|vd[a-z]|hd[a-z]) devs="$devs $name" ;; esac
        done
    fi
    echo "$devs"
}

# ---------- 设备不存在提示 ----------
not_exist() {
    local dev="$1"
    echo ""
    echo "================================================================"
    echo " 检查设备: ${dev} (/dev/${dev})    时间: $(date '+%Y-%m-%d %H:%M:%S')"
    echo "================================================================"
    echo "${C_RED}设备不存在${C_RESET} — /dev/${dev} 不存在（可能未插盘、已被移除或设备号错误），跳过检查。"
    res_status[$dev]="跳过"
    res_summary[$dev]="设备不存在"
}

# ---------- 单盘检查（[1/5]~[5/5] 五段 + 独立结论） ----------
check_one() {
    local dev="$1" devnode="/dev/$1"
    local critical=0 ioerr=0 unavailable=0
    local out rc sm hits dmesg_out

    echo ""
    echo "================================================================"
    echo " 检查设备: ${dev} (${devnode})    时间: $(date '+%Y-%m-%d %H:%M:%S')"
    echo "================================================================"

    # ---------- [1/5] 设备基本信息 ----------
    echo ""
    echo "---------- [1/5] 设备基本信息 ----------"
    if have lsblk; then
        lsblk -d -o NAME,SIZE,MODEL "${devnode}" 2>&1
    else
        echo "[提示] 未找到 lsblk 命令（util-linux），跳过设备信息。"
    fi
    case "$dev" in
        nvme*)
            if [ "$HAS_NVME" -eq 1 ]; then
                echo "-- nvme list --"
                nvme list 2>&1
            else
                echo "[提示] 未安装 nvme-cli，跳过 nvme list 与厂商 smart-log 检查。"
                echo "        安装命令: yum install -y nvme-cli"
                unavailable=$((unavailable+1))
            fi
            ;;
        *)  echo "[提示] 非 NVMe 设备（SATA/USB），跳过 nvme list 检查。" ;;
    esac

    # ---------- [2/5] SMART 健康 ----------
    echo ""
    echo "---------- [2/5] SMART 健康 (smartctl -a) ----------"
    if [ "$HAS_SMARTCTL" -eq 1 ]; then
        out=$(smartctl -a "${devnode}" 2>&1)
        rc=$?
        if [ "$rc" -ne 0 ]; then
            echo "$out"
            echo "[提示] smartctl 执行失败（可能无权限或设备不支持），SMART 项视为不可用。"
            unavailable=$((unavailable+1))
        else
            echo "-- smartctl -a 关键字段 --"
            printf '%s\n' "$out" | grep -iE "Critical Warning|Temperature:|Available Spare|Percentage Used|Media and Data Integrity|Error Information Log|Data Units Written"
            sm=$(printf '%s\n' "$out" | grep -i "Critical Warning" | head -1)
            if [ -n "$sm" ] && [ "$(field_val "$sm")" -ne 0 ]; then
                echo "[!!] 命中严重字段: ${sm}（Critical Warning 非 0）"
                critical=$((critical+1))
            fi
            sm=$(printf '%s\n' "$out" | grep -i "Media and Data Integrity" | head -1)
            if [ -n "$sm" ] && [ "$(field_val "$sm")" -gt 0 ]; then
                echo "[!!] 命中严重字段: ${sm}（Media and Data Integrity Errors > 0）"
                critical=$((critical+1))
            fi
            sm=$(printf '%s\n' "$out" | grep -i "Percentage Used" | head -1)
            if [ -n "$sm" ] && [ "$(field_val "$sm")" -ge 100 ]; then
                echo "[!!] 命中严重字段: ${sm}（Percentage Used >= 100%）"
                critical=$((critical+1))
            fi
            if [ "$critical" -eq 0 ]; then
                echo "(SMART 关键字段未见严重异常)"
            fi
        fi
    else
        echo "[提示] 未安装 smartmontools，跳过 SMART 检查。"
        echo "        安装命令: yum install -y smartmontools"
        unavailable=$((unavailable+1))
    fi

    # ---------- [3/5] NVMe 厂商日志（仅 NVMe 设备） ----------
    echo ""
    echo "---------- [3/5] NVMe 厂商日志 (nvme smart-log) ----------"
    case "$dev" in
        nvme*)
            if [ "$HAS_NVME" -eq 1 ]; then
                nvme smart-log "${devnode}" 2>&1
            else
                echo "[提示] 未安装 nvme-cli，跳过（安装: yum install -y nvme-cli）。"
            fi
            ;;
        *)  echo "[提示] 非 NVMe 设备，跳过该段。" ;;
    esac

    # ---------- [4/5] 内核故障记录 ----------
    echo ""
    echo "---------- [4/5] 内核故障记录 (dmesg) ----------"
    if [ "$HAS_DMESG" -eq 1 ]; then
        dmesg_out=$(dmesg -T 2>&1)
        rc=$?
        if [ "$rc" -ne 0 ]; then
            echo "$dmesg_out"
            echo "[提示] dmesg 读取失败（通常为权限不足），可用 sudo 重跑本脚本获取完整内核日志。"
            unavailable=$((unavailable+1))
        else
            hits=$(printf '%s\n' "$dmesg_out" | grep -i "${dev}" | tail -40)
            if [ -n "$hits" ]; then
                printf '%s\n' "$hits"
            else
                echo "(内核日志中未见 ${dev} 相关故障记录)"
            fi
            # 按盘独立判定：仅当 I/O 错误行与本盘关联时才计数
            if printf '%s\n' "$dmesg_out" | grep -qiE "(print_req_error|I/O error|Buffer I/O).*${dev}|${dev}.*(print_req_error|I/O error|Buffer I/O)"; then
                echo "[!!] 命中内核 I/O 错误记录（print_req_error / I/O error），异常标志 +1"
                ioerr=$((ioerr+1))
            fi
        fi
    else
        echo "[提示] 未找到 dmesg 命令，跳过内核故障记录检查。"
        unavailable=$((unavailable+1))
    fi

    # ---------- [5/5] 文件系统/挂载状态 ----------
    echo ""
    echo "---------- [5/5] 文件系统/挂载状态 ----------"
    if have mount; then
        mount | grep "${dev}" 2>&1 || echo "(mount 列表未见 ${dev} 相关记录)"
    else
        echo "[提示] 未找到 mount 命令，跳过挂载状态检查。"
    fi
    if have lsblk; then
        lsblk -o NAME,MOUNTPOINT,FSTYPE "${devnode}" 2>&1
    else
        echo "[提示] 未找到 lsblk 命令，跳过分区/文件系统信息检查。"
    fi
    if have mount && mount | grep -q "${dev}"; then
        echo "[提示] ${dev} 当前已挂载。如需执行短自检 smartctl -t short，建议先卸载；"
        echo "        fsck/自检等修复操作本脚本只给建议，不自动执行（只读检查）。"
    else
        echo "[提示] ${dev} 未挂载或无法确认。fsck / smartctl -t short 等修复/自检操作仅作建议，本脚本不自动执行（只读检查）。"
    fi

    # ---------- 本盘结论判定（按盘独立；SATA 盘无 nvme 段，工具上限为 2） ----------
    local req=3
    case "$dev" in nvme*) ;; *) req=2 ;; esac
    echo ""
    echo "------------------------------------------------------------"
    if [ "$critical" -gt 0 ] || [ "$ioerr" -gt 0 ]; then
        echo "${C_RED}结论（${dev}）：异常${C_RESET} — SMART 严重字段或内核 I/O 错误命中。"
        echo "      建议：更换/返修该盘，相关压测数据无效，需重测。"
        res_status[$dev]="异常"
    elif [ "$unavailable" -ge "$req" ]; then
        echo "${C_YELLOW}结论（${dev}）：证据不足${C_RESET} — 健康检查工具（smartctl/nvme/dmesg）不可用，需 sudo 重跑。"
        res_status[$dev]="证据不足"
    else
        echo "${C_GREEN}结论（${dev}）：健康${C_RESET} — 未见 SMART 严重字段与内核 I/O 错误记录。"
        res_status[$dev]="健康"
    fi
    echo "------------------------------------------------------------"
    res_summary[$dev]="critical=$critical ioerr=$ioerr unavailable=$unavailable"
}

# ---------- 汇总表 ----------
summary() {
    local dev status summ color
    echo ""
    echo "================================================================"
    echo "                          检查汇总"
    echo "================================================================"
    printf "%-12s %-12s %s\n" "盘" "结论" "关键摘要"
    for dev in $DISKS_LIST; do
        status="${res_status[$dev]:-}"
        summ="${res_summary[$dev]:-}"
        case "$status" in
            健康) color="$C_GREEN" ;;
            异常) color="$C_RED" ;;
            证据不足) color="$C_YELLOW" ;;
            跳过) color="$C_YELLOW" ;;
            *) color="" ;;
        esac
        printf "%-12s %s%-12s%s %s\n" "$dev" "$color" "$status" "$C_RESET" "$summ"
    done
    echo "================================================================"
}

# ---------- 主流程 ----------
main() {
    local mode="自动枚举全部物理盘"
    local devs=""
    local d dev

    if [ "$#" -eq 0 ]; then
        devs=$(list_disks)
    else
        mode="指定设备"
        for d in "$@"; do
            case "$d" in
                nvme*) devs="$devs $d" ;;
                *[!0-9]*) devs="$devs $d" ;;
                *) devs="$devs nvme$d" ;;
            esac
        done
    fi

    echo "================================================================"
    echo " 故障盘一键健康检查（只读）"
    echo " 模式: ${mode}    时间: $(date '+%Y-%m-%d %H:%M:%S')"
    echo "================================================================"

    if [ -z "$devs" ]; then
        echo ""
        echo "未发现任何物理盘（无 NVMe/SATA 盘或枚举失败）。"
        echo "可手动指定设备: bash check-nvme-health.sh nvme0n1 [nvme2n1 ...]"
        exit 0
    fi

    DISKS_LIST=$devs

    for dev in $devs; do
        # 设备不存在判定：/dev 节点缺失 且 lsblk（若可用）也判定不存在
        # （仅当两者都判缺失才报"设备不存在"，避免非 root 无读盘权限时误报）
        if [ ! -e "/dev/$dev" ] && ! { have lsblk && lsblk -d "$dev" >/dev/null 2>&1; }; then
            not_exist "$dev"
            continue
        fi
        check_one "$dev"
    done

    summary
    exit 0
}

main "$@"
