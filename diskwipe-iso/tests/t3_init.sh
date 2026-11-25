#!/bin/bash
# T3：diskwipe-iso initramfs 启动脚本（src/init）假件单测
# 覆盖：src/init 的启动编排——挂载 /proc /sys /dev → busybox modprobe 白名单磁盘驱动 →
#       mdev -s 扫描设备 → sleep 10（v1.5.7：去掉重试 mdev 轮询；v1.5.10：加长等待——
#       mpt3sas SAS 盘扫描需数秒；v1.5.11：再加长到 25——真机 SAS 盘从驱动加载到 lsblk
#       可枚举约需 25 秒；v1.5.13：缩短回 10——盘是否就绪由 menu 无盘无限重试兜底）
#       → exec menu.sh
#       （v1.5.8：exec 前后 kmsg 诊断 + 失败兜底救援 shell）。
# v1.5.6 语义：进度走 /dev/kmsg（dw_progress 写内核 printk 通道，与内核日志混排）+
#   timeout 5 兜底（假件转执行）；显卡循环只加载 ast（mgag200/smifb/bochs-drm/cirrus/
#   virtio-gpu 在无对应硬件时 modprobe 可能内核 D 状态挂起导致 init 卡死，真机实证）；
#   仅挂载失败进入救援 shell；模块加载/mdev 失败仅 WARN 继续（不 rescue，保证到菜单）。
# v1.5.8 适配：Kylin ky10 分支去掉 uas（I5 用例：uas 不得加载；usb-storage 仍加载）；
#   exec 段诊断（I1 断言 exec menu.sh 进度行；I6 用例：exec 失败兜底救援 shell）。
# v1.5.9 适配：Kylin ky10 分支再去掉 usb-storage（I5 用例：usb-storage 不得加载——
#   真机 U 盘绑定后读盘触发内核 I/O 阻塞致系统整体停滞；U 盘不绑定则系统正常启动，
#   USB 键盘走内建 usbhid 不受影响；退出写日志 U 盘降级留内存）。
# v1.5.10 适配：settle wait sleep 3 → 10（I1 用例断言 sleep 10；stub 加假 sleep 立即返回、
#   记录调用——不真等 10s，同假 timeout 既有模式）。
# v1.5.11 适配：显卡循环（ast）后新增 HID 驱动保障——`dw_progress "loading HID drivers
#   (usbhid)"` + `timeout 5 modprobe usbhid 2>/dev/null`（真机 KVM USB 键盘需 usbhid；
#   Kylin 内核 CONFIG_USB_HID=y 内建，modprobe 静默跳过无碍）。I1 断言 kmsg 进度行 +
#   modprobe usbhid 调用 + 顺序（ast 之后、mdev -s 之前）；I5（ky10）同样断言 usbhid 调用。
#   本版 settle wait 加长（sleep 10 → 25，I1 断言 sleep 25——真机 SAS 盘从驱动加载到
#   lsblk 可枚举约需 25 秒）。
# v1.5.13 适配：settle wait 缩短回 10（I1 断言 sleep 10——SAS 盘扫描数秒即可，盘是否
#   就绪由 menu 无盘无限重试兜底，等待煎熬缩短）。
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
#       "diskwipe-init: device scan (mdev -s)" / "diskwipe-init: exec menu.sh"（kmsg 进度载荷）；
#       modprobe 调用覆盖 DRIVE_MODULES 全部模块名 + ast，且**不含** mgag200/smifb/bochs-drm/
#       cirrus/virtio-gpu（显卡循环只留 ast）；stdout 不含 "diskwipe-init:"（进度不打 console）；
#       最后 exec menu.sh（假 menu.sh 打标记）
#   I2  modprobe 某模块（mpt3sas）失败 → 打印 WARN 继续加载后续模块、不 rescue、
#       最终 exec menu.sh（v1.5.5：失败不再 init_rescue）
#   I3  挂载 /sys 失败 → 打印错误、停留在救援 shell、不 exec menu.sh、不加载模块
#       （init_rescue 语义仅保留给 mount）
#   I4  mdev -s 失败 → 打印 WARN 继续（不 rescue）、最终 exec menu.sh
#   I5  Kylin ky10 模式（假 uname 返回 4.19.90 ...ky10）：走 *ky10* 分支白名单——
#       uas 不得加载（v1.5.8 去掉）、usb-storage 不得加载（v1.5.9 去掉）、vfat/fat 等
#       ky10 清单模块加载、exec 正常
#   I6  exec menu.sh 失败（假 menu.sh 去掉执行位）：POSIX 语义下 exec 失败 shell 直接
#       以 126 退出（|| 兜底不可达——bash/dash/busybox ash 实证一致）；断言 exec 前的
#       kmsg 诊断行已先打（定位"exec 前卡住"才是诊断价值所在）
set -u
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
trap 'rc=$?; cleanup_case; exit "$rc"' EXIT

INIT_SH="$REPO_ROOT/diskwipe-iso/src/init"
# 与 src/init 内 DRIVE_MODULES 常量保持一致（Ubuntu 模式清单——本机 Git Bash uname 非 ky10，
# 测试默认走 Ubuntu 分支；ky10 分支白名单见 I5 用例，v1.5.8 起不含 uas）
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
    # 假 sleep：v1.5.10/1.5.11 settle wait（10s → 25s）→ v1.5.13 缩短回 10s——记录调用到
    # cmds.txt 并立即返回（同假 timeout 既有模式，不真等；供 I1 断言 sleep 10）
    fake_bin sleep '#!/bin/sh
[ -n "$ROOT" ] || exit 0
printf "sleep %s\n" "$*" >> "$ROOT/cmds.txt"
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
check_cmds 'sleep 10' 'settle wait 应等待 10s（v1.5.13 缩短：SAS 盘扫描数秒即可，盘是否就绪由 menu 无盘无限重试兜底）'
check_kmsg 'diskwipe-init: exec menu.sh' 'kmsg exec menu.sh 诊断行（v1.5.8）'
# v1.5.6 显卡循环只留 ast：modprobe 调用含 ast、不含其余 5 个显卡驱动
check_cmds 'modprobe ast' '应加载 ast（显卡循环白名单唯一）'
for gv in mgag200 smifb bochs-drm cirrus virtio-gpu; do
    check_not_cmds "modprobe $gv" "不得加载 $gv（无对应硬件时 D 状态挂起致 init 卡死，真机实证）"
done
# v1.5.11：HID 驱动保障（显卡循环后加载 usbhid——真机 KVM USB 键盘需 usbhid 才能输入）
check_cmds 'modprobe usbhid' '应加载 usbhid（v1.5.11 HID 驱动保障）'
check_kmsg 'diskwipe-init: loading HID drivers (usbhid)' 'kmsg HID 进度行（v1.5.11）'
if awk '/^modprobe ast$/{a=NR} /^modprobe usbhid$/{u=NR} /^mdev -s$/{m=NR} END{exit (a&&u&&m&&a<u&&u<m)?0:1}' "$ROOT/cmds.txt"; then
    _pass 'usbhid 在显卡循环（ast）之后、mdev -s 之前'
else
    _fail 'usbhid 应在 ast 之后、mdev -s 之前'
fi
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

# ---------- I5：Kylin ky10 模式（v1.5.8 去掉 uas；v1.5.9 再去掉 usb-storage） ----------
CASE="I5 Kylin ky10 模式去掉 uas/usb-storage"
setup_stub
# 假 uname：返回 Kylin 4.19 ky10 版本串 → init 的 case *ky10* 分支生效
fake_bin uname '#!/bin/sh
echo "4.19.90-89.11.v2401.ky10.x86_64"'
run_init "$OUTF"
check_rc 0 'ky10 模式正常启动应退出 0'
check_out 'MENU_EXEC_MARKER' 'ky10 模式最终应 exec menu.sh'
# ky10 白名单（v1.5.9 起不含 usb-storage；virtio_pci/xhci_pci/scsi_mod/exfat/ntfs3 为内建/无模块，不加载）
for m in ahci libahci libata nvme nvme-core mpt3sas megaraid_sas virtio_blk sd_mod nls_iso8859-1 vfat fat; do
    check_cmds "modprobe $m" "ky10 模式应加载模块 $m"
done
check_not_cmds 'modprobe uas' 'ky10 模式不得加载 uas（v1.5.8：UAS 绑定 U 盘可能 D 状态卡死）'
check_not_cmds 'modprobe usb-storage' 'ky10 模式不得加载 usb-storage（v1.5.9：U 盘绑定读盘触发内核 I/O 阻塞致系统整体停滞）'
check_not_cmds 'modprobe virtio_pci' 'ky10 模式不得加载 virtio_pci（Kylin 内核内建）'
check_not_cmds 'modprobe xhci_pci' 'ky10 模式不得加载 xhci_pci（Kylin 内核内建）'
# v1.5.11：usbhid 在 ky10 模式同样加载（显卡循环后独立 modprobe，不属 DRIVE_MODULES 白名单）
check_cmds 'modprobe usbhid' 'ky10 模式应加载 usbhid（v1.5.11 HID 驱动保障）'
check_kmsg 'diskwipe-init: exec menu.sh' 'ky10 模式 exec menu.sh 诊断行（v1.5.8）'
cleanup_case

# ---------- I6：exec menu.sh 失败（v1.5.8：exec 前诊断行先打） ----------
# POSIX 语义实证（WSL dash/busybox ash/bash 一致）：exec 失败 → shell 立即以 126/127
# 退出，`exec ... || { ... }` 兜底不可达（源码按 brief 保留该兜底，防御性）；
# 本用例断言真实行为：exec 前 kmsg 诊断行已打 + 进程以 126 退出 + 未进入菜单。
CASE="I6 exec menu.sh 失败（诊断行先打）"
setup_stub
chmod -x "$ROOT/stub/menu.sh"
run_init "$OUTF"
check_rc 126 'exec 失败 shell 以 126 退出（POSIX exec 语义，|| 兜底不可达）'
check_kmsg 'diskwipe-init: exec menu.sh' 'exec 前 kmsg 诊断行已先打（定位 exec 前卡点）'
check_not_out 'MENU_EXEC_MARKER' 'exec 失败不得进入菜单'
cleanup_case

finish
