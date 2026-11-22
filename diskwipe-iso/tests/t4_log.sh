#!/bin/bash
# T4：diskwipe-iso 清理日志持久化假件单测
# 覆盖：dw_version（版本读取/回退）/ dw_log（屏幕+文件双写）/ dw_mount_log_media
#      （U 盘可写分区探测与挂载：跳过 VTOYEFI、挂载失败换下一个/降级 none）/
#      menu 日志初始化（会话级单文件、文件头/文件尾、tee 捕获每盘结果、0 退出 umount）。
# 运行：bash diskwipe-iso/tests/run-all.sh（或单独 bash diskwipe-iso/tests/t4_log.sh）
# 安全约束（用户强要求，测试绝不触碰本机真实块设备/真实挂载）：
#   假 lsblk/blkid/wipefs/umount/mount 全部经接缝变量/PATH 注入，绝不真挂载/真清除；
#   日志目录/探测文件/版本文件经 LOG_DIR/DW_LOG_PROBE/DW_VERSION_FILE 接缝指向临时目录。
# 用例：
#   L1 U 盘 sdc（sdc1=VTOYEFI vfat + sdc2=exfat 数据区）→ 跳过 VTOYEFI 挂载 sdc2，DW_LOG_MEDIA=usb
#   L2 无 U 盘（仅 sda 数据盘+光驱）→ DW_LOG_MEDIA=none；menu 打印 No writable log media，清理照常
#   L3 有介质 + menu 两轮清理（两次 YES）→ 仅一个 diskwipe-*.log；含文件头/两轮盘清单/每盘结果/文件尾
#   L4 挂载失败（假 mount 返回非 0）→ 降级 DW_LOG_MEDIA=none，清理照常
#   L5 0 退出路径 → 含文件尾 + umount /diskwipe-log
#   L6 dw_version 缺 /diskwipe.version → unknown；存在 → 读出版本号
#   L7 tee 写入失败（日志目录不可写）→ 清理结果仍显示屏幕、清理不失败
set -u
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
trap 'rc=$?; cleanup_case; exit "$rc"' EXIT

MENU_SH="$REPO_ROOT/diskwipe-iso/src/menu.sh"

echo "==== T4 清理日志持久化测试 ===="

setup_case() { setup_tmp; install_fakes; }

# 运行 dw_mount_log_media 并把结果打到 stdout（run_dw 的子 shell 看不到函数内导出的
# 变量，故在内层 bash 末尾 echo DW_LOG_MEDIA；探测文件指向临时目录避免触碰真实路径）
run_mount() {
    local outf="$1"
    shift
    PATH="$FAKE_BIN:$PATH" \
    LSBLK_BIN=lsblk BLKID_BIN=blkid WIPEFS_BIN=wipefs UMOUNT_BIN=umount \
    DW_LOG_PROBE="$ROOT/probe" \
    bash -c ". \"$LIB_SH\"; dw_mount_log_media; echo \"DW_LOG_MEDIA=\$DW_LOG_MEDIA\"" > "$outf" 2>&1
    LAST_RC=$?
    return 0
}

# 运行 menu.sh：stdin 用管道喂入（模拟交互）；额外环境（DW_LOG_MEDIA/LOG_DIR/
# DW_VERSION_FILE 等）经 "$@" 传入 env（bash 不识别经参数展开的赋值词，须经 env
# 显式设置，避免 "FOO=bar: command not found"）；退出码取管道右端（PIPESTATUS）
run_menu() {
    local input="$1" outf="$2"
    shift 2
    printf '%s\n' "$input" | env \
        PATH="$FAKE_BIN:$PATH" \
        LSBLK_BIN=lsblk BLKID_BIN=blkid WIPEFS_BIN=wipefs UMOUNT_BIN=umount \
        PARTPROBE_BIN=partprobe \
        "$@" \
        bash "$MENU_SH" > "$outf" 2>&1
    LAST_RC=${PIPESTATUS[1]}
    return 0
}

# ---------- L1：U 盘可写分区挂载（跳过 VTOYEFI） ----------
CASE="L1 U 盘可写分区挂载（跳过 VTOYEFI）"
setup_case
cat > "$ROOT/lsblk.table" <<'EOF'
NAME SIZE TYPE MODEL TRAN MOUNTPOINT
sda 894G disk HGST 7K6000 sata
sdc 30G disk USB DISK 3.0 usb
sdc1 32M part USB DISK 3.0 usb
sdc2 8G part USB DISK 3.0 usb
sr0 1024M rom
EOF
add_label sdc1 VTOYEFI
add_label sdc2 数据区
add_blk_type sdc1 vfat
add_blk_type sdc2 exfat
run_mount "$OUTF"
check_rc 0 'dw_mount_log_media 应正常返回'
check_out 'DW_LOG_MEDIA=usb' '应置 DW_LOG_MEDIA=usb'
check_cmds 'mount /dev/sdc2 /diskwipe-log' '应挂载数据区 sdc2 到 /diskwipe-log'
check_not_cmds 'mount /dev/sdc1' 'VTOYEFI 分区不得挂载'
check_not_cmds 'mount /dev/sda' '非 U 盘不得挂载'
check_not_cmds 'wipefs' '日志挂载不得触发任何清除'
cleanup_case

# ---------- L2：无 U 盘 ----------
CASE="L2 无 U 盘降级 none"
setup_case
cat > "$ROOT/lsblk.table" <<'EOF'
NAME SIZE TYPE MODEL TRAN MOUNTPOINT
sda 894G disk HGST 7K6000 sata
sr0 1024M rom
EOF
run_mount "$OUTF"
check_rc 0 'dw_mount_log_media 应正常返回'
check_out 'DW_LOG_MEDIA=none' '无 U 盘应置 DW_LOG_MEDIA=none'
check_not_cmds 'mount /dev/' '不得挂载任何设备'
# menu：无介质 → 提示 No writable log media，清理照常执行
mkdir -p "$ROOT/logdir"
run_menu $'\nYES\n0\n' "$OUTF" DW_LOG_MEDIA=none LOG_DIR="$ROOT/logdir"
check_rc 0 '无介质清理应正常退出 0'
check_out 'No writable log media' '应打印未找到可写日志介质提示'
check_out 'OK /dev/sda reset to uninitialized' '清理结果仍显示屏幕'
check_cmds 'wipefs -a /dev/sda' '清理应照常执行'
check_not_cmds 'umount /diskwipe-log' '无介质不得卸载日志挂载'
cleanup_case

# ---------- L3：会话级单日志文件（两轮清理追加） ----------
CASE="L3 会话级单日志文件（两轮清理追加）"
setup_case
cat > "$ROOT/lsblk.table" <<'EOF'
NAME SIZE TYPE MODEL TRAN MOUNTPOINT
sda 894G disk HGST 7K6000 sata
sda1 512M part HGST 7K6000 sata /boot/efi
sdb 894G disk Samsung PM983 nvme
EOF
add_blk_type sda1 vfat
add_ptname sda1 "EFI System"
echo "1.1.0" > "$ROOT/verfile"
mkdir -p "$ROOT/logdir"
run_menu $'\nYES\n\nYES\n0\n' "$OUTF" DW_LOG_MEDIA=usb LOG_DIR="$ROOT/logdir" DW_VERSION_FILE="$ROOT/verfile"
check_rc 0 '两轮清理 + 0 退出应正常退出 0'
nlog=$(ls "$ROOT/logdir"/diskwipe-*.log 2>/dev/null | wc -l)
if [ "$nlog" -eq 1 ]; then
    _pass '一次启动会话仅生成一个日志文件'
else
    _fail "一次会话应仅一个日志文件（实际 $nlog 个）"
fi
logf=$(ls "$ROOT/logdir"/diskwipe-*.log 2>/dev/null | head -n 1)
check_file "$logf" 'version: 1.1.0' '文件头应含版本（dw_version）'
check_file "$logf" 'session start' '文件头应含会话开始时间'
check_file "$logf" 'log media' '文件头应含介质状态'
n=$(grep -Fc 'Will wipe the following' "$logf" 2>/dev/null)
if [ "$n" -eq 2 ]; then
    _pass '两轮盘清单均落日志'
else
    _fail "盘清单应为两轮（实际 $n 轮）"
fi
check_file "$logf" '/dev/sda  894G' '盘清单应含设备/容量/型号（sda）'
check_file "$logf" '/dev/sdb  894G' '盘清单应含设备/容量/型号（sdb）'
n=$(grep -Fc 'reset to uninitialized' "$logf" 2>/dev/null)
if [ "$n" -eq 4 ]; then
    _pass '两轮每盘结果均落日志（4 行）'
else
    _fail "每盘结果应为 4 行（实际 $n 行）"
fi
check_file "$logf" 'session end' '文件尾应含会话结束'
check_cmds 'umount /diskwipe-log' '0 退出应卸载日志介质'
cleanup_case

# ---------- L4：挂载失败降级 none ----------
CASE="L4 挂载失败降级 none"
setup_case
cat > "$ROOT/lsblk.table" <<'EOF'
NAME SIZE TYPE MODEL TRAN MOUNTPOINT
sda 894G disk HGST 7K6000 sata
sdc 30G disk USB DISK 3.0 usb
sdc1 8G part USB DISK 3.0 usb
EOF
add_blk_type sdc1 exfat
printf '/diskwipe-log\n' > "$ROOT/mount.fail"
run_mount "$OUTF"
check_rc 0 'dw_mount_log_media 应正常返回'
check_out 'DW_LOG_MEDIA=none' '挂载失败应降级 DW_LOG_MEDIA=none'
check_cmds 'mount /dev/sdc1 /diskwipe-log' '应尝试挂载可写分区'
check_not_cmds 'umount /diskwipe-log' '挂载失败不得执行卸载'
# menu：降级 none 后清理照常
mkdir -p "$ROOT/logdir"
run_menu $'\nYES\n0\n' "$OUTF" DW_LOG_MEDIA=none LOG_DIR="$ROOT/logdir"
check_rc 0 '降级后清理应正常退出 0'
check_out 'No writable log media' '降级后应提示未找到可写日志介质'
check_out 'OK /dev/sda reset to uninitialized' '清理结果仍显示屏幕'
check_cmds 'wipefs -a /dev/sda' '清理应照常执行'
cleanup_case

# ---------- L5：0 退出路径（文件尾 + umount） ----------
CASE="L5 0 退出路径"
setup_case
cat > "$ROOT/lsblk.table" <<'EOF'
NAME SIZE TYPE MODEL TRAN MOUNTPOINT
sda 894G disk HGST 7K6000 sata
sda1 512M part HGST 7K6000 sata /boot/efi
EOF
add_blk_type sda1 vfat
echo "1.1.0" > "$ROOT/verfile"
mkdir -p "$ROOT/logdir"
run_menu $'0\n' "$OUTF" DW_LOG_MEDIA=usb LOG_DIR="$ROOT/logdir" DW_VERSION_FILE="$ROOT/verfile"
check_rc 0 '0 退出应退出 0'
check_out 'Exited' '应打印退出提示'
check_out 'Cleanup log saved' '应打印日志保存路径'
check_cmds 'umount /diskwipe-log' '0 退出应卸载日志介质'
logf=$(ls "$ROOT/logdir"/diskwipe-*.log 2>/dev/null | head -n 1)
check_file "$logf" 'version: 1.1.0' '文件头应含版本'
check_file "$logf" 'session start' '文件头应含会话开始'
check_file "$logf" 'session end' '文件尾应含会话结束'
cleanup_case

# ---------- L6：dw_version 读取与回退 ----------
CASE="L6 dw_version 版本读取与回退"
setup_case
PATH="$FAKE_BIN:$PATH" DW_VERSION_FILE="$ROOT/nonexistent" \
bash -c ". \"$LIB_SH\"; dw_version" > "$OUTF" 2>&1
LAST_RC=$?
check_rc 0 'dw_version 应退出 0'
check_out 'unknown' '缺版本文件应回退 unknown'
echo "1.1.0" > "$ROOT/verfile"
PATH="$FAKE_BIN:$PATH" DW_VERSION_FILE="$ROOT/verfile" \
bash -c ". \"$LIB_SH\"; dw_version" > "$OUTF" 2>&1
LAST_RC=$?
check_rc 0 'dw_version 应退出 0'
check_out '1.1.0' '存在版本文件应读出版本号'
cleanup_case

# ---------- L7：tee 写入失败不阻断清理 ----------
CASE="L7 日志写失败不阻断清理"
setup_case
cat > "$ROOT/lsblk.table" <<'EOF'
NAME SIZE TYPE MODEL TRAN MOUNTPOINT
sda 894G disk HGST 7K6000 sata
sdb 894G disk Samsung PM983 nvme
EOF
# 日志目录落在普通文件之下 → mkdir 失败 → tee 无法写文件（模拟目录只读/写满）
touch "$ROOT/afile"
run_menu $'\nYES\n0\n' "$OUTF" DW_LOG_MEDIA=usb LOG_DIR="$ROOT/afile/sub"
check_rc 0 '日志写失败清理应正常退出 0'
check_out 'OK /dev/sda reset to uninitialized' '清理结果仍显示屏幕'
check_out 'OK /dev/sdb reset to uninitialized' '两盘结果均显示'
check_cmds 'wipefs -a /dev/sda' '清理仍执行'
check_cmds 'wipefs -a /dev/sdb' '清理仍执行'
check_cmds 'umount /diskwipe-log' '退出仍尽力卸载'
cleanup_case

# ---------- L8：写测试超时（U 盘写 I/O 阻塞）→ 降级 none，不挂起 ----------
CASE="L8 写测试超时降级 none"
setup_case
cat > "$ROOT/lsblk.table" <<'EOF'
NAME SIZE TYPE MODEL TRAN MOUNTPOINT
sda 894G disk HGST 7K6000 sata
sdc 30G disk USB DISK 3.0 usb
sdc1 8G part USB DISK 3.0 usb
EOF
add_blk_type sdc1 exfat
# 开关：写测试（sh -c 含 printf x >）返回 124（模拟介质写阻塞超时）
touch "$ROOT/timeout.writetest"
run_mount "$OUTF"
check_rc 0 '写测试超时 dw_mount_log_media 应正常返回（不挂起）'
check_out 'DW_LOG_MEDIA=none' '写测试超时应降级 DW_LOG_MEDIA=none'
check_cmds 'mount /dev/sdc1 /diskwipe-log' '应尝试挂载可写分区'
check_not_cmds 'wipefs' '不得触发任何清除'
cleanup_case

# ---------- L9：dw_log tee 超时 → LOG_DEGRADED 降级 + WARN + 后续只屏幕 ----------
CASE="L9 dw_log 写超时降级"
setup_case
touch "$ROOT/timeout.tee"
mkdir -p "$ROOT/logdir"
PATH="$FAKE_BIN:$PATH" \
LSBLK_BIN=lsblk BLKID_BIN=blkid WIPEFS_BIN=wipefs UMOUNT_BIN=umount \
LOG_FILE="$ROOT/logdir/t.log" \
bash -c ". \"$LIB_SH\"; dw_log 'first line'; dw_log 'second line'; echo \"DEGRADED=\$LOG_DEGRADED\"" > "$OUTF" 2>&1
LAST_RC=$?
check_rc 0 'dw_log 写超时应正常返回（不挂起）'
check_out 'second line' '降级后第二行仍显示屏幕（降级分支 echo）'
check_out 'DEGRADED=1' '写超时后应置 LOG_DEGRADED=1'
check_out 'WARN: cleanup log media failed' '应打印一次性 WARN 提示'
# 日志文件不得被写入（tee 超时未落盘；降级后也不写）
if [ -f "$ROOT/logdir/t.log" ] && grep -Fq 'second line' "$ROOT/logdir/t.log"; then
    _fail '降级后日志文件不得写入'
else
    _pass '降级后日志文件不写入'
fi
cleanup_case

# ---------- L10：menu 全流程 + 日志介质写超时 → 清理照常 + 0 退出正常 ----------
CASE="L10 日志介质写超时清理照常"
setup_case
cat > "$ROOT/lsblk.table" <<'EOF'
NAME SIZE TYPE MODEL TRAN MOUNTPOINT
sda 894G disk HGST 7K6000 sata
sdb 894G disk Samsung PM983 nvme
EOF
mkdir -p "$ROOT/logdir"
touch "$ROOT/timeout.tee"
run_menu $'\nYES\n0\n' "$OUTF" DW_LOG_MEDIA=usb LOG_DIR="$ROOT/logdir"
check_rc 0 '日志写超时清理应正常退出 0'
check_out 'WARN: cleanup log media failed' '应提示日志介质写失败'
check_out 'OK /dev/sda reset to uninitialized' '清理结果仍显示屏幕'
check_out 'OK /dev/sdb reset to uninitialized' '两盘结果均显示'
check_out 'Exited' '0 退出正常'
check_cmds 'wipefs -a /dev/sda' '清理仍执行'
check_cmds 'wipefs -a /dev/sdb' '清理仍执行'
check_cmds 'umount /diskwipe-log' '退出仍尽力卸载'
cleanup_case

finish
