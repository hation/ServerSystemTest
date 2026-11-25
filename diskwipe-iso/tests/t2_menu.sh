#!/bin/bash
# T2：diskwipe-iso 交互菜单假件单测
# 覆盖：src/menu.sh 的列盘（编号/设备/容量/型号/类型）、默认全选、排除编号、
#      大写 YES 二次确认、清除后循环刷新、0 退出、仅启动介质退出。
# 运行：bash diskwipe-iso/tests/run-all.sh（或单独 bash diskwipe-iso/tests/t2_menu.sh）
# v1.5.11 适配：menu 的 `exec 0< /dev/tty0`（键盘/VT，真机 KVM USB 键盘输入通道）在
#   WSL 下 /dev/tty0 真实存在——直接运行会把 stdin 改到真实 tty0 并阻塞等待键盘。
#   run_menu 全部经非特权 mount namespace（unshare -mU --map-root-user，WSL2 支持）执行：
#   /dev 换成 tmpfs，按模式预置假设备——fallback（无 /dev/tty0 → 菜单回退读 stdin，喂入
#   文件，等价原管道喂入）与 tty0（假 /dev/tty0=普通文件=键盘输入流 → 菜单从 tty0 读取，
#   M11 用例验证 redirect 分支）；无 /dev/tty0 的环境（如 Git Bash）直接管道喂入（天然
#   fallback）。init usbhid 加载断言在 T3（I1 新增 modprobe usbhid）。
# 交互契约（必须满足）：读 stdin 写 stdout；大写 YES 严格匹配才执行；
#      非法输入忽略（1,2,x → 忽略 x）；排除列表为空 = 默认全选；
#      0 退出（打印 power off/reboot 提示）；无盘可清（仅 usb+光驱）→ 提示并自动重试
#      6 次、仍无盘则自动 reboot（v1.5.10：避免 sda 迟就绪误判 + 避免 exit 致 PID1 内核
#      panic；v1.5.11：重试 3 → 6——真机 SAS 盘就绪约需 25 秒；v1.5.12：reboot 改
#      reboot -f + fallthrough 保护（无效 → 打印提示 + continue 重新枚举，盘就绪则正常））；
#      清除后回到菜单（列表刷新）。
# v1.5.12 适配：枚举原文诊断行（RAW enum ml=[...] 走 kmsg，M10 xtrace 断言）；勾选兜底
#   （mdev 为空从 mtab 补设备名，M12 用例——lib.sh awk 枚举输出恒规范，标准假件无法注入
#   "设备字段空"枚举行，故 M12 直接构造勾选循环输入验证兜底片段）；M6 增加 reboot -f +
#   fallthrough 断言（假 lsblk 在 reboot -f 记录后返回盘 → 重新枚举列出 → 0 退出）。
# 用例：
#   M1  两盘 sda/sdb + sdc(usb)：列表含 sda/sdb 不含 sdc；sda 标 SYS、sdb 标 DATA
#   M2  回车（默认全选）→ YES：调用 wipe.sh 且含 sda sdb；输出确认清单
#   M3  输入 1 排除 → YES：只调用 wipe.sh sdb
#   M4  输入 YES 以外的值（y/no/空）：不执行清除、回到菜单；无 wipe.sh 调用
#   M5  排除输入 1,2,x：忽略 x，排除 1、2 合法项生效（只清 sdd）；全排 → 提示重新选择
#   M6  无盘可清（仅 usb+光驱）：提示"仅发现启动介质"、重试 6 轮（sleep 5）、仍无盘
#        sleep 10 后 reboot -f（v1.5.12：假 reboot 记录调用、绝不真重启测试机）；
#        reboot -f 无效 → fallthrough 保护（sleep 2 + 提示 + continue 重新枚举，
#        此时盘已就绪 → 正常列盘 → 0 退出）；无 wipe 调用
#   M7  清除后循环：再次列出（盘已清后状态刷新：sda 由系统盘变为数据盘）
#   M8  输入 0 退出：打印"可断电/重启"提示、退出 0
#   M9  TRAN 为空 + 型号含空格：型号完整显示、末词不误作 TRAN
set -u
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
trap 'rc=$?; cleanup_case; exit "$rc"' EXIT

MENU_SH="$REPO_ROOT/diskwipe-iso/src/menu.sh"

echo "==== T2 交互菜单测试 ===="

# 运行 menu.sh：输入经文件喂入（模拟交互），假件经接缝变量注入。
# v1.5.11：WSL 下 /dev/tty0 真实存在，menu 会 `exec 0< /dev/tty0` 并阻塞等键盘——测试
# 放入非特权 mount namespace（unshare -mU --map-root-user）：/dev 换成 tmpfs，按模式
# 预置假设备；menu 退出码取 unshare 返回值（即 menu 自身退出码）。
#   mode=fallback（默认）：/dev 无 tty0 → menu 回退读 stdin（喂入文件，等价原管道喂入）；
#   mode=tty0：/dev/tty0=普通文件（内容=输入流）→ menu 从 tty0 读取（redirect 分支）。
run_menu() {
    local input="$1" outf="$2"
    local mode="${3:-fallback}"
    if [ -e /dev/tty0 ]; then
        printf '%s\n' "$input" > "$ROOT/menu.feed"
        export ROOT FAKE_BIN MENU_SH
        local tty0arg=0
        [ "$mode" = tty0 ] && tty0arg=1
        unshare -mU --map-root-user bash -c '
            set -u
            mount -t tmpfs -o size=4m tmpfs /dev || exit 9
            : > /dev/null
            : > /dev/kmsg
            if [ "$1" = 1 ]; then cat "$2" > /dev/tty0; fi
            PATH="$FAKE_BIN:$PATH" LSBLK_BIN=lsblk BLKID_BIN=blkid WIPEFS_BIN=wipefs \
              UMOUNT_BIN=umount PARTPROBE_BIN=partprobe \
              bash "$MENU_SH" < "$2" > "$3" 2>&1
        ' _ "$tty0arg" "$ROOT/menu.feed" "$outf"
        LAST_RC=$?
        return 0
    fi
    # 无 /dev/tty0（如 Git Bash）：原管道喂入（fallback 语义天然成立）
    printf '%s\n' "$input" | PATH="$FAKE_BIN:$PATH" \
        LSBLK_BIN=lsblk BLKID_BIN=blkid WIPEFS_BIN=wipefs UMOUNT_BIN=umount \
        PARTPROBE_BIN=partprobe \
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
check_line_both '/dev/sda' 'SYS' 'sda 应标注 SYS（系统盘）'
check_line_both '/dev/sdb' 'DATA' 'sdb 应标注 DATA（数据盘）'
check_out '/dev/sda  894G   HGST 7K6000 (SATA)  SYS' 'sda 行格式（编号/设备/容量/型号/类型）正确'
check_not_out 'sdc' 'usb 盘 sdc 不得出现在列表中'
check_not_out 'sr0' '不得出现光驱'
cleanup_case

# ---------- M2：回车默认全选 + YES 执行 ----------
CASE="M2 回车默认全选并 YES 执行"
setup_case
std_table
run_menu $'\nYES\n0\n' "$OUTF"
check_rc 0 '结束后应退出 0'
check_out 'Will wipe the following 2 disks' '默认全选应输出 2 盘确认清单'
check_cmds 'umount /boot/efi' '应先卸载 sda1 挂载点'
check_cmds 'wipefs -a /dev/sda' '应调用 wipe.sh 清除 sda'
check_cmds 'wipefs -a /dev/sdb' '应调用 wipe.sh 清除 sdb'
check_cmds 'partprobe /dev/sda' 'sda 清除后应 partprobe'
check_cmds 'wipefs -n /dev/sda' '应验证 sda'
check_out 'OK /dev/sda reset to uninitialized' 'sda 应显示清除成功'
check_out 'OK /dev/sdb reset to uninitialized' 'sdb 应显示清除成功'
check_out 'power off' '0 退出应打印可断电/重启提示'
cleanup_case

# ---------- M3：排除编号 1 后只清 sdb ----------
CASE="M3 排除编号后只清其余盘"
setup_case
std_table
run_menu $'1\nYES\n0\n' "$OUTF"
check_rc 0 '应正常退出 0'
check_out 'Will wipe the following 1 disks' '排除后确认清单应为 1 盘'
check_cmds 'wipefs -a /dev/sdb' '应清除 sdb'
check_cmds 'partprobe /dev/sdb' 'sdb 清除后应 partprobe'
check_not_cmds 'wipefs -a /dev/sda' '不得清除被排除的 sda'
check_not_cmds 'umount' '被排除盘的挂载点不得卸载'
check_out 'OK /dev/sdb reset to uninitialized' 'sdb 应显示清除成功'
cleanup_case

# ---------- M4：非 YES 输入不执行清除 ----------
CASE="M4 非 YES 输入不执行清除"
for ans in y no ''; do
    setup_case
    std_table
    run_menu $'\n'"$ans"$'\n0\n' "$OUTF"
    check_rc 0 '非 YES 应回到菜单并 0 退出'
    check_out 'Cancelled' '非 YES 应提示已取消'
    check_count 'DiskWipe Tool' 2 '非 YES 应回到菜单再次列出'
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
check_out 'Will wipe the following 1 disks' '忽略 x、排除 1 和 2 后应只清 1 盘'
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
check_out 'No disks selected' '全排应提示重新选择'
check_no_cmds '全排不得执行清除'
cleanup_case

# ---------- M6：仅 usb+光驱（v1.5.10/1.5.11/1.5.12：重试 6 轮后 reboot -f + fallthrough） ----------
CASE="M6 仅启动介质（v1.5.12 重试 6 轮后 reboot -f + fallthrough）"
setup_case
cat > "$ROOT/lsblk.table" <<'EOF'
NAME SIZE TYPE MODEL TRAN MOUNTPOINT
sdc 30G disk USB DISK 3.0 usb
sr0 1024M rom
EOF
# v1.5.12：reboot -f 记录后（fallthrough continue 重新枚举）盘已就绪——模拟真机
# "reboot 无效、重新枚举后盘才列出"；此前仅 usb+光驱（无盘重试路径）
cat > "$ROOT/lsblk.ready" <<'EOF'
NAME SIZE TYPE MODEL TRAN MOUNTPOINT
sda 894G disk HGST 7K6000 sata
sdb 894G disk Samsung PM983 nvme
EOF
# 假 lsblk：reboot -f 已记录 → 输出就绪盘表；否则输出无盘表
cat > "$FAKE_BIN/lsblk" <<'FAKE'
#!/bin/sh
[ -n "$ROOT" ] || exit 0
if [ -f "$ROOT/cmds.txt" ] && grep -q '^reboot -f$' "$ROOT/cmds.txt"; then
    cat "$ROOT/lsblk.ready"
    exit 0
fi
cat "$ROOT/lsblk.table"
exit 0
FAKE
chmod +x "$FAKE_BIN/lsblk"
# v1.5.10 起：无盘路径不再 exit——假 reboot（记录调用参数、立即返回，绝不真重启测试机）
fake_bin reboot '#!/bin/sh
[ -n "$ROOT" ] || exit 0
printf "reboot %s\n" "$*" >> "$ROOT/cmds.txt"
exit 0'
# 假 sleep：无盘重试 6×5s + 最终 10s + fallthrough 2s 立即返回（不真等；记录调用供计数断言）
fake_bin sleep '#!/bin/sh
[ -n "$ROOT" ] || exit 0
printf "sleep %s\n" "$*" >> "$ROOT/cmds.txt"
exit 0'
run_menu '0' "$OUTF"
check_rc 0 '应退出 0（reboot -f 无效 → fallthrough 重枚举盘就绪 → 0 输入退出）'
check_out 'Only boot media found' '应提示仅发现启动介质（首轮重试消息）'
check_out 'No wipable disks found after 6 retries' '6 轮重试后应打印最终提示'
check_cmd_count 'sleep 5' 6 '应重试 6 轮（每轮 sleep 5）'
check_cmd_count 'sleep 10' 1 '仍无盘应等待 10s 后 reboot -f'
check_cmds 'reboot -f' '仍无盘应 reboot -f（v1.5.12 强制重启，不依赖 init 守护）'
check_cmd_count 'sleep 2' 1 'reboot -f 后应 sleep 2（fallthrough 保护等待；"reboot ineffective"提示行走 kmsg——真机 KVM 屏幕可见，qemu B 断言）'
check_out '/dev/sda' 'fallthrough → continue 重新枚举后盘已就绪 → 正常列盘（不再假盘行 Disks found: 1 ()）'
check_count 'DiskWipe Tool' 1 '仅就绪后列盘一次（无盘轮次不列盘）'
check_out 'power off' '0 退出应打印可断电/重启提示'
check_not_cmds 'wipefs' '无盘重试不得执行清除命令'
check_not_cmds 'umount' '无盘重试不得执行卸载命令'
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
        # 真实 lsblk 恒有表头（lib.sh 的 NR==1 跳过），此处同样先输出表头
        awk -v d="$dev" -v w="$wiped" 'BEGIN { print "NAME TYPE MOUNTPOINT PKNAME" }
            NR==1{next}{
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
    NAME,TYPE,MOUNTPOINT,PKNAME,PARTTYPENAME,PARTFLAGS)
        [ -f "$ROOT/lsblk.table" ] || exit 0
        # 批量类型探测表（同 install_fakes 形态，叠加已清盘分区过滤：盘已清后 sda1 消失 → sda 变数据盘）
        awk -v w="$wiped" -v ptf="$ROOT/lsblk.ptname" -v flf="$ROOT/lsblk.flags" 'BEGIN {
                print "NAME TYPE MOUNTPOINT PKNAME PARTTYPENAME PARTFLAGS"
                if (ptf != "") while ((getline l < ptf) > 0) { split(l, a, " "); pt[a[1]] = substr(l, index(l, " ") + 1) }
                if (flf != "") while ((getline l < flf) > 0) { split(l, a, " "); fl[a[1]] = a[2] }
            }
            NR==1{next}
            $3=="part"{
                pk=$1
                if (pk ~ /p[0-9]+$/) sub(/p[0-9]+$/, "", pk)
                else while (pk ~ /[0-9]$/) pk=substr(pk,1,length(pk)-1)
                if ((" " w " ") ~ (" " pk " ")) next
            }
            {
                name=$1; type=$3
                mps=""
                for (i=4; i<=NF; i++) { if ($i ~ /^\//) { mps=$i; for (j=i+1; j<=NF; j++) mps=mps " " $j; break } }
                pk=""
                if (type != "disk") {
                    pk=name
                    if (pk ~ /p[0-9]+$/) sub(/p[0-9]+$/, "", pk)
                    else while (pk ~ /[0-9]$/) pk=substr(pk,1,length(pk)-1)
                }
                printf "%s %s %s %s %s %s\n", name, type, mps, pk, pt[name], fl[name]
            }' "$ROOT/lsblk.table"
        ;;
    NAME,TYPE,TRAN,PKNAME)
        [ -f "$ROOT/lsblk.table" ] || exit 0
        # 批量探测的 TRAN 过滤（v1.3.3：blkid 只带非 USB 盘作参数）；同 install_fakes 形态
        awk 'BEGIN { print "NAME TYPE TRAN PKNAME" }
            FNR==1 { next }
            {
                name=$1; type=$3
                tran=""; t=NF
                if ($NF ~ /^\//) t=NF-1
                if (type == "disk" && t > 3 && $t ~ /^(sata|sas|nvme|usb|spi|ata|scsi|virtio|pcie)$/) tran=$t
                pk=""
                if (type != "disk") {
                    pk=name
                    if (pk ~ /p[0-9]+$/) sub(/p[0-9]+$/, "", pk)
                    else while (pk ~ /[0-9]$/) pk=substr(pk,1,length(pk)-1)
                }
                print name, type, tran, pk
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
check_count 'DiskWipe Tool' 2 '清除后应回到菜单再次列出（两轮菜单）'
check_count 'SYS' 1 '仅首轮 sda 标 SYS'
check_count 'DATA' 3 '首轮 sdb + 次轮 sda/sdb 均标 DATA（盘已清状态刷新）'
check_out 'power off' '0 退出应打印可断电/重启提示'
cleanup_case

# ---------- M8：输入 0 退出 ----------
CASE="M8 输入 0 退出"
setup_case
std_table
run_menu '0' "$OUTF"
check_rc 0 '应退出 0'
check_out 'power off' '应打印可断电/重启提示'
check_no_cmds '0 退出不得执行清除'
cleanup_case

# ---------- M9：TRAN 为空 + 型号含空格（末词不得误作 TRAN） ----------
CASE="M9 TRAN 空型号含空格显示正确"
setup_case
cat > "$ROOT/lsblk.table" <<'EOF'
NAME SIZE TYPE MODEL TRAN MOUNTPOINT
sda 894G disk HGST 7K6000  /mnt/data
EOF
run_menu '0' "$OUTF"
check_rc 0 '应正常退出 0'
check_out '/dev/sda  894G   HGST 7K6000  DATA' 'TRAN 为空时型号应完整显示（HGST 7K6000 不截断）'
check_not_out '(7K6000)' '不得把型号末词 7K6000 误作 TRAN 显示'
check_not_out '7K6000 (7K6000)' '不得出现 TRAN 占位误判'
check_no_cmds '仅列盘不得执行清除'
cleanup_case

# ---------- M10：界面 kmsg 双通道（v1.5.8：argv0 诊断 + 关键界面行镜像） ----------
# 真机 /dev/console（tty0）输出不可见时 kmsg 通道保证屏幕可读可操作；本机 /dev/kmsg
# 写失败静默（WSL 非特权下同样如此），用 `bash -x` + BASH_XTRACEFD=3 分流 xtrace 正向
# 断言 kmsg 载荷（`+ echo 'diskwipe-init: ...' > /dev/kmsg` 行即 dw_progress/直接 echo 的
# kmsg 镜像）；stdout（$OUTF）保持纯 console 输出。v1.5.11：同样放入 mount namespace
# （fallback 模式，/dev 无 tty0，输入经文件喂入）。
CASE="M10 界面 kmsg 双通道"
setup_case
std_table
printf '%s\n' '0' > "$ROOT/menu.feed"
export ROOT FAKE_BIN MENU_SH OUTF
unshare -mU --map-root-user bash -c '
    set -u
    mount -t tmpfs -o size=4m tmpfs /dev || exit 9
    : > /dev/null
    : > /dev/kmsg
    PATH="$FAKE_BIN:$PATH" \
    LSBLK_BIN=lsblk BLKID_BIN=blkid WIPEFS_BIN=wipefs UMOUNT_BIN=umount \
    PARTPROBE_BIN=partprobe \
    BASH_XTRACEFD=3 \
    bash -x "$MENU_SH" 3> "$ROOT/xtrace.txt" > "$OUTF" 2>&1 < "$ROOT/menu.feed"
'
LAST_RC=$?
check_rc 0 '输入 0 应正常退出 0'
check_out 'power off' '屏幕输出不受镜像影响（0 退出提示仍在）'
check_file "$ROOT/xtrace.txt" 'diskwipe-init: menu.sh argv0=' '头部 argv0 kmsg 诊断（exec 后立即打点，不依赖 lib.sh）'
check_file "$ROOT/xtrace.txt" 'diskwipe-init: RAW enum ml=[' 'RAW enum 枚举原文诊断行（v1.5.12，kmsg 载荷——真机定位设备名空根因）'
check_file "$ROOT/xtrace.txt" 'diskwipe-init: > ' '输入提示 >  的 kmsg 镜像'
check_file "$ROOT/xtrace.txt" 'diskwipe-init:   Default: all selected' '排除输入提示行 kmsg 镜像'
check_file "$ROOT/xtrace.txt" '/dev/sda  894G   HGST 7K6000 (SATA)  SYS' '盘列表行 kmsg 镜像（行内容与屏幕一致）'
check_file "$ROOT/xtrace.txt" 'diskwipe-init: Exited. You may power off' 'Exited. 行 kmsg 镜像'
cleanup_case

# ---------- M11：v1.5.11 /dev/tty0 stdin 重定向（假 tty0 存在 → 键盘输入流） ----------
# 真机 /dev/console 输入默认映射到最后一个 console（console=tty0 console=ttyS0 → ttyS0
# 串口）致 KVM USB 键盘无效；menu v1.5.11 在 while 前 `exec 0< /dev/tty0`（键盘/VT）。
# 本用例在 mount namespace 中用普通文件充当 /dev/tty0（内容=输入流），菜单 stdin 接
# /dev/null——若 menu 未重定向（回退 stdin），读 /dev/null 立即 EOF、输出
# "Input ended, exiting" 且无清除；断言正常交互输出与清除调用 → 输入确实来自 /dev/tty0。
CASE="M11 /dev/tty0 stdin 重定向（v1.5.11 键盘输入流）"
setup_case
std_table
printf '%s\n' $'\nYES\n0\n' > "$ROOT/menu.feed"
export ROOT FAKE_BIN MENU_SH OUTF
unshare -mU --map-root-user bash -c '
    set -u
    mount -t tmpfs -o size=4m tmpfs /dev || exit 9
    : > /dev/null
    : > /dev/kmsg
    cat "$ROOT/menu.feed" > /dev/tty0
    PATH="$FAKE_BIN:$PATH" LSBLK_BIN=lsblk BLKID_BIN=blkid WIPEFS_BIN=wipefs \
      UMOUNT_BIN=umount PARTPROBE_BIN=partprobe \
      bash "$MENU_SH" < /dev/null > "$OUTF" 2>&1
'
LAST_RC=$?
check_rc 0 'tty0 输入流驱动完整流程后应退出 0'
check_out 'Will wipe the following 2 disks' '输入来自 /dev/tty0（若回退 stdin（/dev/null）则 EOF 直接退出，无此输出）'
check_cmds 'wipefs -a /dev/sda' '应调用 wipe.sh 清除 sda（tty0 键盘输入流生效）'
check_cmds 'wipefs -a /dev/sdb' '应调用 wipe.sh 清除 sdb'
check_out 'OK /dev/sda reset to uninitialized' 'sda 应显示清除成功'
check_out 'power off' '0 退出应打印可断电/重启提示'
cleanup_case

# ---------- M12：v1.5.12 勾选设备名兜底（枚举行设备字段空 → mtab 补设备名） ----------
# 真机 v1.5.11：「Disks found: 1 () + 盘列表 /dev/ 空 + 回车全选 → No disks selected」。
# 兜底：勾选循环 ${mline%% *} 提取 mdev 为空时，从格式化行（mtab 第 mi 行 | 分隔首字段）
# 补设备名（格式化经 awk 字段切分，对前导空白等异常更鲁棒）。注：lib.sh 的 awk 枚举输出
# 恒规范（首 token 非空、经白名单校验），标准假 lsblk 无法注入"设备字段空"的枚举行——
# 本用例直接构造勾选循环输入（ml 含前导空格异常行 + 对应 mtab），按 menu.sh 内同款片段
# 验证兜底生效；并对照无兜底提取（复现真机 No disks selected 根因）。
CASE="M12 勾选设备名兜底（mtab 补设备名）"
setup_case
std_table
# 模拟真机枚举行格式异常：ml 行前导空格 → ${mline%% *} 提取为空；mtab 对应行设备字段正常
ml=" sda 894G HGST 7K6000 sata "
mtab="sda|894G|HGST 7K6000|SATA|0"
# 与 menu.sh 勾选循环一致的提取 + 兜底片段（无排除 → 全选）
msel=""
mcnt=0
mi=0
while IFS= read -r mline; do
    [ -n "$mline" ] || continue
    mi=$((mi + 1))
    case " " in
    *" $mi "*) continue ;;
    esac
    mdev="${mline%% *}"
    if [ -z "$mdev" ]; then
        mtabline="$(printf '%s\n' "$mtab" | sed -n "${mi}p")"
        mdev="${mtabline%%|*}"
    fi
    msel="${msel:+$msel }$mdev"
    mcnt=$((mcnt + 1))
done <<EOF
$ml
EOF
if [ "$msel" = "sda" ] && [ "$mcnt" -eq 1 ]; then
    _pass '枚举行设备字段空时勾选清单从 mtab 补设备名（msel=sda）'
else
    _fail "兜底未生效（msel=$msel mcnt=$mcnt）"
fi
# 对照：无兜底时 ${mline%% *} 提取为空 → 选中清单空（真机 No disks selected 根因复现）
msel=""
mi=0
while IFS= read -r mline; do
    [ -n "$mline" ] || continue
    mi=$((mi + 1))
    mdev="${mline%% *}"
    msel="${msel:+$msel }$mdev"
done <<EOF
$ml
EOF
if [ -z "$msel" ]; then
    _pass '无兜底时提取为空 → 全选清单空（真机 No disks selected 根因复现）'
else
    _fail "对照异常（msel=$msel）"
fi
cleanup_case

finish
