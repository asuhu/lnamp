#!/bin/bash
# tests/smoke2.sh —— 深度冒烟：模式分发 / 生成配置内容 / OS 检测 / 依赖映射 / 助手
cd "$(dirname "$0")/.." || exit 1
PASS=0; FAIL=0; FAILED=()
ck(){ if eval "$2" >/dev/null 2>&1; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); FAILED+=("$1"); echo "  [FAIL] $1"; fi; }
sec(){ echo; echo "==================== $* ===================="; }
load(){ LNAMP_NO_MAIN=1 source ./install.sh; }
base(){
  dep(){ :;}; pkg_install(){ :;}; pkg_update(){ :;}; register_path(){ :;}; enable_service(){ :;}
  open_ports(){ :;}; ensure_www_user(){ :;}; ensure_sysuser(){ :;}; ensure_mysql_user(){ :;}
  build_openssl_prefix(){ :;}; install_php_openssl(){ :;}; install_libsodium(){ :;}; _php_base_deps(){ :;}
  log(){ :;}; log_ok(){ :;}; log_warn(){ :;}; hr(){ :;}; make(){ :;}; cmake(){ :;}; ldconfig(){ :;}
  chown(){ :;}; ln(){ :;}; systemctl(){ return 0;}; id(){ return 0;}; die(){ return 1;}; fetch(){ : > "$1" 2>/dev/null; return 0;}
  tar(){ :;}; reload_php_runtime(){ :;}
}

############### D1. 模式分发 ###############
sec "D1. install_X 按 mode 分发到正确子函数"
disp(){ ( load; base
  _nginx_source(){ echo NS;}; _nginx_pkg(){ echo NP;}
  _apache_source(){ echo AS;}; _apache_pkg(){ echo AP;}
  _mysql_source(){ echo MS;}; _mysql_binary(){ echo MB;}; _mysql_pkg(){ echo MP;}
  _redis_source(){ echo RS;}; _redis_pkg(){ echo RP;}
  _mariadb_binary(){ echo DB;}; _mariadb_pkg(){ echo DP;}
  _php_setup_fpm(){ echo FPM;}; _php_setup_apache_module(){ echo MODPHP;}
  _php_install_imagick(){ :;}; tune_php_ini(){ :;}; _php_write_extra(){ :;}; php_enable_ext(){ :;}
  eval "$1" ); }
ck "nginx source -> _nginx_source"   "test \"\$(disp 'install_nginx 1.26.2 source')\" = NS"
ck "nginx pkg -> _nginx_pkg"         "test \"\$(disp 'install_nginx 1.26.2 pkg')\" = NP"
ck "apache source -> _apache_source" "disp 'install_apache 2.4.67 source event' | grep -q AS"
ck "apache pkg -> _apache_pkg"       "disp 'install_apache 2.4.67 pkg event' | grep -q AP"
ck "mysql source -> _mysql_source"   "disp 'install_mysql 5.7.44 source' | grep -q MS"
ck "mysql binary -> _mysql_binary"   "disp 'install_mysql 8.0.46 binary' | grep -q MB"
ck "mysql pkg -> _mysql_pkg"         "disp 'install_mysql 8.0.46 pkg' | grep -q MP"
ck "redis source -> _redis_source"   "disp 'install_redis 7.4.9 source' | grep -q RS"
ck "redis pkg -> _redis_pkg"         "disp 'install_redis 7.4.9 pkg' | grep -q RP"
ck "mariadb binary -> _mariadb_binary" "disp 'install_mariadb 11.8.6 binary' | grep -q DB"
ck "mariadb pkg -> _mariadb_pkg"     "disp 'install_mariadb 11.8.6 pkg' | grep -q DP"
ck "php fpm -> _php_setup_fpm"       "disp 'install_php 8.3.31 fpm' | grep -q FPM"
ck "php apache -> mod_php"           "disp 'install_php 8.3.31 apache' | grep -q MODPHP"

############### D2. nginx.conf 生成内容 ###############
sec "D2. _nginx_write_conf 生成内容"
ngconf(){ ( load; base; SB=$(mktemp -d)
  export PREFIX_NGINX=$SB/ng WWWROOT=$SB/www WWWLOGS=$SB/logs PHP_FPM_SOCK=/run/php/php-fpm.sock
  mkdir -p $PREFIX_NGINX/conf $WWWROOT $WWWLOGS
  _nginx_write_conf >/dev/null 2>&1
  cat $PREFIX_NGINX/conf/nginx.conf 2>/dev/null > $SB/out; echo $SB/out ); }
OUT=$(ngconf)
ck "nginx.conf: server_tokens off"        "grep -q 'server_tokens   off' $OUT"
ck "nginx.conf: 默认站点 root=/www/web"   "grep -qE 'root .*/web;' $OUT"
ck "nginx.conf: fastcgi unix socket"      "grep -q 'fastcgi_pass   unix:/run/php/php-fpm.sock' $OUT"
ck "nginx.conf: include vhost/*.conf"     "grep -q 'include vhost/\*.conf' $OUT"
ck "nginx.conf: worker_processes auto"    "grep -q 'worker_processes auto' $OUT"
ck "nginx.conf: gzip on"                  "grep -q 'gzip  *on' $OUT"

############### D3. my.cnf 生成内容 ###############
sec "D3. write_my_cnf 生成内容"
mycnf2(){ ( load; base; SB=$(mktemp -d); tune_my_cnf(){ :;}; MEM_MB=4096
  eval "$(declare -f write_my_cnf | sed 's#/etc/my.cnf#'$SB'/my.cnf#g')"
  write_my_cnf "$1" "$2" "$3" "$4" >/dev/null 2>&1; cat $SB/my.cnf > $SB/o; echo $SB/o ); }
M=$(mycnf2 /data/mysql /data/mysql mysql 8.0.46)
ck "my.cnf: datadir=/data/mysql"   "grep -q 'datadir.*=.*/data/mysql' $M"
ck "my.cnf: 含 socket"             "grep -qi 'socket' $M"
ck "my.cnf: 含 innodb_buffer_pool" "grep -q 'innodb_buffer_pool_size' $M"
ck "my.cnf: MySQL8 binlog_expire_logs_seconds" "grep -q 'binlog_expire_logs_seconds' $M"

############### D4. tune_php_ini (安全) ###############
sec "D4. tune_php_ini disable_functions / 安全项"
phpini(){ ( load; base; SB=$(mktemp -d); MEM_MB=4096; MEMORY_LIMIT=256
  cat > $SB/php.ini <<'INI'
memory_limit = 128M
output_buffering =
;cgi.fix_pathinfo=1
short_open_tag = Off
expose_php = On
request_order = "GP"
;date.timezone =
disable_functions =
INI
  tune_php_ini $SB/php.ini >/dev/null 2>&1; cat $SB/php.ini > $SB/o; echo $SB/o ); }
PI=$(phpini)
ck "php.ini: disable_functions 含 exec"        "grep -E '^disable_functions' $PI | grep -q exec"
ck "php.ini: disable_functions 不含 set_time_limit" "! ( grep -E '^disable_functions' $PI | grep -q set_time_limit )"
ck "php.ini: cgi.fix_pathinfo=0"               "grep -q 'cgi.fix_pathinfo=0' $PI"
ck "php.ini: expose_php = Off"                 "grep -q 'expose_php = Off' $PI"

############### D5. _php_setup_fpm (socket) ###############
sec "D5. _php_setup_fpm www.conf socket"
fpmconf(){ ( load; base; SB=$(mktemp -d)
  export PREFIX_PHP=$SB/php SYSTEMD_DIR=$SB/sd PHP_FPM_SOCK=/run/php/php-fpm.sock
  mkdir -p $PREFIX_PHP/etc/php-fpm.d $SB/sd
  cat > $PREFIX_PHP/etc/php-fpm.d/www.conf.default <<'WWW'
;listen = 127.0.0.1:9000
;listen.owner = nobody
;listen.group = nobody
;listen.mode = 0660
WWW
  _php_setup_fpm >/dev/null 2>&1; echo $SB ); }
F=$(fpmconf)
ck "fpm www.conf: listen=unix socket"  "grep -q 'listen = /run/php/php-fpm.sock' $F/php/etc/php-fpm.d/www.conf"
ck "fpm www.conf: listen.owner=www"    "grep -q 'listen.owner = www' $F/php/etc/php-fpm.d/www.conf"
ck "fpm systemd unit 生成"             "test -f $F/sd/php-fpm.service"

############### D6. detect_os ###############
sec "D6. detect_os 多发行版"
osck(){ ( load; SB=$(mktemp -d); printf '%b\n' "$2" > $SB/os-release
  eval "$(declare -f detect_os | sed 's#/etc/os-release#'$SB'/os-release#g')"
  detect_os >/dev/null 2>&1; echo "$OS_FAMILY $PM" ); }
ck "CentOS7 -> rhel/yum|dnf"  "osck c 'ID=centos\nVERSION_ID=\"7\"\nPRETTY_NAME=\"CentOS 7\"' | grep -q rhel"
ck "Rocky9 -> rhel/dnf"       "osck r 'ID=rocky\nVERSION_ID=\"9.3\"\nPRETTY_NAME=\"Rocky 9\"' | grep -q 'rhel dnf'"
ck "Ubuntu22 -> debian/apt"   "osck u 'ID=ubuntu\nVERSION_ID=\"22.04\"\nPRETTY_NAME=\"Ubuntu 22\"' | grep -q 'debian apt-get'"
ck "未知发行版报错"           "! ( load; SB=\$(mktemp -d); printf 'ID=plan9\nVERSION_ID=\"1\"\n' > \$SB/os-release; eval \"\$(declare -f detect_os | sed 's#/etc/os-release#'\$SB'/os-release#g')\"; detect_os ) 2>/dev/null"

############### D7. _dep_name 映射 ###############
sec "D7. _dep_name 跨发行版映射"
ck "debian: zlib-devel->zlib1g-dev"        "( load; OS_FAMILY=debian; test \"\$(_dep_name zlib-devel)\" = zlib1g-dev )"
ck "debian: gcc-c++->g++"                  "( load; OS_FAMILY=debian; test \"\$(_dep_name gcc-c++)\" = g++ )"
ck "debian: ImageMagick-devel->libmagickwand-dev" "( load; OS_FAMILY=debian; test \"\$(_dep_name ImageMagick-devel)\" = libmagickwand-dev )"
ck "rhel: zlib-devel 原样"                 "( load; OS_FAMILY=rhel; test \"\$(_dep_name zlib-devel)\" = zlib-devel )"

############### D8. fetch 行为 ###############
sec "D8. fetch 成功即停 / 全失败兜底"
ck "fetch 首个成功即返回0" "(
  load; SB=\$(mktemp -d); cd \$SB; n=0
  wget(){ n=\$((n+1)); echo \$n > cnt; return 0; }
  fetch out http://a/out >/dev/null 2>&1 && [ \"\$(cat cnt)\" = 1 ] )"
ck "fetch 全失败返回非0且尝试镜像" "(
  load; SB=\$(mktemp -d); cd \$SB
  wget(){ echo \"\$@\" >> log; return 1; }
  ! fetch out.tgz http://a/out.tgz >/dev/null 2>&1 &&
  grep -q zhangfangzhou log && grep -q asuhu log )"

############### D9. parse_pick / D10. gen_password ###############
sec "D9-10. parse_pick / gen_password"
ck "parse_pick ver:mode 拆分" "( load; parse_pick NGINX '1.26.2:source' >/dev/null 2>&1; test \"\$PICK_VER\" = 1.26.2 -a \"\$PICK_MODE\" = source )"
ck "parse_pick 仅版本用默认形式" "( load; parse_pick NGINX '1.24.0' >/dev/null 2>&1; test \"\$PICK_VER\" = 1.24.0 -a -n \"\$PICK_MODE\" )"
ck "gen_password 长度>=12" "( load; p=\$(gen_password); [ \${#p} -ge 12 ] )"
ck "gen_password 每次不同" "( load; [ \"\$(gen_password)\" != \"\$(gen_password)\" ] )"

############### D11. vhost apache ###############
sec "D11. _vhost_apache 生成配置"
ck "vhost apache 写出含域名的配置" "(
  load; base; SB=\$(mktemp -d); export PREFIX_APACHE=\$SB/ap WWWROOT=\$SB/w WWWLOGS=\$SB/l PHP_FPM_SOCK=/run/php/php-fpm.sock
  mkdir -p \$PREFIX_APACHE/conf/vhost \$SB/w \$SB/l
  printf 'Include conf/vhost/\*.conf\n' > \$PREFIX_APACHE/conf/httpd.conf
  _apache_current_mpm(){ echo event;}; _php_fpm_available(){ return 0;}; apachectl(){ :;}; httpd(){ :;}
  _vhost_apache site.com 8081 \$SB/w/site no >/dev/null 2>&1
  grep -rq 'site.com' \$PREFIX_APACHE/conf/vhost/ 2>/dev/null )"

############### D12. redis source conf ###############
sec "D12. _redis_source 配置内容"
ck "redis.conf: bind/maxmemory/requirepass" "(
  load; base; SB=\$(mktemp -d); export HOME=\$SB PREFIX_REDIS=\$SB/redis MEM_MB=4096; gen_password(){ echo SECRET123;}
  _redis_service(){ :;}; make(){ mkdir -p \$PREFIX_REDIS/bin; : > \$PREFIX_REDIS/bin/redis-server;}
  fetch(){ mkdir -p \$HOME/redis-7.4.9; printf 'bind 127.0.0.1 -::1\n# maxmemory <bytes>\n# requirepass foobared\n' > \$HOME/redis-7.4.9/redis.conf; : > \"\$1\"; return 0;}
  tar(){ :;}
  _redis_source 7.4.9 >/dev/null 2>&1
  rc=\$PREFIX_REDIS/etc/redis.conf
  grep -q 'bind 127.0.0.1' \$rc && grep -q '^maxmemory ' \$rc && grep -q 'requirepass SECRET123' \$rc )"

############### 汇总 ###############
sec "汇总"
echo "  PASS=$PASS  FAIL=$FAIL"
[ "$FAIL" -gt 0 ] && { echo "  失败项:"; printf '    - %s\n' "${FAILED[@]}"; exit 1; }
echo "  ✅ 全部通过"
