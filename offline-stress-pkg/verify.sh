#!/bin/bash
# verify.sh —— stress 安装验证脚本（Kylin V10 SP3，服务器无网络）
# 用法：bash verify.sh
# 退出码：0=全部通过（PASS）；1=任一检查失败（FAIL）
# 环境变量：VERIFY_SKIP_SMOKE=1 跳过冒烟压测（对应检查输出 SKIP）

# 1. 解析自身目录并切换，保证任意位置调用（与 install.sh 保持一致风格）
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
cd "$SCRIPT_DIR"

EXPECTED_RPM_QUERY="stress-1.0.4-24.el8.x86_64"
EXPECTED_VERSION="1.0.4"
SMOKE_CMD="stress --cpu 2 --vm 1 --vm-bytes 256M --timeout 10"

# 汇总标记：1=全过；0=存在失败（不使用 set -e，缺失命令也走 FAIL 分支）
ALL_PASS=1

# 2. 检查 A：rpm -q stress 输出精确匹配（rpm 缺失时 grep 收到空输入 → FAIL，不崩溃）
if rpm -q stress 2>/dev/null | grep -qx "$EXPECTED_RPM_QUERY"; then
    echo "PASS 检查A：rpm -q stress 输出为 $EXPECTED_RPM_QUERY"
else
    echo "FAIL 检查A：rpm -q stress 输出非 $EXPECTED_RPM_QUERY（未安装或版本不符，请先运行 bash install.sh）"
    ALL_PASS=0
fi

# 3. 检查 B：stress --version 输出包含 1.0.4（stress 缺失时提示符信息无法匹配 → FAIL，不崩溃）
if stress --version 2>&1 | grep -q "$EXPECTED_VERSION"; then
    echo "PASS 检查B：stress --version 输出包含 $EXPECTED_VERSION"
else
    echo "FAIL 检查B：stress --version 输出不包含 $EXPECTED_VERSION（未安装或版本不符，请先运行 bash install.sh）"
    ALL_PASS=0
fi

# 4. 检查 C：冒烟压测（VERIFY_SKIP_SMOKE=1 时跳过并输出 SKIP）
if [ "${VERIFY_SKIP_SMOKE:-}" = "1" ]; then
    echo "SKIP 检查C：VERIFY_SKIP_SMOKE=1，跳过冒烟压测"
elif $SMOKE_CMD >/dev/null 2>&1; then
    echo "PASS 检查C：冒烟压测（$SMOKE_CMD）退出码 0"
else
    echo "FAIL 检查C：冒烟压测（$SMOKE_CMD）退出码非 0"
    ALL_PASS=0
fi

# 5. 检查 D：dmidecode 可用性（用于自动探测内存条根数；缺失只告警，不判 FAIL）
#    EDAC（/sys/devices/system/edac/mc）是内核接口而非软件包，不在此校验。
if command -v dmidecode >/dev/null 2>&1; then
    echo "PASS 检查D：dmidecode 可用（$(dmidecode -V 2>/dev/null || echo 版本未知)）"
else
    echo "WARN 检查D：未找到 dmidecode，start mem/combo 将回退 EDAC，仍不可用时会给出手动 --vm 的建议命令"
fi

# 6. 汇总：全部 PASS → 输出 PASS 退出 0；任一 FAIL → 输出 FAIL 退出 1
if [ "$ALL_PASS" -eq 1 ]; then
    echo "PASS"
    exit 0
else
    echo "FAIL"
    exit 1
fi
