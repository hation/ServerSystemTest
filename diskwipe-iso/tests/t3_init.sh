#!/bin/bash
# T3：diskwipe-iso initramfs 启动脚本（src/init）假件单测
# 覆盖：src/init 的启动编排——挂载 /proc /sys /dev → busybox modprobe 白名单磁盘驱动 →
#       mdev -s 扫描设备 → sleep 3（v1.5.7：去掉重试 mdev 轮询）→ exec menu.sh。
# v1.5.6 语义：进度走 /dev/kmsg（dw_progress 写内核 printk 通道，与内核日志混排）+
#   timeout 5 兜底（假件转执行）；显卡循环只加载 ast（mgag200/smifb/bochs-drm/cirrus/
#   virtio-gpu 在无对应硬件时 modprobe 可能内核 D 状态挂起导致 init 卡死，真机实证）；
#   仅挂载失败进入救援 shell；模块加载/mdev 失败仅 WARN 继续（不 rescue，保证到菜单）。
# kmsg 进度断言方式：本机 Git Bash 的 /dev 为 MSYS 虚拟只读目录，无法创建 /dev/kmsg
#   假件（写失败静默——恰是生产"写失败不中断启动"语义）；用 `bash -x` + BASH_XTRACEFD=3
#   把 xtrace 分流到 $ROOT/xtrace.txt，正向断言 dw_progress 调用与 kmsg 载荷
#   （`+ echo 'diskwipe-init: ...'` / `+ dw_progress '...'`）；stdout（$OUTF）保持
#   纯 console 输出（断言进度不再打 console、WARN/ERROR 语义不变）。
# 运行：bash diskwipe-iso/tests/run-all.sh（或单独 bash diskwipe-iso/tests/t3_init.sh）
# 安全约束（用户强要求，测试绝不触碰本机真实块设备/真实挂载）：
#   假 mount/modprobe/mdev 只把调用参数记录到 $ROOT/cmds.txt、绝不真挂载/真加载模块；
#   stub 环境里的 menu.sh 为假件（打印标记证明 exec 到了交互菜单）；init 经 INIT_PATH
#   接缝变量注入假件 PATH。
# 用例：
#   I1  正常：假 mount/modprobe/mdev 全部成功 → 输出含挂载 /proc /sys /dev；xtrace 含
#       "diskwipe-init: loading module <name>" / "diskwipe-init: loading video module ast" /
#       "diskwipe-init: device scan (mdev -s)"（kmsg 进度载荷）；modprobe 调用覆盖
#       DRIVE_MODULES 全部模块名 + ast，且**不含** mgag200/smifb/bochs-drm/cirrus/virtio-gpu
#       （显卡循环只留 ast）；stdout 不含 "diskwipe-init:"（进度不打 console）；
#       最后 exec menu.sh（假 menu.sh 打标记）
#   I2  modprobe 某模块（mpt3sas）失败 → 打印 WARN 继续加载后续模块、不 rescue、
#       最终 exec menu.sh（v1.5.5：失败不再 init_rescue）
#   I3  挂载 /sys 失败 → 打印错误、停留在救援 shell、不 exec menu.sh、不加载模块
#       （init_rescue 语义仅保留给 mount）
#   I4  mdev -s 失败 → 打印 WARN 继续（不 rescue）、最终 exec menu.sh
set -u
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
trap 'rc=$?; cleanup_case; exit "$rc"' EXIT

INIT_SH="$REPO_ROOT/diskwipe-iso/src/init"
# 与 src/init 内 DRIVE_MODULES 常量保持一致
DRIVE_MODULES="ahci libahci libata nvme nvme-core mpt3sas megaraid_sas virtio_blk virtio_pci xhci_pci sd_mod scsi_mod usb_storage uas nls_iso8859-1 exfat ntfs3"

echo "==== T3 initramfs 启动脚本测试 ===="

# 搭建 stub 环境：把 src/init 拷入 $ROOT/stub/ 与假 menu.sh 同目录
# （模拟 initramfs 布局：init 用 dirname $0 定位同目录 menu.sh）
setup_stub() {
    setup_tmp
    mkdir -p "$ROOT/stub"
    cp "$INIT_SH" "$ROOT/stub/init"
    # init 会 source 同目录 lib.sh（定义 dw_version 等函数），必须一并拷入 stub；
    # v1.3.2 起 init 阶段零 U 盘 I/O（不探测/不挂载日志介质），故无需 lsblk/blkid/timeout 假件
    cp "$LIB_SH" "$ROOT/stub/lib.sh"
    # 假 mount：记录调用到 cmds.txt；$ROOT/mount.fail 命中挂载点（末参数）时返回 1
    fake_bin mount '#!/bin/sh
[ -n "$ROOT" ] || exit 0
printf "mount %s\n" "$*" >> "$ROOT/cmds.txt"
[ -f "$ROOT/mount.fail" ] || exit 0
mp=""
for a in "$@"; do mp="$a"; done
while IFS= read -r f; do
    [ "$f" = "$mp" ] && exit 1
done < "$ROOT/mount.fail"
exit 0'
    # 假 modprobe：记录调用到 cmds.txt；$ROOT/modprobe.fail 命中模块时返回 1
    fake_bin modprobe '#!/bin/sh
[ -n "$ROOT" ] || exit 0
printf "modprobe %s\n" "$1" >> "$ROOT/cmds.txt"
[ -f "$ROOT/modprobe.fail" ] || exit 0
while IFS= read -r f; do
    [ "$f" = "$1" ] && exit 1
done < "$ROOT/modprobe.fail"
exit 0'
    # 假 mdev：记录调用到 cmds.txt；$ROOT/mdev.fail 存在时返回 1（模拟 mdev 扫描失败）
    fake_bin mdev '#!/bin/sh
[ -n "$ROOT" ] || exit 0
printf "mdev %s\n" "$*" >> "$ROOT/cmds.txt"
[ -f "$ROOT/mdev.fail" ] && exit 1
exit 0'
    # 假 timeout：模拟超时包装——去掉秒数参数后转执行剩余命令（测试内命令立即返回、
    # 不真等 5s）；不记录 cmds.txt（避免影响既有 check_no_cmds/check_cmds 断言）
    fake_bin timeout '#!/bin/sh
[ -n "$ROOT" ] || exit 0
shift
"$@"'
    # 假 sh（救援 shell）：打印标记后退出（模拟"停留 shell"，不真进入交互）
    fake_bin sh '#!/bin/sh
echo "RESCUE_SHELL_MARKER"
exit 0'
    # 假 menu.sh：init 最后 exec 它时打印标记（证明走到交互菜单）
    cat > "$ROOT/stub/menu.sh" <<'EOF'
#!/bin/sh
echo "MENU_EXEC_MARKER"
EOF
    chmod +x "$ROOT/stub/menu.sh"
}

# 运行 stub 环境的 init（stdin 接 /dev/null 防挂起；假件经 INIT_PATH/PATH 注入）。
# v1.5.6：`bash -x` + BASH_XTRACEFD=3 把 xtrace 分流到 $ROOT/xtrace.txt（正向断言
#   dw_progress 调用与 kmsg 载荷）；$OUTF 为纯 console 输出（进度已不打 console）。
# 注：Git Bash 的 /dev 虚拟只读，/dev/kmsg 不可建假件——dw_progress 写失败静默
#   （bash 会把重定向失败打印到 stderr，$OUTF 会出现 Permission denied 行，无碍断言）。
run_init() {
    local outf="$1"
    shift
    INIT_PATH="$FAKE_BIN:$PATH" \
    PATH="$FAKE_BIN:$PATH" \
    BASH_XTRACEFD=3 \
    bash -x "$ROOT/stub/init" "$@" 3> "$ROOT/xtrace.txt" > "$outf" 2>&1 < /dev/null
    LAST_RC=$?
    return 0
}

# kmsg 进度断言（v1.5.6）：在 xtrace.txt 中正向断言 dw_progress 写 /dev/kmsg 的载荷
check_kmsg() {
    local want="$1" desc="$2"
    check_file "$ROOT/xtrace.txt" "$want" "$desc"
}

# ---------- I1：正常启动编排 ----------
CASE="I1 正常启动编排"
setup_stub
run_init "$OUTF"
check_rc 0 '正常路径应退出 0'
check_out 'Mounted /proc' '输出应包含挂载 /proc'
check_out 'Mounted /sys' '输出应包含挂载 /sys'
check_out 'Mounted /dev' '输出应包含挂载 /dev'
check_cmds 'mount -t proc proc /proc' '应挂载 /proc'
check_cmds 'mount -t sysfs sysfs /sys' '应挂载 /sys'
check_cmds 'mount -t devtmpfs devtmpfs /dev' '应挂载 /dev'
check_cmds 'mdev -s' '应执行 mdev -s 扫描设备'
# v1.5.7：去掉设备重试扫描（真机 U 盘枚举后重试 mdev 触发 U 盘 I/O 阻塞——内核 D 状态
# 不可中断、用户态 timeout 无效——致 init 卡死）；mdev -s 仅首扫 1 次，随后仅 sleep 等待
# 设备稳定（U 盘节点由 menu 退出写日志前 dw_save_log_to_usb 内 mdev -s 补建）
check_cmd_count 'mdev -s' 1 '设备扫描应仅执行 1 次（v1.5.7 去掉重试轮）'
check_not_cmds 'mount /dev/' 'init 阶段零 U 盘挂载（不再挂载日志介质）'
for m in $DRIVE_MODULES; do
    check_cmds "modprobe $m" "应加载模块 $m"
done
if awk '/^mount -t proc proc \/proc$/{m=1} /^modprobe ahci$/{if(m)ok=1} END{exit ok?0:1}' "$ROOT/cmds.txt"; then
    _pass '挂载先于模块加载'
else
    _fail '应先挂载 /proc 再加载模块'
fi
if awk '/^modprobe /{last=NR} /^mdev -s$/{if(NR>last)ok=1} END{exit ok?0:1}' "$ROOT/cmds.txt"; then
    _pass 'mdev -s 在全部模块加载之后'
else
    _fail 'mdev -s 应在全部模块加载之后'
fi
check_out 'MENU_EXEC_MARKER' '最后应 exec menu.sh（假 menu.sh 打标记）'
check_not_out 'failed' '正常路径不应出现失败提示'
# v1.5.6 kmsg 进度行必现（真机靠 kmsg 定位卡点；写 /dev/kmsg 与内核日志混排、屏幕最后几行可见）
check_kmsg 'diskwipe-init: loading module ahci' 'kmsg 进度行（磁盘模块循环）'
check_kmsg 'diskwipe-init: loading module mpt3sas' 'kmsg 进度行（磁盘模块循环，全部模块）'
check_kmsg 'diskwipe-init: Disk driver modules loaded' 'kmsg 磁盘循环完成行'
check_kmsg 'diskwipe-init: loading video module ast' 'kmsg 显卡进度行（只加载 ast）'
check_kmsg 'diskwipe-init: device scan (mdev -s)' 'kmsg mdev 扫描进度行'
check_kmsg 'diskwipe-init: Device nodes scanned' 'kmsg 设备节点扫描完成行'
check_kmsg 'diskwipe-init: device settle wait (sleep)' 'kmsg 设备稳定等待进度行（v1.5.7 去掉重试轮）'
# v1.5.6 显卡循环只留 ast：modprobe 调用含 ast、不含其余 5 个显卡驱动
check_cmds 'modprobe ast' '应加载 ast（显卡循环白名单唯一）'
for gv in mgag200 smifb bochs-drm cirrus virtio-gpu; do
    check_not_cmds "modprobe $gv" "不得加载 $gv（无对应硬件时 D 状态挂起致 init 卡死，真机实证）"
done
# v1.5.6 进度不打 console（stdout 纯 console 输出，无 kmsg 载荷）
check_not_out 'diskwipe-init:' '进度走 /dev/kmsg，console 不应出现 diskwipe-init 载荷'
cleanup_case

# ---------- I2：modprobe 某模块失败（v1.5.5：WARN 继续，不 rescue） ----------
CASE="I2 模块加载失败"
setup_stub
printf 'mpt3sas\n' > "$ROOT/modprobe.fail"
run_init "$OUTF"
check_rc 0 '模块失败 WARN 继续，最终 exec menu.sh 正常结束'
check_kmsg 'diskwipe-init: loading module mpt3sas' '失败模块仍打 kmsg 进度行（定位卡点）'
check_out 'WARN: module mpt3sas load failed/timed out' '应打印模块加载失败警告'
check_not_out 'ERROR' '模块失败不再进入救援 shell（v1.5.5 语义）'
check_not_out 'RESCUE_SHELL_MARKER' '不得进入救援 shell'
check_cmds 'modprobe mpt3sas' '应尝试加载失败模块（记录在 cmds.txt）'
check_cmds 'modprobe virtio_blk' '失败后继续加载后续模块（v1.5.5 不再中断）'
check_kmsg 'diskwipe-init: Disk driver modules loaded' '循环结束 kmsg 行应出现（失败继续到循环末尾）'
check_cmd_count 'mdev -s' 1 '模块失败后仍执行 mdev 首扫（v1.5.7 无重试轮）'
check_out 'MENU_EXEC_MARKER' '最终应 exec menu.sh（失败不再 rescue）'
cleanup_case

# ---------- I3：挂载失败 ----------
CASE="I3 挂载失败"
setup_stub
printf '/sys\n' > "$ROOT/mount.fail"
run_init "$OUTF"
check_rc 0 '挂载失败后进入救援 shell，shell 退出后进程正常结束'
check_out 'ERROR: mount /sys failed' '应打印挂载失败错误'
check_out 'RESCUE_SHELL_MARKER' '应进入救援 shell（假 sh 打标记）'
check_not_out 'MENU_EXEC_MARKER' '失败时不得 exec menu.sh'
check_cmd_count 'modprobe' 0 '挂载失败后不得加载模块'
check_cmd_count 'mdev' 0 '挂载失败后不得执行 mdev'
cleanup_case

# ---------- I4：mdev -s 失败（v1.5.5：WARN 继续，不 rescue） ----------
CASE="I4 mdev 扫描失败"
setup_stub
: > "$ROOT/mdev.fail"
run_init "$OUTF"
check_rc 0 'mdev 失败 WARN 继续，最终 exec menu.sh 正常结束'
check_kmsg 'diskwipe-init: device scan (mdev -s)' 'kmsg mdev 扫描进度行（定位卡点）'
check_out 'WARN: mdev scan failed/timed out' '应打印 mdev 扫描失败警告'
check_not_out 'ERROR' 'mdev 失败不再进入救援 shell（v1.5.5 语义）'
check_not_out 'RESCUE_SHELL_MARKER' '不得进入救援 shell'
check_kmsg 'diskwipe-init: Device nodes scanned' 'WARN 后继续打 kmsg 完成行（不 rescue）'
check_out 'MENU_EXEC_MARKER' '最终应 exec menu.sh（失败不再 rescue）'
cleanup_case

finish
