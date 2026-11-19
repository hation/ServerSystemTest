#!/bin/bash
# mount-iso.sh —— U盘挂载 + yum 源构建/复制/配置 一键脚本（Kylin V10 SP3，无外网服务器）
# 用法：
#   bash mount-iso.sh build [--rpm-dir /path/to/rpms]   # 构建 yum 源（createrepo 生成 repodata）
#   bash mount-iso.sh mount                              # 一键：U盘挂载 → 复制源目录到 /opt/kylin-repo → 配置本地yum源
#   bash mount-iso.sh status                             # 查看挂载与本地源状态
#   bash mount-iso.sh umount                             # 卸载U盘（确认后执行；不影响已复制的本地源）
# 环境变量（测试接缝）：
#   DRY_RUN=1          只打印执行计划，不执行任何写操作（跳过交互确认）
#   SKIP_ROOT_CHECK=1  跳过 root 检查（仅本地测试用）
#   LSBLK_BIN          块设备查询命令（默认 lsblk，测试可用伪造输出）
#   CREATEREPO_BIN     createrepo 命令（默认 createrepo，测试可用伪造）
#   MOUNT_LOG          操作日志路径（默认 /root/stress-test/mount.log）
#   USB_MOUNT_POINT    U盘挂载点（默认 /mnt/usb）
#   REPO_DEST          源目录复制/构建目标（默认 /opt/kylin-repo）
#   YUM_REPO_FILE      本地源repo文件（默认 /etc/yum.repos.d/kylin-local.repo）
#   PKG_RPMS_DIR       包内RPM目录（默认脚本同目录 rpms/）
# 退出码：0=正常（含取消/DRY_RUN 计划）；1=用法错误/前置不满足/无 USB 盘/RPM 或 repodata 缺失
# 说明：全程不 set -e；系统盘（df / 所在盘）任何分支硬排除；每步操作写 MOUNT_LOG。

DRY_RUN="${DRY_RUN:-0}"
SKIP_ROOT_CHECK="${SKIP_ROOT_CHECK:-0}"
MOUNT_LOG="${MOUNT_LOG:-/root/stress-test/mount.log}"
LSBLK_BIN="${LSBLK_BIN:-lsblk}"
CREATEREPO_BIN="${CREATEREPO_BIN:-createrepo}"
USB_MOUNT_POINT="${USB_MOUNT_POINT:-/mnt/usb}"
REPO_DEST="${REPO_DEST:-/opt/kylin-repo}"
YUM_REPO_FILE="${YUM_REPO_FILE:-/etc/yum.repos.d/kylin-local.repo}"
PKG_RPMS_DIR="${PKG_RPMS_DIR:-$(dirname "$0")/rpms}"

now() { date '+%Y-%m-%d %H:%M:%S'; }

usage() {
    cat <<EOF
用法:
  bash mount-iso.sh build [--rpm-dir /path/to/rpms]   # 构建 yum 源（createrepo 生成 repodata）
  bash mount-iso.sh mount                              # 一键：U盘挂载 → 复制源目录到 $REPO_DEST → 配置本地yum源
  bash mount-iso.sh status                             # 查看挂载与本地源状态
  bash mount-iso.sh umount                             # 卸载U盘（确认后执行；不影响已复制的本地源）

build 的 RPM 来源优先级：U盘内（已挂载且含 *.rpm） > --rpm-dir > 包内 rpms/
复制目标：$REPO_DEST（默认 /opt/kylin-repo）；U 盘已挂载时另写一份 $USB_MOUNT_POINT/kylin-repo

测试接缝（本地测试用）:
  DRY_RUN=1           只打印计划不执行（跳过交互确认）
  SKIP_ROOT_CHECK=1   跳过 root 检查
  LSBLK_BIN           块设备查询命令（默认 lsblk，测试可伪造）
  CREATEREPO_BIN      createrepo 命令（默认 createrepo，测试可伪造）
  MOUNT_LOG           操作日志路径（默认 /root/stress-test/mount.log）
  USB_MOUNT_POINT     U盘挂载点（默认 /mnt/usb）
  REPO_DEST           源目录复制/构建目标（默认 /opt/kylin-repo）
  YUM_REPO_FILE       本地源repo文件（默认 /etc/yum.repos.d/kylin-local.repo）
  PKG_RPMS_DIR        包内RPM目录（默认脚本同目录 rpms/）
EOF
}

root_check() {
    if [ "$SKIP_ROOT_CHECK" != "1" ] && [ "$(id -u)" -ne 0 ]; then
        echo "请以 root 运行：sudo bash mount-iso.sh"
        exit 1
    fi
}
PKG_DIR="$(cd "$(dirname "$0")" && pwd)"
for _lib in mount-iso-lib-usb mount-iso-lib-repo mount-iso-lib-commands; do
    if [ -f "$PKG_DIR/$_lib.sh" ]; then
        source "$PKG_DIR/$_lib.sh"
    else
        echo "缺少模块文件：$PKG_DIR/$_lib.sh"; exit 1
    fi
done

# ---------- 子命令分发 ----------

CMD="${1:-}"
shift || true
case "$CMD" in
    build)   cmd_build "$@" ;;
    mount)   cmd_mount "$@" ;;
    status)  cmd_status ;;
    umount)  cmd_umount ;;
    *) usage; exit 1 ;;
esac
