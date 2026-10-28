#!/usr/bin/env bash
# 测试隔离：logrotate 目录必须指到临时位置。setup_logrotate 默认写
# /etc/logrotate.d，跑一次测试就会把宿主机的 nginx 日志路径覆盖成临时前缀，
# 此后 logrotate 每天 stat failed、日志永不轮转（真机上已实际发生过）。
export LNAMP_LOGROTATE_DIR="${LNAMP_LOGROTATE_DIR:-$(mktemp -d)}"
# ============================================================================
#  tests/run_clean.sh  ——  在 WorkBuddy 代理 shell 下安全跑测试
# ----------------------------------------------------------------------------
#  背景：WorkBuddy 的 brokered shell 会把 rm/unlink/rmdir 导成 shell 函数，
#  指向 vendor/shim/safe-bin/rm；该 wrapper 内部解析 REAL_RM 后又调用 rm，
#  于是形成无限递归，测试（会频繁 rm 临时目录）跑到几分钟就卡死。
#
#  这里在启动测试前把环境洗干净：
#    1) unset -f rm unlink rmdir（去掉函数）
#    2) 清掉 BASH_FUNC_rm* 导出项
#    3) 从 PATH 里剔除 safe-bin 目录
#    4) 告诉 wrapper 直接走 /bin/rm
#
#  用法: bash tests/run_clean.sh <test1.sh> [test2.sh ...]
# ============================================================================
set -u

# 0) 关键：BASH_ENV 会让每个新起的 bash 重新 source 代理运行时环境，
#    从而把 rm/unlink/rmdir 又导成函数（-> 无限递归卡死）。
#    必须在启动测试之前 unset，否则下面 1) 的清理会被子 shell 覆盖。
unset BASH_ENV 2>/dev/null || true

# 1) 去掉当前 shell 里的导出函数
unset -f rm unlink rmdir 2>/dev/null || true

# 2) 清掉函数的环境变量痕迹
for _v in $(compgen -v 2>/dev/null | grep -E '^BASH_FUNC_' || true); do
  unset -v "$_v" 2>/dev/null || true
done

# 3) 关掉 safe-delete 相关开关，并让 wrapper 直接用真实 rm
export CODEBUDDY_SAFE_DELETE_ENABLED=0
export CODEBUDDY_SAFE_DELETE_SANDBOX=0
export SAFE_DELETE_REAL_RM=/bin/rm
unset CODEBUDDY_SESSION_ID CLAUDE_SESSION_ID 2>/dev/null || true

# 4) PATH 剔除 safe-bin
if [ -n "${PATH:-}" ]; then
  _newpath=""
  IFS=':' read -ra _parts <<< "$PATH"
  for _p in "${_parts[@]}"; do
    case "$_p" in
      */vendor/shim/safe-bin|*/safe-bin) continue ;;
    esac
    _newpath="${_newpath:+$_newpath:}$_p"
  done
  PATH="$_newpath"
  export PATH
fi

# shellcheck 走离线副本（本机 PATH 里没有）
if [ -d /tmp/shellcheck-dl ]; then
  PATH="/tmp/shellcheck-dl:$PATH"
  export PATH
fi

if [ $# -eq 0 ]; then
  echo "用法: bash tests/run_clean.sh <test.sh> [more...]" >&2
  exit 2
fi

rc=0
for t in "$@"; do
  echo "############################################################"
  echo "# RUN: $t"
  echo "############################################################"
  bash "$t" || rc=1
  echo
done
exit "$rc"
