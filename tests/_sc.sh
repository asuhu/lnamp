#!/bin/bash
# tests/smoke.sh —— 全功能冒烟测试（用桩隔离网络/编译/系统调用）
# 用法: bash tests/smoke.sh
cd "$(dirname "$0")/.." || exit 1
ROOT="$(pwd)"
PASS=0; FAIL=0; FAILED=()
ck(){ if eval "$2" >/dev/null 2>&1; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); FAILED+=("$1"); echo "  [FAIL] $1"; fi; }
sec(){ echo; echo "==================== $* ===================="; }

# 通用桩：屏蔽外部命令（在每个子 shell 内 source 后按需覆盖）
load(){ LNAMP_NO_MAIN=1 source ./install.sh; }
# 改写函数定义里的绝对路径，输出到 stdout。用法:
#   eval "$(_rwfn <函数名> <原串> <新串> [<原串> <新串>...])"
# 为什么不用 sed：sed 的替换串一旦含 Windows 路径（C:\...\Temp\2\tmp.xxx），
# 其中的 \2 会被当成反向引用、\U/\L 被当成大小写转义，直接报
# "invalid reference \2" 而整个替换失效（Linux 上没这个问题，但会误报失败）。
# bash 参数展开是纯字符串替换，两个平台都对。
_rwfn(){ local fn; fn=$(declare -f "$1"); shift
  while [ $# -ge 2 ]; do fn="${fn//"$1"/"$2"}"; shift 2; done
  printf '%s\n' "$fn"; }
neutralize(){
  export MY_CNF_PATH="$(mktemp -d)/my.cnf"   # 别写宿主机 /etc/my.cnf
  export LDSO_CONF_DIR="$(mktemp -d)"        # 别写宿主机 /etc/ld.so.conf.d
  export LNAMP_LOGROTATE_DIR="$(mktemp -d)"   # 别写宿主机 /etc/logrotate.d
  export WWWROOT="$(mktemp -d)/www" WWWLOGS="$(mktemp -d)/logs"
  dep(){ :;}; pkg_install(){ :;}; pkg_update(){ :;}; pkg_remove(){ :;}
  systemctl(){ return 0;}; useradd(){ :;}; groupadd(){ :;}; chown(){ :;}; chmod(){ command chmod "$@" 2>/dev/null;}
  ln(){ :;}; ldconfig(){ :;}; firewall-cmd(){ :;}; ufw(){ :;}; update-rc.d(){ :;}; ldd(){ echo;}
  make(){ :;}; cmake(){ :;}; msgfmt(){ :;}; ldconfig(){ :;}
  enable_service(){ :;}; open_ports(){ :;}; register_path(){ :;}
  build_openssl_prefix(){ :;}; install_php_openssl(){ :;}; install_libsodium(){ :;}
  ensure_sysuser(){ :;}; ensure_www_user(){ :;}; ensure_mysql_user(){ :;}
  log(){ :;}; log_ok(){ :;}; log_warn(){ :;}; log_run(){ "$@" >/dev/null 2>&1 || true;}; hr(){ :;}; clear(){ :;}
  reload_php_runtime(){ :;}
}

PASS=0; FAIL=0; FAILED=()
_t_common(){
  export MY_CNF_PATH="$(mktemp -d)/my.cnf"   # 别写宿主机 /etc/my.cnf
  export LDSO_CONF_DIR="$(mktemp -d)"        # 别写宿主机 /etc/ld.so.conf.d
  export WWWROOT="$(mktemp -d)/www" WWWLOGS="$(mktemp -d)/logs"
  dep(){ :;}; pkg_install(){ :;}; pkg_update(){ :;}; register_path(){ :;}; enable_service(){ :;}
  open_ports(){ :;}; ensure_www_user(){ :;}; ensure_sysuser(){ :;}; ensure_mysql_user(){ :;}
  build_openssl_prefix(){ :;}; install_php_openssl(){ :;}; install_libsodium(){ :;}
  log(){ :;}; log_ok(){ :;}; log_warn(){ :;}; hr(){ :;}; make(){ :;}; cmake(){ :;}; ldconfig(){ :;}
  chown(){ :;}; ln(){ :;}; die(){ return 1;}; systemctl(){ return 0;}; id(){ return 0;}
}
_skip_msys(){ case "$(uname -s 2>/dev/null)" in MINGW*|MSYS*|CYGWIN*) return 0 ;; *) return 1 ;; esac; }
sec "20. vhost 残留清理 (prune / del --file)"

# 造一个沙箱：1 个健康站点 + 1 个坏配置 + 1 个根目录缺失 + 1 个孤儿目录
_vh_fixture(){ ( load; _t_common
  SB=$(mktemp -d)
  export PREFIX_NGINX=$SB/ng PREFIX_APACHE=$SB/ap WWWROOT=$SB/www WWWLOGS=$SB/logs
  export LNAMP_VHOST_ARCHIVE=$SB/arch
  mkdir -p $PREFIX_NGINX/conf/vhost $PREFIX_NGINX/sbin $WWWROOT/web $WWWROOT/a.com $WWWROOT/orphan1
  : > $PREFIX_NGINX/conf/nginx.conf
  printf 'server {\n listen 80;\n server_name a.com;\n root %s/www/a.com;\n}\n' "$SB" > $PREFIX_NGINX/conf/vhost/a.com.conf
  printf 'server {\n listen 80;\n root /tmp;\n}\n' > $PREFIX_NGINX/conf/vhost/bad.conf
  printf 'server {\n listen 80;\n server_name old.com;\n root %s/www/gone;\n}\n' "$SB" > $PREFIX_NGINX/conf/vhost/old.com.conf
  printf 'server {\n listen 80;\n server_name dis.com;\n root %s/www/a.com;\n}\n' "$SB" > $PREFIX_NGINX/conf/vhost/dis.com.conf.disabled
  _vh_reload_ws(){ return 0; }; _vh_bin_for_ws(){ echo /bin/true; }
  echo "$SB" > /tmp/_vh_sb_$$
) }

ck "vhost list: 坏配置不再隐形 (bad-conf)" "(
  load; _t_common
  _vh_fixture >/dev/null 2>&1
  SB=\$(cat /tmp/_vh_sb_\$\$); export PREFIX_NGINX=\$SB/ng PREFIX_APACHE=\$SB/ap WWWROOT=\$SB/www WWWLOGS=\$SB/logs LNAMP_VHOST_ARCHIVE=\$SB/arch
  out=\$(vhost_list 2>&1)
  printf '%s' \"\$out\" | grep -q 'bad-conf' && printf '%s' \"\$out\" | grep -q 'no-root' )"

ck "vhost prune: 默认只报告，不动任何文件" "(
  load; _t_common
  _vh_fixture >/dev/null 2>&1
  SB=\$(cat /tmp/_vh_sb_\$\$); export PREFIX_NGINX=\$SB/ng PREFIX_APACHE=\$SB/ap WWWROOT=\$SB/www WWWLOGS=\$SB/logs LNAMP_VHOST_ARCHIVE=\$SB/arch
  _vh_reload_ws(){ return 0; }; _vh_bin_for_ws(){ echo /bin/true; }
  vhost_prune >/dev/null 2>&1
  [ -f \$PREFIX_NGINX/conf/vhost/bad.conf ] && [ -f \$PREFIX_NGINX/conf/vhost/old.com.conf ] )"

ck "vhost prune --yes: 归档残留、保留健康站点" "(
  load; _t_common
  _vh_fixture >/dev/null 2>&1
  SB=\$(cat /tmp/_vh_sb_\$\$); export PREFIX_NGINX=\$SB/ng PREFIX_APACHE=\$SB/ap WWWROOT=\$SB/www WWWLOGS=\$SB/logs LNAMP_VHOST_ARCHIVE=\$SB/arch
  _vh_reload_ws(){ return 0; }; _vh_bin_for_ws(){ echo /bin/true; }
  vhost_prune --yes --archive-keep 100 >/dev/null 2>&1
  [ ! -f \$PREFIX_NGINX/conf/vhost/bad.conf ] &&
  [ ! -f \$PREFIX_NGINX/conf/vhost/old.com.conf ] &&
  [ -f \$PREFIX_NGINX/conf/vhost/a.com.conf ] &&
  [ -f \$PREFIX_NGINX/conf/vhost/dis.com.conf.disabled ] &&
  [ \"\$(ls \$SB/arch 2>/dev/null | wc -l)\" -ge 2 ] )"

ck "vhost prune --disabled: 连禁用配置一起清" "(
  load; _t_common
  _vh_fixture >/dev/null 2>&1
  SB=\$(cat /tmp/_vh_sb_\$\$); export PREFIX_NGINX=\$SB/ng PREFIX_APACHE=\$SB/ap WWWROOT=\$SB/www WWWLOGS=\$SB/logs LNAMP_VHOST_ARCHIVE=\$SB/arch
  _vh_reload_ws(){ return 0; }; _vh_bin_for_ws(){ echo /bin/true; }
  vhost_prune --yes --disabled --archive-keep 100 >/dev/null 2>&1
  [ ! -f \$PREFIX_NGINX/conf/vhost/dis.com.conf.disabled ] )"

ck "vhost prune --purge-dirs: 只删孤儿目录" "(
  _skip_msys && exit 0
  load; _t_common        # Git Bash 的 safe-delete 会拒绝 C:\ 路径，平台跳过
  _vh_fixture >/dev/null 2>&1
  SB=\$(cat /tmp/_vh_sb_\$\$); export PREFIX_NGINX=\$SB/ng PREFIX_APACHE=\$SB/ap WWWROOT=\$SB/www WWWLOGS=\$SB/logs LNAMP_VHOST_ARCHIVE=\$SB/arch
  _vh_reload_ws(){ return 0; }; _vh_bin_for_ws(){ echo /bin/true; }
  vhost_prune --yes --purge-dirs --archive-keep 100 >/dev/null 2>&1
  [ ! -d \$WWWROOT/orphan1 ] && [ -d \$WWWROOT/a.com ] && [ -d \$WWWROOT/web ] )"

ck "vhost del --file: 删除解析不出域名的坏配置" "(
  load; _t_common
  _vh_fixture >/dev/null 2>&1
  SB=\$(cat /tmp/_vh_sb_\$\$); export PREFIX_NGINX=\$SB/ng PREFIX_APACHE=\$SB/ap WWWROOT=\$SB/www WWWLOGS=\$SB/logs LNAMP_VHOST_ARCHIVE=\$SB/arch
  _vh_reload_ws(){ return 0; }; _vh_bin_for_ws(){ echo /bin/true; }
  _php_pool_remove(){ return 0; }
  vhost_del --file \$PREFIX_NGINX/conf/vhost/bad.conf --yes >/dev/null 2>&1
  [ ! -f \$PREFIX_NGINX/conf/vhost/bad.conf ] && [ -f \$PREFIX_NGINX/conf/vhost/a.com.conf ] )"

# 站点目录被删、池还在 -> php-fpm -t 直接失败（chdir 不存在），整机 PHP 起不来。
# 这是「删站点反而把 PHP 弄停」的根因，必须能识别并清掉。
ck "vhost: 识别 chdir 已失效的孤儿池" "(
  load; _t_common; SB=\$(mktemp -d)
  export PREFIX_NGINX=\$SB/ng PREFIX_APACHE=\$SB/ap PREFIX_PHP=\$SB/php WWWROOT=\$SB/www
  export WWWLOGS=\$SB/logs LNAMP_VHOST_ARCHIVE=\$SB/arch
  mkdir -p \$PREFIX_NGINX/conf/vhost \$PREFIX_PHP/etc/php-fpm.d
  : > \$PREFIX_NGINX/conf/nginx.conf
  printf '; 由 lnamp 自动生成 —— 站点 gone.com 的独立 php-fpm 池\n[site_gone_com_1]\nchdir = %s/www/gone.com\nlisten = /tmp/x.sock\n' \"\$SB\" \
    > \$PREFIX_PHP/etc/php-fpm.d/site_gone_com_1.conf
  _php_pool_orphans | grep -q 'site_gone_com_1.conf' )"

ck "vhost prune: 归档孤儿池（避免 php-fpm -t 失败）" "(
  load; _t_common; SB=\$(mktemp -d)
  export PREFIX_NGINX=\$SB/ng PREFIX_APACHE=\$SB/ap PREFIX_PHP=\$SB/php WWWROOT=\$SB/www
  export WWWLOGS=\$SB/logs LNAMP_VHOST_ARCHIVE=\$SB/arch
  mkdir -p \$PREFIX_NGINX/conf/vhost \$PREFIX_PHP/etc/php-fpm.d \$WWWROOT/web
  : > \$PREFIX_NGINX/conf/nginx.conf
  printf '; 由 lnamp 自动生成 —— 站点 gone.com 的独立 php-fpm 池\n[site_gone_com_1]\nchdir = %s/www/gone.com\n' \"\$SB\" \
    > \$PREFIX_PHP/etc/php-fpm.d/site_gone_com_1.conf
  _vh_reload_ws(){ return 0; }; _vh_bin_for_ws(){ echo /bin/true; }
  vhost_prune --yes >/dev/null 2>&1
  [ ! -f \$PREFIX_PHP/etc/php-fpm.d/site_gone_com_1.conf ] &&
  ls \$SB/arch | grep -q 'site_gone_com_1.conf' )"

ck "vhost del --file: 拒绝删 vhost 目录外的文件" "(
  load; _t_common; die(){ exit 1; }; SB=\$(mktemp -d); export PREFIX_NGINX=\$SB/ng
  mkdir -p \$PREFIX_NGINX/conf/vhost
  : > \$PREFIX_NGINX/conf/nginx.conf
  echo x > \$SB/not-a-vhost.txt
  ! ( vhost_del --file \$SB/not-a-vhost.txt --yes ) >/dev/null 2>&1 && [ -f \$SB/not-a-vhost.txt ] )"

############### 21. bench（压测 + 参数推荐） ###############
# 目标："默认值合不合适"要有数据支撑。这里锁住推荐算法与写回语法，
# 真实压测在真机上验（tests 里不跑流量）。
sec "21. bench 参数推荐 (recommend / apply)"

ck "bench: 8核16G/RSS42 → wp=8 max_children=16" "(
  load; _t_common
  r=\$(_bench_recommend 8 16000 42 20)
  [ \"\$(echo \"\$r\" | cut -d'|' -f1)\" = 8 ] &&
  [ \"\$(echo \"\$r\" | cut -d'|' -f3)\" = 16 ] )"

ck "bench: 2核 → worker_processes 用 1（避免上下文切换）" "(
  load; _t_common
  [ \"\$(_bench_recommend 2 8000 40 10 | cut -d'|' -f1)\" = 1 ] )"

ck "bench: 小内存机器取内存上限（小于 CPU 上限）" "(
  load; _t_common
  # 4核 → CPU 上限 8；4G 内存 / RSS 300MB → 内存上限 10 → 仍取 8
  # 2G / RSS 300 → 内存上限 5 → 取 5
  r=\$(_bench_recommend 4 2048 300 10 | cut -d'|' -f3)
  [ \"\$r\" = 5 ] )"

ck "bench: pm 派生值满足 fpm 的约束" "(
  load; _t_common
  IFS='|' read -r wp wc mc st mins maxs _ <<< \"\$(_bench_recommend 8 16000 42 20)\"
  [ \"\$st\" -ge \"\$mins\" ] && [ \"\$st\" -le \"\$maxs\" ] && [ \"\$mins\" -le \"\$maxs\" ] && [ \"\$maxs\" -le \"\$mc\" ] )"

ck "bench: 并发 600 时 worker_connections 抬到 2048" "(
  load; _t_common
  [ \"\$(_bench_recommend 8 16000 42 600 | cut -d'|' -f2)\" = 2048 ] )"

ck "bench: nginx 写回带分号" "(
  load; _t_common; SB=\$(mktemp -d)
  printf 'worker_processes auto;\n' > \$SB/nginx.conf
  log(){ :;}; log_ok(){ :;}; log_err(){ :;}; log_warn(){ :;}
  _bench_apply_kv \$SB/nginx.conf worker_processes 16 '' '' >/dev/null 2>&1
  grep -q '^worker_processes 16;\$' \$SB/nginx.conf )"

ck "bench: php-fpm 写回不带分号（ini 语法）" "(
  load; _t_common; SB=\$(mktemp -d)
  printf '[www]\npm.max_children = 5\n' > \$SB/www.conf
  log(){ :;}; log_ok(){ :;}; log_err(){ :;}; log_warn(){ :;}
  _bench_apply_kv \$SB/www.conf pm.max_children 32 '' '' >/dev/null 2>&1
  grep -q '^pm.max_children = 32\$' \$SB/www.conf && ! grep -q '32;' \$SB/www.conf )"

ck "bench: 写回失败会回滚（校验不过原文件不变）" "(
  load; _t_common; SB=\$(mktemp -d)
  printf 'worker_processes auto;\n' > \$SB/nginx.conf
  log(){ :;}; log_ok(){ :;}; log_err(){ :;}; log_warn(){ :;}
  _bench_apply_kv \$SB/nginx.conf worker_processes 16 'false' '' >/dev/null 2>&1
  grep -q 'auto;' \$SB/nginx.conf )"

echo "PASS=$PASS FAIL=$FAIL"; if [ "$FAIL" -gt 0 ]; then printf "  失败: %s\n" "${FAILED[@]}"; fi
