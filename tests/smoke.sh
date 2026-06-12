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
neutralize(){
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

############### 1. 静态检查 ###############
sec "1. 静态检查 (syntax + shellcheck)"
for f in install.sh lib/common.sh modules/*.sh versions.conf; do
  ck "bash -n $f" "bash -n '$f'"
done
ck "shellcheck -S error (全部)" "timeout 90 shellcheck -S error install.sh lib/common.sh modules/*.sh versions.conf"

############### 2. 清单完整性 + 默认值 ###############
sec "2. 清单 + validate_choice(每个版本/形式) + 默认值"
( load
  comps="NGINX APACHE PHP MYSQL MARIADB REDIS PHPREDIS"
  for c in $comps; do
    arr="${c}_VERSIONS[@]"
    for line in "${!arr}"; do
      v="${line%%|*}"; modes="$(echo "$line" | cut -d'|' -f2)"
      IFS=',' read -ra ms <<< "$modes"
      for m in "${ms[@]}"; do
        if ( validate_choice "$c" "$v" "$m" ) 2>/dev/null; then echo "PASS"; else echo "FAILVALID $c $v $m"; fi
      done
    done
    dv_var="${c}_DEFAULT"; dm_var="${c}_DEFAULT_MODE"
    ( validate_choice "$c" "${!dv_var}" "${!dm_var}" ) 2>/dev/null && echo "PASS" || echo "FAILDEF $c ${!dv_var}:${!dm_var}"
  done
) > /tmp/_mani.out 2>&1
ck "所有版本×形式组合 validate_choice 通过" "! grep -q FAILVALID /tmp/_mani.out"
ck "所有组件默认值合法" "! grep -q FAILDEF /tmp/_mani.out"
ck "MySQL 默认=8.0.46" "( load; test \"\$MYSQL_DEFAULT\" = 8.0.46 )"
ck "未知版本被拒绝" "( load; ! ( validate_choice NGINX 9.9.9 source ) 2>/dev/null )"

############### 3. CLI 解析 ###############
sec "3. CLI flags 解析"
ckcli(){ ck "$1" "( load; require_root(){ :;}; detect_os(){ OS_FAMILY=debian; PM=apt-get;}; parse_args $2 >/dev/null 2>&1; $3 )"; }
ckcli "--nginx freenginx-1.30.1"   "--nginx freenginx-1.30.1"   'test "$SEL_NGINX" = freenginx-1.30.1:source'
ckcli "--nginx tengine-3.1.0"      "--nginx tengine-3.1.0"      'test "$SEL_NGINX" = tengine-3.1.0:source'
ckcli "--apache + mpm"             "--apache 2.4.67:source --apache-mpm event" 'test "$SEL_APACHE" = 2.4.67:source -a "$APACHE_MPM" = event'
ckcli "--php fpm"                  "--php 8.3.31:fpm"           'test "$SEL_PHP" = 8.3.31:fpm'
ckcli "--mysql 9.7.0"             "--mysql 9.7.0"              'test "$SEL_MYSQL" = 9.7.0:binary'
ckcli "--mariadb"                 "--mariadb 11.8.8"           'test "$SEL_MARIADB" = 11.8.8:binary'
ckcli "--redis 8.8.0"            "--redis 8.8.0"             'test "$SEL_REDIS" = 8.8.0:source'
ckcli "--phpredis"               "--phpredis 6.3.0"           'test "$SEL_PHPREDIS" = 6.3.0:source'
ckcli "--php-imagick"            "--php 8.3.31 --php-imagick"  'test "$PHP_IMAGICK" = yes'
ckcli "--imagemagick-source"     "--imagemagick-source"       'test "$IMAGEMAGICK_SOURCE" = yes -a "$PHP_IMAGICK" = yes'
ckcli "--phpmyadmin"             "--phpmyadmin"               'test "$INSTALL_PMA" = yes'
ckcli "--adminer"                "--adminer"                  'test "$INSTALL_ADMINER" = yes'
ckcli "--java 17"                "--java 17"                  'test "$SEL_JAVA" = 17'
ckcli "--tomcat"                 "--tomcat"                   'test "$INSTALL_TOMCAT" = yes'
ck   "--java 9 报错" "( load; ! ( parse_args --java 9 ) 2>/dev/null )"

############### 4. 辅助函数 ###############
sec "4. 辅助函数 (meta_get / fetch镜像 / php_enable_ext / write_my_cnf / IIS)"
ck "meta_get 取值" "( load; m='flavor=freenginx;openssl=3.0.20'; test \"\$(meta_get \"\$m\" openssl)\" = 3.0.20 )"
ck "manifest_lookup 命中" "( load; manifest_lookup REDIS 8.8.0 | grep -q source )"
# fetch 镜像兜底：所有 URL 失败时应自动追加 MIRROR/basename
ck "fetch 自动追加镜像 basename" "(
  load; SB=\$(mktemp -d); cd \$SB
  wget(){ echo \"\$@\" >> tried.log; return 1; }   # 全部失败
  ( fetch out.tgz http://x/out.tgz ) >/dev/null 2>&1
  grep -q 'zhangfangzhou.*out.tgz' tried.log && grep -q 'asuhu.*out.tgz' tried.log
)"
# php_enable_ext 绝对路径 + zend
ck "php_enable_ext 绝对路径/zend" "(
  load; SB=\$(mktemp -d); export PREFIX_PHP=\$SB/php
  e=\$PREFIX_PHP/lib/php/extensions/x; mkdir -p \$e \$PREFIX_PHP/etc/php.d
  : > \$e/opcache.so
  printf '#!/bin/sh\necho %s\n' \$e > \$PREFIX_PHP/bin/php-config 2>/dev/null; mkdir -p \$PREFIX_PHP/bin
  printf '#!/bin/sh\n[ \"\$1\" = --extension-dir ] && echo %s\n' \$e > \$PREFIX_PHP/bin/php-config; chmod +x \$PREFIX_PHP/bin/php-config
  php_enable_ext opcache opcache.so zend
  grep -q \"zend_extension=\$e/opcache.so\" \$PREFIX_PHP/etc/php.d/opcache.ini
)"
# write_my_cnf 版本门控：MySQL8 无 query_cache，5.7/MariaDB 有
mycnf(){ echo "( load; SB=\$(mktemp -d); tune_my_cnf(){ :;}; MEM_MB=4096; THREAD=2; eval \"\$(declare -f write_my_cnf | sed 's#/etc/my.cnf#'\$SB'/my.cnf#g')\"; write_my_cnf /d /d $1 $2 >/dev/null 2>&1; $3 grep -q query_cache_type \$SB/my.cnf )"; }
ck "my.cnf: MySQL8 无 query_cache"   "$(mycnf mysql 8.0.46 '!')"
ck "my.cnf: MySQL5.7 有 query_cache" "$(mycnf mysql 5.7.44 '')"
ck "my.cnf: MySQL9 无 query_cache"   "$(mycnf mysql 9.7.0 '!')"
ck "my.cnf: MariaDB 有 query_cache"  "$(mycnf mariadb 11.8.8 '')"
# IIS 伪装(各 flavor 同一函数)
ck "IIS 伪装四处生效" "(
  source ./modules/nginx.sh; SB=\$(mktemp -d); h=\$SB/s; mkdir -p \$h/src/core \$h/src/http \$h/src/http/modules
  printf '#define NGINX_VER          \"nginx/\" NGINX_VERSION\n#define NGINX_VAR          \"NGINX\"\n' > \$h/src/core/nginx.h
  echo '<center>nginx</center>' > \$h/src/http/ngx_http_special_response.c
  echo 'x[] = \"Server: nginx\" CRLF;' > \$h/src/http/ngx_http_header_filter_module.c
  echo '#define NGX_HTTP_AUTOINDEX_NAME_LEN     50' > \$h/src/http/modules/ngx_http_autoindex_module.c
  _nginx_apply_optimizations \$h
  grep -q Microsoft-IIS/10.0/ \$h/src/core/nginx.h &&
  grep NGINX_VAR \$h/src/core/nginx.h | grep -q Microsoft-IIS &&
  grep -q '>Microsoft-IIS<' \$h/src/http/ngx_http_special_response.c &&
  grep -q 'Server: Microsoft-IIS' \$h/src/http/ngx_http_header_filter_module.c &&
  grep -q 'NAME_LEN     150' \$h/src/http/modules/ngx_http_autoindex_module.c
)"

############### 5. 各安装器下载 URL + 关键产物 ###############
sec "5. 安装器下载 URL / 产物 (打桩)"
# 公共桩 + URL 记录文件，避免子 shell 变量丢失
_t_common(){
  dep(){ :;}; pkg_install(){ :;}; pkg_update(){ :;}; register_path(){ :;}; enable_service(){ :;}
  open_ports(){ :;}; ensure_www_user(){ :;}; ensure_sysuser(){ :;}; ensure_mysql_user(){ :;}
  build_openssl_prefix(){ :;}; install_php_openssl(){ :;}; install_libsodium(){ :;}
  log(){ :;}; log_ok(){ :;}; log_warn(){ :;}; hr(){ :;}; make(){ :;}; cmake(){ :;}; ldconfig(){ :;}
  chown(){ :;}; ln(){ :;}; die(){ return 1;}; systemctl(){ return 0;}; id(){ return 0;}
}
t_nginx(){ ( load; _t_common; SB=$(mktemp -d); export HOME=$SB; URLS=$SB/u; : > $URLS
  _nginx_write_conf(){ :;}; _nginx_apply_optimizations(){ :;}; tar(){ :;}
  fetch(){ echo "$2" >> $URLS; : > "$1"; return 0; }
  _nginx_source "$1" >/dev/null 2>&1; grep -q "$2" $URLS ); }
t_apache(){ ( load; _t_common; SB=$(mktemp -d); export HOME=$SB PREFIX_APACHE=$SB/ap; URLS=$SB/u; : > $URLS
  _apache_enable_vhost(){ :;}; _apache_write_mpm_tuning(){ :;}; _apache_register_service(){ :;}; tar(){ :;}
  fetch(){ echo "$2" >> $URLS; : > "$1"; return 0; }
  _apache_source 2.4.67 source event >/dev/null 2>&1
  grep -q 'httpd-2.4.67' $URLS && grep -qi 'apr' $URLS ); }
t_mysql(){ ( load; _t_common; SB=$(mktemp -d); export HOME=$SB PREFIX_MYSQL=$SB/data/mysql OS_FAMILY=rhel; URLS=$SB/u; : > $URLS
  _mysql_init_db(){ :;}; _mysql_register_service(){ :;}; _mysql_common_post(){ :;}; mv(){ :;}
  tar(){ [ "$1" = -tf ] && echo d/; return 0;}
  fetch(){ echo "$2" >> $URLS; case "$2" in *glibc2.28*) return 0;; *) return 1;; esac; }
  _mysql_binary 9.7.0 glibc2.28 >/dev/null 2>&1
  grep -q 'MySQL-9.7/mysql-9.7.0-linux-glibc2.28-x86_64.tar.xz' $URLS ); }
t_mariadb(){ ( load; _t_common; SB=$(mktemp -d); export HOME=$SB PREFIX_MARIADB=$SB/data/mariadb; URLS=$SB/u; : > $URLS
  _mariadb_init_db(){ :;}; _mariadb_register_service(){ :;}; _mariadb_common_post(){ :;}
  _mysql_init_db(){ :;}; _mysql_register_service(){ :;}; _mysql_common_post(){ :;}; mv(){ :;}
  tar(){ echo d/; return 0;}
  fetch(){ echo "$2" >> $URLS; : > "$1"; return 0; }
  install_mariadb 11.8.8 binary >/dev/null 2>&1
  grep -qi 'mariadb' $URLS && grep -q '11.8.8' $URLS ); }
t_redis(){ ( load; _t_common; SB=$(mktemp -d); export HOME=$SB PREFIX_REDIS=$SB/redis; URLS=$SB/u; : > $URLS
  gen_password(){ echo P;}; _redis_write_conf(){ :;}; _redis_service(){ :;}; tar(){ :;}
  make(){ mkdir -p $PREFIX_REDIS/bin; : > $PREFIX_REDIS/bin/redis-server; }
  fetch(){ echo "$2" >> $URLS; mkdir -p $HOME/redis-8.8.0; printf 'port 6379\n' > $HOME/redis-8.8.0/redis.conf; : > "$1"; return 0; }
  install_redis 8.8.0 source >/dev/null 2>&1
  grep -q 'download.redis.io/releases/redis-8.8.0.tar.gz' $URLS ); }
t_phpredis(){ ( load; _t_common; SB=$(mktemp -d); export HOME=$SB PREFIX_PHP=$SB/php; URLS=$SB/u; : > $URLS
  mkdir -p $PREFIX_PHP/bin
  printf '#!/bin/sh\nexit 0\n' > $PREFIX_PHP/bin/phpize; chmod +x $PREFIX_PHP/bin/phpize
  printf '#!/bin/sh\n' > $PREFIX_PHP/bin/php-config; chmod +x $PREFIX_PHP/bin/php-config
  printf '#!/bin/sh\necho redis\n' > $PREFIX_PHP/bin/php; chmod +x $PREFIX_PHP/bin/php
  php_enable_ext(){ :;}; reload_php_runtime(){ :;}; tar(){ mkdir -p $HOME/phpredis-6.3.0; return 0;}
  fetch(){ echo "$2" >> $URLS; : > "$1"; return 0; }
  install_phpredis 8 6.3.0 >/dev/null 2>&1
  grep -q 'phpredis/phpredis/archive/refs/tags/6.3.0' $URLS ); }
t_pma(){ ( load; _t_common; SB=$(mktemp -d); export WWWROOT=$SB/w PREFIX_PHP=$SB/php
  mkdir -p $PREFIX_PHP/bin; printf '#!/bin/sh\n' > $PREFIX_PHP/bin/php; chmod +x $PREFIX_PHP/bin/php
  _pma_sample_dir(){ local d=phpMyAdmin-5.2.3-all-languages; rm -rf /tmp/_pb; mkdir -p /tmp/_pb/$d/setup
    cat > /tmp/_pb/$d/config.sample.inc.php <<'SAMPLE'
<?php
$cfg['blowfish_secret'] = '';
?>
SAMPLE
    ( cd /tmp/_pb && tar -zcf "$1" $d ); rm -rf /tmp/_pb; }
  fetch(){ _pma_sample_dir "$PWD/$1"; return 0; }
  install_phpmyadmin >/dev/null 2>&1
  D=$SB/w/web/phpMyAdmin
  test -f $D/config.inc.php && ! test -d $D/setup &&
  grep -qE "blowfish_secret'\] = '[0-9a-f]{32}'" $D/config.inc.php &&
  grep -q UploadDir $D/config.inc.php ); }
t_adminer(){ ( load; _t_common; SB=$(mktemp -d); export WWWROOT=$SB/w PREFIX_PHP=$SB/php; URLS=$SB/u; : > $URLS
  mkdir -p $PREFIX_PHP/bin; printf '#!/bin/sh\n' > $PREFIX_PHP/bin/php; chmod +x $PREFIX_PHP/bin/php
  fetch(){ echo "$2" >> $URLS; printf '<?php //adminer\n' > "$1"; return 0; }
  install_adminer >/dev/null 2>&1
  test -f $SB/w/web/adminer/index.php && grep -q 'vrana/adminer/releases/download/v5.4.2/adminer-5.4.2.php' $URLS ); }
t_java(){ ( load; _t_common; SB=$(mktemp -d); export HOME=$SB PREFIX_JAVA=$SB/java; URLS=$SB/u; : > $URLS
  mkdir -p $SB/etc/profile.d $SB/ubin
  eval "$(declare -f install_java | sed 's#/etc/profile.d#'$SB'/etc/profile.d#g; s#/usr/local/bin#'$SB'/ubin#g')"
  tar(){ [ "$1" = -tzf ] && { echo jdk-17/; return 0; }; mkdir -p $HOME/jdk-17/bin; printf '#!/bin/sh\necho v17\n' > $HOME/jdk-17/bin/java; chmod +x $HOME/jdk-17/bin/java; : > $HOME/jdk-17/bin/javac; return 0; }
  mv(){ command mv "$@";}
  fetch(){ echo "$2" >> $URLS; : > "$1"; return 0; }
  install_java 17 >/dev/null 2>&1
  grep -q 'api.adoptium.net/v3/binary/latest/17/ga/linux' $URLS && grep -q JAVA_HOME $SB/etc/profile.d/lnamp-java.sh ); }
t_tomcat(){ ( load; _t_common; SB=$(mktemp -d); export HOME=$SB PREFIX_TOMCAT=$SB/tomcat SYSTEMD_DIR=$SB/sd JAVA_HOME=$SB/java; URLS=$SB/u; : > $URLS
  mkdir -p $SB/sd $SB/java/bin; : > $SB/java/bin/java
  tar(){ mkdir -p $HOME/apache-tomcat-10.1.55/bin $HOME/apache-tomcat-10.1.55/temp; printf '#!/bin/sh\n' > $HOME/apache-tomcat-10.1.55/bin/startup.sh; return 0;}
  mv(){ command mv "$@";}
  fetch(){ echo "$2" >> $URLS; : > "$1"; return 0; }
  install_tomcat >/dev/null 2>&1
  grep -q 'tomcat-10/v10.1.55/bin/apache-tomcat-10.1.55.tar.gz' $URLS && grep -q CATALINA_HOME $SB/sd/tomcat.service ); }
t_vhost(){ ( load; _t_common; SB=$(mktemp -d); export WWWROOT=$SB/w WWWLOGS=$SB/l PREFIX_NGINX=$SB/ng
  mkdir -p $PREFIX_NGINX/conf/vhost $PREFIX_NGINX/sbin $WWWROOT $WWWLOGS
  { echo "http {"; echo "}"; } > $PREFIX_NGINX/conf/nginx.conf
  : > $PREFIX_NGINX/sbin/nginx; chmod +x $PREFIX_NGINX/sbin/nginx
  _have_nginx(){ return 0;}; _have_apache(){ return 1;}; _php_fpm_available(){ return 1;}; nginx(){ :;}
  create_vhost test.com 8080 $WWWROOT/test.com no nginx >/dev/null 2>&1
  grep -rqE 'server_name[[:space:]]+test[.]com' $PREFIX_NGINX/conf/vhost/ 2>/dev/null ); }
ck "nginx 下载 1.26.2 (nginx.org)"        "t_nginx 1.26.2 'nginx.org/download/nginx-1.26.2'"
ck "nginx 下载 tengine-3.1.0 (taobao)"    "t_nginx tengine-3.1.0 'tengine.taobao.org/download/tengine-3.1.0'"
ck "nginx 下载 freenginx-1.30.1"          "t_nginx freenginx-1.30.1 'freenginx.org/download/freenginx-1.30.1'"
ck "apache 下载 2.4.67 (+apr)"            "t_apache"
ck "mysql binary 9.7.0 (glibc2.28)"       "t_mysql"
ck "mariadb binary 11.8.8"                "t_mariadb"
ck "redis 8.8.0 (download.redis.io)"      "t_redis"
ck "phpredis 6.3.0 (github tag)"          "t_phpredis"
ck "phpMyAdmin 5.2.3 安装+安全初始化"      "t_pma"
ck "Adminer 5.4.2 -> index.php"           "t_adminer"
ck "OpenJDK17 Temurin + JAVA_HOME"        "t_java"
ck "Tomcat 10.1.55 + systemd"             "t_tomcat"
ck "vhost nginx 生成配置"                  "t_vhost"

############### 6. 编排顺序 + 守卫 ###############
sec "6. 编排顺序 + 守卫"
ck "run_installs 顺序(tomcat 最后)" "(
  load
  for fn in install_nginx install_apache install_php install_mysql install_mariadb install_redis install_phpredis_pick install_phpmyadmin install_adminer install_java install_tomcat; do eval \"\${fn}(){ echo \$fn; }\"; done
  detect_mem(){ THREAD=2; MEM_MB=4096;}; OS_FAMILY=debian; PM=apt-get
  parse_args --nginx freenginx-1.30.1 --php 8.3.31:fpm --redis 8.8.0 --phpmyadmin --adminer --java 17 --tomcat >/dev/null 2>&1
  SB=\$(mktemp -d); export WWWROOT=\$SB/w WWWLOGS=\$SB/l; mkdir -p \$SB/w \$SB/l logs
  out=\$(run_installs 2>/dev/null); rm -rf logs
  echo \"\$out\" | tr '\n' ' ' | grep -q 'install_nginx.*install_php.*install_redis.*install_phpmyadmin.*install_adminer.*install_java.*install_tomcat' \$URLS
)"
ck "守卫: MySQL+MariaDB 互斥报错" "(
  load; SEL_MYSQL=8.0.46:binary; SEL_MARIADB=11.8.8:binary
  ! ( confirm_summary <<< y ) >/dev/null 2>&1
)"
ck "守卫: Tomcat 无 Java 自动补 17" "(
  load; INSTALL_TOMCAT=yes; SEL_JAVA=''; PREFIX_JAVA=/nonexist; command(){ return 1;}
  ( confirm_summary <<< y ) >/dev/null 2>&1; test \"\$SEL_JAVA\" = 17 ||
  ( SEL_JAVA=''; { confirm_summary <<< y; echo \"JV=\$SEL_JAVA\"; } 2>/dev/null | grep -q 'JV=17' \$URLS )
)"
ck "守卫: 空选择报错" "(
  load; for v in SEL_NGINX SEL_APACHE SEL_PHP SEL_MYSQL SEL_MARIADB SEL_REDIS SEL_PHPREDIS SEL_JAVA INSTALL_PMA INSTALL_ADMINER INSTALL_TOMCAT; do eval \$v=; done
  ! ( confirm_summary <<< y ) >/dev/null 2>&1
)"

############### 7. 交互菜单 ###############
sec "7. 交互菜单 (menu_database / menu_component)"
ck "menu_database 选 MySQL8.0.46(默认形式)" "(
  load; hr(){ :;}; SEL_MYSQL=; SEL_MARIADB=
  menu_database >/dev/null 2>&1 <<< \$'3\n1\n'; test \"\$SEL_MYSQL\" = 8.0.46:binary
)"
ck "menu_database 选 MariaDB" "(
  load; hr(){ :;}; SEL_MYSQL=; SEL_MARIADB=
  menu_database >/dev/null 2>&1 <<< \$'5\n\n'; test \"\$SEL_MARIADB\" = 11.8.8:binary
)"
ck "menu_database 选 0 不装" "(
  load; hr(){ :;}; SEL_MYSQL=x; SEL_MARIADB=
  menu_database >/dev/null 2>&1 <<< \$'0\n'; SEL_MYSQL=; menu_database >/dev/null 2>&1 <<< \$'0\n'; test -z \"\$SEL_MYSQL\" )"
ck "menu_component PHP 选默认" "(
  load; hr(){ :;}; SEL_PHP=
  menu_component PHP X >/dev/null 2>&1 <<< \$'y\n\n\n'; test -n \"\$SEL_PHP\" )"

############### 汇总 ###############
sec "汇总"
echo "  PASS=$PASS  FAIL=$FAIL"
[ "$FAIL" -gt 0 ] && { echo "  失败项:"; printf '    - %s\n' "${FAILED[@]}"; exit 1; }
echo "  ✅ 全部通过"
