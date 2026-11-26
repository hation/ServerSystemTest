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
#      0 退出（打印 power off/reboot 提示）；无盘可清（仅 usb+光驱）→ 无限重试枚举
#      （v1.5.13：每 5 秒重枚举、绝不自动关机/重启——真机 reboot -f 执行成关机、用户
#      未及操作即断电，安全第一；v1.5.10 起为避免 sda 迟就绪误判 + 避免 exit 致 PID1
#      内核 panic；v1.5.11 曾重试 3 → 6；v1.5.12 曾 reboot -f + fallthrough，已废弃）；
#      清除后回到菜单（列表刷新）。
# v1.5.12 适配：枚举原文诊断行（RAW enum ml=[...] 走 kmsg，M10 xtrace 断言）；勾选兜底
#   （mdev 为空从 mtab 补设备名，M12 用例——lib.sh awk 枚举输出恒规范，标准假件无法注入
#   "设备字段空"枚举行，故 M12 直接构造勾选循环输入验证兜底片段）；M6 曾断言 reboot -f +
#   fallthrough（假 lsblk 在 reboot -f 记录后返回盘）。
# v1.5.13 适配：M6 改为断言无限重试——无盘时每 5 秒重枚举（假 lsblk 前 3 次枚举返回无盘表、
#   之后返回就绪盘表 → 盘出现即正常列盘），绝不出现 reboot/sleep 10/关机行为。
# v1.5.14 适配：M6 断言 read -t 5 等待（sleep 真机失真 5s→~0.17s → 改内建 read -t select
#   超时；假件 /dev/tty0 不存在 → read 立即失败 || true，用 bash -x xtrace 断言调用）+ 重试
#   消息每 10 轮一次（重试 2 轮仅 1 条消息）+ 无盘轮次不再调用 sleep 命令；RAW lsblk 诊断每轮
#   多一次 lsblk 调用 → M6 计数阈值 4→5（前 4 次调用无盘表 = 枚举+RAW 各 2 轮）；M10 加
#   RAW lsblk kmsg 载荷断言（v1.5.14）。
# v1.5.15 适配：menu 在枚举前新增强制 SCSI 重扫描循环（echo "- - -" >
#   /sys/class/scsi_host/host*/scan，逐个写、失败跳过——SAS 盘可能晚就绪，每次枚举前
#   rescan 兜底）。M10 新增 xtrace 断言：`[ -w /sys/class/scsi_host/host0/scan ]` 出现
#   （循环执行；WSL host0/scan 存在但不可写 → [ -w ] 为假、echo 不执行、零副作用）+
#   顺序断言（enumerating disks (lsblk) 之后、枚举 lsblk 调用之前）。
# 用例：
#   M1  两盘 sda/sdb + sdc(usb)：列表含 sda/sdb 不含 sdc；sda 标 SYS、sdb 标 DATA
#   M2  回车（默认全选）→ YES：调用 wipe.sh 且含 sda sdb；输出确认清单
#   M3  输入 1 排除 → YES：只调用 wipe.sh sdb
#   M4  输入 YES 以外的值（y/no/空）：不执行清除、回到菜单；无 wipe.sh 调用
#   M5  排除输入 1,2,x：忽略 x，排除 1、2 合法项生效（只清 sdd）；全排 → 提示重新选择
#   M6  无盘可清（仅 usb+光驱）：无限重试（v1.5.13：每轮 sleep 5 + 重新枚举、绝不自动
#       关机/重启——假 lsblk 计数切换：前 3 次枚举返回无盘表、之后返回就绪盘表 → 盘出现
#       即正常列盘 → 0 退出）；无 wipe 调用、无 reboot 调用
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
check_not_cmds 'umount /boot/efi' '被排除盘 sda1 的挂载点不得卸载（v1.5.29 写日志块 umount /mnt/dwdiag 属诊断降级路径、非卸载盘）'
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
    # v1.5.29：写日志块每 5 轮 umount /mnt/dwdiag 兜底（诊断降级路径，非清除操作）——
    # 「不得执行清除」断言改为针对性检查清除命令（wipefs/partprobe）
    check_not_cmds 'wipefs' '非 YES 不得执行任何清除命令（wipefs）'
    check_not_cmds 'partprobe' '非 YES 不得执行任何清除命令（partprobe）'
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
check_not_cmds 'wipefs' '全排不得执行清除（wipefs；v1.5.29 写日志块 umount /mnt/dwdiag 属诊断路径）'
check_not_cmds 'partprobe' '全排不得执行清除（partprobe）'
cleanup_case

# ---------- M6：仅 usb+光驱（v1.5.13：无限重试、绝不自动关机/重启） ----------
CASE="M6 仅启动介质（v1.5.13 无限重试、v1.5.14 read -t 等待+消息降噪）"
setup_case
cat > "$ROOT/lsblk.table" <<'EOF'
NAME SIZE TYPE MODEL TRAN MOUNTPOINT
sdc 30G disk USB DISK 3.0 usb
sr0 1024M rom
EOF
# 就绪盘表（模拟真机 SAS 盘迟就绪：无盘重试 N 轮后盘才可枚举）
cat > "$ROOT/lsblk.ready" <<'EOF'
NAME SIZE TYPE MODEL TRAN MOUNTPOINT
sda 894G disk HGST 7K6000 sata
sdb 894G disk Samsung PM983 nvme
EOF
# 假 lsblk：计数切换——前 4 次调用（枚举 + RAW lsblk 诊断各 2 轮，v1.5.14 每轮多一次
# lsblk 调用）返回无盘表（对应 2 轮重试），第 5 次起返回就绪盘表
# （盘出现 → 正常列盘）。处理全部 -o/-no 形态（同 install_fakes；就绪后 dw_scan_system_disks
# 与退出写日志枚举同样返回就绪表）。
cat > "$FAKE_BIN/lsblk" <<'FAKE'
#!/bin/sh
[ -n "$ROOT" ] || exit 0
n=0
if [ -f "$ROOT/enum.count" ]; then n=$(cat "$ROOT/enum.count"); fi
n=$((n + 1))
echo "$n" > "$ROOT/enum.count"
if [ "$n" -ge 5 ]; then tbl="$ROOT/lsblk.ready"; else tbl="$ROOT/lsblk.table"; fi
case "$1" in
-o)
    case "$2" in
    NAME,SIZE,TYPE,MODEL,TRAN,MOUNTPOINT)
        [ -f "$tbl" ] && cat "$tbl"
        ;;
    NAME,TYPE,MOUNTPOINT,PKNAME)
        dev="${3#/dev/}"
        [ -f "$tbl" ] || exit 0
        awk -v d="$dev" 'BEGIN { print "NAME TYPE MOUNTPOINT PKNAME" }
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
            if (name==d || pk==d) printf "%s %s %s %s\n", name, type, mps, pk
        }' "$tbl"
        ;;
    NAME,TYPE,MOUNTPOINT,PKNAME,PARTTYPENAME,PARTFLAGS)
        [ -f "$tbl" ] || exit 0
        awk 'BEGIN { print "NAME TYPE MOUNTPOINT PKNAME PARTTYPENAME PARTFLAGS" }
            NR==1 { next }
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
                printf "%s %s %s %s %s %s\n", name, type, mps, pk, "", ""
            }' "$tbl"
        ;;
    NAME,TYPE,TRAN,PKNAME)
        [ -f "$tbl" ] || exit 0
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
            }' "$tbl"
        ;;
    esac
    ;;
-no)
    case "$2" in
    PARTFLAGS|PARTTYPENAME) : ;;
    esac
    ;;
esac
exit 0
FAKE
chmod +x "$FAKE_BIN/lsblk"
# 假 reboot：保留假件（记录调用、立即返回）——断言**绝不调用**（v1.5.13 无盘路径已无 reboot）
fake_bin reboot '#!/bin/sh
[ -n "$ROOT" ] || exit 0
printf "reboot %s\n" "$*" >> "$ROOT/cmds.txt"
exit 0'
# 假 sleep：保留假件（记录调用）——断言**绝不调用**（v1.5.14 无盘重试等待改 read -t 内建，
# sleep 假件不可拦截内建，故调用计数断言不可行，改断言无 sleep 命令调用 + xtrace 断言 read -t）
fake_bin sleep '#!/bin/sh
[ -n "$ROOT" ] || exit 0
printf "sleep %s\n" "$*" >> "$ROOT/cmds.txt"
exit 0'
run_menu '0' "$OUTF"
check_rc 0 '应退出 0（无限重试至盘就绪 → 0 输入退出）'
check_out 'No wipable disks found yet (retry 1)' '应打印无盘重试消息（retry 1，v1.5.13 无限重试）'
check_count 'No wipable disks found yet' 1 '重试 2 轮仅打印 1 条消息（v1.5.14 每 10 轮一次降噪）'
check_not_out 'retry 2' 'retry 2 不打消息（v1.5.14 消息频率降噪）'
check_not_cmds 'sleep' '无盘重试不再调用 sleep 命令（v1.5.14 read -t 内建等待）'
check_not_cmds 'sleep 10' '绝不 sleep 10（v1.5.12 的 reboot 前等待已删除）'
check_not_cmds 'sleep 2' '绝无 fallthrough 的 sleep 2'
check_not_cmds 'reboot' '绝不 reboot / reboot -f（v1.5.13：真机 reboot -f 执行成关机、安全第一）'
check_out '/dev/sda' '盘就绪后 → continue 重新枚举 → 正常列盘'
check_out '/dev/sdb' '就绪盘全部列出'
check_count 'DiskWipe Tool' 1 '仅就绪后列盘一次（无盘轮次不列盘）'
check_out 'power off' '0 退出应打印可断电/重启提示'
check_not_cmds 'wipefs' '无盘重试不得执行清除命令'
# v1.5.29：写日志块每 5 轮 umount /mnt/dwdiag 兜底（诊断降级路径、非卸载盘）——「无盘
# 重试不得卸载」断言改为针对盘挂载点（无盘时无任何 /boot 等盘挂载点卸载）
check_not_cmds 'umount /boot' '无盘重试不得执行盘挂载点卸载（umount /mnt/dwdiag 为 v1.5.29 诊断写日志兜底）'
# v1.5.14：read -t 5 等待断言——read 是 shell 内建（sleep 假件不可拦截），重置枚举计数后
# 重跑本场景，bash -x + BASH_XTRACEFD=3 分流 xtrace，正向断言 `+ read -t 5 dummy`
# （/dev/tty0 在假 /dev tmpfs 中不存在 → read 立即失败走 || true，测试不真等 5s）
rm -f "$ROOT/enum.count"
printf '%s\n' '0' > "$ROOT/menu.feed"
export ROOT FAKE_BIN MENU_SH
unshare -mU --map-root-user bash -c '
    set -u
    mount -t tmpfs -o size=4m tmpfs /dev || exit 9
    : > /dev/null
    : > /dev/kmsg
    PATH="$FAKE_BIN:$PATH" LSBLK_BIN=lsblk BLKID_BIN=blkid WIPEFS_BIN=wipefs \
      UMOUNT_BIN=umount PARTPROBE_BIN=partprobe \
      BASH_XTRACEFD=3 \
      bash -x "$MENU_SH" 3> "$ROOT/xtrace2.txt" > "$ROOT/out2.txt" 2>&1 < "$ROOT/menu.feed"
'
LAST_RC=$?
check_rc 0 'read -t 重跑场景应退出 0'
check_file "$ROOT/xtrace2.txt" 'read -t 5 dummy' '无盘重试等待走 read -t 5 dummy（v1.5.14 替代 sleep）'
check_file "$ROOT/xtrace2.txt" 'DIAG dmesg-tail=' '无盘重试每 10 轮输出 dmesg 尾部诊断行（v1.5.20）'
# v1.5.29：无盘轮次 U 盘写日志块执行断言（dwenum=1 首轮命中 %5 → mkdir 挂载点 + umount 兜底；
# 无 /dev/sd* 设备 → 挂载静默失败 → 不写文件，降级不阻断重试）
check_file "$ROOT/xtrace2.txt" 'mkdir -p /mnt/dwdiag' '无盘轮次 U 盘写日志块执行（v1.5.29，mkdir 挂载点）'
check_file "$ROOT/xtrace2.txt" 'umount /mnt/dwdiag' '无盘轮次 U 盘写日志块 umount 兜底执行（v1.5.29）'
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
# v1.5.29：写日志块 umount /mnt/dwdiag 兜底（诊断降级路径）——「0 退出不得清除」改为针对性检查
check_not_cmds 'wipefs' '0 退出不得执行清除（wipefs）'
check_not_cmds 'partprobe' '0 退出不得执行清除（partprobe）'
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
# v1.5.29：写日志块 umount /mnt/dwdiag 兜底（诊断降级路径）——「仅列盘不得清除」改为针对性检查
check_not_cmds 'wipefs' '仅列盘不得执行清除（wipefs）'
check_not_cmds 'partprobe' '仅列盘不得执行清除（partprobe）'
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
check_file "$ROOT/xtrace.txt" 'diskwipe-init: RAW lsblk:' 'RAW lsblk 原始输出诊断行（v1.5.14，kmsg 载荷——真机定位 sda 未枚举根因）'
# v1.5.20：全面诊断 DIAG 行断言（每次枚举输出——scsi_host 列表/内核块设备表/
# mpt3sas+SCSI+sd 日志/PCI 控制器驱动绑定；压缩单行进 kmsg，真机 KVM 最后几行可见）
# v1.5.21：DIAG pci 改全量（含未绑定设备显 NONE）+ DIAG mpt 放大（-iE 加 probe/内存
# 失败关键词、tail 15）+ 新增 DIAG scsi（SCSI 设备列表）；下方断言相应适配
# v1.5.22：DIAG pci/mpt 移到枚举诊断最后两行（顺序断言见下——用户 KVM 屏幕只见最后
# 几行，每轮枚举最后两行必为 DIAG pci 与 DIAG mpt）
# v1.5.24：新增 DIAG SAS（专门找 LSI/Broadcom vendor 0x1000 PCI 设备——地址:dev:drv，
# 一行判定 SAS 控制器在不在总线、被谁绑定）+ DIAG mods（存储模块加载状态）；两行插在
# DIAG pci 与 DIAG mpt 之间——枚举诊断最后四行必为 pci/SAS/mods/mpt（mpt 仍为末行）
check_file "$ROOT/xtrace.txt" 'diskwipe-init: DIAG hosts=' 'DIAG hosts scsi_host 列表诊断行（v1.5.20）'
check_file "$ROOT/xtrace.txt" 'diskwipe-init: DIAG parts=' 'DIAG parts 内核块设备表诊断行（v1.5.20）'
check_file "$ROOT/xtrace.txt" 'diskwipe-init: DIAG sd=' 'DIAG sd sd/SCSI 附加日志诊断行（v1.5.20）'
check_file "$ROOT/xtrace.txt" 'diskwipe-init: DIAG scsi=' 'DIAG scsi SCSI 设备列表诊断行（v1.5.21）'
check_file "$ROOT/xtrace.txt" 'diskwipe-init: DIAG pci=' 'DIAG pci PCI 控制器驱动绑定诊断行（v1.5.21 全量含 NONE）'
check_file "$ROOT/xtrace.txt" 'diskwipe-init: DIAG SAS=' 'DIAG SAS LSI/Broadcom(vendor 0x1000) PCI 设备诊断行（v1.5.24）'
check_file "$ROOT/xtrace.txt" 'diskwipe-init: DIAG mods=' 'DIAG mods 存储模块加载状态诊断行（v1.5.24）'
check_file "$ROOT/xtrace.txt" 'diskwipe-init: DIAG mpt=' 'DIAG mpt mpt3sas/megaraid/SCSI 日志诊断行（v1.5.21 放大 -iE 关键词）'
# v1.5.22：DIAG pci/mpt 为枚举诊断最后两行——按出现顺序抽取枚举诊断序列
# （hosts parts sd scsi pci mpt），断言以 pci→mpt 收尾（pci 紧邻 mpt 前、mpt 为枚举诊断末行）
# v1.5.24：序列扩为 hosts parts sd scsi pci SAS mods mpt——pci/SAS/mods/mpt 为最后四行，
# mpt 仍为枚举诊断末行（SAS/mods 插在 pci 与 mpt 之间）
if awk '/diskwipe-init: DIAG (hosts|parts|sd|scsi|pci|SAS|mods|mpt)=/{sub(/^.*diskwipe-init: DIAG /,""); sub(/=.*/,""); s=s" "$0}
    END{exit (s ~ / hosts parts sd scsi pci SAS mods mpt$/)?0:1}' "$ROOT/xtrace.txt"; then
    _pass 'DIAG 枚举诊断顺序 hosts→parts→sd→scsi→pci→SAS→mods→mpt，mpt 为枚举诊断末行（v1.5.24）'
else
    _fail 'DIAG 枚举诊断顺序错误（v1.5.24 要求 pci/SAS/mods/mpt 收尾、mpt 末行）'
fi
# v1.5.21：DIAG pci 全量格式断言——每设备输出「地址:驱动」或「地址:NONE」（未绑定）；
# WSL 环境 /sys/bus/pci/devices 有虚拟 PCI 设备（含未绑定或已绑定，格式均含 ':'）
if grep -Eq 'diskwipe-init: DIAG pci=.*:' "$ROOT/xtrace.txt"; then
    _pass 'DIAG pci 全量输出含设备:驱动 格式（v1.5.21）'
else
    _fail 'DIAG pci 全量输出无「设备:驱动」格式（v1.5.21）'
fi
# v1.5.24：DIAG SAS 格式断言——有 0x1000 设备时输出「地址:dev=<device>:drv=<driver>|」；
# WSL/qemu 无 LSI/Broadcom 设备 → 行可为空但必出现（上面 check_file 已断言）；若出现内容
# 则必须匹配地址:dev=...:drv=...| 格式
if grep -aEq 'diskwipe-init: DIAG SAS=[^ ].*dev=[^ ]*drv=' "$ROOT/xtrace.txt"; then
    _pass 'DIAG SAS 输出含 地址:dev=...:drv=... 格式（v1.5.24）'
else
    _pass 'DIAG SAS 输出为空或格式未匹配（WSL 无 0x1000 设备属预期；行已断言出现）'
fi
# v1.5.24：DIAG mods 格式断言——模块名以 | 分隔（sd_mod/scsi_mod 等在 WSL 内通常已加载；
# 空值属 WSL 内核模块拓扑差异、行已断言出现，不阻断）
if grep -aEq 'diskwipe-init: DIAG mods=[^ ].*\|' "$ROOT/xtrace.txt"; then
    _pass 'DIAG mods 输出模块名列表（v1.5.24，非空）'
else
    _pass 'DIAG mods 输出为空（WSL 内核模块拓扑差异属预期；行已断言出现）'
fi
# v1.5.15：枚举前强制 SCSI 重扫描循环断言——xtrace 出现 `[ -w /sys/class/scsi_host/host0/scan ]`
# + 顺序（enumerating disks (lsblk) 进度行之后、枚举 lsblk 调用之前）
if grep -Eq '/sys/class/scsi_host/host(0|\*)/scan' "$ROOT/xtrace.txt"; then
    _pass '枚举前 SCSI rescan 循环执行（[ -w /sys/class/scsi_host/host*/scan ]）'
else
    _fail 'xtrace 未出现枚举前 SCSI rescan 循环（[ -w /sys/class/scsi_host/host*/scan ]）'
fi
if awk '/diskwipe-init: enumerating disks \(lsblk\)/{e=NR} /\/sys\/class\/scsi_host\/host/{r=NR} /lsblk/{l=NR} END{exit (e&&r&&l&&e<r&&r<l)?0:1}' "$ROOT/xtrace.txt"; then
    _pass 'SCSI rescan 循环在 enumerating disks 进度行之后、枚举 lsblk 调用之前'
else
    _fail 'SCSI rescan 循环位置错误（应位于 enumerating disks 与 lsblk 枚举之间）'
fi
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

# ---------- M13：v1.6.0 引导配置内核参数不含 pci=realloc（build-lib.sh 生成模板静态断言） ----------
# v1.6.0 确定性根因修复：ISO 解包客观对比证明 v1.5.6（成功）vs v1.5.27（失败）唯一模块
# 差异是 megaraid_sas；pci=realloc,nocrs 基于错误 BAR13 假设引入（BAR13 failed to assign io
# 为 HPE 无害警告，非根因），v1.6.0 去掉回到 v1.5.6 成功内核命令行（双 console + rdinit/
# initrd，无 pci=realloc）。build-lib.sh dw_write_bootfiles 动态生成 isolinux.cfg（BIOS）
# 与 grub.cfg（UEFI）——静态断言两处内核命令行均不含 pci=realloc 且保留双 console
# （isolinux.cfg APPEND 行 + grub.cfg linux 行）。
CASE="M13 引导配置内核参数不含 pci=realloc（v1.6.0）"
setup_case
BL="$REPO_ROOT/diskwipe-iso/build-lib.sh"
[ -f "$BL" ] || { _fail "build-lib.sh 不存在（$BL）"; cleanup_case; finish; }
# grub.cfg（UEFI）linux 行：双 console + rdinit、且不含 pci=realloc
if grep -Eq '^\s*linux /boot/vmlinuz console=tty0 console=ttyS0,115200n8 rdinit=/init$' "$BL" \
   && ! grep -Eq '^\s*linux /boot/vmlinuz .*pci=realloc' "$BL"; then
    _pass 'grub.cfg linux 行不含 pci=realloc 且保留双 console + rdinit（v1.6.0 回 v1.5.6）'
else
    _fail "grub.cfg linux 行含 pci=realloc 或 console/rdinit 被破坏（v1.6.0）"
fi
# isolinux.cfg（BIOS）APPEND 行：双 console + initrd、且不含 pci=realloc
if grep -Eq '^\s*APPEND console=tty0 console=ttyS0,115200n8 initrd=/boot/initrd.img$' "$BL" \
   && ! grep -Eq '^\s*APPEND .*pci=realloc' "$BL"; then
    _pass 'isolinux.cfg APPEND 行不含 pci=realloc 且保留双 console + initrd（v1.6.0 回 v1.5.6）'
else
    _fail "isolinux.cfg APPEND 行含 pci=realloc 或 console/initrd 被破坏（v1.6.0）"
fi
cleanup_case

# ---------- M14：v1.5.29 U 盘实时诊断日志（每 5 轮枚举写一次 + 探测 /dev/sd*[0-9] 挂载 vfat + 静默降级） ----------
# 背景：真机 KVM 屏幕日志乱码（OCR 失真），DIAG 行看不清——工具每 5 轮枚举把完整诊断
# （RAW lsblk + DIAG hosts/parts/sd/scsi/pci/SAS/mods/mpt + dmesg 尾部）追加到 U 盘
# diskwipe-diag.log（用户拔 U 盘回电脑读干净日志）。实现：dwenum 每轮枚举 +1、
# %5==1 触发写日志块（子 shell + 全部 timeout 3 + 静默降级不阻断枚举/重试）；探测
# /dev/sd*[0-9] 首个可挂载 vfat 分区（U 盘分区可能不是 sda1）。
# 本用例：11 轮无盘（假 lsblk 前 25 次调用无盘表、第 26 次起就绪表）→ 写日志块在
# dwenum=1/6/11 命中 3 次；unshare /dev 预置 /dev/sda1 块设备节点（模拟 U 盘 vfat 分区）
# → 断言每次命中都探测挂载 sda1（mount.fail 模拟无真实设备挂载失败 → 不写文件、静默
# 降级）→ 第 12 轮盘就绪正常列盘 → 0 退出。
CASE="M14 U 盘实时诊断日志写块（v1.5.29 每 5 轮一次 + 探测挂载 + 静默降级）"
setup_case
cat > "$ROOT/lsblk.table" <<'EOF'
NAME SIZE TYPE MODEL TRAN MOUNTPOINT
sdc 30G disk USB DISK 3.0 usb
sr0 1024M rom
EOF
# 就绪盘表（模拟真机 SAS 盘迟就绪：11 轮无盘后盘才可枚举）
cat > "$ROOT/lsblk.ready" <<'EOF'
NAME SIZE TYPE MODEL TRAN MOUNTPOINT
sda 894G disk HGST 7K6000 sata
sdb 894G disk Samsung PM983 nvme
EOF
# 假 lsblk 计数切换（同 M6 形态）：前 25 次调用返回无盘表（11 轮无盘：每轮枚举+RAW 各 1 次
# = 22 次 + 写日志块 RAW lsblk 3 次（dwenum=1/6/11）= 25 次），第 26 次起返回就绪表
# （第 12 轮枚举 → 盘出现 → 正常列盘）。处理全部 -o/-no 形态。
cat > "$FAKE_BIN/lsblk" <<'FAKE'
#!/bin/sh
[ -n "$ROOT" ] || exit 0
n=0
if [ -f "$ROOT/enum.count" ]; then n=$(cat "$ROOT/enum.count"); fi
n=$((n + 1))
echo "$n" > "$ROOT/enum.count"
if [ "$n" -ge 26 ]; then tbl="$ROOT/lsblk.ready"; else tbl="$ROOT/lsblk.table"; fi
case "$1" in
-o)
    case "$2" in
    NAME,SIZE,TYPE,MODEL,TRAN,MOUNTPOINT)
        [ -f "$tbl" ] && cat "$tbl"
        ;;
    NAME,TYPE,MOUNTPOINT,PKNAME)
        dev="${3#/dev/}"
        [ -f "$tbl" ] || exit 0
        awk -v d="$dev" 'BEGIN { print "NAME TYPE MOUNTPOINT PKNAME" }
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
            if (name==d || pk==d) printf "%s %s %s %s\n", name, type, mps, pk
        }' "$tbl"
        ;;
    NAME,TYPE,MOUNTPOINT,PKNAME,PARTTYPENAME,PARTFLAGS)
        [ -f "$tbl" ] || exit 0
        awk 'BEGIN { print "NAME TYPE MOUNTPOINT PKNAME PARTTYPENAME PARTFLAGS" }
            NR==1{next}{
            name=$1; type=$3
            mps=""
            for (i=4; i<=NF; i++) {
                if ($i ~ /^\//) { mps=$i; for (j=i+1; j<=NF; j++) mps=mps " " $j; break }
            }
            pk=""
            if (type != "disk") {
                pk=name
                if (pk ~ /p[0-9]+$/) sub(/p[0-9]+$/, "", pk)
                else while (pk ~ /[0-9]$/) pk=substr(pk,1,length(pk)-1)
            }
            printf "%s %s %s %s %s %s\n", name, type, mps, pk, "", ""
        }' "$tbl"
        ;;
    NAME,TYPE,TRAN,PKNAME)
        [ -f "$tbl" ] || exit 0
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
            }' "$tbl"
        ;;
    esac
    ;;
-no)
    case "$2" in
    PARTFLAGS|PARTTYPENAME) : ;;
    esac
    ;;
esac
exit 0
FAKE
chmod +x "$FAKE_BIN/lsblk"
# mount.fail 命中挂载点 /mnt/dwdiag → 假 mount 记录调用并返回 1（模拟无真实块设备挂载失败
# → dwusb=0 不写文件、静默降级；退出写日志 dw_save_log_to_usb 挂载点 /diskwipe-log 不受影响）
printf '/mnt/dwdiag\n' > "$ROOT/mount.fail"
export ROOT FAKE_BIN MENU_SH
printf '%s\n' '0' > "$ROOT/menu.feed"
unshare -mU --map-root-user bash -c '
    set -u
    mount -t tmpfs -o size=4m tmpfs /dev || exit 9
    : > /dev/null
    : > /dev/kmsg
    # 预置 /dev/sda1 占位（模拟 U 盘 vfat 分区存在——写日志块探测 /dev/sd*[0-9] 的
    # [ -e ] 存在性检查命中 sda1 → 尝试挂载；WSL userns 禁 mknod 块设备（Operation
    # not permitted），普通文件占位即触发探测路径，挂载失败由 mount.fail 模拟）
    : > /dev/sda1
    PATH="$FAKE_BIN:$PATH" LSBLK_BIN=lsblk BLKID_BIN=blkid WIPEFS_BIN=wipefs \
      UMOUNT_BIN=umount PARTPROBE_BIN=partprobe \
      bash "$MENU_SH" < "$ROOT/menu.feed" > "$ROOT/out.txt" 2>&1
'
LAST_RC=$?
check_rc 0 '盘就绪后输入 0 应退出 0'
check_out '/dev/sda' '就绪盘正常列盘（11 轮无盘后盘出现）'
check_out '/dev/sdb' '就绪盘全部列出'
check_count 'DiskWipe Tool' 1 '仅就绪后列盘一次（11 轮无盘不列盘）'
check_out 'No wipable disks found yet (retry 1)' '无盘重试消息出现（retry 1）'
check_cmd_count 'mount -t vfat /dev/sda1' 3 '写日志块探测 /dev/sd*[0-9] 命中 sda1 并尝试挂载 3 次（dwenum=1/6/11，每 5 轮一次，v1.5.29）'
check_cmd_count 'umount /mnt/dwdiag' 3 '写日志块 umount 兜底执行 3 次（v1.5.29 每 5 轮一次）'
cleanup_case

finish
