#!/bin/sh
# diskwipe-iso 一键构建入口（Windows Git Bash；构建逻辑在 WSL Ubuntu 内执行）。
# 用法：bash diskwipe-iso/build.sh [kylin|ubuntu|auto]
#   可选参数指定内核模式（默认 auto）：
#     auto   自动检测——diskwipe-iso/kylin-src/boot/vmlinuz-4.19* 存在即用 Kylin 内核
#            （v1.4.0：Kylin 内核模式，解决 Ubuntu 内核与该海光服务器 USB 不兼容启动卡死）
#     kylin  强制用 Kylin 内核（kylin-src/ 材料，须已解压于 diskwipe-iso/kylin-src/）
#     ubuntu 强制用 WSL Ubuntu generic 内核
# 流程：检测 WSL（wsl -l -v 含 Ubuntu；缺失则打印安装指引退出 1）→ 经
#       `wsl -e bash -c` 加载 build-lib.sh 执行构建（apt 依赖→组装 rootfs→cpio
#       initrd→引导文件(BIOS ISOLINUX + UEFI 精简 GRUB)→xorriso 打包双引导 iso→isoinfo 校验）
#       → 产物 output/diskwipe-v<版本>.iso。
# 安全：构建只产出 iso 文件（全部在 WSL 虚拟盘文件系统 + output/ 内），
#       绝不写任何真实块设备（本机物理盘零接触）。
# 任何一步失败 → build-lib 打印「✗ ...」并以非 0 退出，本入口原样透传退出码（不静默）。

set -u

me_dir="$(cd "$(dirname "$0")" && pwd)" || { echo "✗ 无法定位脚本所在目录" >&2; exit 1; }

# 可选内核模式参数（透传给 WSL 内 build-lib.sh 的 DW_KERNEL_MODE）
mode="${1:-auto}"
case "$mode" in
auto|ubuntu|kylin) ;;
*) echo "✗ 未知内核模式：$mode（应为 auto|ubuntu|kylin）" >&2; exit 1 ;;
esac
export DW_KERNEL_MODE="$mode"

# 1) 检测 WSL Ubuntu（wsl -l -v 输出为 UTF-16，需先去除 NUL 再 grep）
if ! wsl -l -v 2>/dev/null | tr -d '\0' | grep -qi ubuntu; then
    cat >&2 <<'EOF'
✗ 未检测到 WSL Ubuntu 发行版，无法构建。
安装指引：
  1. 以管理员身份打开 PowerShell，执行：wsl --install -d Ubuntu-24.04
  2. 首次启动时创建 Linux 用户；随后执行 sudo visudo，在文件末尾追加一行：
       <用户名> ALL=(ALL) NOPASSWD: ALL
     （本构建在 WSL 内 apt 安装依赖需要免密 sudo）
  3. 重新运行：bash diskwipe-iso/build.sh
EOF
    exit 1
fi
echo "✓ 检测到 WSL Ubuntu，开始构建（首次需下载 apt 包，耗时数分钟；重跑幂等）..."

# 2) 进入脚本目录后经 WSL 执行构建（WSL 进程继承当前目录 → /mnt/c/.../diskwipe-iso）
#    MSYS_NO_PATHCONV：防止 Git Bash 把 /mnt 形式参数误当作 Windows 路径转换
cd "$me_dir" || exit 1
MSYS_NO_PATHCONV=1 wsl -e bash -c '
set -u
proj="$PWD"
[ -f "$proj/VERSION" ] || { echo "✗ WSL 内未定位到项目目录（pwd=$proj）" >&2; exit 1; }
. "$proj/build-lib.sh" || { echo "✗ 加载 build-lib.sh 失败" >&2; exit 1; }
dw_build_iso "$proj"
'
rc=$?
if [ "$rc" -ne 0 ]; then
    echo "✗ 构建失败（退出码 $rc），见上方错误输出。" >&2
    exit "$rc"
fi
echo "✓ 构建完成。ISO：$me_dir/output/diskwipe-v$(tr -d '\r\n ' < "$me_dir/VERSION").iso"
