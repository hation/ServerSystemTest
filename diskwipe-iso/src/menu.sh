#!/bin/sh
# diskwipe-iso 交互菜单：列盘（编号/设备/容量/型号/类型）→ 默认全选、输入编号排除、
# 回车=全部 → 打印将清除清单 → 输入大写 YES 才执行（调 wipe.sh）→ 循环；0 退出。
#
# 硬约束：
#   - POSIX/ash 兼容（initramfs 运行时只有 busybox ash；禁止 [[ ]]、数组、${var:0:3}
#     等 bash 专属语法），LF 行尾，中文注释。
#   - 读 stdin 写 stdout；大写 YES 严格匹配才执行；非法输入忽略（1,2,x → 忽略 x）；
#     排除列表为空 = 默认全选；无盘可清（仅 usb+光驱）→ 提示"仅发现启动介质"并退出；
#     0 退出（打印"可断电/重启"提示）；清除后回到菜单（列表刷新）。
#   - 设备白名单/umount/wipefs/验证全部由 lib.sh/wipe.sh 保证，本脚本不重复实现。

. "$(dirname "$0")/lib.sh"

WIPE_SH="$(dirname "$0")/wipe.sh"

# 从 dw_enum_disks 输出行提取展示字段，输出 "设备|容量|型号|TRAN大写"（| 分隔）。
# 行格式：设备 容量 型号[可含空格] TRAN[可空] 挂载点[可含空格]。
# 解析：从右往左定位挂载点起始（首个以 / 开头的字段），其前一个字段为 TRAN、再前为型号；
#       TRAN 为空时型号占位"未知型号"与挂载点相邻，据占位词与真实 TRAN 区分。
disk_display_fields() {
    dline="$1"
    printf '%s\n' "$dline" | awk '
        {
            dev=$1; size=$2
            mpstart=0
            for (i=NF; i>=3; i--) if ($i ~ /^\//) { mpstart=i; break }
            model=""; tran=""
            if (mpstart == 0) {
                if (NF == 3) model=$3
                else {
                    tran=$NF
                    for (i=3; i<NF; i++) model=model " " $i
                    model=substr(model,2)
                }
            } else {
                pre=$(mpstart-1)
                if (pre == "未知型号") {
                    for (i=3; i<=mpstart-1; i++) model=model " " $i
                    model=substr(model,2)
                } else {
                    tran=pre
                    for (i=3; i<mpstart-1; i++) model=model " " $i
                    model=substr(model,2)
                }
            }
            print dev "|" size "|" model "|" tran "|" toupper(tran)
        }
    '
}

# 类型标注文本（dw_is_system_disk 返回：0=数据盘 1=系统盘 2=未知；仅提示不影响可勾选）
disk_type_label() {
    case "$1" in
    0) echo "数据盘" ;;
    1) echo "系统盘" ;;
    *) echo "未知" ;;
    esac
}

while :; do
    # 枚举全部可清盘；启动 U 盘/光驱已在 lib.sh 排除，仍为空 = 仅启动介质
    ml="$(dw_enum_disks)"
    if [ -z "$ml" ]; then
        echo
        echo "仅发现启动介质（未发现可清除的硬盘；启动 U 盘/光驱已自动排除）"
        echo "可安全断电或重启退出。"
        exit 0
    fi

    echo "=============================================="
    echo "  硬盘清理工具 v1.0  清除分区并恢复为未初始化"
    echo "=============================================="
    echo "  编号  设备      容量    型号/状态              类型"
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
    echo "  默认已全部选中；输入要【排除】的编号（可多选如 1,2；直接回车=全部）"
    printf '> '
    IFS= read -r mex || { echo; echo "输入结束，已退出（可断电/重启）。"; exit 0; }

    # 0 = 退出（打印可断电/重启提示）
    case "$mex" in
    0)
        echo
        echo "已退出。清除完成后可断电或重启。"
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
        echo "未选择任何硬盘，请重新选择。"
        continue
    fi

    # 二次确认清单（逐盘列出将清除的盘）
    echo
    echo "将清除以下 $mcnt 块硬盘，清除后它们将恢复为【未初始化】："
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
        printf '  /dev/%s  %s  %s\n' "$mdev" "$msize" "$mshow"
    done <<EOF
$ml
EOF
    echo "此操作不可恢复！输入大写 YES 确认："
    printf '> '
    IFS= read -r myn || { echo; echo "已取消（未输入 YES）。"; continue; }
    if [ "$myn" = "YES" ]; then
        echo
        echo "开始清除（umount → wipefs -a → wipefs -n 验证）..."
        "$WIPE_SH" $msel
        echo
        continue
    fi
    echo "已取消（未执行清除）。"
done
