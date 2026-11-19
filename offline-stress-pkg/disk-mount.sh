#!/bin/bash
# disk-mount.sh —— 挂载辅助脚本（Kylin V10 SP3，硬盘压测前挂载测试盘）
# 用法：
#   bash disk-mount.sh list                     # 列出块设备，标出系统盘与分区/挂载状态
#   bash disk-mount.sh mount [--disks sdb,sdc] [--yes] [--rebuild] [--dry-run]
#                                               # 逐盘选择→计划确认→挂载到 /mnt/HDDxx（--yes 跳过 y 确认）
#   bash disk-mount.sh umount [--all]           # 卸载全部已挂载测试盘（--all 跳过确认）
# 环境变量（测试接缝）：
#   DRY_RUN=1          只打印执行计划，不执行任何写操作（含不写 mount.log）
#   SKIP_ROOT_CHECK=1  跳过 root 检查（仅本地测试用）
#   MOUNT_LOG          挂载日志路径（默认 /root/stress-test/mount.log）
#   LSBLK_BIN          块设备查询命令（默认 lsblk，测试可用伪造输出）
#   BLKID_BIN          文件系统探测命令（默认 blkid，测试可用伪造输出）
#   PARTED_BIN/PARTPROBE_BIN/UDEVADM_BIN/MKFS_BIN/MOUNT_BIN/UMOUNT_BIN/DF_BIN
#                      写操作与 df 命令接缝（默认同名系统命令）
# 退出码：0=全部成功（含取消/无需操作）；1=用法/前置错误、含系统盘、存在跳过或失败盘
# 说明：全程不 set -e；系统盘（df / 所在盘）任何分支硬跳过；每步操作写 mount.log。
#       默认模式不清盘：有分区→测首个分区；无分区→测整盘；仅 --rebuild 才重建分区表。

PKG_DIR="$(cd "$(dirname "$0")" && pwd)"
DRY_RUN="${DRY_RUN:-0}"
SKIP_ROOT_CHECK="${SKIP_ROOT_CHECK:-0}"
MOUNT_LOG="${MOUNT_LOG:-/root/stress-test/mount.log}"
LSBLK_BIN="${LSBLK_BIN:-lsblk}"
BLKID_BIN="${BLKID_BIN:-blkid}"
PARTED_BIN="${PARTED_BIN:-parted}"
PARTPROBE_BIN="${PARTPROBE_BIN:-partprobe}"
UDEVADM_BIN="${UDEVADM_BIN:-udevadm}"
MKFS_BIN="${MKFS_BIN:-mkfs.ext4}"
MOUNT_BIN="${MOUNT_BIN:-mount}"
UMOUNT_BIN="${UMOUNT_BIN:-umount}"
DF_BIN="${DF_BIN:-df}"

REBUILD=0

for _lib in disk-mount-lib-detect disk-mount-lib-plan disk-mount-lib-commands; do
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
    list)   cmd_list ;;
    mount)  cmd_mount "$@" ;;
    umount) cmd_umount "$@" ;;
    *) usage; exit 1 ;;
esac
