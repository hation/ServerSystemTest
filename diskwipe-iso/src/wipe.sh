#!/bin/sh
# diskwipe-iso 清除入口：wipe.sh <dev...>
#
# 逐盘调用 dw_wipe_disk（umount 全部子树挂载点 → wipefs -a 整盘 → wipefs -n 验证），
# 每盘打印「✓ 已恢复未初始化」或「✗ <原因>」；白名单校验失败打印原因跳过；
# 有失败/被拒绝盘退出 1；无参数打印用法并退出 1。逐盘独立：单盘失败不影响其他盘。
#
# POSIX/ash 兼容（initramfs 运行时只有 busybox ash）；LF 行尾。
# 用法示例：wipe.sh sda sdb

. "$(dirname "$0")/lib.sh"

if [ "$#" -eq 0 ]; then
    echo "用法：wipe.sh <设备...>（例：wipe.sh sda sdb；白名单：sd[a-z]/nvme[0-9]n[0-9]/vd[a-z]/mmcblk[0-9]）" >&2
    exit 1
fi

fails=""
rc=0
for dev in "$@"; do
    if ! dw_dev_ok "$dev"; then
        echo "✗ 非白名单设备，跳过：$dev"
        rc=1
        continue
    fi
    if ! dw_wipe_disk "$dev"; then
        rc=1
        fails="${fails:+$fails }$dev"
    fi
done

if [ "$rc" -ne 0 ]; then
    [ -n "$fails" ] && echo "清除失败盘：$fails"
    exit 1
fi
exit 0
