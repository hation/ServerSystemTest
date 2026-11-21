#!/bin/sh
# diskwipe-iso 共享库：盘枚举 / 白名单校验 / 子树挂载点 / OS 迹象标注 / 单盘清除
#
# 硬约束：
#   - POSIX/ash 兼容（initramfs 运行时只有 busybox ash；禁止 [[ ]]、数组、${var:0:3} 等
#     bash 专属语法），LF 行尾，中文注释。
#   - 设备白名单：仅 sd[a-z] / nvme[0-9]n[0-9] / vd[a-z] / mmcblk[0-9]；排除 TRAN=usb
#     （启动 U 盘）与 sr* / loop* / ram*（光驱/循环/内存盘）。
#   - 接缝变量：LSBLK_BIN / BLKID_BIN / WIPEFS_BIN / UMOUNT_BIN（默认系统命令，
#     测试经 PATH 假件注入，绝不触碰真实块设备）。
#
# 接口（后续任务依赖的签名）：
#   dw_dev_ok <dev>            0=合法白名单设备 / 1=拒绝（支持带或不带 /dev/ 前缀）
#   dw_enum_disks              无参；stdout 每行「设备 容量 型号 TRAN 挂载点」，
#                             挂载点为该盘子树挂载点逗号拼接；仅 TYPE=disk + 白名单 + 非 usb
#   dw_disk_mountpoints <dev>  stdout 每行一个该盘子树挂载点（无挂载输出空）
#   dw_is_system_disk <dev>    echo 0=数据盘 / 1=系统盘 / 2=未知（OS 迹象判定）
#   dw_wipe_disk <dev>         0=已恢复未初始化 / 非0=失败（umount 全部→wipefs -a→wipefs -n 验证）

# ---------- 接缝变量（默认系统命令，测试可覆盖） ----------
LSBLK_BIN="${LSBLK_BIN:-lsblk}"
BLKID_BIN="${BLKID_BIN:-blkid}"
WIPEFS_BIN="${WIPEFS_BIN:-wipefs}"
UMOUNT_BIN="${UMOUNT_BIN:-umount}"

# 设备名白名单校验（代码层护栏，从源头杜绝误操作）
dw_dev_ok() {
    ddev="$1"
    case "$ddev" in
    /dev/*) ddev="${ddev#/dev/}" ;;
    esac
    case "$ddev" in
    sd[a-z]|nvme[0-9]n[0-9]|vd[a-z]|mmcblk[0-9]) return 0 ;;
    *) return 1 ;;
    esac
}

# 枚举全部可清盘。lsblk 列解析用 awk：
#   按 NAME/SIZE/TYPE 三列定位；MODEL 可含空格，从右往左解析——
#   末字段以 / 开头为挂载点，其前一 token 为 TRAN，TYPE 之后到 TRAN 之前为 MODEL 原文；
#   分区挂载点按父盘推导（nvme0n1p1/mmcblk0p1 去 p+数字、sda1 去尾部数字）归并（逗号拼接）。
dw_enum_disks() {
    "$LSBLK_BIN" -o NAME,SIZE,TYPE,MODEL,TRAN,MOUNTPOINT 2>/dev/null | awk '
        NR==1 { next }
        $3 != "disk" && $3 != "part" { next }
        $3 == "disk" {
            # 白名单 + 双保险排除 sr*/loop*/ram*
            if ($1 ~ /^(sr|loop|ram)[0-9]/) next
            if (!($1 ~ /^sd[a-z]$/ || $1 ~ /^nvme[0-9]n[0-9]$/ || $1 ~ /^vd[a-z]$/ || $1 ~ /^mmcblk[0-9]$/)) next
            name=$1; size=$2
            mps=""; t=NF
            if ($NF ~ /^\//) { mps=$NF; t=NF-1 }
            tran=""; if (t > 3) tran=$t
            if (tran == "usb") next          # 排除启动 U 盘
            model=""
            for (i=4; i<t; i++) { if (model != "") model = model " "; model = model $i }
            if (model == "") model = "未知型号"
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

# 输出该盘子树全部挂载点（盘自身 + 其分区），每行一个；无挂载输出空
dw_disk_mountpoints() {
    ddev="$1"
    case "$ddev" in /dev/*) ddev="${ddev#/dev/}" ;; esac
    [ -n "$ddev" ] || return 0
    "$LSBLK_BIN" -o NAME,TYPE,MOUNTPOINT,PKNAME "/dev/$ddev" 2>/dev/null | awk '
        NR==1 { next }
        { if ($3 != "") print $3 }
    '
}

# OS 迹象判定：任一分区满足 → 1 系统盘；有分区但 blkid 探测不到类型 → 2 未知；
# 无 OS 迹象且全部类型已知 → 0 数据盘。仅提示用，不影响可勾选。
dw_is_system_disk() {
    ddev="$1"
    case "$ddev" in /dev/*) ddev="${ddev#/dev/}" ;; esac
    dparts=$("$LSBLK_BIN" -o NAME,TYPE,MOUNTPOINT,PKNAME "/dev/$ddev" 2>/dev/null | awk -v d="$ddev" '
        NR==1 { next }
        $4 == d && $2 == "part" { print $1 }
    ')
    [ -n "$dparts" ] || { echo 0; return 0; }   # 无分区 → 数据盘
    dunknown=0
    for dpart in $dparts; do
        dfstype=$("$BLKID_BIN" -s TYPE -o value "/dev/$dpart" 2>/dev/null)
        dbrc=$?
        if [ -z "$dfstype" ] || [ "$dbrc" -ne 0 ]; then dunknown=1; continue; fi
        dflags=$("$LSBLK_BIN" -no PARTFLAGS "/dev/$dpart" 2>/dev/null)
        case "$dfstype" in
        vfat)
            case "$dflags" in *boot*|*esp*|*BOOT*|*ESP*) echo 1; return 0 ;; esac
            ;;
        ntfs)
            echo 1; return 0
            ;;
        ext4|xfs|btrfs)
            case "$dflags" in *boot*|*BOOT*) echo 1; return 0 ;; esac
            ;;
        esac
    done
    [ "$dunknown" -eq 1 ] && { echo 2; return 0; }
    echo 0
}

# 单盘清除：umount 全部子树挂载点 → wipefs -a 整盘 → wipefs -n 验证（输出空=未初始化）。
# 任一失败该盘标失败（不误报成功）；成功/失败分别打印一行结果。
# 注意：POSIX 无 local，函数内部变量统一 dw_ 前缀，避免覆盖调用方同名变量。
dw_wipe_disk() {
    ddev="$1"
    case "$ddev" in /dev/*) ddev="${ddev#/dev/}" ;; esac
    if ! dw_dev_ok "$ddev"; then
        echo "✗ 非白名单设备：/dev/$ddev"
        return 1
    fi
    # 1) 卸载该盘全部子树挂载点（失败即中止该盘，不 wipefs）
    for dmp in $(dw_disk_mountpoints "$ddev"); do
        if ! "$UMOUNT_BIN" "$dmp" >/dev/null 2>&1; then
            echo "✗ 卸载失败：/dev/$ddev（挂载点 $dmp）"
            return 1
        fi
    done
    # 2) wipefs -a 整盘（清分区表 + 盘内全部 fs/raid/PV 签名）
    if ! "$WIPEFS_BIN" -a "/dev/$ddev" >/dev/null 2>&1; then
        echo "✗ wipefs -a 失败：/dev/$ddev"
        return 1
    fi
    # 3) wipefs -n 验证：命令成功且输出为空 = 未初始化；仍输出签名或命令失败 → 残留失败
    if dsigs=$("$WIPEFS_BIN" -n "/dev/$ddev" 2>/dev/null) && [ -z "$dsigs" ]; then
        echo "✓ 已恢复未初始化：/dev/$ddev"
        return 0
    fi
    echo "✗ 仍有签名残留：/dev/$ddev"
    return 1
}
