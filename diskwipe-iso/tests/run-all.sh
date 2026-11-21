#!/bin/bash
# diskwipe-iso 总测试入口：依次运行 t1~tN，任一失败整体非 0
# 运行：bash diskwipe-iso/tests/run-all.sh（本机 Git Bash）
set -u
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RC=0

for t in t1_wipe t2_menu t3_init t4_log; do
    echo
    echo "========== 运行 tests/${t}.sh =========="
    if bash "$TEST_DIR/$t.sh"; then
        echo "${t} ALL PASS"
    else
        echo "${t} FAILED"
        RC=1
    fi
done

echo
if [ "$RC" -eq 0 ]; then
    echo "==== 全部测试: ALL PASS ===="
else
    echo "==== 全部测试: FAIL（存在失败用例，详见上方输出）===="
fi
exit "$RC"
