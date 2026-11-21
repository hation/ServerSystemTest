#!/bin/bash
# T3：diskwipe-iso initramfs 启动脚本（src/init）假件单测
# 覆盖：src/init 的启动编排——挂载 /proc /sys /dev → busybox modprobe 白名单磁盘驱动 →
#       mdev -s 扫描设备 → sleep 2 → exec menu.sh；任一步失败（挂载/模块加载）打印错误
#       并停留在救援 shell（不 exec menu.sh，便于现场诊断），与设计 §6.3 一致。
# 运行：bash diskwipe-iso/tests/run-all.sh（或单独 bash diskwipe-iso/tests/t3_init.sh）
# 安全约束（用户强要求，测试绝不触碰本机真实块设备/真实挂载）：
#   假 mount/modprobe/mdev 只把调用参数记录到 $ROOT/cmds.txt、绝不真挂载/真加载模块；
#   stub 环境里的 menu.sh 为假件（打印标记证明 exec 到了交互菜单）；init 经 INIT_PATH
#   接缝变量注入假件 PATH。
# 用例：
#   I1  正常：假 mount/modprobe/mdev 全部成功 → 输出含挂载 /proc /sys /dev；
#       modprobe 调用覆盖 DRIVE_MODULES 全部模块名；最后 exec menu.sh（假 menu.sh 打标记）
#   I2  modprobe 某模块（mpt3sas）失败 → 打印错误、停留在救援 shell（假 sh 打标记）、
#       不 exec menu.sh、不继续加载后续模块
#   I3  挂载 /sys 失败 → 打印错误、停留在救援 shell、不 exec menu.sh、不加载模块
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
    # init 现在会 source 同目录 lib.sh（dw_mount_log_media 等），必须一并拷入 stub
    cp "$LIB_SH" "$ROOT/stub/lib.sh"
    # 空 lsblk/blkid 假件：init 的 dw_mount_log_media 需要 lsblk/blkid 枚举日志介质；
    # stub 环境无 U 盘 → 返回空，走 DW_LOG_MEDIA=none 分支（防真实 lsblk 触碰本机设备）
    fake_bin lsblk '#!/bin/sh
exit 0'
    fake_bin blkid '#!/bin/sh
exit 2'
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
    # 假 mdev：记录调用到 cmds.txt
    fake_bin mdev '#!/bin/sh
[ -n "$ROOT" ] || exit 0
printf "mdev %s\n" "$*" >> "$ROOT/cmds.txt"
exit 0'
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

# 运行 stub 环境的 init（stdin 接 /dev/null 防挂起；假件经 INIT_PATH/PATH 注入）
run_init() {
    local outf="$1"
    shift
    INIT_PATH="$FAKE_BIN:$PATH" \
    PATH="$FAKE_BIN:$PATH" \
    bash "$ROOT/stub/init" "$@" > "$outf" 2>&1 < /dev/null
    LAST_RC=$?
    return 0
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
# USB 存储设备异步枚举：init 在 sleep 后进入重试循环（每轮 mdev -s + 探测）；
# stub 环境假 lsblk 恒空（无 U 盘）→ 3 轮重试 + 首扫 = mdev -s 共 4 次
check_cmd_count 'mdev -s' 4 '设备扫描应执行 4 次（首扫 1 + 日志介质重试 3 轮）'
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
cleanup_case

# ---------- I2：modprobe 某模块失败 ----------
CASE="I2 模块加载失败"
setup_stub
printf 'mpt3sas\n' > "$ROOT/modprobe.fail"
run_init "$OUTF"
check_rc 0 '失败后进入救援 shell，shell 退出后进程正常结束'
check_out 'ERROR: failed to load kernel module mpt3sas' '应打印模块加载失败错误'
check_out 'rescue shell' '应提示停留在救援 shell'
check_out 'RESCUE_SHELL_MARKER' '应进入救援 shell（假 sh 打标记）'
check_not_out 'MENU_EXEC_MARKER' '失败时不得 exec menu.sh'
check_cmds 'modprobe mpt3sas' '应尝试加载失败模块（记录在 cmds.txt）'
check_not_cmds 'modprobe virtio_blk' '失败后不得继续加载后续模块'
check_cmd_count 'mdev' 0 '模块加载失败后不得执行 mdev'
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

finish
