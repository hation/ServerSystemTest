#!/bin/bash
# install.sh —— stress 离线安装脚本（Kylin V10 SP3，服务器无网络）
# 用法：sudo bash install.sh
# 退出码：0=成功（含已装同版本）；1=失败（非 root / 校验失败 / 安装失败）
# 测试接缝：INSTALL_SKIP_ROOT_CHECK=1 跳过 root 检查（仅本地测试用）

# 1. 解析自身目录并切换，保证任意位置调用
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
cd "$SCRIPT_DIR"

RPM_FILE="rpms/stress-1.0.4-24.el8.x86_64.rpm"
LOCKED_SHA256="0090571FD05C307DBE894E0FCF1E9804DBB27EA64D11A6D0248FFA61AE93EFDA"

# 2. root 检查（非 root 且未跳过时退出）
if [ "$(id -u)" -ne 0 ] && [ "${INSTALL_SKIP_ROOT_CHECK:-}" != "1" ]; then
    echo "请以 root 运行：sudo bash install.sh"
    exit 1
fi

# 3. 文件存在检查
if [ ! -f "$RPM_FILE" ]; then
    echo "RPM 文件不存在：$RPM_FILE，请重新拷贝"
    exit 1
fi

# 4. SHA256 完整性校验
if ! echo "$LOCKED_SHA256  $RPM_FILE" | sha256sum -c - >/dev/null 2>&1; then
    echo "RPM 校验失败，文件可能损坏，请重新拷贝"
    exit 1
fi

# 5. 已安装同版本检查（命中则提前退出）
if rpm -q stress >/dev/null 2>&1; then
    if rpm -q stress 2>/dev/null | grep -q "1.0.4-24.el8"; then
        echo "已安装"
        exit 0
    fi
fi

# 6. 安装（NOKEY 签名警告属正常现象，不视为错误；退出码判定成败）
if rpm -Uvh "$RPM_FILE"; then
    echo "stress 安装成功：$(rpm -q stress)"
    echo "下一步运行 bash verify.sh"
    exit 0
else
    echo "安装失败，请检查上方 rpm 输出"
    exit 1
fi
