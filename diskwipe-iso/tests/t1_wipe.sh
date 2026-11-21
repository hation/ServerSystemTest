#!/bin/bash
# T1：diskwipe-iso 核心逻辑假件单测
# 覆盖：src/lib.sh 的 dw_enum_disks / dw_disk_mountpoints / dw_is_system_disk / dw_dev_ok /
#       dw_wipe_disk，以及 src/wipe.sh 的逐盘清除与汇总。
# 运行：bash diskwipe-iso/tests/run-all.sh（或单独 bash diskwipe-iso/tests/t1_wipe.sh）
# 用例：
#   W1  枚举过滤+类型标注（系统盘/数据盘，排除 usb/sr0/分区）
#   W2  白名单外设备（loop0/sdb1）拒绝：枚举不出现、wipe 不清除
#   W3  型号列含空格/为空：显示原型号或"未知型号"，不崩
#   W4  带挂载点清除成功：umount 在先 → wipefs -a → wipefs -n 验证空
#   W5  无挂载盘直接清除：无 umount、退出 0
#   W6  umount 失败：该盘失败、不 wipefs、退出非 0
#   W7  wipefs -a 失败：该盘失败、不执行后续验证、退出非 0
#   W8  wipefs -n 仍有残留：该盘失败（残留）、退出非 0
#   W9  逐盘独立：sda 失败 + sdb 成功；汇总输出失败盘清单
#   W10 类型判定失败（blkid 无输出）→ "未知"，不影响可清除
#   W11 wipefs -n 命令失败 → 单独提示验证失败，退出非 0
#   W12 挂载点含空格 → 整行卸载不拆词
#   W13 无参数 → 打印用法提示并退出 1
set -u
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
trap 'rc=$?; cleanup_case; exit "$rc"' EXIT

echo "==== T1 核心逻辑（枚举/标注/清除）测试 ===="

setup_case() { setup_tmp; install_fakes; }

# ---------- W1：枚举过滤 + 类型标注（真实探测格式） ----------
CASE="W1 枚举过滤与类型标注"
setup_case
cat > "$ROOT/lsblk.table" <<'EOF'
NAME SIZE TYPE MODEL TRAN MOUNTPOINT
sda 894G disk HGST 7K6000 sata
sda1 512M part HGST 7K6000 sata /boot/efi
sda2 200G part HGST 7K6000 sata /home
sdb 894G disk Samsung PM983 nvme
sdc 30G disk USB DISK 3.0 usb
sr0 1024M rom
sdd 200G disk
sdd1 200G part /data
nvme0n1 894G disk Samsung PM983 nvme
nvme0n1p1 894G part Samsung PM983 nvme /nvme
sde 500G disk
sde1 500G part /boot
sdf 1T disk
sdf1 1T part
sdg 300G disk
sdg1 300G part
EOF
# GPT ESP：PARTTYPENAME="EFI System"（真实格式，非文本标志）
add_blk_type sda1 vfat
add_ptname sda1 "EFI System"
# MBR Linux 根：ext4 + 活动标志 0x80（真实格式）
add_blk_type sde1 ext4
add_flag sde1 0x80
# Windows 系统分区：ntfs
add_blk_type sdf1 ntfs
# 数据盘：ext4 无活动标志
add_blk_type sdg1 ext4
run_dw "$OUTF" dw_enum_disks
check_rc 0 '枚举应退出 0'
check_out 'sda 894G HGST 7K6000 sata /boot/efi,/home' 'sda 在列且挂载点逗号拼接'
check_out 'sdb 894G Samsung PM983 nvme' 'sdb 在列'
check_out 'sdd 200G 未知型号' 'sdd 在列（空型号显示未知型号）'
check_out 'nvme0n1 894G Samsung PM983 nvme /nvme' 'nvme 盘在列且分区挂载点归并到父盘'
check_not_out 'sdc' 'usb 盘不得出现'
check_not_out 'sr0' '光驱不得出现'
check_not_out 'sdd1' '分区 sdd1 不得出现'
check_not_out 'nvme0n1p1' '分区 nvme0n1p1 不得出现'
run_dw "$OUTF" dw_is_system_disk sda
check_rc 0 'sda 类型判定应退出 0'
check_out '1' 'sda（GPT vfat + PARTTYPENAME=EFI System）应为系统盘'
run_dw "$OUTF" dw_is_system_disk sdb
check_out '0' 'sdb（无分区）应为数据盘'
run_dw "$OUTF" dw_is_system_disk sde
check_out '1' 'sde（MBR ext4 + PARTFLAGS=0x80）应为系统盘'
run_dw "$OUTF" dw_is_system_disk sdf
check_out '1' 'sdf（ntfs）应为系统盘'
run_dw "$OUTF" dw_is_system_disk sdg
check_out '0' 'sdg（ext4 无 0x80 标志）应为数据盘'
cleanup_case

# ---------- W2：白名单外设备拒绝 ----------
CASE="W2 白名单外设备拒绝"
setup_case
cat > "$ROOT/lsblk.table" <<'EOF'
NAME SIZE TYPE MODEL TRAN MOUNTPOINT
sda 894G disk HGST 7K6000 sata
loop0 10G disk
sdb1 5G part /data
EOF
run_dw "$OUTF" dw_enum_disks
check_out 'sda 894G HGST 7K6000 sata' '合法盘仍列出'
check_not_out 'loop0' 'loop0 不得出现'
check_not_out 'sdb1' '分区 sdb1 不得出现'
run_wipe "$OUTF" loop0 sdb1
check_rc 1 '白名单外设备应拒绝并退出 1'
check_out '✗ 非白名单设备，跳过：loop0' '应打印 loop0 拒绝原因'
check_out '✗ 非白名单设备，跳过：sdb1' '应打印 sdb1 拒绝原因'
check_no_cmds '拒绝后不得执行任何清除命令'
cleanup_case

# ---------- W3：型号含空格/为空 ----------
CASE="W3 型号含空格或为空"
setup_case
cat > "$ROOT/lsblk.table" <<'EOF'
NAME SIZE TYPE MODEL TRAN MOUNTPOINT
sda 894G disk HGST 7K6000 SATA sata
sdb 200G disk nvme
EOF
run_dw "$OUTF" dw_enum_disks
check_rc 0 '枚举应退出 0'
check_out 'sda 894G HGST 7K6000 SATA sata' '含空格型号原文保留'
check_out 'sdb 200G 未知型号 nvme' '空型号显示未知型号'
cleanup_case

# ---------- W4：带挂载点清除成功 ----------
CASE="W4 带挂载点清除成功"
setup_case
cat > "$ROOT/lsblk.table" <<'EOF'
NAME SIZE TYPE MODEL TRAN MOUNTPOINT
sda 894G disk HGST 7K6000 sata
sda1 512M part HGST 7K6000 sata /mnt
EOF
run_wipe "$OUTF" sda
check_rc 0 '清除应退出 0'
check_cmds 'umount /mnt' '应先卸载挂载点'
check_cmds 'wipefs -a /dev/sda' '应整盘 wipefs -a'
check_cmds 'wipefs -n /dev/sda' '应执行 wipefs -n 验证'
if awk '/^umount \/mnt$/{u=1} /^wipefs -a \/dev\/sda$/{if(u)ok=1} END{exit ok?0:1}' "$ROOT/cmds.txt"; then
    _pass 'umount 先于 wipefs -a 执行'
else
    _fail 'umount 应先于 wipefs -a 执行'
fi
check_out '✓ 已恢复未初始化：/dev/sda' '应输出已恢复未初始化'
cleanup_case

# ---------- W5：无挂载盘直接清除 ----------
CASE="W5 无挂载盘直接清除"
setup_case
cat > "$ROOT/lsblk.table" <<'EOF'
NAME SIZE TYPE MODEL TRAN MOUNTPOINT
sdb 894G disk Samsung PM983 nvme
EOF
run_wipe "$OUTF" sdb
check_rc 0 '无挂载盘应退出 0'
check_cmd_count 'umount' 0 '无挂载不得 umount'
check_cmds 'wipefs -a /dev/sdb' '应直接 wipefs -a'
check_out '✓ 已恢复未初始化：/dev/sdb' '应输出已恢复未初始化'
cleanup_case

# ---------- W6：umount 失败 ----------
CASE="W6 umount 失败"
setup_case
cat > "$ROOT/lsblk.table" <<'EOF'
NAME SIZE TYPE MODEL TRAN MOUNTPOINT
sda 894G disk HGST 7K6000 sata
sda1 512M part HGST 7K6000 sata /mnt
EOF
printf '/mnt\n' > "$ROOT/umount.failmp"
run_wipe "$OUTF" sda
check_rc 1 'umount 失败应退出非 0'
check_cmds 'umount /mnt' '应尝试卸载'
check_cmd_count 'wipefs -a' 0 'umount 失败不得 wipefs'
check_out '✗ 卸载失败：/dev/sda（挂载点 /mnt）' '应输出失败原因'
check_not_out '已恢复未初始化' '不得误报成功'
cleanup_case

# ---------- W7：wipefs -a 失败 ----------
CASE="W7 wipefs -a 失败"
setup_case
cat > "$ROOT/lsblk.table" <<'EOF'
NAME SIZE TYPE MODEL TRAN MOUNTPOINT
sda 894G disk HGST 7K6000 sata
sda1 512M part HGST 7K6000 sata /mnt
EOF
printf 'sda\n' > "$ROOT/wipefs.afail"
run_wipe "$OUTF" sda
check_rc 1 'wipefs -a 失败应退出非 0'
check_cmds 'umount /mnt' '应先卸载'
check_cmds 'wipefs -a /dev/sda' '应尝试 wipefs -a'
check_not_cmds 'wipefs -n' 'wipefs -a 失败不得执行验证'
check_out '✗ wipefs -a 失败：/dev/sda' '应输出失败原因'
check_not_out '已恢复未初始化' '不得误报成功'
cleanup_case

# ---------- W8：wipefs -n 仍有残留 ----------
CASE="W8 验证残留"
setup_case
cat > "$ROOT/lsblk.table" <<'EOF'
NAME SIZE TYPE MODEL TRAN MOUNTPOINT
sda 894G disk HGST 7K6000 sata
sda1 512M part HGST 7K6000 sata /mnt
EOF
printf 'sda: 0x55aa\n' > "$ROOT/wipefs.sigs"
run_wipe "$OUTF" sda
check_rc 1 '有残留应退出非 0'
check_cmds 'umount /mnt' '应先卸载'
check_cmds 'wipefs -a /dev/sda' '应整盘 wipefs -a'
check_cmds 'wipefs -n /dev/sda' '应执行验证'
check_out '✗ 仍有签名残留：/dev/sda' '应输出残留失败原因'
check_not_out '已恢复未初始化' '不得误报成功'
cleanup_case

# ---------- W9：逐盘独立 + 汇总失败盘 ----------
CASE="W9 逐盘独立"
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
check_out '✗ wipefs -a 失败：/dev/sda' 'sda 应失败'
check_out '✓ 已恢复未初始化：/dev/sdb' 'sdb 应成功'
check_cmds 'wipefs -a /dev/sdb' 'sdb 仍被清除'
check_out '清除失败盘：sda' '应汇总失败盘清单'
cleanup_case

# ---------- W10：类型判定失败仍可清除 ----------
CASE="W10 类型判定失败仍可清除"
setup_case
cat > "$ROOT/lsblk.table" <<'EOF'
NAME SIZE TYPE MODEL TRAN MOUNTPOINT
sda 894G disk HGST 7K6000 sata
sda1 512M part HGST 7K6000 sata /mnt
EOF
run_dw "$OUTF" dw_is_system_disk sda
check_rc 0 '类型判定应退出 0'
check_out '2' 'blkid 无输出应判为未知'
run_wipe "$OUTF" sda
check_rc 0 '类型未知不影响可清除'
check_cmds 'wipefs -a /dev/sda' '仍应整盘清除'
check_out '✓ 已恢复未初始化：/dev/sda' '应清除成功'
cleanup_case

# ---------- W11：wipefs -n 命令失败 ----------
CASE="W11 wipefs -n 验证失败"
setup_case
cat > "$ROOT/lsblk.table" <<'EOF'
NAME SIZE TYPE MODEL TRAN MOUNTPOINT
sda 894G disk HGST 7K6000 sata
sda1 512M part HGST 7K6000 sata /mnt
EOF
printf 'sda\n' > "$ROOT/wipefs.nfail"
run_wipe "$OUTF" sda
check_rc 1 'wipefs -n 失败应退出非 0'
check_cmds 'umount /mnt' '应先卸载'
check_cmds 'wipefs -a /dev/sda' '应整盘 wipefs -a'
check_cmds 'wipefs -n /dev/sda' '应执行验证'
check_out '✗ wipefs -n 验证失败：/dev/sda' '应输出验证失败原因'
check_not_out '✗ 仍有签名残留' '命令失败不应误报为残留'
check_not_out '已恢复未初始化' '不得误报成功'
cleanup_case

# ---------- W12：挂载点含空格 ----------
CASE="W12 挂载点含空格"
setup_case
cat > "$ROOT/lsblk.table" <<'EOF'
NAME SIZE TYPE MODEL TRAN MOUNTPOINT
sda 894G disk HGST 7K6000 sata
sda1 512M part HGST 7K6000 sata /mnt/my data
EOF
run_wipe "$OUTF" sda
check_rc 0 '含空格挂载点清除应退出 0'
check_cmds 'umount /mnt/my data' '应整行卸载含空格挂载点（不拆词）'
check_cmds 'wipefs -a /dev/sda' '应整盘 wipefs -a'
check_out '✓ 已恢复未初始化：/dev/sda' '应清除成功'
cleanup_case

# ---------- W13：无参数用法提示 ----------
CASE="W13 无参数用法提示"
setup_case
run_wipe "$OUTF"
check_rc 1 '无参数应退出 1'
check_out '用法：wipe.sh' '应打印用法提示'
cleanup_case

finish
