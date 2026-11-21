#!/bin/bash
# T2：diskwipe-iso 交互菜单假件单测
# 覆盖：src/menu.sh 的列盘（编号/设备/容量/型号/类型）、默认全选、排除编号、
#      大写 YES 二次确认、清除后循环刷新、0 退出、仅启动介质退出。
# 运行：bash diskwipe-iso/tests/run-all.sh（或单独 bash diskwipe-iso/tests/t2_menu.sh）
# 交互契约（必须满足）：读 stdin 写 stdout；大写 YES 严格匹配才执行；
#      非法输入忽略（1,2,x → 忽略 x）；排除列表为空 = 默认全选；
#      0 退出（打印"可断电/重启"提示）；无盘可清（仅 usb+光驱）→ 提示"仅发现启动介质"并退出；
#      清除后回到菜单（列表刷新）。
# 用例：
#   M1  两盘 sda/sdb + sdc(usb)：列表含 sda/sdb 不含 sdc；sda 标"系统盘"、sdb 标"数据盘"
#   M2  回车（默认全选）→ YES：调用 wipe.sh 且含 sda sdb；输出确认清单
#   M3  输入 1 排除 → YES：只调用 wipe.sh sdb
#   M4  输入 YES 以外的值（y/no/空）：不执行清除、回到菜单；无 wipe.sh 调用
#   M5  排除输入 1,2,x：忽略 x，排除 1、2 合法项生效（只清 sdd）；全排 → 提示重新选择
#   M6  无盘可清（仅 usb+光驱）：提示"仅发现启动介质"、退出、无 wipe.sh 调用
#   M7  清除后循环：再次列出（盘已清后状态刷新：sda 由系统盘变为数据盘）
#   M8  输入 0 退出：打印"可断电/重启"提示、退出 0
set -u
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
trap 'rc=$?; cleanup_case; exit "$rc"' EXIT

MENU_SH="$REPO_ROOT/diskwipe-iso/src/menu.sh"

echo "==== T2 交互菜单测试 ===="

# 运行 menu.sh：stdin 用管道喂入（模拟交互），假件经接缝变量注入；
# 退出码取管道右端（bash 测试可用 PIPESTATUS）
run_menu() {
    local input="$1" outf="$2"
    printf '%s\n' "$input" | PATH="$FAKE_BIN:$PATH" \
        LSBLK_BIN=lsblk BLKID_BIN=blkid WIPEFS_BIN=wipefs UMOUNT_BIN=umount \
        bash "$MENU_SH" > "$outf" 2>&1
    LAST_RC=${PIPESTATUS[1]}
    return 0
}

setup_case() { setup_tmp; install_fakes; }

# 标准双盘 + 启动 U 盘（sda 带 EFI 分区 → 系统盘；sdb 无分区 → 数据盘；sdc usb 排除）
std_table() {
    cat > "$ROOT/lsblk.table" <<'EOF'
NAME SIZE TYPE MODEL TRAN MOUNTPOINT
sda 894G disk HGST 7K6000 sata
sda1 512M part HGST 7K6000 sata /boot/efi
sdb 894G disk Samsung PM983 nvme
sdc 30G disk USB DISK 3.0 usb
EOF
    add_blk_type sda1 vfat
    add_ptname sda1 "EFI System"
}

# 断言：输出中某一行同时含 A 与 B（如 /dev/sda 与 系统盘 在同一行）
check_line_both() {
    local a="$1" b="$2" desc="$3"
    if grep -F -- "$a" "$OUTF" | grep -Fq -- "$b"; then
        _pass "$desc"
    else
        _fail "$desc（无同时含 "$a" 与 "$b" 的行）"
    fi
}

# 断言：输出中匹配文本的行数为 n
check_count() {
    local text="$1" want="$2" desc="$3" n
    n=$(grep -Fc -- "$text" "$OUTF" 2>/dev/null || true)
    [ -n "$n" ] || n=0
    if [ "$n" -eq "$want" ]; then
        _pass "$desc"
    else
        _fail "$desc（实际 $n 行，期望 $want 行）"
    fi
}

# ---------- M1：列盘与类型标注 ----------
CASE="M1 列盘与类型标注"
setup_case
std_table
run_menu '0' "$OUTF"
check_rc 0 '输入 0 应正常退出 0'
check_line_both '/dev/sda' '系统盘' 'sda 应标注"系统盘"'
check_line_both '/dev/sdb' '数据盘' 'sdb 应标注"数据盘"'
check_out '/dev/sda  894G   HGST 7K6000 (SATA)  系统盘' 'sda 行格式（编号/设备/容量/型号/类型）正确'
check_not_out 'sdc' 'usb 盘 sdc 不得出现在列表中'
check_not_out 'sr0' '不得出现光驱'
cleanup_case

# ---------- M2：回车默认全选 + YES 执行 ----------
CASE="M2 回车默认全选并 YES 执行"
setup_case
std_table
run_menu $'\nYES\n0\n' "$OUTF"
check_rc 0 '结束后应退出 0'
check_out '将清除以下 2 块硬盘' '默认全选应输出 2 盘确认清单'
check_cmds 'umount /boot/efi' '应先卸载 sda1 挂载点'
check_cmds 'wipefs -a /dev/sda' '应调用 wipe.sh 清除 sda'
check_cmds 'wipefs -a /dev/sdb' '应调用 wipe.sh 清除 sdb'
check_cmds 'wipefs -n /dev/sda' '应验证 sda'
check_out '✓ 已恢复未初始化：/dev/sda' 'sda 应显示清除成功'
check_out '✓ 已恢复未初始化：/dev/sdb' 'sdb 应显示清除成功'
check_out '可断电' '0 退出应打印可断电/重启提示'
cleanup_case

# ---------- M3：排除编号 1 后只清 sdb ----------
CASE="M3 排除编号后只清其余盘"
setup_case
std_table
run_menu $'1\nYES\n0\n' "$OUTF"
check_rc 0 '应正常退出 0'
check_out '将清除以下 1 块硬盘' '排除后确认清单应为 1 盘'
check_cmds 'wipefs -a /dev/sdb' '应清除 sdb'
check_not_cmds 'wipefs -a /dev/sda' '不得清除被排除的 sda'
check_not_cmds 'umount' '被排除盘的挂载点不得卸载'
check_out '✓ 已恢复未初始化：/dev/sdb' 'sdb 应显示清除成功'
cleanup_case

# ---------- M4：非 YES 输入不执行清除 ----------
CASE="M4 非 YES 输入不执行清除"
for ans in y no ''; do
    setup_case
    std_table
    run_menu $'\n'"$ans"$'\n0\n' "$OUTF"
    check_rc 0 '非 YES 应回到菜单并 0 退出'
    check_out '已取消' '非 YES 应提示已取消'
    check_count '硬盘清理工具' 2 '非 YES 应回到菜单再次列出'
    check_no_cmds '非 YES 不得执行任何清除命令'
    cleanup_case
done

# ---------- M5：排除列表含非法项 ----------
CASE="M5 排除列表忽略非法项"
setup_case
cat > "$ROOT/lsblk.table" <<'EOF'
NAME SIZE TYPE MODEL TRAN MOUNTPOINT
sda 894G disk HGST 7K6000 sata
sdb 894G disk Samsung PM983 nvme
sdc 30G disk USB DISK 3.0 usb
sdd 1T disk WDC WD1002FAEX sata
EOF
run_menu $'1,2,x\nYES\n0\n' "$OUTF"
check_rc 0 '应正常退出 0'
check_out '将清除以下 1 块硬盘' '忽略 x、排除 1 和 2 后应只清 1 盘'
check_cmds 'wipefs -a /dev/sdd' '应清除 sdd'
check_not_cmds 'wipefs -a /dev/sda' 'sda 不得被清除'
check_not_cmds 'wipefs -a /dev/sdb' 'sdb 不得被清除'
cleanup_case

# 全部排除 → 提示重新选择，不执行
setup_case
cat > "$ROOT/lsblk.table" <<'EOF'
NAME SIZE TYPE MODEL TRAN MOUNTPOINT
sda 894G disk HGST 7K6000 sata
sdb 894G disk Samsung PM983 nvme
EOF
run_menu $'1,2\n0\n' "$OUTF"
check_rc 0 '应正常退出 0'
check_out '未选择任何硬盘' '全排应提示重新选择'
check_no_cmds '全排不得执行清除'
cleanup_case

# ---------- M6：仅 usb+光驱 ----------
CASE="M6 仅启动介质"
setup_case
cat > "$ROOT/lsblk.table" <<'EOF'
NAME SIZE TYPE MODEL TRAN MOUNTPOINT
sdc 30G disk USB DISK 3.0 usb
sr0 1024M rom
EOF
run_menu '0' "$OUTF"
check_rc 0 '应退出 0'
check_out '仅发现启动介质' '应提示仅发现启动介质'
check_no_cmds '不得执行任何清除命令'
cleanup_case

# ---------- M7：清除后循环，列表刷新 ----------
CASE="M7 清除后循环刷新"
setup_case
std_table
# 覆写假 lsblk：已清除盘（cmds.txt 已记录 wipefs -a）的分区行不再出现 →
# 盘已清后状态刷新（sda1 消失 → sda 由系统盘变为数据盘）
cat > "$FAKE_BIN/lsblk" <<'FAKE'
#!/bin/sh
[ -n "$ROOT" ] || exit 0
wiped=""
if [ -f "$ROOT/cmds.txt" ]; then
    wiped=$(awk '/^wipefs -a \/dev\//{ sub(/^wipefs -a \/dev\//, ""); list=list " " $0 } END { print list }' "$ROOT/cmds.txt")
fi
case "$1" in
-o)
    case "$2" in
    NAME,SIZE,TYPE,MODEL,TRAN,MOUNTPOINT)
        [ -f "$ROOT/lsblk.table" ] || exit 0
        awk -v w="$wiped" 'NR==1{print;next}
            $3=="part"{
                pk=$1
                if (pk ~ /p[0-9]+$/) sub(/p[0-9]+$/, "", pk)
                else while (pk ~ /[0-9]$/) pk=substr(pk,1,length(pk)-1)
                if ((" " w " ") ~ (" " pk " ")) next
            }
            { print }' "$ROOT/lsblk.table"
        ;;
    NAME,TYPE,MOUNTPOINT,PKNAME)
        dev="${3#/dev/}"
        [ -f "$ROOT/lsblk.table" ] || exit 0
        awk -v d="$dev" -v w="$wiped" 'NR==1{next}{
            name=$1; type=$3
            mps=""
            for (i=4; i<=NF; i++) {
                if ($i ~ /^\//) { mps=$i; for (j=i+1; j<=NF; j++) mps=mps " " $j; break }
            }
            pk=""
            if (name != d) {
                pk=name
                if (pk ~ /p[0-9]+$/) sub(/p[0-9]+$/, "", pk)
                else while (pk ~ /[0-9]$/) pk=substr(pk,1,length(pk)-1)
            }
            if (type=="part" && ((" " w " ") ~ (" " pk " "))) next
            if (name==d || pk==d) printf "%s %s %s %s\n", name, type, mps, pk
        }' "$ROOT/lsblk.table"
        ;;
    esac
    ;;
-no)
    case "$2" in
    PARTFLAGS)
        dev="${3#/dev/}"
        [ -f "$ROOT/lsblk.flags" ] || exit 0
        awk -v d="$dev" '$1==d { print $2 }' "$ROOT/lsblk.flags"
        ;;
    PARTTYPENAME)
        dev="${3#/dev/}"
        [ -f "$ROOT/lsblk.ptname" ] || exit 0
        awk -v d="$dev" '$1==d { $1=""; sub(/^ /, ""); print }' "$ROOT/lsblk.ptname"
        ;;
    esac
    ;;
esac
exit 0
FAKE
chmod +x "$FAKE_BIN/lsblk"
run_menu $'\nYES\n0\n' "$OUTF"
check_rc 0 '应正常退出 0'
check_cmds 'wipefs -a /dev/sda' '首轮应清除 sda'
check_cmds 'wipefs -a /dev/sdb' '首轮应清除 sdb'
check_count '硬盘清理工具' 2 '清除后应回到菜单再次列出（两轮菜单）'
check_count '系统盘' 1 '仅首轮 sda 标系统盘'
check_count '数据盘' 3 '首轮 sdb + 次轮 sda/sdb 均标数据盘（盘已清状态刷新）'
check_out '可断电' '0 退出应打印可断电/重启提示'
cleanup_case

# ---------- M8：输入 0 退出 ----------
CASE="M8 输入 0 退出"
setup_case
std_table
run_menu '0' "$OUTF"
check_rc 0 '应退出 0'
check_out '可断电' '应打印可断电/重启提示'
check_no_cmds '0 退出不得执行清除'
cleanup_case

finish
