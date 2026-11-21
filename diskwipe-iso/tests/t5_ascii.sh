#!/bin/bash
# T5：diskwipe-iso 真机修复验收 —— 屏幕 ASCII 化 + 白名单扩展 + partprobe
# 覆盖（设计 §7 与任务简报 Step 1 的 N1-N6）：
#   N1  典型流程（列盘→回车→YES→清除→0 退出）全部 stdout 无 CJK/非 ASCII 字符
#   N2  类型标注：系统盘（PARTTYPENAME=EFI System）标 SYS；数据盘标 DATA；未知标 UNK
#   N3  每盘结果：OK /dev/<dev> reset to uninitialized；FAIL /dev/<dev>: <english reason>
#   N4  wipefs -a 成功后立即调用 partprobe（无论验证结果）；partprobe 假件返回 1 →
#       WARN: 提示但该盘结论不变
#   N5  PARTPROBE_BIN 接缝指向假件时记录调用；生产默认 partprobe
#   N6  dw_dev_ok / dw_enum_disks：sdab/nvme0n10/mmcblk10/sdaa 通过；
#       sr0/loop0/TRAN=usb 仍排除
# 运行：bash diskwipe-iso/tests/run-all.sh（或单独 bash diskwipe-iso/tests/t5_ascii.sh）
set -u
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
trap 'rc=$?; cleanup_case; exit "$rc"' EXIT

MENU_SH="$REPO_ROOT/diskwipe-iso/src/menu.sh"

echo "==== T5 真机修复验收（ASCII/白名单/partprobe）测试 ===="

# 运行 menu.sh：stdin 用管道喂入（模拟交互），假件经接缝变量注入；
# 退出码取管道右端（bash 测试可用 PIPESTATUS）
run_menu() {
    local input="$1" outf="$2"
    printf '%s\n' "$input" | PATH="$FAKE_BIN:$PATH" \
        LSBLK_BIN=lsblk BLKID_BIN=blkid WIPEFS_BIN=wipefs UMOUNT_BIN=umount \
        PARTPROBE_BIN=partprobe \
        bash "$MENU_SH" > "$outf" 2>&1
    LAST_RC=${PIPESTATUS[1]}
    return 0
}

setup_case() { setup_tmp; install_fakes; }

# 断言：输出中某一行同时含 A 与 B
check_line_both() {
    local a="$1" b="$2" desc="$3"
    if grep -F -- "$a" "$OUTF" | grep -Fq -- "$b"; then
        _pass "$desc"
    else
        _fail "$desc（无同时含 "$a" 与 "$b" 的行）"
    fi
}

# ---------- N1：典型流程全部输出纯 ASCII ----------
CASE="N1 屏幕输出纯 ASCII"
setup_case
cat > "$ROOT/lsblk.table" <<'EOF'
NAME SIZE TYPE MODEL TRAN MOUNTPOINT
sda 894G disk HGST 7K6000 sata
sda1 512M part HGST 7K6000 sata /boot/efi
sdb 894G disk Samsung PM983 nvme
sdc 200G disk WDC WD1002FAEX sata
sdc1 200G part WDC WD1002FAEX sata
EOF
add_blk_type sda1 vfat
add_ptname sda1 "EFI System"
# 典型流程：回车（默认全选）→ YES 清除 → 0 退出
run_menu $'\nYES\n0\n' "$OUTF"
check_rc 0 '典型流程应正常退出 0'
nbad=$(grep -Pc '[^\x00-\x7F]' "$OUTF" 2>/dev/null)
[ -n "$nbad" ] || nbad=0
if [ "$nbad" -eq 0 ]; then
    _pass 'menu 典型流程全部输出行为纯 ASCII（无 CJK）'
else
    _fail "menu 典型流程输出含 $nbad 行非 ASCII（应全英文）"
    grep -Pn '[^\x00-\x7F]' "$OUTF" | sed 's/^/    NON-ASCII: /' || true
fi
# wipe.sh 直接调用（成功盘 + 白名单拒绝盘）输出亦须纯 ASCII
run_wipe "$OUTF" sda loop0
nbad=$(grep -Pc '[^\x00-\x7F]' "$OUTF" 2>/dev/null)
[ -n "$nbad" ] || nbad=0
if [ "$nbad" -eq 0 ]; then
    _pass 'wipe.sh 输出全部为纯 ASCII（无 CJK）'
else
    _fail "wipe.sh 输出含 $nbad 行非 ASCII"
    grep -Pn '[^\x00-\x7F]' "$OUTF" | sed 's/^/    NON-ASCII: /' || true
fi
cleanup_case

# ---------- N2：类型标注 SYS/DATA/UNK ----------
CASE="N2 类型标注 SYS/DATA/UNK"
setup_case
cat > "$ROOT/lsblk.table" <<'EOF'
NAME SIZE TYPE MODEL TRAN MOUNTPOINT
sda 894G disk HGST 7K6000 sata
sda1 512M part HGST 7K6000 sata /boot/efi
sdb 894G disk Samsung PM983 nvme
sdc 200G disk WDC WD1002FAEX sata
sdc1 200G part WDC WD1002FAEX sata
EOF
add_blk_type sda1 vfat
add_ptname sda1 "EFI System"
# sdc1 无 blk.type 条目 → blkid 探测失败 → 未知
run_menu '0' "$OUTF"
check_rc 0 '输入 0 应正常退出 0'
check_line_both '/dev/sda' 'SYS' '系统盘（EFI System）应标 SYS'
check_line_both '/dev/sdb' 'DATA' '数据盘（无分区）应标 DATA'
check_line_both '/dev/sdc' 'UNK' '未知盘（blkid 无类型）应标 UNK'
cleanup_case

# ---------- N3：每盘结果 OK/FAIL + 英文 reason ----------
CASE="N3 每盘结果 OK/FAIL + 英文 reason"
setup_case
cat > "$ROOT/lsblk.table" <<'EOF'
NAME SIZE TYPE MODEL TRAN MOUNTPOINT
sda 894G disk HGST 7K6000 sata
sda1 512M part HGST 7K6000 sata /mnt
sdb 894G disk Samsung PM983 nvme
EOF
printf 'sda\n' > "$ROOT/wipefs.afail"
run_wipe "$OUTF" sda sdb
check_rc 1 '存在失败盘应退出 1'
check_out 'OK /dev/sdb reset to uninitialized' '成功盘应输出 OK 结果行'
check_out 'FAIL /dev/sda: wipefs -a failed' '失败盘应输出 FAIL + 英文 reason（wipefs -a failed）'
cleanup_case

# ---------- N4：wipefs -a 成功后立即 partprobe；失败仅 WARN ----------
CASE="N4 wipefs -a 成功后立即 partprobe（验证失败亦调用）"
setup_case
cat > "$ROOT/lsblk.table" <<'EOF'
NAME SIZE TYPE MODEL TRAN MOUNTPOINT
sda 894G disk HGST 7K6000 sata
sda1 512M part HGST 7K6000 sata /mnt
EOF
printf 'sda\n' > "$ROOT/wipefs.nfail"
run_wipe "$OUTF" sda
check_rc 1 'wipefs -n 失败应退出 1'
check_cmds 'wipefs -a /dev/sda' '应执行 wipefs -a'
check_cmds 'partprobe /dev/sda' 'wipefs -a 成功后应立即 partprobe（即使验证失败）'
check_out 'FAIL /dev/sda: wipefs -n failed' '验证失败仍输出 FAIL'
cleanup_case

CASE="N4b partprobe 失败仅 WARN、结论不变"
setup_case
cat > "$ROOT/lsblk.table" <<'EOF'
NAME SIZE TYPE MODEL TRAN MOUNTPOINT
sdb 894G disk Samsung PM983 nvme
EOF
printf 'sdb\n' > "$ROOT/partprobe.fail"
run_wipe "$OUTF" sdb
check_rc 0 'partprobe 失败不影响清除结论'
check_cmds 'partprobe /dev/sdb' '仍应调用 partprobe'
check_out 'WARN: partprobe failed' '应输出 WARN 提示'
check_out 'OK /dev/sdb reset to uninitialized' '该盘结论仍为 OK'
cleanup_case

# ---------- N5：PARTPROBE_BIN 接缝与生产默认 ----------
CASE="N5 PARTPROBE_BIN 接缝与生产默认"
setup_case
cat > "$ROOT/lsblk.table" <<'EOF'
NAME SIZE TYPE MODEL TRAN MOUNTPOINT
sda 894G disk HGST 7K6000 sata
EOF
# (a) 接缝显式指向假件 → 记录调用
run_wipe "$OUTF" sda
check_rc 0 '清除应退出 0'
check_cmds 'partprobe /dev/sda' 'PARTPROBE_BIN=partprobe 时应调用并记录'
# (b) 未显式设置时生产默认值 = partprobe
PATH="$FAKE_BIN:$PATH" \
bash -c ". \"$LIB_SH\"; echo \"PARTPROBE_BIN=\$PARTPROBE_BIN\"" > "$OUTF" 2>&1
check_out 'PARTPROBE_BIN=partprobe' '未显式设置时应默认 partprobe'
# (c) 默认值经 PATH 解析到假件 → 调用记录（证明默认值可被假件拦截、不触真实命令）
: > "$ROOT/cmds.txt"
PATH="$FAKE_BIN:$PATH" \
LSBLK_BIN=lsblk BLKID_BIN=blkid WIPEFS_BIN=wipefs UMOUNT_BIN=umount \
bash -c ". \"$LIB_SH\"; dw_wipe_disk sda" > "$OUTF" 2>&1
check_rc 0 '默认 partprobe 清除应退出 0'
check_cmds 'partprobe /dev/sda' '默认 partprobe 应经 PATH 解析并记录调用'
cleanup_case

# ---------- N6：白名单扩展 ----------
CASE="N6 白名单扩展"
setup_case
# dw_dev_ok：扩展后应通过
for dev in sdaa sdab nvme0n10 mmcblk10; do
    run_dw "$OUTF" dw_dev_ok "$dev"
    check_rc 0 "$dev 应通过白名单（扩展）"
done
# dw_dev_ok：仍拒绝
for dev in sr0 loop0 sdb1; do
    run_dw "$OUTF" dw_dev_ok "$dev"
    check_rc 1 "$dev 应被白名单拒绝"
done
# dw_enum_disks：枚举过滤
cat > "$ROOT/lsblk.table" <<'EOF'
NAME SIZE TYPE MODEL TRAN MOUNTPOINT
sdaa 894G disk HGST 7K6000 sata
sdab 894G disk Samsung PM983 nvme
nvme0n10 894G disk Samsung PM983 nvme
mmcblk10 30G disk SD Card
sdc 30G disk USB DISK 3.0 usb
sr0 1024M rom
loop0 10G disk
EOF
run_dw "$OUTF" dw_enum_disks
check_out 'sdaa 894G HGST 7K6000 sata' 'sdaa（两位字母）应枚举'
check_out 'sdab 894G Samsung PM983 nvme' 'sdab 应枚举'
check_out 'nvme0n10 894G Samsung PM983 nvme' 'nvme0n10（多位数字）应枚举'
check_out 'mmcblk10 30G SD Card' 'mmcblk10（多位数字）应枚举'
check_not_out 'sdc' 'TRAN=usb 仍排除'
check_not_out 'sr0' 'sr0 仍排除'
check_not_out 'loop0' 'loop0 仍排除'
cleanup_case

finish
