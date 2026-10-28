#!/usr/bin/env bash
# 测试隔离：logrotate 目录必须指到临时位置。setup_logrotate 默认写
# /etc/logrotate.d，跑一次测试就会把宿主机的 nginx 日志路径覆盖成临时前缀，
# 此后 logrotate 每天 stat failed、日志永不轮转（真机上已实际发生过）。
export LNAMP_LOGROTATE_DIR="${LNAMP_LOGROTATE_DIR:-$(mktemp -d)}"
# ============================================================================
#  fetch() 下载优先级仿真测试
#  直接加载真实的 lib/common.sh 中的 fetch()，用 stub 的 wget 精确验证：
#     1) 本地缓存 LNAMP_CACHE / <installer>/packages
#     2) 官方源 ($@ 顺序)
#     3) MIRROR_PRIMARY/third  与 /third/so/
#     4) MIRROR_FALLBACK/ftp    与 /ftp/so/
#  注：每个场景使用独立的输出文件名，避免反复删除同一路径。
# ============================================================================
set -u

LNAMP_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# ---- 加载真实的 log 函数与 fetch()（避免 source 整个 common.sh 触发副作用）
eval "$(sed -n '/^_c()/,/^log_err()/p' "${LNAMP_ROOT}/lib/common.sh")"
eval "$(sed -n '/^fetch()/,/^}/p' "${LNAMP_ROOT}/lib/common.sh")"

# 本测试只 eval 了 fetch() 函数体，没加载 common.sh 顶部的 DRY_RUN 全局，
# 而 fetch() 内部会引用它 —— 必须在这里定义，否则 set -u 下会静默退出。
DRY_RUN="${DRY_RUN:-0}"

# ---- 镜像地址取自真实的 versions.conf（安装器里也是先 source 它）
MIRROR_PRIMARY="$(sed -n 's/^MIRROR_PRIMARY="\(.*\)"$/\1/p'    "${LNAMP_ROOT}/versions.conf")"
MIRROR_FALLBACK="$(sed -n 's/^MIRROR_FALLBACK="\(.*\)"$/\1/p' "${LNAMP_ROOT}/versions.conf")"
export MIRROR_PRIMARY MIRROR_FALLBACK

MP="${MIRROR_PRIMARY}"
MF="${MIRROR_FALLBACK}"
WORK="/tmp/fetchsim.$$"
mkdir -p "$WORK"

# ---- stub wget：用 MOCK_WGET_FAIL 控制哪些 URL 失败
MOCK_WGET_FAIL=""
MOCK_WGET_LOG=""

wget() {
  local url="${!#}"
  MOCK_WGET_LOG+="${url}"$'\n'
  if printf '%s\n' "$MOCK_WGET_FAIL" | grep -qxF "$url"; then
    return 1
  fi
  # 成功：把 URL 写进输出文件(模拟下载到内容)
  local prev="" a
  for a in "$@"; do
    if [ "$prev" = "-O" ]; then echo "PAYLOAD_FROM:${url}" > "$a"; fi
    prev="$a"
  done
  return 0
}

PASS=0; FAIL=0
SC=0
t() { printf '\n--- %s\n' "$*"; }

chk() { # chk <desc> <expected> <actual>
  if [ "$2" = "$3" ]; then
    printf '  [PASS] %s\n' "$1"; PASS=$((PASS+1))
  else
    printf '  [FAIL] %s\n         期望: %s\n         实际: %s\n' "$1" "$2" "$3"
    FAIL=$((FAIL+1))
  fi
}

used() { printf '%s' "$MOCK_WGET_LOG" | grep -v '^$' | tail -1; }

# 每个场景一个独立输出文件名（fetch 的缓存/镜像 URL 都基于 basename 构造）
new_out() { SC=$((SC+1)); printf '%s/pkg%02d.tar.gz' "$WORK" "$SC"; }

run_fetch() { # run_fetch <out> <url...>
  local out="$1"; shift
  MOCK_WGET_LOG=""
  fetch "$out" "$@" >/dev/null 2>&1
}

# ================================================================ 场景
printf '===============================================================================\n'
printf '  fetch() 下载优先级仿真测试 (wget stubbed, 真实 fetch())\n'
printf '  MIRROR_PRIMARY=%s\n' "$MP"
printf '  MIRROR_FALLBACK=%s\n' "$MF"
printf '===============================================================================\n'

# 场景 1：官方源可用 -> 必须用官方，且只尝试第一个官方 URL
t "场景1 官方源可用时优先官方"
MOCK_WGET_FAIL=""
O="$(new_out)"
run_fetch "$O" "http://nginx.org/download/nginx-1.30.6.tar.gz"
chk "命中官方源" "http://nginx.org/download/nginx-1.30.6.tar.gz" "$(used)"

# 场景 2：第一个官方失败 -> 第二个官方
t "场景2 首选官方失败则用第二个官方"
MOCK_WGET_FAIL="http://nginx.org/download/nginx-1.30.6.tar.gz"
O="$(new_out)"
run_fetch "$O" "http://nginx.org/download/nginx-1.30.6.tar.gz" \
              "https://mirror.example/nginx-1.30.6.tar.gz"
chk "降级到第二官方" "https://mirror.example/nginx-1.30.6.tar.gz" "$(used)"

# 场景 3：官方全败 -> MIRROR_PRIMARY 根目录
t "场景3 官方全败 -> MIRROR_PRIMARY/<file>"
MOCK_WGET_FAIL="http://nginx.org/download/nginx-1.30.6.tar.gz"
O="$(new_out)"
B="$(basename "$O")"
run_fetch "$O" "http://nginx.org/download/nginx-1.30.6.tar.gz"
chk "命中主镜像根目录" "${MP}/${B}" "$(used)"

# 场景 4：主镜像根目录无 -> 主镜像 so/
t "场景4 主镜像根目录缺失 -> MIRROR_PRIMARY/so/<file>"
O="$(new_out)"; B="$(basename "$O")"
MOCK_WGET_FAIL="http://nginx.org/download/nginx-1.30.6.tar.gz
${MP}/${B}"
run_fetch "$O" "http://nginx.org/download/nginx-1.30.6.tar.gz"
chk "命中主镜像 so/ 子目录" "${MP}/so/${B}" "$(used)"

# 场景 5：主镜像全败 -> MIRROR_FALLBACK 根目录
t "场景5 主镜像全败 -> MIRROR_FALLBACK/<file>"
O="$(new_out)"; B="$(basename "$O")"
MOCK_WGET_FAIL="http://nginx.org/download/nginx-1.30.6.tar.gz
${MP}/${B}
${MP}/so/${B}"
run_fetch "$O" "http://nginx.org/download/nginx-1.30.6.tar.gz"
chk "命中备用镜像根目录" "${MF}/${B}" "$(used)"

# 场景 6：仅剩备用镜像 so/
t "场景6 仅剩备用镜像 so/"
O="$(new_out)"; B="$(basename "$O")"
MOCK_WGET_FAIL="http://nginx.org/download/nginx-1.30.6.tar.gz
${MP}/${B}
${MP}/so/${B}
${MF}/${B}"
run_fetch "$O" "http://nginx.org/download/nginx-1.30.6.tar.gz"
chk "命中备用镜像 so/" "${MF}/so/${B}" "$(used)"

# 场景 7：本地缓存优先（完全不联网）
t "场景7 本地缓存优先于一切"
CACHE="${WORK}/cache"; mkdir -p "$CACHE"
O="$(new_out)"; B="$(basename "$O")"
printf 'CACHED-PAYLOAD\n' > "${CACHE}/${B}"
MOCK_WGET_FAIL=""       # 即使官方可达，也应命中缓存
MOCK_WGET_LOG=""
LNAMP_CACHE="$CACHE"
fetch "$O" "http://nginx.org/download/nginx-1.30.6.tar.gz" >/dev/null 2>&1
LNAMP_CACHE=""
chk "命中本地缓存(未发起任何网络请求)" "" "$MOCK_WGET_LOG"
if grep -q 'CACHED-PAYLOAD' "$O" 2>/dev/null; then
  printf '  [PASS] 输出文件内容来自缓存\n'; PASS=$((PASS+1))
else
  printf '  [FAIL] 输出文件内容不是缓存内容\n'; FAIL=$((FAIL+1))
fi

# 场景 8：全链路失败返回非 0 且不留下文件
t "场景8 全链路失败：返回非 0 且不留残file"
O="$(new_out)"; B="$(basename "$O")"
MOCK_WGET_FAIL="http://nginx.org/download/nginx-1.30.6.tar.gz
${MP}/${B}
${MP}/so/${B}
${MF}/${B}
${MF}/so/${B}"
run_fetch "$O" "http://nginx.org/download/nginx-1.30.6.tar.gz"
rc=$?
if [ "$rc" -ne 0 ]; then
  printf '  [PASS] 全部源失败返回非 0 (rc=%s)\n' "$rc"; PASS=$((PASS+1))
else
  printf '  [FAIL] 全部源失败却返回 0\n'; FAIL=$((FAIL+1))
fi
case "$(uname -s 2>/dev/null)" in
  MINGW*|MSYS*|CYGWIN*)
    # Git Bash 上 rm 对"刚被写入的文件"常有句柄延迟，fetch 的 rm -f 会失败，
    # 于是半截文件残留。Linux 真机不存在此问题，这里只跳过这一条。
    printf '  [SKIP] 失败后是否残留文件（Git Bash 的 rm 句柄延迟，平台限制）\n' ;;
  *)
    if [ ! -s "$O" ]; then
      printf '  [PASS] 失败后未残留文件\n'; PASS=$((PASS+1))
    else
      printf '  [FAIL] 残留了半截文件\n'; FAIL=$((FAIL+1))
    fi ;;
esac

# 场景 9：官方 URL 顺序严格保留（Apache 三级降级）
t "场景9 官方 URL 顺序保持声明顺序"
MOCK_WGET_FAIL="https://dlcdn.apache.org/httpd/httpd-2.4.69.tar.gz"
O="$(new_out)"; B="$(basename "$O")"
run_fetch "$O" \
  "https://dlcdn.apache.org/httpd/httpd-2.4.69.tar.gz" \
  "https://downloads.apache.org/httpd/httpd-2.4.69.tar.gz" \
  "https://archive.apache.org/dist/httpd/httpd-2.4.69.tar.gz"
chk "按序降级到 downloads.apache.org" \
    "https://downloads.apache.org/httpd/httpd-2.4.69.tar.gz" "$(used)"

# 场景 10：缓存文件名必须等于 basename(官方URL) —— 用真实文件名验证
t "场景10 缓存命中依赖 basename 与官方一致"
CACHE2="${WORK}/cache2"; mkdir -p "$CACHE2"
printf 'REALNAME-CACHE\n' > "${CACHE2}/php-8.3.36.tar.gz"
O="${WORK}/php-8.3.36.tar.gz"
MOCK_WGET_LOG=""
LNAMP_CACHE="$CACHE2"
fetch "$O" "https://www.php.net/distributions/php-8.3.36.tar.gz" >/dev/null 2>&1
# shellcheck disable=SC2034  # LNAMP_CACHE 由 fetch() 内部读取
LNAMP_CACHE=""
chk "真实文件名命中缓存" "" "$MOCK_WGET_LOG"

# 场景 11：缓存文件名为空/不存在时不误命中
t "场景11 缓存无对应文件则继续走官方"
CACHE3="${WORK}/cache3"; mkdir -p "$CACHE3"
O="$(new_out)"; B="$(basename "$O")"
MOCK_WGET_FAIL=""
MOCK_WGET_LOG=""
LNAMP_CACHE="$CACHE3"
fetch "$O" "http://nginx.org/download/nginx-1.30.6.tar.gz" >/dev/null 2>&1
# shellcheck disable=SC2034  # LNAMP_CACHE 由 fetch() 内部读取
LNAMP_CACHE=""
chk "缓存为空则走官方" "http://nginx.org/download/nginx-1.30.6.tar.gz" "$(used)"

printf '\n===============================================================================\n'
printf '  PASS=%s  FAIL=%s\n' "$PASS" "$FAIL"
printf '  RESULT: %s\n' "$([ "$FAIL" -eq 0 ] && echo PASS || echo FAIL)"
printf '===============================================================================\n'
[ "$FAIL" -eq 0 ]