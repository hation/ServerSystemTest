#!/bin/bash
# kylin-kernel-export.sh —— 在 Kylin 服务器上一键提取内核材料，打包供 diskwipe-iso 构建
# 用法：把本脚本拷到 Kylin 服务器任意目录，执行：
#     bash kylin-kernel-export.sh [输出目录]
# 默认输出 /tmp/kylin-src-<日期>.tar.gz；把该 tar.gz 拷到 U 盘/共享目录传回本机即可。
set -u

OUT="${1:-/tmp}"
STAMP="$(date +%Y%m%d)"
KVER="$(uname -r)"
DST="$OUT/kylin-src"
TARBALL="$OUT/kylin-src-$STAMP.tar.gz"

echo "==== Kylin 内核材料一键导出 ===="
echo "内核版本: $KVER"
echo "输出目录: $OUT"
echo

# 1) 内核 vmlinuz（boot/）
mkdir -p "$DST/boot"
if ls /boot/vmlinuz-* >/dev/null 2>&1; then
    cp -a /boot/vmlinuz-* "$DST/boot/"
    echo "[1/5] vmlinuz 已提取：$(ls "$DST/boot")"
else
    echo "[1/5] 警告：/boot 下未找到 vmlinuz-*（请检查内核安装）"
fi

# 2) Kylin dracut initramfs（boot/，diskwipe-iso 对比测试/兼容构建用）
if ls /boot/initramfs-*.img >/dev/null 2>&1; then
    cp -a /boot/initramfs-*.img "$DST/boot/"
    echo "[2/5] initramfs 已提取：$(ls "$DST/boot" | grep initramfs)"
else
    echo "[2/5] 警告：/boot 下未找到 initramfs-*.img（跳过）"
fi

# 3) 当前内核模块（modules/）
mkdir -p "$DST/modules"
if [ -d "/lib/modules/$KVER" ]; then
    cp -a "/lib/modules/$KVER" "$DST/modules/"
    echo "[3/5] 内核模块已提取：$DST/modules/$KVER"
else
    echo "[3/5] 警告：/lib/modules/$KVER 不存在"
fi

# 4) 固件（firmware/，可选但建议——含 CPU 微码/磁盘控制器固件）
mkdir -p "$DST/firmware"
if [ -d /lib/firmware ] && [ -n "$(ls /lib/firmware 2>/dev/null)" ]; then
    cp -a /lib/firmware/. "$DST/firmware/"
    echo "[4/5] 固件已提取（可能较大）"
else
    echo "[4/5] 无 /lib/firmware，跳过（可选）"
fi

# 5) 打包
echo
echo "[5/5] 打包中..."
tar -czf "$TARBALL" -C "$OUT" kylin-src 2>/dev/null || {
    tar -czf "$TARBALL" -C "$(dirname "$DST")" "$(basename "$DST")" 2>/dev/null
}
echo
echo "==== 完成 ===="
echo "产物：$TARBALL"
ls -lh "$TARBALL"
echo
echo "下一步：把该 tar.gz 拷到 U 盘（或共享目录）传回本机，"
echo "并告知文件路径（如 c:\\xxx\\kylin-src-20261122.tar.gz），我将继续处理构建。"
