#!/bin/bash
# diskwipe-iso 离线测试共享库 —— 假件注入骨架 + 断言 + 运行包装
# 运行环境：本机 Git Bash（bash）；全部测试在 mktemp 临时目录进行。
# 安全约束（用户强要求，测试绝不触碰本机真实块设备）：
#   假 lsblk/blkid/wipefs/umount 全部经接缝变量（LSBLK_BIN/BLKID_BIN/WIPEFS_BIN/UMOUNT_BIN）
#   注入；wipefs 假件只把调用参数记录到 $ROOT/cmds.txt、绝不执行真实 wipefs；脚本操作的
#   "设备"全部来自假件输出的名字，不存在真实 /dev 设备。
#
# 用例写法：
#   set -u; . "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
#   CASE="用例名"; setup_tmp; install_fakes; 写 lsblk.table/blk.type/...
#   run_dw "$OUTF" dw_enum_disks; check_*; cleanup_case
#
# 假 lsblk 表约定（lsblk.table，src/lib.sh 的解析同此约定）：
#   列序 NAME SIZE TYPE MODEL TRAN MOUNTPOINT（空格分隔；MODEL 可含空格；
#   为空的列（TRAN/挂载点/MODEL）直接省略；挂载点一律以 / 开头、可含空格）。
#   -o NAME,SIZE,TYPE,MODEL,TRAN,MOUNTPOINT            → 原样输出整表
#   -o NAME,TYPE,MOUNTPOINT,PKNAME <dev>               → 输出表头 + 该盘及子树行
#                                                        （与真实 lsblk 一致带表头；挂载点取
#                                                        首个 / 开头字段起至行尾原文；
#                                                        PKNAME 由名字推导：nvme0n1p1 去
#                                                        p+数字、sda1 去尾部数字）
#   -no PARTFLAGS <dev>                                → 按 lsblk.flags（"设备 标志"，
#                                                        真实格式如 MBR 活动=0x80）
#   -no PARTTYPENAME <dev>                             → 按 lsblk.ptname（"设备 类型名"，
#                                                        真实格式如 GPT ESP="EFI System"）

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TEST_DIR/../.." && pwd)"
LIB_SH="$REPO_ROOT/diskwipe-iso/src/lib.sh"
WIPE_SH="$REPO_ROOT/diskwipe-iso/src/wipe.sh"

PASS=0
FAIL=0
FAILED_LIST=""
CASE="(未命名用例)"
ROOT=""
FAKE=""
FAKE_BIN=""
OUTF=""
LAST_RC=""

# 建立临时工作区：ROOT 为用例根目录，fakebin/ 放 PATH 假命令，out.txt 收集被测输出
setup_tmp() {
    ROOT="$(mktemp -d "${TMPDIR:-/tmp}/dwipe.XXXXXX")" || { echo "无法创建临时目录"; exit 1; }
    FAKE="$ROOT/fake"
    FAKE_BIN="$ROOT/fakebin"
    OUTF="$ROOT/out.txt"
    mkdir -p "$FAKE" "$FAKE_BIN"
    : > "$OUTF"
    LAST_RC=""
    export ROOT FAKE FAKE_BIN
}

# 在 FAKE_BIN 下生成可执行假件：fake_bin <name> <content>
fake_bin() {
    local name="$1"
    shift
    printf '%s\n' "$*" > "$FAKE_BIN/$name"
    chmod +x "$FAKE_BIN/$name"
}

# 安装核心逻辑用到的全部假命令（详见各假件注释）
install_fakes() {
    # 假 lsblk：按 $ROOT/lsblk.table / $ROOT/lsblk.flags 返回
    fake_bin lsblk '#!/bin/sh
[ -n "$ROOT" ] || exit 0
case "$1" in
-o)
    case "$2" in
    NAME,SIZE,TYPE,MODEL,TRAN,MOUNTPOINT)
        [ -f "$ROOT/lsblk.table" ] && cat "$ROOT/lsblk.table"
        ;;
    NAME,TYPE,MOUNTPOINT,PKNAME)
        dev="${3#/dev/}"
        [ -f "$ROOT/lsblk.table" ] || exit 0
        # 真实 lsblk 恒有表头（lib.sh 的 NR==1 跳过），此处同样先输出表头
        awk -v d="$dev" '"'"'BEGIN { print "NAME TYPE MOUNTPOINT PKNAME" }
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
        }'"'"' "$ROOT/lsblk.table"
        ;;
    esac
    ;;
-no)
    case "$2" in
    PARTFLAGS)
        dev="${3#/dev/}"
        [ -f "$ROOT/lsblk.flags" ] || exit 0
        awk -v d="$dev" '"'"'$1==d { print $2 }'"'"' "$ROOT/lsblk.flags"
        ;;
    PARTTYPENAME)
        dev="${3#/dev/}"
        [ -f "$ROOT/lsblk.ptname" ] || exit 0
        awk -v d="$dev" '"'"'$1==d { $1=""; sub(/^ /, ""); print }'"'"' "$ROOT/lsblk.ptname"
        ;;
    esac
    ;;
esac
exit 0'
    # 假 blkid：blkid -s TYPE -o value <dev>，按 $ROOT/blk.type（"设备 类型"）返回；
    # 无条目 → 无输出 rc 2（模拟无法探测）
    fake_bin blkid '#!/bin/sh
[ -n "$ROOT" ] || exit 2
dev=""
for a in "$@"; do
    case "$a" in /dev/*) dev="${a#/dev/}" ;; esac
done
[ -n "$dev" ] || exit 2
[ -f "$ROOT/blk.type" ] || exit 2
awk -v d="$dev" '"'"'$1==d { print $2; found=1; exit } END { exit (found?0:2) }'"'"' "$ROOT/blk.type"'
    # 假 wipefs：-a 记录调用到 cmds.txt（$ROOT/wipefs.afail 列出的设备返回 1）；
    #           -n 也记录调用，并按 $ROOT/wipefs.sigs 输出（无文件/空 = 无残留）
    fake_bin wipefs '#!/bin/sh
[ -n "$ROOT" ] || exit 0
mode=""
dev=""
devname=""
for a in "$@"; do
    case "$a" in
    -a) mode=a ;;
    -n) mode=n ;;
    /dev/*) dev="$a"; devname="${a#/dev/}" ;;
    esac
done
case "$mode" in
a)
    printf "wipefs -a %s\n" "$dev" >> "$ROOT/cmds.txt"
    if [ -f "$ROOT/wipefs.afail" ]; then
        while IFS= read -r f; do
            [ "$f" = "$devname" ] && exit 1
        done < "$ROOT/wipefs.afail"
    fi
    ;;
n)
    printf "wipefs -n %s\n" "$dev" >> "$ROOT/cmds.txt"
    if [ -f "$ROOT/wipefs.nfail" ]; then
        while IFS= read -r f; do
            [ "$f" = "$devname" ] && exit 1
        done < "$ROOT/wipefs.nfail"
    fi
    [ -f "$ROOT/wipefs.sigs" ] && cat "$ROOT/wipefs.sigs"
    ;;
esac
exit 0'
    # 假 umount：记录调用到 cmds.txt；$ROOT/umount.failmp 逐行命中参数时返回 1
    fake_bin umount '#!/bin/sh
[ -n "$ROOT" ] || exit 0
printf "umount %s\n" "$*" >> "$ROOT/cmds.txt"
mp="$1"
[ -f "$ROOT/umount.failmp" ] || exit 0
while IFS= read -r f; do
    [ "$f" = "$mp" ] && exit 1
done < "$ROOT/umount.failmp"
exit 0'
}

# 追加 blk.type 条目：add_blk_type <分区> <类型>（ESP→vfat、Windows→ntfs、Linux→ext4）
add_blk_type() {
    printf '%s %s\n' "$1" "$2" >> "$ROOT/blk.type"
}

# 追加分区类型名条目：add_ptname <分区> <类型名>（真实格式，如 GPT ESP="EFI System"）
add_ptname() {
    printf '%s %s\n' "$1" "$2" >> "$ROOT/lsblk.ptname"
}

# 追加分区标志条目：add_flag <分区> <标志>（真实格式，如 MBR 活动=0x80）
add_flag() {
    printf '%s %s\n' "$1" "$2" >> "$ROOT/lsblk.flags"
}

# 调 src/lib.sh 中的函数：run_dw <outf> <函数名> [参数...]（接缝变量指向 PATH 假件）
# 注意：LIB_SH/func 由外层 shell 展开嵌入（不可加反斜杠，否则内层 bash 拿到字面量）；
#       "$@" 保留给内层传给函数。
run_dw() {
    local outf="$1" func="$2"
    shift 2
    PATH="$FAKE_BIN:$PATH" \
    LSBLK_BIN=lsblk \
    BLKID_BIN=blkid \
    WIPEFS_BIN=wipefs \
    UMOUNT_BIN=umount \
    bash -c ". \"$LIB_SH\"; $func \"\$@\"" _ "$@" > "$outf" 2>&1
    LAST_RC=$?
    return 0
}

# 调 src/wipe.sh：run_wipe <outf> [dev...]（stdin 接 /dev/null，接缝指向 PATH 假件）
run_wipe() {
    local outf="$1"
    shift
    PATH="$FAKE_BIN:$PATH" \
    LSBLK_BIN=lsblk \
    BLKID_BIN=blkid \
    WIPEFS_BIN=wipefs \
    UMOUNT_BIN=umount \
    bash "$WIPE_SH" "$@" > "$outf" 2>&1 < /dev/null
    LAST_RC=$?
    return 0
}

_pass() { PASS=$((PASS + 1)); echo "  PASS [$CASE] $1"; }
_fail() { FAIL=$((FAIL + 1)); FAILED_LIST="${FAILED_LIST}  - [$CASE] $1"$'\n'; echo "  FAIL [$CASE] $1"; }

# 断言输出含指定文本
check_out() {
    local want="$1" desc="$2"
    if grep -Fq -- "$want" "$OUTF" 2>/dev/null; then
        _pass "$desc"
    else
        _fail "$desc（输出未包含：$want）"
    fi
}

# 断言输出不含指定文本
check_not_out() {
    local bad="$1" desc="$2"
    if ! grep -Fq -- "$bad" "$OUTF" 2>/dev/null; then
        _pass "$desc"
    else
        _fail "$desc（输出不应包含：$bad）"
    fi
}

# 断言最近一次 run_dw/run_wipe 的退出码
check_rc() {
    local want="$1" desc="$2"
    if [ "${LAST_RC:-}" = "$want" ]; then
        _pass "$desc"
    else
        _fail "$desc（退出码 ${LAST_RC:-未执行}，期望 $want）"
    fi
}

# 断言 $ROOT/cmds.txt 含某整行命令（-F 精确匹配）
check_cmds() {
    local want="$1" desc="$2" f="$ROOT/cmds.txt"
    if [ -f "$f" ] && grep -Fxq -- "$want" "$f"; then
        _pass "$desc"
    else
        _fail "$desc（cmds.txt 未包含整行：$want）"
    fi
}

# 断言 $ROOT/cmds.txt 不含匹配文本的行
check_not_cmds() {
    local bad="$1" desc="$2" f="$ROOT/cmds.txt"
    if [ -f "$f" ] && grep -Fq -- "$bad" "$f"; then
        _fail "$desc（cmds.txt 不应包含：$bad）"
    else
        _pass "$desc"
    fi
}

# 断言 $ROOT/cmds.txt 中匹配某文本的行数为 n
check_cmd_count() {
    local text="$1" want="$2" desc="$3" n=0 f="$ROOT/cmds.txt"
    if [ -f "$f" ]; then
        n=$(grep -Fc -- "$text" "$f")
        [ -n "$n" ] || n=0
    fi
    if [ "$n" -eq "$want" ]; then
        _pass "$desc"
    else
        _fail "$desc（实际 $n 次，期望 $want 次）"
    fi
}

# 断言没有执行任何命令（cmds.txt 不存在或为空）
check_no_cmds() {
    local desc="$1"
    if [ ! -s "$ROOT/cmds.txt" ]; then
        _pass "$desc"
    else
        _fail "$desc（仍有命令：$(tr '\n' '|' < "$ROOT/cmds.txt")）"
    fi
}

# 清理用例：删除临时目录并复位状态
cleanup_case() {
    if [ -n "${ROOT:-}" ] && [ -d "$ROOT" ]; then
        rm -rf "$ROOT"
    fi
    ROOT=""
    FAKE=""
    FAKE_BIN=""
    OUTF=""
    LAST_RC=""
}

# 汇总结果：有失败则以 1 退出
finish() {
    echo
    echo "==== 测试汇总 ===="
    echo "通过 $PASS 项，失败 $FAIL 项"
    if [ "$FAIL" -gt 0 ]; then
        echo "失败用例："
        printf '%s' "$FAILED_LIST"
        echo "==== 结果: FAIL ===="
        exit 1
    fi
    echo "==== 结果: ALL PASS ===="
    exit 0
}
