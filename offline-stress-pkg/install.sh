#!/bin/bash
# install.sh —— 离线安装脚本（stress + dmidecode，Kylin V10 SP3，服务器无网络）
# 用法：sudo bash install.sh
# 退出码：0=成功（含已装同版本）；1=失败（非 root / 校验失败 / 安装失败）
# 测试接缝：INSTALL_SKIP_ROOT_CHECK=1 跳过 root 检查（仅本地测试用）

# 1. 解析自身目录并切换，保证任意位置调用
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
cd "$SCRIPT_DIR"

# 2. 安装清单：rpm 路径 | 锁定 SHA256 | 包名 | 已安装判定串（顺序即安装顺序）
#    dmidecode 用于自动探测内存条根数（/sys 与 EDAC 都不可用时仍可手动 --vm）
RPM_LIST=(
    "rpms/stress-1.0.4-24.el8.x86_64.rpm|0090571FD05C307DBE894E0FCF1E9804DBB27EA64D11A6D0248FFA61AE93EFDA|stress|stress-1.0.4-24.el8.x86_64"
    "rpms/dmidecode-3.2-10.el8.x86_64.rpm|CD2F140BD1718B4403AD66568155264B69231748A3C813E2FEAAC1B704DA62C6|dmidecode|dmidecode"
)

# 3. root 检查（非 root 且未跳过时退出）
if [ "$(id -u)" -ne 0 ] && [ "${INSTALL_SKIP_ROOT_CHECK:-}" != "1" ]; then
    echo "请以 root 运行：sudo bash install.sh"
    exit 1
fi

# 4. 文件存在检查（任一缺失整体退出，避免装一半）
missing=0
for entry in "${RPM_LIST[@]}"; do
    IFS='|' read -r rpm_file _rest <<< "$entry"
    if [ ! -f "$rpm_file" ]; then
        echo "RPM 文件不存在：$rpm_file，请重新拷贝"
        missing=1
    fi
done
[ "$missing" -eq 0 ] || exit 1

# 5. SHA256 完整性校验（任一不匹配整体退出）
for entry in "${RPM_LIST[@]}"; do
    IFS='|' read -r rpm_file locked_sha _rest <<< "$entry"
    if ! echo "$locked_sha  $rpm_file" | sha256sum -c - >/dev/null 2>&1; then
        echo "RPM 校验失败：$rpm_file，文件可能损坏，请重新拷贝"
        exit 1
    fi
done

# 6. 逐个安装（已装同版本则跳过；NOKEY 签名警告属正常现象，退出码判定成败）
for entry in "${RPM_LIST[@]}"; do
    IFS='|' read -r rpm_file _sha pkg expect <<< "$entry"
    if installed=$(rpm -q "$pkg" 2>/dev/null) && printf '%s\n' "$installed" | grep -q "$expect"; then
        echo "已安装：$installed"
        continue
    fi
    if rpm -Uvh "$rpm_file"; then
        echo "${pkg} 安装成功：$(rpm -q "$pkg")"
    else
        echo "安装失败：$rpm_file，请检查上方 rpm 输出"
        exit 1
    fi
done

echo "下一步运行 bash verify.sh"
exit 0
