#!/bin/bash
# 运行全部冒烟测试套件
cd "$(dirname "$0")/.." || exit 1
rc=0
echo "########## smoke.sh (功能/URL/编排) ##########"
bash tests/smoke.sh || rc=1
echo; echo "########## smoke2.sh (分发/配置内容/OS/助手) ##########"
bash tests/smoke2.sh || rc=1
echo; echo "=================================================="
[ "$rc" = 0 ] && echo "  ✅✅ 所有测试套件通过" || echo "  ❌ 有套件失败"
exit $rc
