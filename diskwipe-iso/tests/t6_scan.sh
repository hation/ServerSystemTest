#!/bin/bash
# T6：diskwipe-iso 真机"列盘卡住"修复验收（列盘零 exec + timeout 兜底 + 枚举降级 + 进度/日志）
# 覆盖（设计 §5/§6 与任务简报 Step 1 的 H1-H9）：
#   H1  menu 列盘典型流程 cmds.txt 无逐盘 lsblk/blkid/awk（枚举+批量探测各 1 次，其后列盘零新增命令）
#   H2  dw_scan_system_disks：假件 lsblk（含 PARTTYPENAME/PARTFLAGS 列）+ 假件 blkid
#       （-c /dev/null -o full 形态输出 设备: TYPE="..."）→ ESP 盘 SYS(1)、ntfs SYS(1)、
#       无签名 DATA(0)、探测不到 UNK(2)；输出 设备|类型码
#   H3  TIMEOUT_BIN=假件（仅批量探测返回 124）：批量探测返回空 → 全部盘标 UNK；
#       菜单仍显示其余盘、不挂死
#   H4  TIMEOUT_BIN 接缝：假件记录调用 timeout 3 <cmd>；生产默认 timeout
#   H5  类型查表与 dw_is_system_disk 口径一致（SYS/DATA/UNK 映射不变）
#   H6  枚举后屏幕含 Scanning disks...；日志含盘清单行
#   H7  枚举假件超时（124）→ menu 打印 ERROR: disk scan timed out or failed 并重试一次；
#       重试仍失败 → 打印错误+可安全重启提示；不出现 Only boot media found
#   H8  清除流程 cmds.txt：wipefs/umount/partprobe 调用无 timeout 前缀
#   H9  dw_disk_mountpoints 与退出写 U 盘（dw_save_log_to_usb）调用包 timeout 3（cmds.txt 断言）
# 运行：bash diskwipe-iso/tests/run-all.sh（或单独 bash diskwipe-iso/tests/t6_scan.sh）
# 安全约束（用户强要求，测试绝不触碰本机真实块设备）：全部经假件注入（LSBLK_BIN/BLKID_BIN/
#   TIMEOUT_BIN 接缝 + PATH 假件），脚本操作的"设备"全部来自假件输出的名字。
set -u
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
trap 'rc=$?; cleanup_case; exit "$rc"' EXIT

MENU_SH="$REPO_ROOT/diskwipe-iso/src/menu.sh"

echo "==== T6 列盘卡住修复（零 exec/超时兜底/降级/进度）测试 ===="

setup_case() { setup_tmp; install_fakes; }

# 记录版假 timeout：记录 "timeout <args>" 到 cmds.txt 后转执行（断言接缝调用形态/次数用）
install_recording_timeout() {
    fake_bin timeout '#!/bin/sh
[ -n "$ROOT" ] || exit 0
printf "timeout %s\n" "$*" >> "$ROOT/cmds.txt"
shift
"$@"'
}

# 运行 menu.sh：stdin 用管道喂入（模拟交互）；额外环境（LOG_DIR 等）经 "$@" 传入 env
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

# 运行 dw_save_log_to_usb 并 echo 返回码（同 t4 run_save；日志文件为用例临时文件）
run_save() {
    local outf="$1" logf="$2"
    shift 2
    PATH="$FAKE_BIN:$PATH" \
    LSBLK_BIN=lsblk BLKID_BIN=blkid WIPEFS_BIN=wipefs UMOUNT_BIN=umount \
    bash -c ". \"$LIB_SH\"; dw_save_log_to_usb \"$logf\"; echo \"RC=\$?\"" > "$outf" 2>&1
    LAST_RC=$?
    return 0
}

# 断言：输出中某一行同时含 A 与 B
check_line_both() {
    local a="$1" b="$2" desc="$3"
    if grep -F -- "$a" "$OUTF" | grep -Fq -- "$b"; then
        _pass "$desc"
    else
        _fail "$desc（无同时含 "$a" 与 "$b" 的行）"
    fi
}

# ---------- H1：列盘典型流程零逐盘 exec ----------
CASE="H1 列盘零逐盘 exec（枚举+批量探测各 1 次）"
setup_case
cat > "$ROOT/lsblk.table" <<'EOF'
NAME SIZE TYPE MODEL TRAN MOUNTPOINT
sda 894G disk HGST 7K6000 sata
sda1 512M part HGST 7K6000 sata /boot/efi
sdb 894G disk Samsung PM983 nvme
EOF
add_blk_type sda1 vfat
add_ptname sda1 "EFI System"
install_recording_timeout
run_menu '0' "$OUTF"
check_rc 0 '输入 0 应正常退出 0'
check_out '/dev/sda' '列表应显示 sda'
# 枚举 + 批量探测各 1 次 lsblk；退出时 dw_save_log_to_usb 再枚举 1 次（无 U 盘候选 → 降级）
check_cmd_count 'timeout 3 lsblk' 3 '枚举 + 批量探测 + 退出写 U 盘枚举各 1 次 lsblk'
check_cmd_count 'timeout 3 blkid' 1 '批量 blkid 仅 1 次'
check_not_cmds '/dev/sd' '列盘期间不得出现逐盘 lsblk/blkid（无设备参数调用）'
cleanup_case

# ---------- H2：批量类型探测 ----------
CASE="H2 批量类型探测 dw_scan_system_disks"
setup_case
cat > "$ROOT/lsblk.table" <<'EOF'
NAME SIZE TYPE MODEL TRAN MOUNTPOINT
sda 500G disk DiskA sata
sda1 512M part DiskA sata
sdb 500G disk DiskB sata
sdb1 100G part DiskB sata
sdc 500G disk DiskC sata
sdc1 500G part DiskC sata
sdd 500G disk DiskD sata
sdd1 500G part DiskD sata
sde 500G disk DiskE sata
EOF
add_blk_type sda1 vfat
add_blk_type sdb1 ntfs
add_blk_type sdc1 ext4
add_ptname sda1 "EFI System"
install_recording_timeout
run_dw "$OUTF" dw_scan_system_disks
check_rc 0 '批量探测应退出 0'
check_out 'sda|1' 'ESP（vfat + PARTTYPENAME=EFI System）→ SYS(1)'
check_out 'sdb|1' 'ntfs → SYS(1)'
check_out 'sdc|0' 'ext4 无 0x80 标志 → DATA(0)'
check_out 'sdd|2' 'blkid 探测不到 → UNK(2)'
check_out 'sde|0' '无分区盘 → DATA(0)'
check_cmd_count 'timeout 3 lsblk' 1 '批量 lsblk 仅 1 次'
check_cmd_count 'timeout 3 blkid' 1 '批量 blkid 仅 1 次'
check_cmds 'timeout 3 lsblk -o NAME,TYPE,MOUNTPOINT,PKNAME,PARTTYPENAME,PARTFLAGS' '批量 lsblk 应带 PARTTYPENAME/PARTFLAGS 列'
check_cmds 'timeout 3 blkid -c /dev/null -o full' '批量 blkid 应带 -c /dev/null -o full（含设备名输出形态）'
cleanup_case

# ---------- H3：批量探测超时 → 全部盘 UNK，菜单不挂死 ----------
CASE="H3 批量探测超时全部盘标 UNK"
setup_case
cat > "$ROOT/lsblk.table" <<'EOF'
NAME SIZE TYPE MODEL TRAN MOUNTPOINT
sda 894G disk HGST 7K6000 sata
sda1 512M part HGST 7K6000 sata /boot/efi
sdb 894G disk Samsung PM983 nvme
EOF
add_blk_type sda1 vfat
add_ptname sda1 "EFI System"
# 假 timeout：仅批量探测（PARTTYPENAME 列 / -o full）返回 124，其余（枚举等）转执行
fake_bin timeout '#!/bin/sh
case "$*" in
*PARTTYPENAME*) exit 124 ;;
*-o\ full*) exit 124 ;;
esac
shift
"$@"'
run_menu '0' "$OUTF"
check_rc 0 '批量探测超时菜单仍应正常退出 0（不挂死）'
check_out 'Scanning disks... (please wait)' '枚举后应打印进度提示'
check_line_both '/dev/sda' 'UNK' 'sda 应标 UNK（批量探测超时）'
check_line_both '/dev/sdb' 'UNK' 'sdb 应标 UNK'
check_not_out 'ERROR: disk scan' '枚举未失败不得进入枚举降级路径'
check_not_out 'Only boot media found' '不得误判仅启动介质'
cleanup_case

# ---------- H4：TIMEOUT_BIN 接缝与生产默认 ----------
CASE="H4 TIMEOUT_BIN 接缝与生产默认"
setup_case
cat > "$ROOT/lsblk.table" <<'EOF'
NAME SIZE TYPE MODEL TRAN MOUNTPOINT
sda 894G disk HGST 7K6000 sata
EOF
install_recording_timeout
# (a) 接缝指向记录假件 → 记录 "timeout 3 <cmd>" 调用形态
run_dw "$OUTF" dw_enum_disks
check_rc 0 '枚举应退出 0'
check_cmds 'timeout 3 lsblk -o NAME,SIZE,TYPE,MODEL,TRAN,MOUNTPOINT' '枚举 lsblk 应包 timeout 3'
check_out 'sda 894G HGST 7K6000 sata' '枚举输出正常'
# (b) 未显式设置时生产默认值 = timeout
PATH="$FAKE_BIN:$PATH" \
bash -c ". \"$LIB_SH\"; echo \"TIMEOUT_BIN=\$TIMEOUT_BIN\"" > "$OUTF" 2>&1
check_out 'TIMEOUT_BIN=timeout' '未显式设置时应默认 timeout'
# (c) 默认值经 PATH 解析到假件（透明转执行）→ 枚举照常（证明默认值可被假件拦截、不触真实命令）
: > "$ROOT/cmds.txt"
run_dw "$OUTF" dw_enum_disks
check_rc 0 '默认 timeout 包装下枚举应退出 0'
check_out 'sda 894G HGST 7K6000 sata' '默认 timeout 包装下枚举输出不变'
cleanup_case

# ---------- H5：类型查表与 dw_is_system_disk 口径一致 ----------
CASE="H5 类型查表与 dw_is_system_disk 口径一致"
setup_case
cat > "$ROOT/lsblk.table" <<'EOF'
NAME SIZE TYPE MODEL TRAN MOUNTPOINT
sda 500G disk DiskA sata
sda1 512M part DiskA sata
sdb 500G disk DiskB sata
sdb1 100G part DiskB sata
sdc 500G disk DiskC sata
sdc1 500G part DiskC sata
sdd 500G disk DiskD sata
sdd1 500G part DiskD sata
sde 500G disk DiskE sata
sdf 500G disk DiskF sata
sdf1 500G part DiskF sata
EOF
add_blk_type sda1 vfat
add_ptname sda1 "EFI System"
add_blk_type sdb1 ntfs
add_blk_type sdc1 ext4
add_flag sdc1 0x80
add_blk_type sdd1 ext4
# sdf1 无 blk.type 条目 → blkid 探测不到 → UNK
# 一次性批量探测 → 扫描输出存 scan.out；逐盘对比旧口径 dw_is_system_disk（SYS=1/DATA=0/UNK=2）
run_dw "$OUTF" dw_scan_system_disks
check_rc 0 '批量探测应退出 0'
cp "$OUTF" "$ROOT/scan.out"
for dev in sda sdb sdc sdd sde sdf; do
    sc="$(awk -F'|' -v d="$dev" '$1==d { print $2; exit }' "$ROOT/scan.out")"
    run_dw "$OUTF" dw_is_system_disk "$dev"
    oc="$(cat "$OUTF")"
    if [ -n "$sc" ] && [ "$sc" = "$oc" ]; then
        _pass "$dev 查表码 $sc 与 dw_is_system_disk 口径一致"
    else
        _fail "$dev 查表码 ${sc:-空} 与旧口径 ${oc:-空} 不一致"
    fi
done
# 口径映射断言（针对扫描输出本身）
if grep -Fq -- 'sda|1' "$ROOT/scan.out"; then _pass 'ESP 盘 → SYS(1)'; else _fail 'ESP 盘 → SYS(1)（扫描输出未包含 sda|1）'; fi
if grep -Fq -- 'sdb|1' "$ROOT/scan.out"; then _pass 'ntfs 盘 → SYS(1)'; else _fail 'ntfs 盘 → SYS(1)（扫描输出未包含 sdb|1）'; fi
if grep -Fq -- 'sdc|1' "$ROOT/scan.out"; then _pass 'MBR 0x80 活动盘 → SYS(1)'; else _fail 'MBR 0x80 活动盘 → SYS(1)（扫描输出未包含 sdc|1）'; fi
if grep -Fq -- 'sdd|0' "$ROOT/scan.out"; then _pass 'ext4 无标志 → DATA(0)'; else _fail 'ext4 无标志 → DATA(0)（扫描输出未包含 sdd|0）'; fi
if grep -Fq -- 'sde|0' "$ROOT/scan.out"; then _pass '无分区盘 → DATA(0)'; else _fail '无分区盘 → DATA(0)（扫描输出未包含 sde|0）'; fi
if grep -Fq -- 'sdf|2' "$ROOT/scan.out"; then _pass '探测不到 → UNK(2)'; else _fail '探测不到 → UNK(2)（扫描输出未包含 sdf|2）'; fi
cleanup_case

# ---------- H6：进度提示 + 枚举结果落日志 ----------
CASE="H6 进度提示与枚举结果落日志"
setup_case
cat > "$ROOT/lsblk.table" <<'EOF'
NAME SIZE TYPE MODEL TRAN MOUNTPOINT
sda 894G disk HGST 7K6000 sata
sda1 512M part HGST 7K6000 sata /boot/efi
sdb 894G disk Samsung PM983 nvme
EOF
add_blk_type sda1 vfat
add_ptname sda1 "EFI System"
mkdir -p "$ROOT/logdir"
run_menu $'\nYES\n0\n' "$OUTF" LOG_DIR="$ROOT/logdir"
check_rc 0 '日志流程应正常退出 0'
check_out 'Scanning disks... (please wait)' '枚举后屏幕应含进度提示'
logf=$(ls "$ROOT/logdir"/diskwipe-*.log 2>/dev/null | head -n 1)
check_file "$logf" 'Disks found: 2 (sda sdb)' '日志应含枚举盘清单行（数量+设备）'
check_file "$logf" '/dev/sda  894G' '日志应含盘清单（设备/容量/型号）'
cleanup_case

# ---------- H7：枚举超时降级（ERROR + 重试一次 + 安全重启提示） ----------
CASE="H7 枚举超时降级与重试"
setup_case
cat > "$ROOT/lsblk.table" <<'EOF'
NAME SIZE TYPE MODEL TRAN MOUNTPOINT
sda 894G disk HGST 7K6000 sata
EOF
# 假 timeout：恒 124（记录调用后返回超时码，供断言重试次数）
fake_bin timeout '#!/bin/sh
[ -n "$ROOT" ] || exit 0
printf "timeout %s\n" "$*" >> "$ROOT/cmds.txt"
exit 124'
run_menu '0' "$OUTF"
check_rc 1 '枚举超时且重试仍失败应退出 1'
check_out 'ERROR: disk scan timed out or failed' '应打印枚举超时错误'
check_out 'You may power off or reboot safely' '应打印可安全重启提示'
check_not_out 'Only boot media found' '不得误判仅启动介质'
# 枚举 2 次（首次 + 重试）；本用例假 timeout 恒 124 → 日志文件从未创建（tee 未执行），
# 退出时 dw_save_log_to_usb 因日志文件不存在直接返回 1（WARN），不新增枚举
check_cmd_count 'timeout 3 lsblk' 2 '枚举应自动重试一次（共 2 次）'
check_out 'WARN: could not write log to USB' '退出应打印写 U 盘降级提示'
cleanup_case

# ---------- H8：清除流程不带 timeout 前缀 ----------
CASE="H8 清除流程不带 timeout 前缀"
setup_case
cat > "$ROOT/lsblk.table" <<'EOF'
NAME SIZE TYPE MODEL TRAN MOUNTPOINT
sda 894G disk HGST 7K6000 sata
sda1 512M part HGST 7K6000 sata /boot/efi
sdb 894G disk Samsung PM983 nvme
EOF
add_blk_type sda1 vfat
add_ptname sda1 "EFI System"
install_recording_timeout
run_menu $'\nYES\n0\n' "$OUTF"
check_rc 0 '清除流程应正常退出 0'
check_cmds 'umount /boot/efi' 'umount 调用无 timeout 前缀（整行精确匹配）'
check_cmds 'wipefs -a /dev/sda' 'wipefs -a 无 timeout 前缀'
check_cmds 'partprobe /dev/sda' 'partprobe 无 timeout 前缀'
check_cmds 'wipefs -n /dev/sda' 'wipefs -n 无 timeout 前缀'
check_not_cmds 'timeout 3 umount' 'umount 不得包 timeout'
check_not_cmds 'timeout 3 wipefs' 'wipefs 不得包 timeout'
check_not_cmds 'timeout 3 partprobe' 'partprobe 不得包 timeout'
cleanup_case

# ---------- H9：dw_disk_mountpoints 与退出写 U 盘（dw_save_log_to_usb）包 timeout ----------
CASE="H9 dw_disk_mountpoints 包 timeout"
setup_case
cat > "$ROOT/lsblk.table" <<'EOF'
NAME SIZE TYPE MODEL TRAN MOUNTPOINT
sda 894G disk HGST 7K6000 sata
sda1 512M part HGST 7K6000 sata /mnt
EOF
install_recording_timeout
run_dw "$OUTF" dw_disk_mountpoints sda
check_rc 0 '挂载点探测应退出 0'
check_out '/mnt' '应输出挂载点'
check_cmds 'timeout 3 lsblk -o NAME,TYPE,MOUNTPOINT,PKNAME /dev/sda' 'dw_disk_mountpoints 的 lsblk 应包 timeout 3'
cleanup_case

CASE="H9b 退出写 U 盘（dw_save_log_to_usb）包 timeout"
setup_case
cat > "$ROOT/lsblk.table" <<'EOF'
NAME SIZE TYPE MODEL TRAN MOUNTPOINT
sda 894G disk HGST 7K6000 sata
sdc 30G disk USB DISK 3.0 usb
sdc1 32M part USB DISK 3.0 usb
sdc2 8G part USB DISK 3.0 usb
EOF
add_label sdc1 VTOYEFI
add_blk_type sdc1 vfat
add_blk_type sdc2 exfat
install_recording_timeout
echo "test log" > "$ROOT/dummylog"
run_save "$OUTF" "$ROOT/dummylog"
check_rc 0 '退出写 U 盘应正常返回'
check_out 'RC=0' 'U 盘候选可写应保存成功'
check_cmds 'timeout 3 lsblk -o NAME,TYPE,TRAN,PKNAME -l' '介质枚举 lsblk 应包 timeout 3'
check_cmds 'timeout 3 blkid -s TYPE -o value /dev/sdc1' '介质 blkid TYPE 应包 timeout 3'
check_cmds 'timeout 3 blkid -s LABEL -o value /dev/sdc1' '介质 blkid LABEL 应包 timeout 3'
check_cmds 'timeout 3 mount /dev/sdc2 /diskwipe-log' 'mount 应包 timeout 3（I/O 阻塞时兜底）'
check_cmds 'umount /diskwipe-log' '保存后应卸载'
cleanup_case

finish
