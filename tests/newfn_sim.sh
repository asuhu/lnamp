#!/usr/bin/env bash
# 测试隔离：logrotate 目录必须指到临时位置。setup_logrotate 默认写
# /etc/logrotate.d，跑一次测试就会把宿主机的 nginx 日志路径覆盖成临时前缀，
# 此后 logrotate 每天 stat failed、日志永不轮转（真机上已实际发生过）。
export LNAMP_LOGROTATE_DIR="${LNAMP_LOGROTATE_DIR:-$(mktemp -d)}"
# ============================================================================
#  新增功能测试：backup_file / save_file / setup_logrotate / DRY_RUN gate
#  加载真实的 lib/common.sh，用 stub 隔离 systemctl/pkg 管理器。
# ============================================================================
set -u
LNAMP_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
W="/tmp/lnamp_newfn.$$"; mkdir -p "$W"
# 清理临时目录：不清理会留在 /tmp，且 Git Bash 的 $$ (Windows PID) 会复用，
# 下一轮同 PID 时 mkdir -p 不清旧内容，残留的 my.cnf.bak.* 会污染备份计数断言。
trap 'rm -rf "$W"' EXIT

eval "$(sed -n '/^_c()/,/^log_err()/p' "${LNAMP_ROOT}/lib/common.sh")"
eval "$(sed -n '/^fetch()/,/^}/p' "${LNAMP_ROOT}/lib/common.sh")"
eval "$(sed -n '/^save_file()/,/^}/p' "${LNAMP_ROOT}/lib/common.sh")"
eval "$(sed -n '/^backup_file()/,/^}/p' "${LNAMP_ROOT}/lib/common.sh")"
eval "$(sed -n '/^safe_mkdir()/,/^}/p' "${LNAMP_ROOT}/lib/common.sh")"
eval "$(sed -n '/^setup_logrotate()/,/^}/p' "${LNAMP_ROOT}/lib/common.sh")"
eval "$(sed -n '/^log_run()/,/^}/p' "${LNAMP_ROOT}/lib/common.sh")"
eval "$(sed -n '/^pkg_install()/,/^}/p' "${LNAMP_ROOT}/lib/common.sh")"
eval "$(sed -n '/^enable_service()/,/^}/p' "${LNAMP_ROOT}/lib/common.sh")"

MIRROR_PRIMARY="$(sed -n 's/^MIRROR_PRIMARY="\(.*\)"$/\1/p'    "${LNAMP_ROOT}/versions.conf")"
MIRROR_FALLBACK="$(sed -n 's/^MIRROR_FALLBACK="\(.*\)"$/\1/p' "${LNAMP_ROOT}/versions.conf")"
export MIRROR_PRIMARY MIRROR_FALLBACK
# shellcheck disable=SC2034  # OS_FAMILY 由 setup_logrotate 内部读取
OS_FAMILY=rhel
DRY_RUN="${DRY_RUN:-0}"

# stub：不真正动系统（注意：不能 stub pkg_install，真实实现已自带 dry-run 分支，
# stub 掉会掩盖被测逻辑）
systemctl() { return 0; }
chmod() { command chmod "$@"; }
chown() { :; }
wget() { echo "REALWGET $*" >> "$W/wget.calls"; return 1; }

P=0; F=0
ok(){ printf '  [PASS] %s\n' "$1"; P=$((P+1)); }
no(){ printf '  [FAIL] %s\n' "$1"; F=$((F+1)); }
chk(){ [ "$2" = "$3" ] && ok "$1" || no "$1 (期望[$2] 实际[$3])"; }

printf '===============================================================================\n'
printf '  新增功能测试: backup / save_file / logrotate / dry-run\n'
printf '===============================================================================\n'

# ============ backup_file ============
printf '\n--- backup_file 备份与轮换\n'
T="$W/my.cnf"; printf 'OLD-CONTENT\n' > "$T"
: > "$W/b1.log"
backup_file "$T" 5 >"$W/b1.log" 2>&1
n=$(ls -1 "$T".bak.* 2>/dev/null | wc -l)
chk "首次备份生成1份" 1 "$n"
grep -q "已备份" "$W/b1.log" && ok "有备份日志" || no "缺备份日志"
printf 'NEW\n' > "$T"
backup_file "$T" 5 >/dev/null 2>&1
chk "二次备份生成2份" 2 "$(ls -1 "$T".bak.* 2>/dev/null | wc -l)"
# 保留上限：keep=2 时第3次备份后应只剩2份
printf 'N3\n' > "$T"; backup_file "$T" 2 >/dev/null 2>&1
chk "keep=2 时只保留2份" 2 "$(ls -1 "$T".bak.* 2>/dev/null | wc -l)"
# 不存在的文件不报错
backup_file "$W/notexist.conf" 5 >/dev/null 2>&1 && ok "不存在文件返回0" || no "不存在文件应返回0"
# 同一秒内连续备份不得互相覆盖（曾出现重名导致只剩1份的bug）
T5="$W/samesec.conf"
for i in 1 2 3 4; do printf 'v%s\n' "$i" > "$T5"; backup_file "$T5" 10 >/dev/null 2>&1; done
chk "同一秒内4次备份生成4份" 4 "$(ls -1 "$T5".bak.* 2>/dev/null | wc -l)"

# ============ save_file ============
printf '\n--- save_file 写入并自动备份\n'
T2="$W/nginx.conf"; printf 'OLD-NGINX\n' > "$T2"
save_file "$T2" <<EOF
NEW-NGINX-CONTENT
EOF
chk "save_file 写入新内容" "NEW-NGINX-CONTENT" "$(cat "$T2")"
chk "save_file 同时备份旧文件" 1 "$(ls -1 "$T2".bak.* 2>/dev/null | wc -l)"
# 新文件（无旧内容）直接写、不生成空备份
T3="$W/fresh.conf"
save_file "$T3" <<EOF
FRESH
EOF
chk "新文件直接写入" "FRESH" "$(cat "$T3")"
chk "新文件不产生备份" 0 "$(ls -1 "$T3".bak.* 2>/dev/null | wc -l)"

# ============ setup_logrotate ============
printf '\n--- setup_logrotate 生成配置\n'
# 把目标目录指到临时位置，避免写 /etc
LRO="$W/logrotate.d"; mkdir -p "$LRO"
# 用函数生成内容到临时路径（复用其 heredoc 逻辑）
gen_lr() {
  local name="$1" glob="$2" post="${3:-}"; shift 3 2>/dev/null || shift $#
  local extra=("$@") e
  {
    printf '%s {\n' "$glob"
    printf '    daily\n    rotate 30\n    missingok\n    notifempty\n    dateext\n    compress\n    delaycompress\n    sharedscripts\n'
    for e in ${extra+"${extra[@]}"}; do [ -n "$e" ] && printf '    %s\n' "$e"; done
    [ -n "$post" ] && printf '    postrotate\n        %s\n    endscript\n' "$post"
    printf '}\n'
  } > "${LRO}/${name}"
}
gen_lr nginx "/home/wwwlogs/*log" '[ -e /var/run/nginx.pid ] && kill -USR1 `cat /var/run/nginx.pid`'
c="${LRO}/nginx"
grep -q '^/home/wwwlogs/\*log {$' "$c" && ok "日志 glob 正确" || no "日志 glob 错"
grep -q '^    daily$' "$c"        && ok "daily 存在" || no "缺 daily"
grep -q '^    rotate 30$' "$c"    && ok "rotate 30 存在" || no "缺 rotate 30"
grep -q '^    compress$' "$c"     && ok "compress 存在" || no "缺 compress"
grep -q 'kill -USR1' "$c"         && ok "nginx postrotate 重载命令在" || no "缺 postrotate"
gen_lr php-fpm "/usr/local/php/var/log/*.log" "" "su www www"
c2="${LRO}/php-fpm"
grep -q '^    su www www$' "$c2"  && ok "php-fpm su www www 在" || no "缺 su www www"
grep -q 'postrotate' "$c2"        && no "php-fpm 不应有 postrotate" || ok "php-fpm 无 postrotate(符合预期)"
gen_lr mysqld "/data/mysql/data/*.log" "" "su mysql mysql"
grep -q '^    su mysql mysql$' "${LRO}/mysqld" && ok "mysqld su mysql mysql 在" || no "缺 su mysql mysql"

# ============ DRY_RUN gate ============
printf '\n--- DRY_RUN=1 时不产生副作用\n'
DRY_RUN=1
: > "$W/wget.calls"
O="$W/pkg.tar.gz"
fetch "$O" "http://nginx.org/download/nginx-1.26.2.tar.gz" >"$W/fetch.log" 2>&1
rc=$?
chk "fetch 干跑返回0" 0 "$rc"
grep -q '\[dry-run\] 将下载' "$W/fetch.log" && ok "fetch 打印下载计划" || no "fetch 未打印计划"
grep -q 'nginx.org/download/nginx-1.26.2.tar.gz' "$W/fetch.log" && ok "官方 URL 在计划里" || no "官方 URL 缺失"
grep -q "${MIRROR_PRIMARY}/pkg.tar.gz" "$W/fetch.log" && ok "主镜像 URL 在计划里" || no "主镜像 URL 缺失"
grep -q "${MIRROR_FALLBACK}/so/pkg.tar.gz" "$W/fetch.log" && ok "备镜像 so/ URL 在计划里" || no "备镜像 so/ 缺失"
[ -s "$O" ] && no "干跑不应产生下载文件" || ok "干跑未产生下载文件"
chk "干跑未调用真实 wget" 0 "$(wc -l < "$W/wget.calls")"

# pkg_install / log_run / enable_service 干跑
out=$(pkg_install gcc make 2>&1)
case "$out" in *"[dry-run] 将安装系统包: gcc make"*) ok "pkg_install 干跑打印" ;; *) no "pkg_install 干跑未打印: $out" ;; esac
out=$(log_run "编译 nginx" make -j4 2>&1)
case "$out" in *"[dry-run] 将执行: 编译 nginx"*) ok "log_run 干跑打印" ;; *) no "log_run 干跑未打印" ;; esac
case "$out" in *"make -j4"*) ok "log_run 打印完整命令" ;; *) no "log_run 未打印命令" ;; esac
out=$(enable_service nginx 2>&1)
case "$out" in *"[dry-run] 将注册并启动服务: nginx.service"*) ok "enable_service 干跑打印" ;; *) no "enable_service 干跑未打印" ;; esac

# save_file / backup_file 干跑
T4="$W/dry.conf"; printf 'OLD\n' > "$T4"
out=$(save_file "$T4" <<EOF
SHOULD-NOT-WRITE
EOF
)
chk "save_file 干跑不落盘" "OLD" "$(cat "$T4")"
case "$out" in *"[dry-run] 将写入配置文件"*) ok "save_file 干跑打印" ;; *) no "save_file 干跑未打印" ;; esac
chk "save_file 干跑不生成备份" 0 "$(ls -1 "$T4".bak.* 2>/dev/null | wc -l)"
out=$(backup_file "$T4" 2>&1)
case "$out" in *"[dry-run] 将备份"*) ok "backup_file 干跑打印" ;; *) no "backup_file 干跑未打印" ;; esac

# setup_logrotate 干跑
# 先快照存在性：只在"干跑前不存在、干跑后出现"时判定为副作用。
# 已真实安装过 LNAMP 的机器上该文件本就存在，不能算干跑写入（与 dryrun_sim 的 pre-existing 判定保持一致）。
_lr_pre=0; [ -e /etc/logrotate.d/nginx ] && _lr_pre=1
out=$(setup_logrotate nginx "/x/*log" 'reload' 2>&1)
case "$out" in *"[dry-run] 将写入日志轮转配置"*) ok "setup_logrotate 干跑打印" ;; *) no "setup_logrotate 干跑未打印" ;; esac
if [ "$_lr_pre" = 0 ] && [ -e /etc/logrotate.d/nginx ]; then
  no "干跑不应写 /etc/logrotate.d/nginx"
else
  ok "干跑未写 /etc/logrotate.d"
fi

# 恢复正常模式，确认开关可逆
DRY_RUN=0
: > "$W/wget.calls"
O2="$W/pkg2.tar.gz"
# 正确解析 wget 参数：-O 的下一个参数才是输出文件（fetch 传了 -4 --no-check-certificate 等一堆参数）
wget() {
  local prev="" a
  for a in "$@"; do [ "$prev" = "-O" ] && { echo "PAYLOAD" > "$a"; return 0; }; prev="$a"; done
  return 1
}
fetch "$O2" "http://nginx.org/download/nginx-1.26.2.tar.gz" >/dev/null 2>&1
chk "恢复正常后 fetch 真的下载" "PAYLOAD" "$(cat "$O2" 2>/dev/null)"

printf '\n===============================================================================\n'
printf '  PASS=%s  FAIL=%s\n' "$P" "$F"
printf '  RESULT: %s\n' "$([ "$F" -eq 0 ] && echo PASS || echo FAIL)"
printf '===============================================================================\n'
[ "$F" -eq 0 ]