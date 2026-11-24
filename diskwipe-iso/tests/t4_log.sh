#!/bin/bash
# T4：diskwipe-iso 清理日志（v1.3.2：无条件内存日志 + 退出尽力写 U 盘）假件单测
# 覆盖：menu 无条件内存日志（文件头/盘清单/每盘结果/文件尾，不再依赖 U 盘探测）/
#       dw_log 写内存（LOG_DEGRADED 不触发）/ dw_save_log_to_usb（U 盘候选枚举、
#       跳过 VTOYEFI、挂载失败返回 1、成功路径 mount+cp+umount）/ init 零 U 盘 I/O
#       （src 中 dw_mount_log_media 已删除；init 无 U 盘挂载调用）。
# v1.5.7 适配：init 去掉设备重试扫描（mdev -s 轮询）——dw_save_log_to_usb 开头补建
#       U 盘设备节点（"$TIMEOUT_BIN" 5 mdev -s 2>/dev/null），L3 成功路径断言 mdev 调用。
# v1.5.9 适配：init Kylin 白名单去掉 usb-storage → 真机 U 盘不再绑定 → 退出写日志必走
#       降级留内存路径（无候选 → WARN + Log kept in memory）——L1 的无 U 盘降级断言即
#       v1.5.9 常态路径；L5 追加「init Kylin 白名单无 usb-storage」源码级断言。
# 运行：bash diskwipe-iso/tests/run-all.sh（或单独 bash diskwipe-iso/tests/t4_log.sh）
# 安全约束（用户强要求，测试绝不触碰本机真实块设备/真实挂载）：
#   假 lsblk/blkid/wipefs/umount/mount/cp 全部经接缝变量/PATH 注入，绝不真挂载/真清除；
#   日志目录经 LOG_DIR 接缝指向临时目录；cp 假件把日志复制到用例临时目录 $ROOT/mnt/。
# 用例：
#   L1 menu 无 U 盘 → 内存日志含文件头/盘清单/每盘结果/文件尾；退出时无候选 → WARN
#      （日志保留内存）；清理照常
#   L2 menu 全流程（两轮）→ 内存日志两轮内容；0 退出正常
#   L3 dw_save_log_to_usb 成功路径（假件 U 盘候选 + mount 成功 + cp）→ 返回 0、
#      mount/cp/umount 记录、日志复制到挂载点
#   L4 dw_save_log_to_usb 挂载失败（mount.fail）→ 返回 1（降级提示）
#   L5 init 零 U 盘 I/O：src/init 与 src/lib.sh 均不再出现 dw_mount_log_media；
#      init 脚本内无任何 U 盘挂载调用（t3_init.sh I1 再做运行级 cmds.txt 断言）
#   L6 dw_log 写内存正常（LOG_DEGRADED 未触发）；v1.5.8 加 kmsg 镜像断言（xtrace 载荷）
set -u
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
trap 'rc=$?; cleanup_case; exit "$rc"' EXIT

MENU_SH="$REPO_ROOT/diskwipe-iso/src/menu.sh"
INIT_SH="$REPO_ROOT/diskwipe-iso/src/init"

echo "==== T4 清理日志（内存 + 退出写 U 盘）测试 ===="

setup_case() { setup_tmp; install_fakes; }

# 运行 menu.sh：stdin 用管道喂入（模拟交互）；额外环境（LOG_DIR/DW_VERSION_FILE 等）
# 经 "$@" 传入 env（bash 不识别经参数展开的赋值词，须经 env 显式设置）；退出码取
# 管道右端（PIPESTATUS）
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

# 运行 dw_save_log_to_usb 并把返回码打到 stdout：run_save <outf> <logf>
# （内层 bash source lib.sh 后调用；接缝变量指向 PATH 假件）
run_save() {
    local outf="$1" logf="$2"
    shift 2
    PATH="$FAKE_BIN:$PATH" \
    LSBLK_BIN=lsblk BLKID_BIN=blkid WIPEFS_BIN=wipefs UMOUNT_BIN=umount \
    bash -c ". \"$LIB_SH\"; dw_save_log_to_usb \"$logf\"; echo \"RC=\$?\"" > "$outf" 2>&1
    LAST_RC=$?
    return 0
}

# ---------- L1：menu 无 U 盘 → 内存日志 + 退出 WARN（日志保留内存），清理照常 ----------
# v1.5.9：init 不再加载 usb-storage → 真机 U 盘不绑定、无写日志候选——本用例的无 U 盘
# 降级路径即 v1.5.9 常态（断言 Log kept in memory + WARN: could not write log to USB）。
CASE="L1 无 U 盘内存日志 + 退出 WARN"
setup_case
cat > "$ROOT/lsblk.table" <<'EOF'
NAME SIZE TYPE MODEL TRAN MOUNTPOINT
sda 894G disk HGST 7K6000 sata
sdb 894G disk Samsung PM983 nvme
EOF
echo "1.1.0" > "$ROOT/verfile"
mkdir -p "$ROOT/logdir"
run_menu $'\nYES\n0\n' "$OUTF" LOG_DIR="$ROOT/logdir" DW_VERSION_FILE="$ROOT/verfile"
check_rc 0 '无 U 盘清理应正常退出 0'
check_out 'OK /dev/sda reset to uninitialized' '清理结果仍显示屏幕'
check_cmds 'wipefs -a /dev/sda' '清理应照常执行'
# 内存日志：文件头 / 盘清单 / 每盘结果 / 文件尾
logf=$(ls "$ROOT/logdir"/diskwipe-*.log 2>/dev/null | head -n 1)
check_file "$logf" 'version: 1.1.0' '文件头应含版本（dw_version）'
check_file "$logf" 'session start' '文件头应含会话开始时间'
check_file "$logf" 'log media: memory' '文件头应标注介质为内存'
check_file "$logf" 'Will wipe the following 2 disks' '盘清单应落日志'
check_file "$logf" 'OK /dev/sda reset to uninitialized' '每盘结果应落日志'
check_file "$logf" 'session end' '文件尾应含会话结束'
check_out 'Log kept in memory' '退出应打印内存日志路径'
check_out 'WARN: could not write log to USB' '无 U 盘应打印 WARN（日志保留内存）'
check_not_out 'No writable log media' '不应出现旧的无介质提示分支'
check_not_cmds 'mount /dev/' '退出时无 U 盘候选不得挂载任何设备'
check_not_cmds 'umount /diskwipe-log' '未挂载不得执行卸载'
cleanup_case

# ---------- L2：menu 全流程（两轮）→ 内存日志两轮内容 ----------
CASE="L2 两轮清理内存日志"
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
run_menu $'\nYES\n\nYES\n0\n' "$OUTF" LOG_DIR="$ROOT/logdir" DW_VERSION_FILE="$ROOT/verfile"
check_rc 0 '两轮清理 + 0 退出应正常退出 0'
nlog=$(ls "$ROOT/logdir"/diskwipe-*.log 2>/dev/null | wc -l)
if [ "$nlog" -eq 1 ]; then
    _pass '一次启动会话仅生成一个日志文件'
else
    _fail "一次会话应仅一个日志文件（实际 $nlog 个）"
fi
logf=$(ls "$ROOT/logdir"/diskwipe-*.log 2>/dev/null | head -n 1)
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
check_out 'Log kept in memory' '0 退出应打印内存日志路径'
check_out 'WARN: could not write log to USB' '无 U 盘应打印 WARN'
cleanup_case

# ---------- L3：dw_save_log_to_usb 成功路径（跳过 VTOYEFI → 挂载数据区 → cp → umount） ----------
CASE="L3 日志写 U 盘成功路径"
setup_case
cat > "$ROOT/lsblk.table" <<'EOF'
NAME SIZE TYPE MODEL TRAN MOUNTPOINT
sda 894G disk HGST 7K6000 sata
sdc 30G disk USB DISK 3.0 usb
sdc1 32M part USB DISK 3.0 usb
sdc2 8G part USB DISK 3.0 usb
EOF
add_label sdc1 VTOYEFI
add_label sdc2 数据区
add_blk_type sdc1 vfat
add_blk_type sdc2 exfat
echo "test log content" > "$ROOT/dummylog"
# v1.5.7：写日志前补建 U 盘节点——装假 mdev（记录调用到 cmds.txt）断言 dw_save_log_to_usb
# 开头的 "$TIMEOUT_BIN" 5 mdev -s 已执行（init 已不再重试 mdev，节点由这里补建）
fake_bin mdev '#!/bin/sh
[ -n "$ROOT" ] || exit 0
printf "mdev %s\n" "$*" >> "$ROOT/cmds.txt"
exit 0'
run_save "$OUTF" "$ROOT/dummylog"
check_rc 0 'dw_save_log_to_usb 应正常返回'
check_out 'RC=0' '应返回 0（保存成功）'
check_cmds 'mdev -s' '写日志前应先补建 U 盘设备节点（mdev -s）'
check_cmds 'mount /dev/sdc2 /diskwipe-log' '应挂载数据区 sdc2 到 /diskwipe-log'
check_cmds "cp $ROOT/dummylog /diskwipe-log/" '应复制日志到挂载点'
check_cmds 'umount /diskwipe-log' '保存后应卸载'
check_not_cmds 'mount /dev/sdc1' 'VTOYEFI 分区不得挂载'
check_not_cmds 'mount /dev/sda' '非 U 盘不得挂载'
check_not_cmds 'wipefs' '日志保存不得触发任何清除'
if [ -f "$ROOT/mnt/dummylog" ]; then
    _pass '日志文件已复制到（假）挂载点'
else
    _fail '日志文件未复制到挂载点'
fi
cleanup_case

# ---------- L4：dw_save_log_to_usb 挂载失败 → 返回 1（降级提示） ----------
CASE="L4 挂载失败返回 1"
setup_case
cat > "$ROOT/lsblk.table" <<'EOF'
NAME SIZE TYPE MODEL TRAN MOUNTPOINT
sda 894G disk HGST 7K6000 sata
sdc 30G disk USB DISK 3.0 usb
sdc1 8G part USB DISK 3.0 usb
EOF
add_blk_type sdc1 exfat
printf '/diskwipe-log\n' > "$ROOT/mount.fail"
echo "test log content" > "$ROOT/dummylog"
run_save "$OUTF" "$ROOT/dummylog"
check_rc 0 'dw_save_log_to_usb 应正常返回（不挂起）'
check_out 'RC=1' '挂载失败应返回 1（调用方降级提示）'
check_cmds 'mount /dev/sdc1 /diskwipe-log' '应尝试挂载可写分区'
check_not_cmds 'cp ' '挂载失败不得复制日志'
check_not_cmds 'umount /diskwipe-log' '挂载失败不得执行卸载'
cleanup_case

# ---------- L5：init 零 U 盘 I/O（dw_mount_log_media 已删除；init 无 U 盘挂载） ----------
CASE="L5 init 零 U 盘 I/O"
if grep -q 'dw_mount_log_media' "$INIT_SH"; then
    _fail 'src/init 不得再出现 dw_mount_log_media'
else
    _pass 'src/init 无 dw_mount_log_media'
fi
if grep -q 'dw_mount_log_media' "$LIB_SH"; then
    _fail 'src/lib.sh 不得再出现 dw_mount_log_media'
else
    _pass 'src/lib.sh 无 dw_mount_log_media（函数已删除）'
fi
# init 注释可提及 dw_save_log_to_usb（说明设计），但不得出现调用行（仅 menu 退出时调用）
if grep -E '^[[:space:]]*dw_save_log_to_usb' "$INIT_SH"; then
    _fail 'init 不得调用 dw_save_log_to_usb（仅 menu 退出时调用）'
else
    _pass 'init 无 dw_save_log_to_usb 调用'
fi
# init 脚本内不得出现 U 盘挂载形态调用（mount 仅用于基础文件系统）
if grep -Eq '^[[:space:]]*mount[[:space:]]+/?dev/' "$INIT_SH"; then
    _fail 'init 脚本内不得出现 /dev/ 设备挂载调用'
else
    _pass 'init 脚本内无 /dev/ 设备挂载调用'
fi
# v1.5.9：init Kylin（ky10 分支）白名单不得含 usb-storage——U 盘不绑定 → 退出写日志
# 必走降级留内存路径（menu 退出打印 WARN + Log kept in memory；USB 键盘走内建 usbhid
# 不受影响）。grep 锚定 DRIVE_MODULES 赋值行（注释提及 usb-storage 不算）。
if grep -E '^[[:space:]]*DRIVE_MODULES="[^"]*usb-storage' "$INIT_SH"; then
    _fail 'src/init Kylin 白名单不得含 usb-storage（v1.5.9 去掉）'
else
    _pass 'src/init Kylin 白名单无 usb-storage（v1.5.9，写日志必降级留内存）'
fi
cleanup_case

# ---------- L6：dw_log 写内存正常（LOG_DEGRADED 未触发）+ kmsg 镜像（v1.5.8） ----------
CASE="L6 dw_log 写内存正常"
setup_case
mkdir -p "$ROOT/logdir"
PATH="$FAKE_BIN:$PATH" \
LSBLK_BIN=lsblk BLKID_BIN=blkid WIPEFS_BIN=wipefs UMOUNT_BIN=umount \
LOG_FILE="$ROOT/logdir/t.log" \
BASH_XTRACEFD=3 \
bash -x -c ". \"$LIB_SH\"; dw_log 'first line'; dw_log 'second line'; echo \"DEGRADED=\${LOG_DEGRADED:-0}\"" 3> "$ROOT/xtrace.txt" > "$OUTF" 2>&1
LAST_RC=$?
check_rc 0 'dw_log 写内存应正常返回'
check_out 'second line' '两行均显示屏幕'
check_out 'DEGRADED=0' '内存写失败应不触发 LOG_DEGRADED'
check_not_out 'WARN' '不应出现写失败 WARN'
if [ -f "$ROOT/logdir/t.log" ] && grep -Fq 'first line' "$ROOT/logdir/t.log" && grep -Fq 'second line' "$ROOT/logdir/t.log"; then
    _pass '日志文件应完整写入内存目录'
else
    _fail '日志文件未完整写入'
fi
# v1.5.8：dw_log 加 kmsg 镜像（xtrace 载荷断言——Git Bash /dev/kmsg 写失败静默，镜像行为
# 经 `+ echo 'diskwipe-init: ...' > /dev/kmsg` 行正向验证）
check_file "$ROOT/xtrace.txt" 'diskwipe-init: first line' 'dw_log 应镜像到 kmsg（第一行）'
check_file "$ROOT/xtrace.txt" 'diskwipe-init: second line' 'dw_log 应镜像到 kmsg（第二行）'
cleanup_case

finish
