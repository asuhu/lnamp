#!/bin/bash
# 运行全部冒烟测试套件
cd "$(dirname "$0")/.." || exit 1
# 测试隔离：logrotate 目录必须指到临时位置。setup_logrotate 默认写
# /etc/logrotate.d，跑一次测试就会把宿主机的 nginx 日志路径覆盖成临时前缀，
# 此后 logrotate 每天 stat failed、日志永不轮转（真机上已实际发生过）。
export LNAMP_LOGROTATE_DIR="${LNAMP_LOGROTATE_DIR:-$(mktemp -d)}"
rc=0
echo "########## smoke.sh (功能/URL/编排) ##########"
bash tests/smoke.sh || rc=1
echo; echo "########## smoke2.sh (分发/配置内容/OS/助手) ##########"
bash tests/smoke2.sh || rc=1
echo; echo "########## fetch_sim.sh (下载优先级 fetch) ##########"
bash tests/fetch_sim.sh || rc=1
echo; echo "########## newfn_sim.sh (备份/logrotate/干跑) ##########"
bash tests/newfn_sim.sh || rc=1
echo; echo "########## dryrun_sim.sh (端到端干跑 + 副作用审计) ##########"
bash tests/dryrun_sim.sh >/tmp/lnamp_dryrun_sim.log 2>&1 || rc=1
if grep -q '副作用审计通过' /tmp/lnamp_dryrun_sim.log 2>/dev/null; then
  echo "  副作用审计通过 (no side effects)"
else
  echo "  [FAIL] 干跑产生了真实副作用，见 /tmp/lnamp_dryrun_sim.log"
  rc=1
fi
echo; echo "=================================================="
[ "$rc" = 0 ] && echo "  ✅✅ 所有测试套件通过" || echo "  ❌ 有套件失败"
exit $rc
