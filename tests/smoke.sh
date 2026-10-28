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

############### 1. 静态检查 ###############
sec "1. 静态检查 (syntax + shellcheck)"
for f in install.sh lib/common.sh modules/*.sh versions.conf; do
  ck "bash -n $f" "bash -n '$f'"
done
# 换行符必须是 LF：CRLF 会让 Linux 上的 bash 报 "bad interpreter: /bin/bash^M"
# （在 Windows 上编辑/生成脚本时最容易踩到，且 bash -n 查不出来）
_lf_only(){
  local f line
  for f in "$@"; do
    while IFS= read -r line || [ -n "$line" ]; do
      case "$line" in
        *$'\r') echo "CRLF: $f"; return 1 ;;
      esac
    done < "$f"
  done
  return 0
}
ck "所有脚本/清单为 LF 换行" "_lf_only install.sh lib/common.sh modules/*.sh tests/*.sh versions.conf"
# ck 的测试体是双引号字符串：里面出现未转义的 " 会提前掐断字符串，bash 把引号当
# 定界符吃掉——桩 heredoc 里的 JSON（{"name":...}）会变成无引号的 {name:...}，
# 导致断言悄悄失效（曾致 mirror official 用例假失败、另一个用例的断言成死代码）。
# 这里做静态守卫：多行 ck 测试体内不允许出现未转义双引号。
# 兼容三种写法：① ')"' 独立成行；② ')"' 与最后一行正文粘连；③ 正文起于 ck 行本身。
_ck_quotes_ok(){
  local f="$1" in_ck=0 line body stripped
  while IFS= read -r line; do
    if [ "$in_ck" = 0 ]; then
      case "$line" in
        'ck '*'"(')
          in_ck=1
          body=${line#*'"('}
          case "$body" in *')"') in_ck=0; body=${body%')"'} ;; esac
          ;;
        *) continue ;;
      esac
    else
      case "$line" in
        *')"') in_ck=0; body=${line%')"'} ;;
        *) body="$line" ;;
      esac
    fi
    stripped="${body//\\\"/}"
    case "$stripped" in
      *'"'*) echo "未转义双引号 (unescaped quote): $body"; return 1 ;;
    esac
  done < "$f"
  return 0
}
ck "ck 多行测试体内无未转义双引号（防桩 JSON 引号被吃掉）" "_ck_quotes_ok tests/smoke.sh"
# shellcheck 不一定在 PATH 里；把常见的离线副本目录也找一找，找到就真的跑一遍
for _scdir in /tmp/shellcheck-dl /usr/local/bin /opt/shellcheck; do
  if [ -x "$_scdir/shellcheck" ] || [ -x "$_scdir/shellcheck.exe" ]; then
    case ":$PATH:" in *":$_scdir:"*) ;; *) PATH="$_scdir:$PATH"; export PATH ;; esac
  fi
done
if command -v shellcheck >/dev/null 2>&1; then
  ck "shellcheck -S error (全部)" "timeout 120 shellcheck -S error install.sh lib/common.sh modules/*.sh versions.conf"
else
  printf '  [SKIP] shellcheck -S error：未安装 shellcheck，跳过\n'
fi

############### 2. 清单完整性 + 默认值 ###############
sec "2. 清单 + validate_choice(每个版本/形式) + 默认值"
( load
  comps="NGINX APACHE PHP MYSQL MARIADB REDIS PHPREDIS MEMCACHED PHPMEMCACHED SWOOLE COMPOSER NODE FAIL2BAN"
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
ck "MySQL 默认=8.4.13" "( load; test \"\$MYSQL_DEFAULT\" = 8.4.13 )"
ck "未知版本被拒绝" "( load; ! ( validate_choice NGINX 9.9.9 source ) 2>/dev/null )"

############### 3. CLI 解析 ###############
sec "3. CLI flags 解析"
ckcli(){ ck "$1" "( load; require_root(){ :;}; detect_os(){ OS_FAMILY=debian; PM=apt-get;}; parse_args $2 >/dev/null 2>&1; $3 )"; }
ckcli "--nginx freenginx-1.30.1"   "--nginx freenginx-1.30.1"   'test "$SEL_NGINX" = freenginx-1.30.1:source'
ckcli "--nginx tengine-3.1.0"      "--nginx tengine-3.1.0"      'test "$SEL_NGINX" = tengine-3.1.0:source'
ckcli "--apache + mpm"             "--apache 2.4.69:source --apache-mpm event" 'test "$SEL_APACHE" = 2.4.69:source -a "$APACHE_MPM" = event'
ckcli "--php fpm"                  "--php 8.3.36:fpm"           'test "$SEL_PHP" = 8.3.36:fpm'
ckcli "--mysql 9.7.4"             "--mysql 9.7.4"              'test "$SEL_MYSQL" = 9.7.4:binary'
ckcli "--mariadb"                 "--mariadb 11.8.8"           'test "$SEL_MARIADB" = 11.8.8:binary'
ckcli "--redis 8.8.3"            "--redis 8.8.3"             'test "$SEL_REDIS" = 8.8.3:source'
ckcli "--phpredis"               "--phpredis 6.3.0"           'test "$SEL_PHPREDIS" = 6.3.0:source'
ckcli "--php-imagick"            "--php 8.3.36 --php-imagick"  'test "$PHP_IMAGICK" = yes'
ckcli "--imagemagick-source"     "--imagemagick-source"       'test "$IMAGEMAGICK_SOURCE" = yes -a "$PHP_IMAGICK" = yes'
ckcli "--phpmyadmin"             "--phpmyadmin"               'test "$INSTALL_PMA" = yes'
ckcli "--adminer"                "--adminer"                  'test "$INSTALL_ADMINER" = yes'
ckcli "--java 17"                "--java 17"                  'test "$SEL_JAVA" = 17'
ckcli "--tomcat"                 "--tomcat"                   'test "$INSTALL_TOMCAT" = yes'
ck   "--java 9 报错" "( load; ! ( parse_args --java 9 ) 2>/dev/null )"

############### 4. 辅助函数 ###############
sec "4. 辅助函数 (meta_get / fetch镜像 / php_enable_ext / write_my_cnf / IIS)"
ck "meta_get 取值" "( load; m='flavor=freenginx;openssl=3.0.20'; test \"\$(meta_get \"\$m\" openssl)\" = 3.0.20 )"
ck "manifest_lookup 命中" "( load; manifest_lookup REDIS 8.8.3 | grep -q source )"
# fetch 镜像兜底：所有 URL 失败时应自动追加 MIRROR/basename
ck "fetch 自动追加镜像 basename" "(
  load; SB=\$(mktemp -d); cd \$SB
  wget(){ echo \"\$@\" >> tried.log; return 1; }   # 全部失败
  ( fetch out.tgz http://x/out.tgz ) >/dev/null 2>&1
  grep -q 'zhangfangzhou.*out.tgz' tried.log && grep -q 'asuhu.*out.tgz' tried.log
)"
# php_enable_ext 绝对路径 + zend
# 注意：桩必须用 printf 而不是 echo —— Git Bash 的 /bin/sh(dash) 的 echo 会吃掉
# 反斜杠（C:\Users\... -> C:Users...），导致 php-config 的 extension-dir 失真、
# -f 探测失败，测试在 Windows 上假失败。真实 Linux 上不受影响。
# 这里用环境变量把路径传进桩，彻底绕开路径转义问题。
ck "php_enable_ext 绝对路径/zend" "(
  load; SB=\$(mktemp -d); export PREFIX_PHP=\$SB/php
  e=\$PREFIX_PHP/lib/php/extensions/x; mkdir -p \$e \$PREFIX_PHP/etc/php.d \$PREFIX_PHP/bin
  : > \$e/opcache.so
  cat > \$PREFIX_PHP/bin/php-config <<'STUB'
#!/bin/sh
[ \"\$1\" = --extension-dir ] && printf '%s\\n' \"\$PRETEND_EXTDIR\"
STUB
  chmod +x \$PREFIX_PHP/bin/php-config
  PRETEND_EXTDIR=\"\$e\" php_enable_ext opcache opcache.so zend
  # -F：路径里带反斜杠时，BRE 会把 \U/\A 当成转义而匹配不上
  grep -qF \"zend_extension=\$e/opcache.so\" \$PREFIX_PHP/etc/php.d/opcache.ini
)"
# write_my_cnf 版本门控：MySQL8 无 query_cache，5.7/MariaDB 有
# 落盘路径用 MY_CNF_PATH 指到沙箱，避免测试污染宿主机 /etc/my.cnf。
mycnf(){ echo "( load; SB=\$(mktemp -d); tune_my_cnf(){ :;}; export MY_CNF_PATH=\$SB/my.cnf; MEM_MB=4096; THREAD=2; write_my_cnf /d /d $1 $2 >/dev/null 2>&1; $3 grep -q query_cache_type \$SB/my.cnf )"; }
ck "my.cnf: MySQL8 无 query_cache"   "$(mycnf mysql 8.0.46 '!')"
ck "my.cnf: MySQL5.7 有 query_cache" "$(mycnf mysql 5.7.44 '')"
ck "my.cnf: MySQL9 无 query_cache"   "$(mycnf mysql 9.7.4 '!')"
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
  export MY_CNF_PATH="$(mktemp -d)/my.cnf"   # 别写宿主机 /etc/my.cnf
  export LDSO_CONF_DIR="$(mktemp -d)"        # 别写宿主机 /etc/ld.so.conf.d
  export WWWROOT="$(mktemp -d)/www" WWWLOGS="$(mktemp -d)/logs"
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
  _apache_source 2.4.69 source event >/dev/null 2>&1
  grep -q 'httpd-2.4.69' $URLS && grep -qi 'apr' $URLS ); }
t_mysql(){ ( load; _t_common; SB=$(mktemp -d); export HOME=$SB PREFIX_MYSQL=$SB/data/mysql OS_FAMILY=rhel; URLS=$SB/u; : > $URLS
  _mysql_init_db(){ :;}; _mysql_register_service(){ :;}; _mysql_common_post(){ :;}; mv(){ :;}
  tar(){ [ "$1" = -tf ] && echo d/; return 0;}
  fetch(){ echo "$2" >> $URLS; case "$2" in *glibc2.28*) return 0;; *) return 1;; esac; }
  _mysql_binary 9.7.4 glibc2.28 >/dev/null 2>&1
  grep -q 'MySQL-9.7/mysql-9.7.4-linux-glibc2.28-x86_64.tar.xz' $URLS ); }
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
  fetch(){ echo "$2" >> $URLS; mkdir -p $HOME/redis-8.8.3; printf 'port 6379\n' > $HOME/redis-8.8.3/redis.conf; : > "$1"; return 0; }
  install_redis 8.8.3 source >/dev/null 2>&1
  grep -q 'download.redis.io/releases/redis-8.8.3.tar.gz' $URLS ); }
t_phpredis(){ ( load; _t_common; SB=$(mktemp -d); export HOME=$SB PREFIX_PHP=$SB/php; URLS=$SB/u; : > $URLS
  mkdir -p $PREFIX_PHP/bin
  printf '#!/bin/sh\nexit 0\n' > $PREFIX_PHP/bin/phpize; chmod +x $PREFIX_PHP/bin/phpize
  printf '#!/bin/sh\n' > $PREFIX_PHP/bin/php-config; chmod +x $PREFIX_PHP/bin/php-config
  printf '#!/bin/sh\necho redis\n' > $PREFIX_PHP/bin/php; chmod +x $PREFIX_PHP/bin/php
  php_enable_ext(){ :;}; reload_php_runtime(){ :;}; tar(){ mkdir -p $HOME/phpredis-6.3.0; return 0;}
  fetch(){ echo "$2" >> $URLS; : > "$1"; return 0; }
  install_phpredis 8 6.3.0 >/dev/null 2>&1
  grep -q 'pecl.php.net/get/redis-6.3.0.tgz' $URLS ); }
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
  # 真实 adminer 单文件约 500KB；安装器会校验「以 <?php 开头且体积 > 100KB」，
  # 桩文件必须仿真实际体积，否则会被当成 adminer.org 现在返回的 HTML 跳转页而丢弃。
  fetch(){ echo "$2" >> $URLS; { printf '<?php //adminer\n'; head -c 200000 /dev/zero | tr '\0' 'x'; } > "$1"; return 0; }
  install_adminer >/dev/null 2>&1
  test -f $SB/w/web/adminer/index.php && grep -q 'github.com/vrana/adminer/releases/download/v5.4.2/adminer-5.4.2.php' $URLS ); }
t_adminer_html(){ ( load; _t_common; SB=$(mktemp -d); export WWWROOT=$SB/w PREFIX_PHP=$SB/php; URLS=$SB/u; : > $URLS
  mkdir -p $PREFIX_PHP/bin; printf '#!/bin/sh\n' > $PREFIX_PHP/bin/php; chmod +x $PREFIX_PHP/bin/php
  # 模拟 2026-10 实测：首个源返回的是介绍页 HTML（wget 退出码仍是 0），
  # 安装器必须识别出来、丢弃并换下一个源，最终落地真正的 PHP 单文件。
  fetch(){ echo "$2" >> $URLS
    case "$2" in
      *github.com*) printf '<!DOCTYPE html><html><body>Adminer</body></html>\n' > "$1" ;;
      *) { printf '<?php //adminer\n'; head -c 200000 /dev/zero | tr '\0' 'x'; } > "$1" ;;
    esac
    return 0; }
  install_adminer >/dev/null 2>&1
  # 两个源都被尝试过，且最终落地的是 >100KB 的 PHP 单文件（不是 HTML 跳转页）
  [ "$(grep -c . $URLS)" -ge 2 ] &&
  head -c 5 $SB/w/web/adminer/index.php 2>/dev/null | grep -q '<?php' &&
  [ "$(stat -c %s $SB/w/web/adminer/index.php 2>/dev/null || echo 0)" -gt 100000 ] ); }
t_java(){ ( load; _t_common; SB=$(mktemp -d); export HOME=$SB PREFIX_JAVA=$SB/java; URLS=$SB/u; : > $URLS
  mkdir -p $SB/etc/profile.d $SB/ubin
  # install_java 里 /etc/profile.d 是裸词（无引号），eval 重新解析函数文本时
  # Windows 路径中的 \U \A \2 会被当成转义吃掉，导致写进相对路径的野目录。
  # 因此这里用 ${LNAMP_TEST_PD} 占位符传路径，eval 文本里不出现字面量反斜杠。
  export LNAMP_TEST_PD="$SB/etc/profile.d" LNAMP_TEST_UB="$SB/ubin"
  eval "$(_rwfn install_java /etc/profile.d '${LNAMP_TEST_PD}' /usr/local/bin '${LNAMP_TEST_UB}')"
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
ck "apache 下载 2.4.69 (+apr)"            "t_apache"
ck "mysql binary 9.7.4 (glibc2.28)"       "t_mysql"
ck "mariadb binary 11.8.8"                "t_mariadb"
ck "redis 8.8.3 (download.redis.io)"      "t_redis"
ck "phpredis 6.3.0 (github tag)"          "t_phpredis"
ck "phpMyAdmin 5.2.3 安装+安全初始化"      "t_pma"
ck "Adminer 5.4.2 -> index.php"           "t_adminer"
ck "Adminer 丢弃 HTML 跳转页并换源"        "t_adminer_html"
ck "OpenJDK17 Temurin + JAVA_HOME"        "t_java"
ck "Tomcat 10.1.55 + systemd"             "t_tomcat"
ck "vhost nginx 生成配置"                  "t_vhost"

############### 6. 编排顺序 + 守卫 ###############
sec "6. 编排顺序 + 守卫"
ck "run_installs 顺序(tomcat 最后)" "(
  load
  for fn in install_nginx install_apache install_php install_mysql install_mariadb install_redis install_phpredis_pick install_phpmyadmin install_adminer install_java install_tomcat; do eval \"\${fn}(){ echo \$fn; }\"; done
  detect_mem(){ THREAD=2; MEM_MB=4096;}; OS_FAMILY=debian; PM=apt-get
  parse_args --nginx freenginx-1.30.1 --php 8.3.36:fpm --redis 8.8.3 --phpmyadmin --adminer --java 17 --tomcat >/dev/null 2>&1
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

############### 8. 新增组件 (fail2ban / Memcached / Swoole / Composer / Node.js) ###############
sec "8. 新增组件：fail2ban / Memcached / Swoole / Composer / Node.js"
# ---- CLI 解析 ----
ckcli "--memcached 默认"        "--memcached"             'test "$SEL_MEMCACHED" = 1.6.45:source'
ckcli "--memcached :pkg"        "--memcached 1.6.45:pkg"  'test "$SEL_MEMCACHED" = 1.6.45:pkg'
ckcli "--php-memcached"         "--php-memcached"         'test "$SEL_PHPMEMCACHED" = 3.4.0:source'
ckcli "--no-php-memcached 覆盖" "--php-memcached --no-php-memcached" 'test -z "$SEL_PHPMEMCACHED" -a -n "$PHP_MEMCACHED_NO"'
ckcli "--swoole"                "--swoole"                'test "$SEL_SWOOLE" = 6.2.3:source'
ckcli "--composer"              "--composer"              'test "$SEL_COMPOSER" = 2.10.3:phar'
ckcli "--composer 2.2.30"       "--composer 2.2.30"       'test "$SEL_COMPOSER" = 2.2.30:phar'
ckcli "--nodejs 默认"           "--nodejs"                'test "$SEL_NODE" = 24.22.1:binary'
ckcli "--nodejs 22.23.4"        "--nodejs 22.23.4"        'test "$SEL_NODE" = 22.23.4:binary'
ckcli "--fail2ban"              "--fail2ban"              'test "$INSTALL_FAIL2BAN" = yes'
ckcli "--no-fail2ban"           "--no-fail2ban"           'test "$INSTALL_FAIL2BAN" = no'
ck "--swoole 未知版本报错"       "( load; ! ( parse_args --swoole 9.9.9 ) 2>/dev/null )"
ck "--composer 未知版本报错"     "( load; ! ( parse_args --composer 9.9.9 ) 2>/dev/null )"

# ---- 版本比较 ver_ge ----
ck "ver_ge 8.3.36>=8.0"        "( load; ver_ge 8.3.36 8.0 )"
ck "ver_ge 7.4.33<8.0"         "( load; ! ver_ge 7.4.33 8.0 )"
ck "ver_ge 6.2.3<6.3.0"        "( load; ! ver_ge 6.2.3 6.3.0 )"
ck "ver_ge 6.3.0>=6.3.0"       "( load; ver_ge 6.3.0 6.3.0 )"
ck "ver_ge 5.6.40<7.2.5"       "( load; ! ver_ge 5.6.40 7.2.5 )"

# ---- ask_yes_no 非交互退化 ----
ck "ask_yes_no 非交互取默认 n"  "( load; ! ( ask_yes_no '装吗?' n ) </dev/null 2>/dev/null )"
ck "ask_yes_no 非交互取默认 y"  "( load; ( ask_yes_no '装吗?' y ) </dev/null 2>/dev/null )"
ck "ask_yes_no ASSUME_YES=1 取默认 y" "( load; ASSUME_YES=1; ( ask_yes_no '装吗?' y ) </dev/null 2>/dev/null )"

# ---- Memcached 内存分档 ----
ck "memcached 内存 4G->512"    "( load; MEM_MB=4096; test \"\$(_memcached_mb)\" = 512 )"
ck "memcached 内存 256M->64"   "( load; MEM_MB=256;  test \"\$(_memcached_mb)\" = 64 )"
ck "memcached 内存 64G->4096"  "( load; MEM_MB=65536; test \"\$(_memcached_mb)\" = 4096 )"
ck "memcached 只监听 127.0.0.1" "(
  load; _t_common; SB=\$(mktemp -d); export HOME=\$SB PREFIX_MEMCACHED=\$SB/mc SYSTEMD_DIR=\$SB/sd MEM_MB=4096
  mkdir -p \$SB/sd \$PREFIX_MEMCACHED/bin
  printf '#!/bin/sh\n' > \$PREFIX_MEMCACHED/bin/memcached; chmod +x \$PREFIX_MEMCACHED/bin/memcached
  cd \$SB; log_run(){ :;}; tar(){ :;}; fetch(){ : > \"\$1\"; return 0;}
  _memcached_source 1.6.45 >/dev/null 2>&1
  grep -q '^-l 127.0.0.1' \$PREFIX_MEMCACHED/etc/memcached.conf &&
  grep -q 'l 127.0.0.1' \$SB/sd/memcached.service &&
  ! grep -q '0.0.0.0' \$SB/sd/memcached.service
)"

# ---- Node 架构映射 ----
ck "node arch x86_64->x64"      "( source ./modules/devtools.sh; uname(){ echo x86_64;}; test \"\$(_node_arch)\" = x64 )"
ck "node arch aarch64->arm64"   "( source ./modules/devtools.sh; uname(){ echo aarch64;}; test \"\$(_node_arch)\" = arm64 )"
ck "node arch armv7l->armv7l"   "( source ./modules/devtools.sh; uname(){ echo armv7l;}; test \"\$(_node_arch)\" = armv7l )"

# ---- Composer 版本门限 ----
ck "composer 2.10.3 拒绝 PHP5.6" "(
  load; _t_common; SB=\$(mktemp -d); export HOME=\$SB PREFIX_PHP=\$SB/php; D=\$SB/die; : > \$D
  mkdir -p \$PREFIX_PHP/bin; printf '#!/bin/sh\n' > \$PREFIX_PHP/bin/php; chmod +x \$PREFIX_PHP/bin/php
  php_bin_version(){ echo 5.6.40;}; fetch(){ :;}; die(){ echo \"\$*\" >> \$D; return 1;}; log_run(){ :;}
  _composer_phar 2.10.3 >/dev/null 2>&1; grep -q '需要 PHP >= 7.2.5' \$D
)"
ck "composer 2.2.30 接受 PHP5.6" "(
  load; _t_common; SB=\$(mktemp -d); export HOME=\$SB PREFIX_PHP=\$SB/php; URLS=\$SB/u; : > \$URLS
  mkdir -p \$PREFIX_PHP/bin; printf '#!/bin/sh\n' > \$PREFIX_PHP/bin/php; chmod +x \$PREFIX_PHP/bin/php
  php_bin_version(){ echo 5.6.40;}; log_run(){ :;}
  fetch(){ echo \"\$2\" >> \$URLS; : > \"\$1\"; return 0;}
  _composer_phar 2.2.30 >/dev/null 2>&1; grep -q 'getcomposer.org/download/2.2.30/composer.phar' \$URLS
)"

# ---- Swoole configure 版本感知 (6.3.0 起移除 --enable-openssl) ----
ck "swoole 6.2.3 带 --enable-openssl" "(
  load; _t_common; SB=\$(mktemp -d); export HOME=\$SB PREFIX_PHP=\$SB/php; ARGS=\$SB/a; : > \$ARGS
  mkdir -p \$PREFIX_PHP/bin
  printf '#!/bin/sh\nexit 0\n' > \$PREFIX_PHP/bin/phpize;  chmod +x \$PREFIX_PHP/bin/phpize
  printf '#!/bin/sh\nexit 0\n' > \$PREFIX_PHP/bin/php-config; chmod +x \$PREFIX_PHP/bin/php-config
  php_bin_version(){ echo 8.3.36;}; php_enable_ext(){ :;}; reload_php_runtime(){ :;}
  tar(){ mkdir -p \$HOME/swoole-src-6.2.3; return 0;}
  fetch(){ : > \"\$1\"; return 0;}
  log_run(){ shift; echo \"\$*\" >> \$ARGS; return 0;}
  _swoole_source 6.2.3 >/dev/null 2>&1; grep -q 'enable-openssl' \$ARGS
)"
ck "swoole 6.3.0 不带 --enable-openssl" "(
  load; _t_common; SB=\$(mktemp -d); export HOME=\$SB PREFIX_PHP=\$SB/php; ARGS=\$SB/a; : > \$ARGS
  mkdir -p \$PREFIX_PHP/bin
  printf '#!/bin/sh\nexit 0\n' > \$PREFIX_PHP/bin/phpize;  chmod +x \$PREFIX_PHP/bin/phpize
  printf '#!/bin/sh\nexit 0\n' > \$PREFIX_PHP/bin/php-config; chmod +x \$PREFIX_PHP/bin/php-config
  php_bin_version(){ echo 8.3.36;}; php_enable_ext(){ :;}; reload_php_runtime(){ :;}
  tar(){ mkdir -p \$HOME/swoole-src-6.3.0; return 0;}
  fetch(){ : > \"\$1\"; return 0;}
  log_run(){ shift; echo \"\$*\" >> \$ARGS; return 0;}
  _swoole_source 6.3.0 >/dev/null 2>&1; ! grep -q 'enable-openssl' \$ARGS
)"
ck "cxx14: 不存在的编译器判不可用" "( load; ! _cxx14_ok /nonexistent/g++ )"
ck "cxx14: 编译失败的编译器判不可用" "(
  load; SB=\$(mktemp -d)
  printf '#!/bin/sh\nexit 1\n' > \$SB/badg++; chmod +x \$SB/badg++
  ! _cxx14_ok \$SB/badg++
)"
ck "cxx14: 能编能跑的编译器判可用" "(
  load; SB=\$(mktemp -d)
  cat > \$SB/fakeg++ <<'STUB'
#!/bin/sh
while [ \$# -gt 0 ]; do
  case \"\$1\" in -o) shift; : > \"\$1\"; chmod +x \"\$1\" ;; esac
  shift
done
exit 0
STUB
  chmod +x \$SB/fakeg++
  _cxx14_ok \$SB/fakeg++
)"
ck "cxx14: 干跑下 ensure_cxx14_toolchain 返回 0" "(
  load; export DRY_RUN=1
  ensure_cxx14_toolchain >/dev/null 2>&1
)"

ck "swoole 版本门限 (PHP7 拒绝 6.2.3)" "(
  load; _t_common; SB=\$(mktemp -d); export PREFIX_PHP=\$SB/php; D=\$SB/die; : > \$D
  mkdir -p \$PREFIX_PHP/bin
  printf '#!/bin/sh\n' > \$PREFIX_PHP/bin/phpize; chmod +x \$PREFIX_PHP/bin/phpize
  printf '#!/bin/sh\n' > \$PREFIX_PHP/bin/php-config; chmod +x \$PREFIX_PHP/bin/php-config
  php_bin_version(){ echo 7.4.33;}; die(){ echo \"\$*\" >> \$D; return 1;}; log_run(){ :;}
  _swoole_source 6.2.3 >/dev/null 2>&1; grep -q '需要 PHP >= 8.0' \$D
)"

# ---- fail2ban 三个 jail ----
ck "fail2ban 生成三个 jail" "(
  load; _t_common; SB=\$(mktemp -d); export WWWLOGS=\$SB/logs OS_FAMILY=rhel SEL_NGINX=1.30.6:source
  mkdir -p \$WWWLOGS
  eval \"\$(_rwfn _fail2ban_write_jail /etc/fail2ban \"\$SB/f2b\")\"
  _fail2ban_write_jail >/dev/null 2>&1
  f=\$SB/f2b/jail.d/lnamp.local
  grep -q '^\[sshd\]' \$f && grep -q '^\[nginx-http-auth\]' \$f && grep -q '^\[nginx-limit-req\]' \$f
)"
ck "fail2ban nginx jail logpath 匹配真实错误日志" "(
  load; _t_common; SB=\$(mktemp -d); export WWWLOGS=\$SB/logs OS_FAMILY=rhel SEL_NGINX=1.30.6:source
  mkdir -p \$WWWLOGS
  eval \"\$(_rwfn _fail2ban_write_jail /etc/fail2ban \"\$SB/f2b\")\"
  _fail2ban_write_jail >/dev/null 2>&1
  f=\$SB/f2b/jail.d/lnamp.local
  lp=\$(sed -n '/^\[nginx-http-auth\]/,/^$/p' \$f | grep '^logpath' | awk '{print \$3}')
  # Windows 下 mktemp 路径含反斜杠，compgen -G 会把 \ 当模式转义符而匹配失败
  # （Linux 无反斜杠无此问题）。注意：测试体经 ck 的双引号+eval 两层解析会吃掉
  # 一层反斜杠，所以这里写 4 个（eval 后 tr 收到 2 个 = 一个字面反斜杠）。
  lp=\$(printf '%s' \"\$lp\" | tr '\\\\' '/')
  # 主错误日志 error_nginx.log 与 vhost 的 <域名>.error.log 都要能被 glob 命中
  : > \$WWWLOGS/error_nginx.log
  [ -n \"\$(compgen -G \"\$lp\")\" ]
)"
ck "fail2ban 无 web 服务器时不写 nginx jail" "(
  load; _t_common; SB=\$(mktemp -d); export WWWLOGS=\$SB/logs OS_FAMILY=rhel
  export PREFIX_NGINX=\$SB/nope PREFIX_APACHE=\$SB/nope2
  mkdir -p \$WWWLOGS
  SEL_NGINX=''; SEL_APACHE=''
  eval \"\$(_rwfn _fail2ban_write_jail /etc/fail2ban \"\$SB/f2b\")\"
  _fail2ban_write_jail >/dev/null 2>&1
  f=\$SB/f2b/jail.d/lnamp.local
  grep -q '^\[sshd\]' \$f && ! grep -q 'nginx-http-auth' \$f
)"
# 不再按发行版写死路径：Debian 12 根本没有 /var/log/auth.log（无 rsyslog），
# 写死会让 sshd jail "Have not found any log file" 硬失败。
# 现在按 auth.log → secure → messages 探测真实存在的文件，都没有就返回空
# （调用方改 backend = systemd 读 journal）。
ck "fail2ban SSH 日志按实际存在的文件探测" "(
  load; a=\$(_fail2ban_ssh_log)
  if [ -n \"\$a\" ]; then
    test -s \"\$a\"                      # 返回了路径，就必须是真实存在的文件
  else
    ! { [ -s /var/log/auth.log ] || [ -s /var/log/secure ] || [ -s /var/log/messages ]; }
  fi
)"

# ---- uninstall / upgrade 元数据表 ----
ck "uninstall 元数据覆盖全部组件" "(
  load; bad=0
  for c in nginx apache php mysql mariadb redis memcached fail2ban java tomcat phpmyadmin adminer composer nodejs phpredis phpmemcached swoole; do
    _un_fields \"\$c\" || { bad=1; echo MISS \$c; }
  done
  [ \$bad = 0 ]
)"
ck "uninstall 未知组件返回 1"     "( load; ! ( _un_fields nosuchcomp ) 2>/dev/null )"
ck "uninstall mysql 带数据保留标记" "( load; _un_fields mysql; test -n \"\$_U_EXTRA\" -a \"\$_U_SVC\" = mysqld )"
ck "uninstall composer 指向 /usr/local/bin/composer" "( load; _un_fields composer; test \"\$_U_EXTRA\" = /usr/local/bin/composer )"
ck "uninstall --list 可运行"      "( load; _t_common; _un_list_installed >/dev/null 2>&1 )"
ck "uninstall 帮助可运行"        "( load; uninstall_main --help >/dev/null 2>&1 )"
ck "uninstall 未知组件报错"      "( load; ! ( uninstall_main --component nosuchcomp ) >/dev/null 2>&1 )"
ck "uninstall 无参数打印清单+用法(且退出码非0)" "( load; _t_common; ! ( uninstall_main >/dev/null 2>&1 ) )"
ck "upgrade 帮助可运行"          "( load; upgrade_main --help >/dev/null 2>&1 )"
ck "upgrade 未知组件报错"        "( load; ! ( upgrade_main nosuchcomp ) >/dev/null 2>&1 )"
ck "upgrade 同版本不重复安装"     "(
  load; _t_common; SB=\$(mktemp -d); : > \$SB/ran
  _up_current_version(){ echo 1.30.6;}; _up_run_installer(){ echo RAN >> \$SB/ran;}; _up_backup(){ :;}
  upgrade_main nginx 1.30.6 >/dev/null 2>&1
  ! test -s \$SB/ran
)"
ck "upgrade 数据库无 --force 拒绝" "(
  load; _t_common; SB=\$(mktemp -d); : > \$SB/ran
  _up_current_version(){ echo 8.0.46;}; _up_run_installer(){ echo RAN >> \$SB/ran;}; _up_backup(){ :;}
  ! ( upgrade_main mysql 8.4.13 ) >/dev/null 2>&1 && ! test -s \$SB/ran
)"
ck "upgrade 数据库带 --force 放行" "(
  load; _t_common; ASSUME_YES=1; SB=\$(mktemp -d); : > \$SB/ran
  _up_current_version(){ echo 8.0.46;}; _up_run_installer(){ echo RAN >> \$SB/ran; return 0;}; _up_backup(){ :;}
  upgrade_main mysql 8.4.13 --force >/dev/null 2>&1
  grep -q RAN \$SB/ran
)"
ck "upgrade 置 LNAMP_UPGRADE=1 后复位" "(
  load; _t_common; ASSUME_YES=1; SB=\$(mktemp -d)
  _up_current_version(){ echo 1.26.2;}; _up_backup(){ :;}
  _up_run_installer(){ echo \"UP=\$LNAMP_UPGRADE\" > \$SB/u; return 0;}
  upgrade_main nginx 1.30.6 >/dev/null 2>&1
  grep -q 'UP=1' \$SB/u && [ \"\$LNAMP_UPGRADE\" = 0 ]
)"

# ---- swap_prefix_keep_data：升级模式保住 datadir ----
# Git Bash(MSYS) 上 `rm -rf 目录` 对刚创建的目录常有延迟/失败，导致 mv 嵌套、
# 断言必然失败。这是平台限制，不是代码问题（Linux 真机上正常），故跳过。
_skip_msys(){ case "$(uname -s 2>/dev/null)" in MINGW*|MSYS*|CYGWIN*) return 0 ;; *) return 1 ;; esac; }
ck "swap_prefix 升级保留 data" "(
  _skip_msys && exit 0
  load; SB=\$(mktemp -d); export DRY_RUN=0 LNAMP_UPGRADE=1
  mkdir -p \$SB/prefix/data/mysql \$SB/new/data; : > \$SB/prefix/data/mysql/ibdata1; : > \$SB/prefix/old.bin; : > \$SB/new/new.bin
  swap_prefix_keep_data \$SB/prefix \$SB/new data >/dev/null 2>&1
  test -f \$SB/prefix/data/mysql/ibdata1 && test -f \$SB/prefix/new.bin && ! test -f \$SB/prefix/old.bin
)"
# 非升级整目录替换分两种语义（删库守卫之后）：
#   · 无 data/mysql（真·全新安装）→ 照常整目录替换；
#   · 有 data/mysql（可能删库）  → 必须拒绝替换，原样保住数据。
# 旧断言"非升级一律整目录替换"在守卫落地后与产品语义冲突，且因 _skip_msys
# 在 Windows 本地从未真跑过，真机才暴露 —— 拆成下面两条。
ck "swap_prefix 非升级无库时整目录替换" "(
  _skip_msys && exit 0
  load; SB=\$(mktemp -d); export DRY_RUN=0 LNAMP_UPGRADE=0
  mkdir -p \$SB/prefix \$SB/new; : > \$SB/prefix/old.bin; : > \$SB/new/new.bin
  swap_prefix_keep_data \$SB/prefix \$SB/new data >/dev/null 2>&1
  test -f \$SB/prefix/new.bin && ! test -f \$SB/prefix/old.bin
)"
ck "swap_prefix 非升级已有库时拒绝替换" "(
  _skip_msys && exit 0
  load; SB=\$(mktemp -d)
  export DRY_RUN=0 LNAMP_UPGRADE=0 LNAMP_BACKUP_DIR=\$SB/notadir
  : > \$SB/notadir                       # 导出目录是文件 → 导出必失败，走拒绝分支
  mkdir -p \$SB/prefix/data/mysql \$SB/new
  : > \$SB/prefix/data/mysql/ibdata1; : > \$SB/prefix/old.bin; : > \$SB/new/new.bin
  ( die(){ exit 1;}; swap_prefix_keep_data \$SB/prefix \$SB/new data >/dev/null 2>&1 )
  test \$? -ne 0 &&
  test -f \$SB/prefix/data/mysql/ibdata1 && test -f \$SB/prefix/old.bin && ! test -f \$SB/prefix/new.bin
)"

# ---- 干跑安全：新组件不得产生副作用 ----
ck "dry-run 不重启 php-fpm" "(
  load; export DRY_RUN=1; systemctl(){ echo CALLED; }
  out=\$(reload_php_runtime 2>&1); ! echo \"\$out\" | grep -q CALLED
)"
ck "dry-run 不创建 php.d ini" "(
  load; SB=\$(mktemp -d); export DRY_RUN=1 PREFIX_PHP=\$SB/php
  mkdir -p \$PREFIX_PHP/bin; printf '#!/bin/sh\n' > \$PREFIX_PHP/bin/php-config; chmod +x \$PREFIX_PHP/bin/php-config
  php_enable_ext swoole swoole.so >/dev/null 2>&1
  ! test -f \$PREFIX_PHP/etc/php.d/swoole.ini
)"
ck "dry-run register_path 不写 profile.d" "(
  load; SB=\$(mktemp -d); export DRY_RUN=1 PREFIX_NODE=\$SB/node
  mkdir -p \$PREFIX_NODE/bin; : > \$PREFIX_NODE/bin/node
  eval \"\$(_rwfn register_path /etc/profile.d \"\$SB/pd\" /usr/local/bin \"\$SB/ub\")\"
  register_path nodejs \$PREFIX_NODE/bin node >/dev/null 2>&1
  ! test -f \$SB/pd/lnamp-nodejs.sh
)"

############### 9. 新增：sysctl / precheck / mirror ###############
sec "9. 内核调优 / 安装前预检 / 包镜像"

# ---- sysctl：只朝好的方向，不覆盖已有更优配置 ----
ck "_num_ge 拒绝非数字" "( load; ! _num_ge abc 1 && ! _num_ge 1 abc && _num_ge 5 5 )"
ck "_sysctl_resolve max 保留更大当前值" "(
  load; _sysctl_get(){ echo 262144; }
  [ \"\$(_sysctl_resolve net.core.somaxconn 65535 max)\" = 'net.core.somaxconn = 262144' ]
)"
ck "_sysctl_resolve max 用目标值" "(
  load; _sysctl_get(){ echo 128; }
  [ \"\$(_sysctl_resolve net.core.somaxconn 65535 max)\" = 'net.core.somaxconn = 65535' ]
)"
ck "_sysctl_resolve min 保留更小当前值" "(
  load; _sysctl_get(){ echo 5; }
  [ \"\$(_sysctl_resolve vm.swappiness 10 min)\" = 'vm.swappiness = 5' ]
)"
ck "_sysctl_resolve set 始终用目标值" "(
  load; _sysctl_get(){ echo '10000 65535'; }
  [ \"\$(_sysctl_resolve net.ipv4.ip_local_port_range '10240 65000' set)\" = 'net.ipv4.ip_local_port_range = 10240 65000' ]
)"
ck "_sysctl_build_conf 覆盖全部目标项" "(
  load; _sysctl_get(){ :;}
  n=\$(_sysctl_build_conf | grep -c ' = ')
  [ \"\$n\" -eq 11 ]
)"
ck "sysctl dry-run 不写任何文件" "(
  load; SB=\$(mktemp -d); export DRY_RUN=1
  export SYSCTL_CONF=\$SB/s.conf LIMITS_CONF=\$SB/l.conf SYSTEMD_LIMITS_CONF=\$SB/sd.conf
  out=\$(install_sysctl t 2>&1)
  ! test -e \$SB/s.conf && ! test -e \$SB/l.conf && ! test -e \$SB/sd.conf
  echo \"\$out\" | grep -q '将写入内核参数' && echo \"\$out\" | grep -q '将执行: sysctl --system'
)"
ck "sysctl 内容一致时整份跳过(不再增加)" "(
  load; SB=\$(mktemp -d); export DRY_RUN=0
  export SYSCTL_CONF=\$SB/s.conf LIMITS_CONF=\$SB/l.conf SYSTEMD_LIMITS_CONF=\$SB/sd.conf
  _sysctl_get(){ :;}; log_run(){ :;}
  install_sysctl t >/dev/null 2>&1
  out=\$(install_sysctl t 2>&1)
  echo \"\$out\" | grep -q 'already tuned, skipped'
)"
ck "sysctl 已达标时 sysctl_tuned 为真" "(
  load; _sysctl_get(){ echo 65535; }
  sysctl_tuned
)"
ck "sysctl 未达标时 sysctl_tuned 为假" "(
  load; _sysctl_get(){ echo 128; }
  ! sysctl_tuned
)"

# ---- precheck：只读检查，FAIL 时返回 2 ----
ck "precheck: glibc 不足 -> FAIL" "(
  load; SEL_MYSQL='8.0.46:binary'; _pc_glibc_ver(){ echo 2.12; }
  out=\$(_pc_glibc 2>&1)
  grep -q 'glibc 2.12 低于 MYSQL 8.0.46 二进制包要求' <<< \"\$out\"
)"
ck "precheck: glibc 满足 -> OK" "(
  load; SEL_MYSQL='8.0.46:binary'; _pc_glibc_ver(){ echo 2.28; }
  out=\$(_pc_glibc 2>&1)
  grep -q 'glibc 2.28 满足 MYSQL 8.0.46 的要求' <<< \"\$out\"
)"
ck "precheck: MariaDB 二进制也参与 glibc 校验" "(
  load; SEL_MARIADB='11.8.8:binary'; _pc_glibc_ver(){ echo 2.17; }
  out=\$(_pc_glibc 2>&1)
  grep -q 'glibc 2.17 低于 MARIADB 11.8.8' <<< \"\$out\"
)"
ck "precheck: 端口被占用 -> WARN 并带进程名" "(
  load; _pc_port_tool(){ return 0;}; _pc_port_busy(){ return 0;}; _pc_port_owner(){ echo nginx; }
  out=\$(_pc_ports 2>&1)
  grep -q '端口 80 (HTTP) 已被占用（进程: nginx）' <<< \"\$out\"
)"
ck "precheck: 端口空闲 -> OK" "(
  load; _pc_port_tool(){ return 0;}; _pc_port_busy(){ return 1;}
  out=\$(_pc_ports 2>&1)
  grep -q '端口 80 (HTTP) 空闲' <<< \"\$out\"
)"
ck "precheck: 内存低于组件要求 -> WARN" "(
  load; export MEM_MB=512; SEL_PHP='8.3.36:fpm'
  out=\$(_pc_mem 2>&1)
  grep -q '内存 512MB <' <<< \"\$out\"
)"
ck "precheck: /tmp 可执行性有结论" "(
  load; out=\$(_pc_misc 2>&1)
  grep -qE '/tmp (可执行|挂载了 noexec)' <<< \"\$out\"
)"
ck "precheck: 存在 FAIL 时返回 2" "(
  load; _pc_system(){ _pc_fail boom; }; _pc_disk(){ :;}; _pc_mem(){ :;}; _pc_ports(){ :;}
  _pc_conflict(){ :;}; _pc_glibc(){ :;}; _pc_time(){ :;}; _pc_dns(){ :;}; _pc_misc(){ :;}
  _pc_tools(){ :;}
  precheck_main >/dev/null 2>&1; [ \$? -eq 2 ]
)"
ck "precheck: 无 FAIL 时返回 0" "(
  load; _pc_system(){ _pc_ok ok; }; _pc_disk(){ :;}; _pc_mem(){ :;}; _pc_ports(){ :;}
  _pc_conflict(){ :;}; _pc_glibc(){ :;}; _pc_time(){ :;}; _pc_dns(){ :;}; _pc_misc(){ :;}
  _pc_tools(){ :;}
  precheck_main >/dev/null 2>&1; [ \$? -eq 0 ]
)"

# ---- mirror：Composer/npm 包索引 ----
# 注意：install.sh 带 set -o pipefail，管道里 `xxx | grep -q` 会让 grep 提前退出、
# 上游收到 SIGPIPE，整条管道返回 141。所以这里一律先 `out=$(...)` 再用 `<<<` 喂 grep。
ck "mirror: 非法模式被拒" "( load; ! ( install_mirrors bogus ) >/dev/null 2>&1 )"
ck "mirror: none 模式不动" "( load; out=\$(install_mirrors none 2>&1); grep -q '跳过' <<< \"\$out\" )"
ck "mirror: dry-run 只打印命令" "(
  load; SB=\$(mktemp -d); export DRY_RUN=1
  _mirror_composer_bin(){ echo \$SB/composer; }; _mirror_npm_bin(){ echo \$SB/npm; }
  out=\$(install_mirrors cn 2>&1)
  grep -q 'composer config -g repo.packagist composer' <<< \"\$out\"
  grep -q 'config set registry' <<< \"\$out\"
)"
ck "mirror: 已是中国镜像时跳过(unchanged)" "(
  load; SB=\$(mktemp -d)
  _mirror_composer_bin(){ echo \$SB/composer; }; _mirror_npm_bin(){ echo \$SB/npm; }
  cat > \$SB/composer <<'STUB'
#!/bin/sh
case \"\$*\" in
  'config -g repositories') printf '{\"0\":{\"name\":\"packagist\",\"type\":\"composer\",\"url\":\"https://mirrors.aliyun.com/composer/\"},\"packagist.org\":{\"type\":\"composer\",\"url\":\"https://repo.packagist.org\"}}\\n' ;;
esac
exit 0
STUB
  cat > \$SB/npm <<'STUB'
#!/bin/sh
[ \"\$*\" = 'config get registry' ] && echo https://registry.npmmirror.com
exit 0
STUB
  chmod +x \$SB/composer \$SB/npm
  out=\$(install_mirrors cn 2>&1)
  grep -q 'Composer 镜像已是 .*跳过 (unchanged)' <<< \"\$out\"
  grep -q 'npm registry 已是 .*跳过 (unchanged)' <<< \"\$out\"
)"
ck "mirror: 未配置时写入镜像" "(
  load; SB=\$(mktemp -d); export MIRROR_RAN=\$SB/ran; : > \$MIRROR_RAN
  _mirror_composer_bin(){ echo \$SB/composer; }; _mirror_npm_bin(){ echo \$SB/npm; }
  cat > \$SB/composer <<'STUB'
#!/bin/sh
echo \"composer \$*\" >> \"\$MIRROR_RAN\"
exit 0
STUB
  cat > \$SB/npm <<'STUB'
#!/bin/sh
echo \"npm \$*\" >> \"\$MIRROR_RAN\"
exit 0
STUB
  chmod +x \$SB/composer \$SB/npm
  install_mirrors cn >/dev/null 2>&1
  grep -q 'repo.packagist composer' \$SB/ran && grep -q 'set registry' \$SB/ran
)"
ck "mirror: official 模式恢复官方源" "(
  load; SB=\$(mktemp -d); export MIRROR_RAN=\$SB/ran; : > \$MIRROR_RAN
  _mirror_composer_bin(){ echo \$SB/composer; }; _mirror_npm_bin(){ echo \$SB/npm; }
  cat > \$SB/composer <<'STUB'
#!/bin/sh
case \"\$*\" in
  'config -g repositories') printf '{\"0\":{\"name\":\"packagist\",\"type\":\"composer\",\"url\":\"https://mirrors.aliyun.com/composer/\"}}\\n'; exit 0 ;;
esac
echo \"composer \$*\" >> \"\$MIRROR_RAN\"
exit 0
STUB
  cat > \$SB/npm <<'STUB'
#!/bin/sh
echo \"npm \$*\" >> \"\$MIRROR_RAN\"
exit 0
STUB
  chmod +x \$SB/composer \$SB/npm
  install_mirrors official >/dev/null 2>&1
  grep -q -- '--unset repos.packagist' \$SB/ran
)"
ck "mirror_main 无参打印当前索引" "(
  load; _mirror_composer_get(){ echo; }; _mirror_npm_get(){ echo; }
  out=\$(mirror_main 2>&1); grep -q '当前包索引' <<< \"\$out\"
)"
ck "mirror: soft 模式下 npm 写入失败不返回非零" "(
  load; SB=\$(mktemp -d)
  _mirror_composer_bin(){ echo \$SB/composer; }; _mirror_npm_bin(){ echo \$SB/npm; }
  printf '#!/bin/sh\nexit 0\n' > \$SB/composer
  printf '#!/bin/sh\nexit 1\n' > \$SB/npm
  chmod +x \$SB/composer \$SB/npm
  install_mirrors cn soft >/dev/null 2>&1
)"
ck "mirror: 非 soft 模式下 npm 写入失败仍返回非零" "(
  load; SB=\$(mktemp -d)
  _mirror_composer_bin(){ echo \$SB/composer; }; _mirror_npm_bin(){ echo \$SB/npm; }
  printf '#!/bin/sh\nexit 0\n' > \$SB/composer
  printf '#!/bin/sh\nexit 1\n' > \$SB/npm
  chmod +x \$SB/composer \$SB/npm
  ! install_mirrors cn >/dev/null 2>&1
)"

# ---- CLI / 编排接入 ----
ckcli "--mirror cn"        "--mirror cn"        'test "$MIRROR_MODE" = cn'
ckcli "--no-mirror"        "--no-mirror"        'test "$MIRROR_MODE" = none'
ckcli "--skip-precheck"    "--skip-precheck"    'test "${SKIP_PRECHECK:-0}" = 1'
ck "--mirror 非法值被拒" "( load; require_root(){ :;}; detect_os(){ OS_FAMILY=debian; PM=apt-get;}; ! ( parse_args --mirror bogus ) >/dev/null 2>&1 )"
ck "main 接入 precheck 子命令" "( grep -q 'precheck_main' install.sh )"
ck "main 接入 sysctl 子命令"   "( grep -q 'install_sysctl' install.sh )"
ck "main 接入 mirror 子命令"   "( grep -q 'mirror_main' install.sh )"
ck "system_prep 调用 install_sysctl" "( grep -q 'install_sysctl \"lnamp-v1\"' install.sh )"
ck "_run_installs_inner 调用 install_mirrors" "( grep -q 'install_mirrors' install.sh )"
ck "usage 提到三个新子命令" "( grep -q 'precheck' install.sh && grep -q 'sysctl' install.sh && grep -q 'mirror' install.sh )"


############### 11. 本轮回归（P0/P1 缺陷修复） ###############
sec "11. 本轮回归：pipefail/卸载/守卫/vhost"

# 11.1 P0：卸载必须真的停服务。
# 旧实现用 `systemctl list-unit-files | grep -q` 做前置判断，pipefail + SIGPIPE
# 让判断恒为假 -> stop 从未执行 -> 删了程序进程还在占端口。
t_un_stop(){ ( load; _t_common; SB=$(mktemp -d)
  export HOME=$SB PREFIX_REDIS=$SB/redis SYSTEMD_DIR=$SB/sd CALLS=$SB/calls
  mkdir -p $SB/sd $PREFIX_REDIS/var $PREFIX_REDIS/bin; : > $CALLS; : > $PREFIX_REDIS/bin/redis-server
  systemctl(){ echo "$1 $2" >> $CALLS; [ "$1" = is-active ] && return 1; return 0; }
  log_run(){ shift; "$@" >/dev/null 2>&1; }   # 真正执行 stop/disable（第1个参数是描述，需 shift）
  uninstall_component redis no >/dev/null 2>&1
  grep -q '^stop redis' $CALLS && grep -q '^disable redis' $CALLS ); }
ck "卸载真的调用 stop/disable（pipefail 不再误判）" "t_un_stop"

# 11.2/11.3 非 purge 保留 Redis 数据(var) 与凭据；--purge 才删。
# 这两条按"决策"断言（记录 find/safe_rm_rf 的调用），不依赖 Windows/Linux 的
# find/rm 行为差异，两边都能跑。
t_un_keep(){ ( load; _t_common; SB=$(mktemp -d)
  export HOME=$SB PREFIX_REDIS=$SB/redis SYSTEMD_DIR=$SB/sd RM=$SB/rm.log
  mkdir -p $SB/sd $PREFIX_REDIS/var $PREFIX_REDIS/bin
  : > $SB/.redis_password; : > $RM; : > $PREFIX_REDIS/bin/redis-server
  systemctl(){ [ "$1" = is-active ] && return 1; return 0; }
  log_run(){ shift; "$@" >/dev/null 2>&1; }
  find(){ echo "find $*" >> $RM; }
  safe_rm_rf(){ echo "rm $*" >> $RM; }
  uninstall_component redis no >/dev/null 2>&1
  grep -q -- '-name var' $RM && ! grep -q 'rm .*\.redis_password' $RM ); }
ck "非 purge 卸载保留 var(dump.rdb) 与凭据文件" "t_un_keep"

t_un_purge(){ ( load; _t_common; SB=$(mktemp -d)
  export HOME=$SB PREFIX_REDIS=$SB/redis SYSTEMD_DIR=$SB/sd RM=$SB/rm.log
  mkdir -p $SB/sd $PREFIX_REDIS/var $PREFIX_REDIS/bin
  : > $SB/.redis_password; : > $RM; : > $PREFIX_REDIS/bin/redis-server
  systemctl(){ [ "$1" = is-active ] && return 1; return 0; }
  log_run(){ shift; "$@" >/dev/null 2>&1; }
  find(){ echo "find $*" >> $RM; }
  safe_rm_rf(){ echo "rm $*" >> $RM; }
  uninstall_component redis yes >/dev/null 2>&1
  grep -q "rm .*redis$" $RM && grep -q 'rm .*\.redis_password' $RM && ! grep -q -- '-name var' $RM ); }
ck "--purge 才删除数据与凭据" "t_un_purge"

# 11.4 uninstall / upgrade 无参数应返回非 0
ck "uninstall 无参数返回非 0" "( load; _un_list_installed(){ :;}; uninstall_usage(){ :;}; ( uninstall_main >/dev/null 2>&1 ); [ \$? -ne 0 ] )"
ck "upgrade 无参数返回非 0"   "( load; upgrade_usage(){ :;}; ( upgrade_main >/dev/null 2>&1 ); [ \$? -ne 0 ] )"

# 11.5 vhost：非法域名必须在落盘前被拒（否则一个坏 vhost 拖垮整个 nginx 配置）
ck "vhost 拒绝含空格的域名"   "( load; _t_common; die(){ exit 1; };  ! ( create_vhost 'bad domain!' 8080 /tmp/vh_x ) >/dev/null 2>&1 )"
ck "vhost 拒绝路径穿越的域名" "( load; _t_common; die(){ exit 1; };  ! ( create_vhost '../etc/x' 8080 /tmp/vh_x ) >/dev/null 2>&1 )"
ck "vhost 拒绝相对路径根目录且不创建目录" "( load; _t_common; die(){ exit 1; };  PREFIX_NGINX=/nonexistent; SB=\$(mktemp -d); cd \$SB; ! ( create_vhost ok.example.com 8080 relative/path ) >/dev/null 2>&1 && [ ! -e relative/path ] )"
ck "vhost 非法域名不产生配置文件" "( load; _t_common; die(){ exit 1; };  SB=\$(mktemp -d); export WWWROOT=\$SB/w; ! ( create_vhost 'x y' 8080 \$SB/w/x ) >/dev/null 2>&1; test ! -e \$SB/w/x )"

# 11.5b vhost 配置测试失败必须回滚（不能把坏 vhost 留在 include 目录里）
t_vhost_rollback(){ ( load; _t_common; die(){ exit 1; };  SB=$(mktemp -d)
  export WWWROOT=/tmp/vh_w_${FUNCNAME}_$$ PREFIX_NGINX=/tmp/vh_ng_${FUNCNAME}_$$ WWWLOGS=/tmp/vh_log_${FUNCNAME}_$$ PHP_FPM_SOCK=/tmp/vh_fpm.sock
  rm -rf $PREFIX_NGINX $WWWROOT $WWWLOGS; mkdir -p $PREFIX_NGINX/sbin $PREFIX_NGINX/conf $WWWROOT $WWWLOGS
  printf '#!/bin/sh\nexit 1\n' > $PREFIX_NGINX/sbin/nginx; chmod +x $PREFIX_NGINX/sbin/nginx
  printf 'http {\n}\n' > $PREFIX_NGINX/conf/nginx.conf
  ! ( create_vhost ok.example.com 8080 /tmp/vh_rb_$$ ) >/dev/null 2>&1 &&
  [ ! -f $PREFIX_NGINX/conf/vhost/ok.example.com.conf ] ); }
ck "vhost 配置测试失败时回滚不残留" "t_vhost_rollback"

t_vhost_ok(){ ( load; _t_common; die(){ exit 1; };  SB=$(mktemp -d)
  export WWWROOT=/tmp/vh_w_${FUNCNAME}_$$ PREFIX_NGINX=/tmp/vh_ng_${FUNCNAME}_$$ WWWLOGS=/tmp/vh_log_${FUNCNAME}_$$ PHP_FPM_SOCK=/tmp/vh_fpm.sock
  rm -rf $PREFIX_NGINX $WWWROOT $WWWLOGS; mkdir -p $PREFIX_NGINX/sbin $PREFIX_NGINX/conf $WWWROOT $WWWLOGS
  printf '#!/bin/sh\nexit 0\n' > $PREFIX_NGINX/sbin/nginx; chmod +x $PREFIX_NGINX/sbin/nginx
  printf 'http {\n}\n' > $PREFIX_NGINX/conf/nginx.conf
  ( create_vhost ok.example.com 8080 /tmp/vh_ok_$$ yes ) >/dev/null 2>&1 &&
  grep -q 'server_name  ok.example.com' $PREFIX_NGINX/conf/vhost/ok.example.com.conf &&
  grep -q 'fastcgi_pass   unix:' $PREFIX_NGINX/conf/vhost/ok.example.com.conf ); }
ck "vhost 合法域名正常生成配置" "t_vhost_ok"

# 11.6 组合守卫：nginx+apache 互斥；php apache 形式需要 apache
ck "nginx+apache 同选被拒" "( load; _t_common; die(){ exit 1; };  ASSUME_YES=1; SEL_NGINX=1.30.6:source; SEL_APACHE=2.4.69:source; ! ( confirm_summary ) >/dev/null 2>&1 )"
ck "php:apache 缺 apache 被拒" "( load; _t_common; die(){ exit 1; };  ASSUME_YES=1; PREFIX_APACHE=/nonexistent; SEL_PHP=8.5.12:apache; ! ( confirm_summary ) >/dev/null 2>&1 )"
ck "php:fpm + nginx 不误拦" "( load; _t_common; die(){ exit 1; };  ASSUME_YES=1; SEL_NGINX=1.30.6:source; SEL_PHP=8.5.12:fpm; ( confirm_summary ) >/dev/null 2>&1 )"

# 11.7 取值型选项不得吞掉后面的另一个选项
ckcli "--php 后紧跟 --dry-run 用默认 PHP" "--php --dry-run" 'test "$SEL_PHP" = "${PHP_DEFAULT}:${PHP_DEFAULT_MODE}" && test "$DRY_RUN" = 1'
ckcli "--redis 后紧跟 --dry-run 用默认 Redis" "--redis --dry-run" 'test "$SEL_REDIS" = "${REDIS_DEFAULT}:${REDIS_DEFAULT_MODE}" && test "$DRY_RUN" = 1'
ckcli "--nginx 不带版本用默认" "--nginx" 'test "$SEL_NGINX" = "${NGINX_DEFAULT}:${NGINX_DEFAULT_MODE}"'

# 11.10 upgrade 组件名映射（历史缺陷 P1：case 分支当命令执行 -> 所有 upgrade 报"未知组件"）
ck "upgrade 映射 redis=REDIS"       "( load; test \"\$(_up_manifest_key redis)\" = REDIS )"
ck "upgrade 映射 nodejs=NODE"       "( load; test \"\$(_up_manifest_key nodejs)\" = NODE )"
ck "upgrade 映射 phpmemcached 正确"  "( load; test \"\$(_up_manifest_key phpmemcached)\" = PHPMEMCACHED )"
ck "upgrade 全部组件映射无报错"      "( load; for c in nginx apache php redis memcached mysql mariadb fail2ban composer nodejs swoole phpredis phpmemcached; do _up_manifest_key \$c >/dev/null || exit 1; done )"
ck "upgrade 未知组件映射失败"        "( load; ! _up_manifest_key bogus >/dev/null 2>&1 )"
# redis-server --version 输出带 "v=" 前缀，必须剥掉才能与清单版本比对（否则同版本也重编）
ck "upgrade 解析 redis 当前版本(v= 前缀)" "(
  load; _t_common; SB=\$(mktemp -d); export PREFIX_REDIS=\$SB/r
  mkdir -p \$PREFIX_REDIS/bin
  printf '#!/bin/sh\necho \"Redis server v=8.10.2 sha=00000000:0 malloc=jemalloc bits=64 build=1\"\n' > \$PREFIX_REDIS/bin/redis-server
  chmod +x \$PREFIX_REDIS/bin/redis-server
  test \"\$(_up_current_version redis)\" = 8.10.2 )"

# IIS 伪装的 -v 输出（"nginx version: Microsoft-IIS/10.0/<版本>"）若按第一个 "/"
# 取段会拿到伪装的 10.0（真机教训：190 上 upgrade 显示 "10.0 -> 1.30.6"），
# 必须取"version: "后第一段的最后一个 / 之后才是真版本
ck "upgrade 解析 nginx 伪装版本(IIS 串取最后一段)" "(
  load; _t_common; SB=\$(mktemp -d); export PREFIX_NGINX=\$SB/n
  mkdir -p \$PREFIX_NGINX/sbin
  printf '#!/bin/sh\necho \"nginx version: Microsoft-IIS/10.0/1.30.6\"\n' > \$PREFIX_NGINX/sbin/nginx
  chmod +x \$PREFIX_NGINX/sbin/nginx
  test \"\$(_up_current_version nginx)\" = 1.30.6 )"

# Tengine 输出 "Tengine/3.1.0 (nginx/1.18.0)"：括号里的 1.18.0 在空白之后，
# 取第一空白段的最后一个 / 之后仍应得 3.1.0
ck "upgrade 解析 nginx Tengine 版本不误取括号段" "(
  load; _t_common; SB=\$(mktemp -d); export PREFIX_NGINX=\$SB/n
  mkdir -p \$PREFIX_NGINX/sbin
  printf '#!/bin/sh\necho \"Tengine version: Tengine/3.1.0 (nginx/1.18.0)\"\n' > \$PREFIX_NGINX/sbin/nginx
  chmod +x \$PREFIX_NGINX/sbin/nginx
  test \"\$(_up_current_version nginx)\" = 3.1.0 )"

# PHP_IMAGICK 环境变量必须透传：upgrade 子命令不接受 --php-imagick，
# 只能靠 env；install.sh 初始化若无条件置空会把外部 yes 冲掉
# （真机教训：190 升 8.4.27 后 imagick 没装上）
ck "install.sh: PHP_IMAGICK 环境变量透传不被置空" "(
  grep -q 'PHP_IMAGICK=\"\${PHP_IMAGICK:-}\"' install.sh &&
  ! grep -q '^PHP_IMAGICK=\"\"' install.sh )"

# upgrade php 后必须按 php.d/imagick.ini 自动重建 imagick（模块 API 换号旧 .so 必失配）
ck "upgrade: php 升级后重建 imagick(与 redis/swoole/memcached 同判定)" "(
  load; grep -q '重建扩展: imagick' modules/uninstall.sh &&
  grep -A2 'php.d/imagick.ini' modules/uninstall.sh | grep -q '_php_install_imagick' )"

# 11.11 并发保护：同一时刻只允许一个安装/升级/卸载进程
ck "并发锁被占用时拒绝启动" "(
  load; _t_common; die(){ exit 1; }; SB=\$(mktemp -d); export LNAMP_LOCK_FILE=\$SB/lnamp.lock
  command -v flock >/dev/null 2>&1 || exit 0
  ( exec 9>\$LNAMP_LOCK_FILE; flock -n 9; sleep 3 ) &
  holder=\$!; sleep 1
  ! ( _lock_guard ) >/dev/null 2>&1; rc=\$?
  kill \$holder 2>/dev/null; wait \$holder 2>/dev/null
  [ \$rc -eq 0 ] )"
ck "锁释放后可正常启动" "(
  load; _t_common; SB=\$(mktemp -d); export LNAMP_LOCK_FILE=\$SB/lnamp.lock
  command -v flock >/dev/null 2>&1 || exit 0
  ( _lock_guard ) >/dev/null 2>&1 )"

# 11.12 遗留问题修复（R1 数据库升级备份 / R2 Redis 模块 / R4 锁等待）
# R1: --backup-only 只备份、不调安装器
ck "upgrade --backup-only 只备份不安装" "(
  load; _t_common; SB=\$(mktemp -d); export PREFIX_MYSQL=\$SB/my
  C=\$SB/calls; : > \$C
  _up_current_version(){ echo 8.0.46;}; _up_backup(){ echo backup >> \$C; }
  _up_db_dump(){ echo dump >> \$C; return 0; }
  _up_run_installer(){ echo install >> \$C; }
  upgrade_main mysql --backup-only >/dev/null 2>&1 || exit 1
  grep -q backup \$C && grep -q dump \$C && ! grep -q install \$C )"
# R1: 数据库升级前 dump 失败必须中止（不能裸奔升级）
ck "DB 升级 dump 失败则中止" "(
  load; _t_common; die(){ exit 1; }; SB=\$(mktemp -d); export PREFIX_MYSQL=\$SB/my
  C=\$SB/calls; : > \$C
  _up_current_version(){ echo 8.0.46;}; _up_backup(){ :;}; _up_db_dump(){ return 1; }
  _up_run_installer(){ echo install >> \$C; }
  ! ( upgrade_main mysql 8.4.13 --force --yes ) >/dev/null 2>&1 && ! grep -q install \$C )"
# R1: 显式 --skip-db-backup 才允许跳过
ck "DB 升级 --skip-db-backup 可继续" "(
  load; _t_common; SB=\$(mktemp -d); export PREFIX_MYSQL=\$SB/my
  C=\$SB/calls; : > \$C
  _up_current_version(){ echo 8.0.46;}; _up_backup(){ :;}; _up_db_dump(){ echo dump >> \$C; }
  _up_run_installer(){ echo install >> \$C; }
  upgrade_main mysql 8.4.13 --force --yes --skip-db-backup >/dev/null 2>&1 || exit 1
  grep -q install \$C && ! grep -q dump \$C )"
# R2: --redis-modules 解析 + 源码具备预检
ckcli "--redis-modules 打开开关" "--redis-modules" 'test "$REDIS_MODULES" = 1'
ck "redis 模块预检存在(cmake/cargo)" "grep -q 'cargo' modules/redis.sh && grep -q 'REDIS_MODULES' modules/redis.sh"
# R4: --lock-wait 解析与合法性
ckcli "--lock-wait 30 解析" "--lock-wait 30" 'test "$LNAMP_LOCK_WAIT" = 30'
ck "_lock_wait_scan 预扫描生效" "( load; LNAMP_LOCK_WAIT=0; _lock_wait_scan --force --lock-wait 7 >/dev/null 2>&1; test \"\$LNAMP_LOCK_WAIT\" = 7 )"
ck "--lock-wait 非法值被拒" "( load; require_root(){ :;}; detect_os(){ OS_FAMILY=debian; PM=apt-get;}; ! ( parse_args --lock-wait abc ) >/dev/null 2>&1 )"

# 11.9 测试隔离：跑测试不得改写宿主机 /etc/logrotate.d
ck "_php_setup_fpm 的 logrotate 落到沙箱" "(
  load; _t_common; SB=\$(mktemp -d); export PREFIX_PHP=\$SB/php SYSTEMD_DIR=\$SB/sd LNAMP_LOGROTATE_DIR=\$SB/lr
  export PHP_FPM_SOCK=/run/php/php-fpm.sock
  mkdir -p \$PREFIX_PHP/etc/php-fpm.d \$SB/sd \$SB/lr
  cat > \$PREFIX_PHP/etc/php-fpm.d/www.conf.default <<'WWW'
;listen = 127.0.0.1:9000
WWW
  _php_setup_fpm >/dev/null 2>&1
  test -f \$SB/lr/php-fpm && grep -Fq \"\${PREFIX_PHP}/var/log\" \$SB/lr/php-fpm )"
ck "setup_logrotate 目录可注入" "grep -q 'LNAMP_LOGROTATE_DIR' lib/common.sh"

# 11.8 源码层面护栏：pipefail 下不得再用 `| grep -q` 做判断（SIGPIPE 会反转结果）
ck "无 systemctl list-unit-files|grep -q 反模式" "! grep -rn 'list-unit-files.*| *grep -q' modules/ lib/ install.sh | grep -qvE ':[0-9]+: *#'"
ck "端口探测不再用 grep -q" "! grep -qE 'awk .*\\| *grep -q' modules/precheck.sh modules/verify.sh"

############### 12. 上传加固 + status / backup / doctor ###############
sec "12. 上传目录加固 + status / backup / restore / doctor"

# 12.1 上传/数据目录必须禁执行 PHP。
# 背景：模板注释一直写着"上传目录加固"，但生成的配置里根本没有这条规则，
# 于是 /uploads/shell.php 会被 `location ~ \.php$` 正常交给 php-fpm 执行 ——
# 有上传功能的应用等于开了个 RCE 后门。
# 顺序也要卡住：nginx 的正则 location 按出现顺序匹配，deny 写在 .php 之后
# 等于没写（永远轮不到它）。
t_vh_deny(){ ( load; _t_common; die(){ exit 1; }
  export WWWROOT=/tmp/vh_dn_w_$$ PREFIX_NGINX=/tmp/vh_dn_ng_$$ WWWLOGS=/tmp/vh_dn_l_$$ PHP_FPM_SOCK=/tmp/vh_dn.sock
  rm -rf $PREFIX_NGINX $WWWROOT $WWWLOGS; mkdir -p $PREFIX_NGINX/sbin $PREFIX_NGINX/conf $WWWROOT $WWWLOGS
  printf '#!/bin/sh\nexit 0\n' > $PREFIX_NGINX/sbin/nginx; chmod +x $PREFIX_NGINX/sbin/nginx
  printf 'http {\n}\n' > $PREFIX_NGINX/conf/nginx.conf
  ( create_vhost deny.example.com 8080 $WWWROOT yes ) >/dev/null 2>&1 || exit 1
  f=$PREFIX_NGINX/conf/vhost/deny.example.com.conf
  grep -Fq 'uploads?' "$f" || exit 1
  grep -Fq 'git|svn|hg|env' "$f" || exit 1        # 敏感文件也要挡（原模板只挡 .ht*）
  # 注意用 -F：配置里是字面的 "\.php"（带反斜杠），正则模式下 \. 匹配的是点，永远匹配不上
  a=$(grep -nF 'uploads?' "$f" | head -1 | cut -d: -f1)
  b=$(grep -nF 'location ~ \.php' "$f" | head -1 | cut -d: -f1)
  [ -n "$a" ] && [ -n "$b" ] && [ "$a" -lt "$b" ] ); }
ck "vhost: 上传目录禁执行 PHP（且排在 .php 规则之前）" "t_vh_deny"

# 12.2 apache 模板同样要有禁执行规则（nginx 与 apache 侧行为必须一致）
ck "apache vhost 模板含 DirectoryMatch 禁执行" \
   "grep -Fq 'DirectoryMatch' modules/vhost.sh && grep -Fq 'phtml|phar' modules/vhost.sh"

# 12.4 status 是最低门槛的只读命令：不应因为"系统不受支持"或非 root 就用不了
ck "status 输出主机/组件段" "
  out=\$(timeout 90 bash install.sh status 2>&1)
  printf '%s' \"\$out\" | grep -c '== 主机' >/dev/null &&
  printf '%s' \"\$out\" | grep -c '== 组件' >/dev/null"

ck "status --brief 单行摘要供监控采集" "
  out=\$(timeout 90 bash install.sh status --brief 2>/dev/null)
  printf '%s' \"\$out\" | grep -cE '^lnamp_status=(ok|degraded) services=[0-9]+/[0-9]+' >/dev/null"

ck "status 拒绝未知参数" "! ( bash install.sh status --bogus >/dev/null 2>&1 )"

# 12.5 doctor：每条问题都给修复命令；汇总分 OK/WARN/FAIL/SKIP
ck "doctor 输出四类汇总" "
  out=\$(timeout 120 bash install.sh doctor 2>&1)
  printf '%s' \"\$out\" | grep -cE '汇总: OK=[0-9]+  WARN=[0-9]+  FAIL=[0-9]+  SKIP=[0-9]+' >/dev/null"

# 12.6 backup/restore 的参数校验（防止 --only 写错却静默少备份）
ck "backup --only 非法值被拒"   "( load; _t_common; die(){ exit 1; }; ! ( backup_main --only xx ) >/dev/null 2>&1 )"
ck "backup --only 混入非法值被拒" "( load; _t_common; die(){ exit 1; }; ! ( backup_main --only db,xx ) >/dev/null 2>&1 )"
ck "backup --keep 非数字被拒"   "( load; _t_common; die(){ exit 1; }; ! ( backup_main --keep abc ) >/dev/null 2>&1 )"
ck "restore 无参数被拒"         "( load; _t_common; die(){ exit 1; }; ! ( restore_main ) >/dev/null 2>&1 )"
ck "restore 包不存在被拒"       "( load; _t_common; die(){ exit 1; }; ! ( restore_main /nonexistent/x.tar.gz ) >/dev/null 2>&1 )"

# 12.7 --dry-run 不产生任何文件（备份是重操作，必须先能空跑确认范围）
ck "backup --dry-run 不产生备份包" "
  ( load; _t_common; SB=/tmp/lnamp_bkd_\$\$; rm -rf \$SB; mkdir -p \$SB; LNAMP_BACKUP_DIR=\$SB
    ( DRY_RUN=1; backup_main --only db >/dev/null 2>&1 )
    [ -z \"\$(ls \$SB/*.tar.gz 2>/dev/null)\" ] )"

# 12.8 真的打包：产物含 manifest 与 db dump（用桩替换 mysqldump）
t_bk_pack(){ ( load; _t_common; SB=/tmp/lnamp_bk_$$; rm -rf "$SB"; mkdir -p "$SB"
  export LNAMP_BACKUP_DIR="$SB/bk" PREFIX_NGINX="$SB/nx" HOME="$SB"
  _up_db_dump(){ printf 'FAKEDUMP\n' | gzip > "$2"; DB_DUMP_FILE="$2"; return 0; }
  _bk_do_redis(){ :; }
  _up_current_version(){ case "$1" in mysql) echo 8.4.13 ;; nginx) echo 1.31.4 ;; esac; }
  backup_main --only db,conf --keep 3 >/dev/null 2>&1 || exit 1
  pkg=$(ls "$LNAMP_BACKUP_DIR"/lnamp-backup-*.tar.gz 2>/dev/null | head -1)
  [ -n "$pkg" ] || exit 1
  lst=$(tar -tzf "$pkg" 2>/dev/null)
  printf '%s\n' "$lst" | grep -c 'manifest.txt' >/dev/null || exit 1
  printf '%s\n' "$lst" | grep -c 'db/mysql-all.sql.gz' >/dev/null || exit 1
  printf '%s\n' "$lst" | grep -c 'credentials' >/dev/null ); }
ck "backup 产物含 manifest 与 db dump" "t_bk_pack"

# 12.9 保留策略：--keep 1 时旧包要被清掉（否则每天一份会撑满磁盘）
t_bk_keep(){ ( load; _t_common; SB=/tmp/lnamp_bkk_$$; rm -rf "$SB"; mkdir -p "$SB"
  export LNAMP_BACKUP_DIR="$SB/bk" PREFIX_NGINX="$SB/nx" HOME="$SB"
  _up_db_dump(){ printf 'X\n' | gzip > "$2"; DB_DUMP_FILE="$2"; return 0; }
  _bk_do_redis(){ :; }; _up_current_version(){ echo 1.0; }
  backup_main --only db --keep 1 >/dev/null 2>&1
  sleep 1      # 时间戳精确到秒，不等会重名覆盖，测不出清理
  backup_main --only db --keep 1 >/dev/null 2>&1
  n=$(ls "$LNAMP_BACKUP_DIR"/lnamp-backup-*.tar.gz 2>/dev/null | wc -l)
  [ "$n" -eq 1 ] ); }
ck "backup --keep 1 只保留一份" "t_bk_keep"

# 12.10 _up_db_dump 的输出路径可注入（测试与 backup 各用自己的落盘点，不写死 /root）
ck "_up_db_dump 输出路径可注入" "
  ( load; _t_common; SB=\$(mktemp -d); export HOME=\$SB PREFIX_MYSQL=\$SB/my
    mkdir -p \$PREFIX_MYSQL/bin
    printf '#!/bin/sh\necho FAKE\n' > \$PREFIX_MYSQL/bin/mysqldump; chmod +x \$PREFIX_MYSQL/bin/mysqldump
    _up_db_dump mysql \"\$SB/o.sql.gz\" >/dev/null 2>&1 && [ -s \"\$SB/o.sql.gz\" ] )"

# 12.11 logrotate 的备份必须用 logrotate 会忽略的后缀。
# logrotate 读取 /etc/logrotate.d 下**所有**文件，只忽略 .disabled/.dpkg-old 等后缀；
# 用 ".bak.<ts>" 留在原地会被当成第二份配置，报 "duplicate log entry ... skipping"。
t_lr_bak(){ ( load; _t_common; SB=/tmp/lnamp_lr_$$; rm -rf "$SB"; mkdir -p "$SB/logs"
  export LNAMP_LOGROTATE_DIR="$SB/lr" OS_FAMILY=debian PM=apt-get
  pkg_install(){ :; }
  setup_logrotate nginx "$SB/logs/*.log" >/dev/null 2>&1
  setup_logrotate nginx "$SB/logs/*.log" >/dev/null 2>&1
  ls "$SB"/lr/nginx.bak.*.disabled >/dev/null 2>&1 || exit 1
  # 不允许存在 logrotate 会读取的裸 .bak.* 文件
  bad=$(ls "$SB"/lr/*.bak.* 2>/dev/null | grep -cv '\.disabled$')
  [ "${bad:-0}" -eq 0 ] ); }
ck "logrotate 备份用 .disabled 后缀（不被 logrotate 读取）" "t_lr_bak"

# 12.12 nginx 的日志轮转通配必须是 *.log（写成 *log 永远匹配不到，日志不轮转）
ck "nginx logrotate 通配为 *.log" "grep -Fq 'WWWLOGS}/*.log' modules/nginx.sh"

############### 13. vhost list / del / disable / enable ###############
sec "13. vhost 站点清单 / 删除 / 启停"

# 沙箱：造 4 种形态的站点（HTTP / HTTPS / 双栈 / 自定义端口）
vh_sbx(){  # $1 沙箱根
  export WWWROOT="$1/www" WWWLOGS="$1/logs" PREFIX_NGINX="$1/ng" PREFIX_APACHE="$1/na"
  export LNAMP_VHOST_ARCHIVE="$1/archive"
  rm -rf "$1"; mkdir -p "$PREFIX_NGINX/conf/vhost" "$PREFIX_NGINX/sbin" "$WWWROOT"/k "$WWWLOGS"
  printf '#!/bin/sh\nexit 0\n' > "$PREFIX_NGINX/sbin/nginx"; chmod +x "$PREFIX_NGINX/sbin/nginx"
  printf 'http {\n}\n' > "$PREFIX_NGINX/conf/nginx.conf"
}
vh_mk(){  # 文件 内容
  printf '%s\n' "$2" > "$PREFIX_NGINX/conf/vhost/$1"
}
vh_fixtures(){
  vh_mk http80.example.com.conf 'server {
    listen 80;
    server_name http80.example.com;
    root '"$WWWROOT"'/k;
    location / { try_files $uri $uri/ /index.php?$args; }
    location ~ \.php$ {
        try_files $uri =404;
        fastcgi_pass   unix:/tmp/x.sock;
        include        fastcgi_params;
    }
}'
  vh_mk https443.example.com.conf 'server {
    listen 443 ssl;
    server_name https443.example.com;
    root '"$WWWROOT"'/k;
    ssl_certificate /etc/ssl/a.pem;
    ssl_certificate_key /etc/ssl/a.key;
}'
  vh_mk both.example.com.conf 'server {
    listen 80;
    server_name both.example.com;
    root '"$WWWROOT"'/k;
}
server {
    listen 443 ssl;
    server_name both.example.com;
    root '"$WWWROOT"'/k;
    ssl_certificate /etc/ssl/b.pem;
}'
  vh_mk port8080.example.com.conf 'server {
    listen 8080;
    server_name port8080.example.com;
    root '"$WWWROOT"'/k;
}'
}

# 13.1 列表要能区分 HTTP(80) / HTTPS(443) / 双栈 / 自定义端口
# 这一条直接对应需求"要区分 80 和 443 ssl"：不能只显示一个笼统的"站点"。
ck "vhost list 区分 HTTP/HTTPS/双栈/自定义端口" "
  ( load; _t_common; B=/tmp/vh_l_\$\$; vh_sbx \$B; vh_fixtures
    out=\$( vhost_list 2>&1 )
    printf '%s' \"\$out\" | grep -c 'HTTP+HTTPS' >/dev/null &&
    printf '%s' \"\$out\" | grep -cE '^  HTTP  +80 ' >/dev/null &&
    printf '%s' \"\$out\" | grep -cE '^  HTTPS  +443 ' >/dev/null &&
    printf '%s' \"\$out\" | grep -cE '^  HTTP  +8080 ' >/dev/null &&
    printf '%s' \"\$out\" | grep -c '共 4 个站点：HTTPS 2 个' >/dev/null )"

# 13.2 禁用/启用：改后缀而不是改内容，且能原样还原
ck "vhost disable/enable 幂等且内容不变" "
  ( load; _t_common; B=/tmp/vh_t_\$\$; vh_sbx \$B; vh_fixtures
    d=\$PREFIX_NGINX/conf/vhost/http80.example.com.conf
    cp -f \"\$d\" \$B/orig
    vhost_disable http80.example.com >/dev/null 2>&1 || exit 1
    [ -f \"\$d.disabled\" ] || exit 1
    vhost_list 2>&1 | grep -c 'disabled' >/dev/null || exit 1
    # 再禁用一次必须幂等（不报错、不产生第二个副本）
    vhost_disable http80.example.com >/dev/null 2>&1 || exit 1
    vhost_enable http80.example.com >/dev/null 2>&1 || exit 1
    [ -f \"\$d\" ] && [ ! -f \"\$d.disabled\" ] && cmp -s \"\$d\" \$B/orig )"

# 13.3 删除：配置必须归档而不是直接消失（线上误删要能捞回来）
ck "vhost del 归档配置并从 include 目录移除" "
  ( load; _t_common; B=/tmp/vh_d_\$\$; vh_sbx \$B; vh_fixtures
    vhost_del port8080.example.com --yes >/dev/null 2>&1 || exit 1
    [ ! -f \$PREFIX_NGINX/conf/vhost/port8080.example.com.conf ] &&
    ls \$B/archive/port8080.example.com.conf.* >/dev/null 2>&1 )"

# 13.4 未知域名：必须失败并给出可选列表（不能静默"删了 0 个"当成功）
ck "vhost del 未知域名返回非 0"     "( load; _t_common; B=/tmp/vh_n1_\$\$; vh_sbx \$B; vh_fixtures; ! ( vhost_del nosuch.example.com --yes ) >/dev/null 2>&1 )"
ck "vhost disable 未知域名返回非 0" "( load; _t_common; B=/tmp/vh_n2_\$\$; vh_sbx \$B; vh_fixtures; ! ( vhost_disable nosuch.example.com ) >/dev/null 2>&1 )"

# 13.5 --purge 的安全闸：根目录不在 WWWROOT 之下必须拒绝
# （防止配置里写了 /etc 或 / 之类，一个 --purge 把系统删了）
ck "vhost del --purge 拒绝 WWWROOT 之外的目录" "
  ( load; _t_common; die(){ exit 1; }; B=/tmp/vh_p1_\$\$; vh_sbx \$B
    mkdir -p \$B/outside; printf 'server {\n    listen 80;\n    server_name evil.example.com;\n    root %s;\n}\n' \"\$B/outside\" > \$PREFIX_NGINX/conf/vhost/evil.example.com.conf
    ! ( vhost_del evil.example.com --purge --yes ) >/dev/null 2>&1 &&
    [ -d \$B/outside ] )"

# 13.6 --purge 正常路径：WWWROOT 下的目录应被删掉
ck "vhost del --purge 删除 WWWROOT 内目录" "
  ( load; _t_common; B=/tmp/vh_p2_\$\$; vh_sbx \$B; vh_fixtures
    mkdir -p \$WWWROOT/gone; printf 'x' > \$WWWROOT/gone/index.html
    vhost_del http80.example.com --purge --yes >/dev/null 2>&1 || exit 1
    [ -f \$WWWROOT/k ] || [ ! -d \$WWWROOT/k ] )"

# 13.7 配置测试失败必须回滚（否则一次启停就让 nginx 永久 reload 失败）
ck "vhost disable 在 nginx -t 失败时回滚" "
  ( load; _t_common; B=/tmp/vh_r_\$\$; vh_sbx \$B; vh_fixtures
    d=\$PREFIX_NGINX/conf/vhost/http80.example.com.conf
    printf '#!/bin/sh\nexit 1\n' > \$PREFIX_NGINX/sbin/nginx; chmod +x \$PREFIX_NGINX/sbin/nginx
    ! ( vhost_disable http80.example.com ) >/dev/null 2>&1 &&
    [ -f \"\$d\" ] && [ ! -f \"\$d.disabled\" ] )"

# 13.8 入口分发：list/ls、del/rm、disable/off、enable/on 都通
ck "vhost 子命令别名可分发" "
  ( load; _t_common; B=/tmp/vh_a_\$\$; vh_sbx \$B; vh_fixtures
    vhost_main list   >/dev/null 2>&1 &&
    vhost_main ls     >/dev/null 2>&1 &&
    vhost_main disable http80.example.com >/dev/null 2>&1 &&
    vhost_main off     http80.example.com >/dev/null 2>&1 &&
    vhost_main enable  http80.example.com >/dev/null 2>&1 &&
    vhost_main on      http80.example.com >/dev/null 2>&1 )"

############### 14. php.ini 幂等性 ###############
sec "14. php.ini 调优必须幂等（否则重复安装会指数膨胀）"

# 14.1 这是真机上炸过的 P0：原来用
#       sed 's@^output_buffering =@A\nB@'
#     插一行，但 sed 只替换每行第一次；执行一次后文件里就有两行以 output_buffering
#     开头，下一次两行各自再插一行 -> 行数翻倍。装 N 次就是 2^N 行。
#     真机 php.ini 被撑到 738MB / 3355 万行，PHP 解析它直接烧满 CPU（php -v 卡死）。
t_ini_idem(){ ( load; _t_common; SB=/tmp/phpini_$$; rm -rf "$SB"; mkdir -p "$SB/php/etc" "$SB/php/var/log"
  export PREFIX_PHP="$SB/php" MEM_MB=8192 MEMORY_LIMIT=256
  printf '[PHP]\nmemory_limit = 128M\noutput_buffering = 4096\n' > "$PREFIX_PHP/etc/php.ini"
  local i
  for i in 1 2 3; do tune_php_ini "$PREFIX_PHP/etc/php.ini" >/dev/null 2>&1; done
  [ "$(grep -c '^output_buffering' "$PREFIX_PHP/etc/php.ini")" -eq 1 ] &&
  [ "$(wc -l < "$PREFIX_PHP/etc/php.ini")" -lt 40 ] ); }
ck "tune_php_ini 连跑 3 次不膨胀" "t_ini_idem"

# 14.2 反复执行不得让行数增长（对比 1 次与 5 次的结果）
t_ini_stable(){ ( load; _t_common; SB=/tmp/phpini2_$$; rm -rf "$SB"; mkdir -p "$SB/php/etc" "$SB/php/var/log"
  export PREFIX_PHP="$SB/php" MEM_MB=8192 MEMORY_LIMIT=256
  printf '[PHP]\nmemory_limit = 128M\n' > "$PREFIX_PHP/etc/php.ini"
  tune_php_ini "$PREFIX_PHP/etc/php.ini" >/dev/null 2>&1
  local n1; n1=$(wc -l < "$PREFIX_PHP/etc/php.ini")
  local i; for i in 1 2 3 4; do tune_php_ini "$PREFIX_PHP/etc/php.ini" >/dev/null 2>&1; done
  local n5; n5=$(wc -l < "$PREFIX_PHP/etc/php.ini")
  [ "$n1" = "$n5" ] ); }
ck "tune_php_ini 1 次与 5 次结果行数相同" "t_ini_stable"

# 14.3 源码层面护栏：禁止再出现"用 sed 的 \n 往 ini 里插行"这种写法
ck "php.sh 不再用 sed 插行写 ini" "! grep -Fq 'output_buffering = On\\noutput_buffering' modules/php.sh"

############### 15. vhost ssl（一键 TLS） ###############
sec "15. vhost ssl 一键 TLS（不申请证书）"

# 15.1 没有证书时必须失败，并给出三条出路（不能静默什么都不做）
ck "ssl: 无证书时失败" "(
  load; _t_common; B=/tmp/vh_s1_\$\$; vh_sbx \$B; vh_fixtures
  ! ( vhost_ssl http80.example.com ) >/dev/null 2>&1 )"

# 15.2 自签：生成证书 + 443 配置 + 保留原站点规则
ck "ssl: --self-signed 生成证书并写 443" "(
  load; _t_common; B=/tmp/vh_s2_\$\$; vh_sbx \$B; vh_fixtures
  command -v openssl >/dev/null 2>&1 || exit 0
  ( vhost_ssl http80.example.com --self-signed ) >/dev/null 2>&1 || exit 1
  f=\$PREFIX_NGINX/conf/vhost/http80.example.com.conf
  [ -f \$PREFIX_NGINX/conf/ssl/http80.example.com.crt ] &&
  grep -qE '^[[:space:]]*listen[[:space:]]+443 ssl;' \$f &&
  grep -q 'ssl_certificate ' \$f &&
  grep -q 'fastcgi_pass' \$f )"

# 15.3 默认把 80 变成 301 跳转
ck "ssl: 默认 80 跳转到 https" "(
  load; _t_common; B=/tmp/vh_s3_\$\$; vh_sbx \$B; vh_fixtures
  command -v openssl >/dev/null 2>&1 || exit 0
  ( vhost_ssl http80.example.com --self-signed ) >/dev/null 2>&1 || exit 1
  f=\$PREFIX_NGINX/conf/vhost/http80.example.com.conf
  grep -q 'return 301 https' \$f &&
  [ \"\$(grep -c 'try_files' \$f)\" -eq 2 ] )"

# 15.4 --no-redirect：80 的配置必须原样保留（早期版本这里会把 80 整段吃掉）
ck "ssl: --no-redirect 保留 80 配置" "(
  load; _t_common; B=/tmp/vh_s4_\$\$; vh_sbx \$B; vh_fixtures
  command -v openssl >/dev/null 2>&1 || exit 0
  ( vhost_ssl http80.example.com --self-signed --no-redirect ) >/dev/null 2>&1 || exit 1
  f=\$PREFIX_NGINX/conf/vhost/http80.example.com.conf
  grep -qE '^[[:space:]]*listen[[:space:]]+80;' \$f &&
  grep -qE '^[[:space:]]*listen[[:space:]]+443 ssl;' \$f &&
  ! grep -q 'return 301' \$f )"

# 15.5 幂等：已启用 HTTPS 时再跑不重复叠加
ck "ssl: 重复执行不叠加 443" "(
  load; _t_common; B=/tmp/vh_s5_\$\$; vh_sbx \$B; vh_fixtures
  command -v openssl >/dev/null 2>&1 || exit 0
  ( vhost_ssl http80.example.com --self-signed ) >/dev/null 2>&1 || exit 1
  n1=\$(grep -cE '^[[:space:]]*listen[[:space:]]+443 ssl;' \$PREFIX_NGINX/conf/vhost/http80.example.com.conf)
  ( vhost_ssl http80.example.com --self-signed ) >/dev/null 2>&1 || exit 1
  n2=\$(grep -cE '^[[:space:]]*listen[[:space:]]+443 ssl;' \$PREFIX_NGINX/conf/vhost/http80.example.com.conf)
  [ \"\$n1\" = \"\$n2\" ] && [ \"\$n1\" -eq 1 ] )"

# 15.6 证书与私钥不匹配必须拒绝（否则 nginx 起来后握手全失败）
ck "ssl: 证书私钥不匹配被拒" "(
  load; _t_common; die(){ exit 1; }; B=/tmp/vh_s6_\$\$; vh_sbx \$B; vh_fixtures
  command -v openssl >/dev/null 2>&1 || exit 0
  openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj '/CN=other' \
    -keyout \$B/o.key -out \$B/o.crt >/dev/null 2>&1 || exit 0
  openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj '/CN=k2' \
    -keyout \$B/k2.key -out \$B/k2.crt >/dev/null 2>&1 || exit 0
  ! ( vhost_ssl http80.example.com --cert \$B/o.crt --key \$B/k2.key ) >/dev/null 2>&1 )"

# 15.7 站点不存在时失败
ck "ssl: 站点不存在时失败" "(
  load; _t_common; B=/tmp/vh_s7_\$\$; vh_sbx \$B; vh_fixtures
  ! ( vhost_ssl nosuch.example.com --self-signed ) >/dev/null 2>&1 )"

# 15.8 自定义 HTTPS 端口
ck "ssl: --port 8443" "(
  load; _t_common; B=/tmp/vh_s8_\$\$; vh_sbx \$B; vh_fixtures
  command -v openssl >/dev/null 2>&1 || exit 0
  ( vhost_ssl http80.example.com --self-signed --port 8443 ) >/dev/null 2>&1 || exit 1
  grep -qE '^[[:space:]]*listen[[:space:]]+8443 ssl;' \$PREFIX_NGINX/conf/vhost/http80.example.com.conf )"

# 15.9 HSTS 头
ck "ssl: --hsts 下发 STS 头" "(
  load; _t_common; B=/tmp/vh_s9_\$\$; vh_sbx \$B; vh_fixtures
  command -v openssl >/dev/null 2>&1 || exit 0
  ( vhost_ssl http80.example.com --self-signed --hsts ) >/dev/null 2>&1 || exit 1
  grep -c 'Strict-Transport-Security' \$PREFIX_NGINX/conf/vhost/http80.example.com.conf >/dev/null )"

# 15.10 列表能反映出 HTTPS
ck "ssl: list 显示 HTTP+HTTPS" "(
  load; _t_common; B=/tmp/vh_sa_\$\$; vh_sbx \$B; vh_fixtures
  command -v openssl >/dev/null 2>&1 || exit 0
  ( vhost_ssl http80.example.com --self-signed ) >/dev/null 2>&1 || exit 1
  out=\$(vhost_list 2>&1)
  printf '%s' \"\$out\" | grep -q 'HTTP+HTTPS' )"

############### 16. 站点隔离 (per-site php-fpm pool) ###############
sec "16. 站点隔离 open_basedir (per-site pool)"
iso_sbx(){  # $1 沙箱根
  export WWWROOT="$1/www" WWWLOGS="$1/logs" PREFIX_NGINX="$1/ng" PREFIX_PHP="$1/php"
  export PHP_FPM_SOCK="$1/run/php-fpm.sock" LNAMP_VHOST_ARCHIVE="$1/archive"
  export LNAMP_POOL_DEFER_RELOAD=1
  rm -rf "$1"; mkdir -p "$PREFIX_NGINX/conf/vhost" "$PREFIX_NGINX/sbin" "$WWWROOT" "$WWWLOGS" \
    "$PREFIX_PHP/sbin" "$PREFIX_PHP/etc/php-fpm.d" "$PREFIX_PHP/var/log" "$(dirname "$PHP_FPM_SOCK")"
  printf '#!/bin/sh\nexit 0\n' > "$PREFIX_NGINX/sbin/nginx"; chmod +x "$PREFIX_NGINX/sbin/nginx"
  printf '#!/bin/sh\nexit 0\n' > "$PREFIX_PHP/sbin/php-fpm"; chmod +x "$PREFIX_PHP/sbin/php-fpm"
  printf 'http {\n}\n' > "$PREFIX_NGINX/conf/nginx.conf"
  : > "$PREFIX_PHP/etc/php-fpm.conf"
  printf '[www]\nlisten = %s\n' "$PHP_FPM_SOCK" > "$PREFIX_PHP/etc/php-fpm.d/www.conf"
}
iso_stub(){ _php_fpm_test(){ return 0; }; _php_fpm_reload(){ return 0; }; }

# 16.1 slug 唯一性：a-b.com 与 a.b.com 归一化后同名会抢同一个 socket
ck "pool: slug 对 a-b.com / a.b.com 不冲突" "(
  load; _t_common; B=/tmp/iso1_\$\$; iso_sbx \$B
  [ \"\$(_php_site_slug a-b.com)\" != \"\$(_php_site_slug a.b.com)\" ] )"

ck "pool: slug 只含 [A-Za-z0-9_]" "(
  load; _t_common; B=/tmp/iso2_\$\$; iso_sbx \$B
  printf '%s' \"\$(_php_site_slug 'x-y.z')\" | grep -qE '^[A-Za-z0-9_]+\$' )"

# 16.2 pool 内容：四个必要路径缺一个就会"会话丢失/日志空白"且不报错
ck "pool: open_basedir 含 站点根+/tmp+日志+session" "(
  load; _t_common; B=/tmp/iso3_\$\$; iso_sbx \$B
  _php_pool_write a.com \$B/www/a.com >/dev/null 2>&1 || exit 1
  f=\$B/php/etc/php-fpm.d/\$(_php_site_slug a.com).conf
  bd=\$(grep '^php_admin_value\[open_basedir\]' \$f)
  printf '%s' \"\$bd\" | grep -q \"\$B/www/a.com\" &&
  printf '%s' \"\$bd\" | grep -q ':/tmp:' &&
  printf '%s' \"\$bd\" | grep -q 'var/log' &&
  printf '%s' \"\$bd\" | grep -q 'sessions' )"

ck "pool: listen 独立 socket + user www" "(
  load; _t_common; B=/tmp/iso4_\$\$; iso_sbx \$B
  _php_pool_write a.com \$B/www/a.com >/dev/null 2>&1 || exit 1
  f=\$B/php/etc/php-fpm.d/\$(_php_site_slug a.com).conf
  grep -qF \"listen = \$(_php_site_sock a.com)\" \$f && grep -q '^user = www' \$f )"

ck "pool: 限制可执行后缀 .php 且有 slowlog" "(
  load; _t_common; B=/tmp/iso5_\$\$; iso_sbx \$B
  _php_pool_write a.com \$B/www/a.com >/dev/null 2>&1 || exit 1
  f=\$B/php/etc/php-fpm.d/\$(_php_site_slug a.com).conf
  grep -q '^security.limit_extensions = .php' \$f && grep -q '^slowlog' \$f )"

ck "pool: 空域名拒绝写入" "(
  load; _t_common; B=/tmp/iso6_\$\$; iso_sbx \$B
  ( timeout 5 _php_pool_write '' /tmp/x ) >/dev/null 2>&1; [ \$? -ne 0 ] )"

# 16.3 create_vhost 自动建池并指向它
ck "pool: create_vhost 的 fastcgi_pass 指向站点池" "(
  load; _t_common; B=/tmp/iso7_\$\$; iso_sbx \$B; iso_stub
  ( create_vhost c.com 8080 \$B/www/c.com '' nginx ) >/dev/null 2>&1 || exit 1
  f=\$PREFIX_NGINX/conf/vhost/c.com.conf
  grep -qF \"unix:\$(_php_site_sock c.com)\" \$f &&
  ! grep -qF \"unix:\$PHP_FPM_SOCK\" \$f )"

# 16.4 rebind：存量站点（全局 socket）切到独立池
ck "pool: rebind 把全局 socket 切到站点池" "(
  load; _t_common; B=/tmp/iso8_\$\$; iso_sbx \$B; iso_stub
  mkdir -p \$WWWROOT/d.com
  printf '%s\n' 'server {' '    listen 8080;' '    server_name d.com;' '    root '\$WWWROOT'/d.com;' \
    '    location ~ \\.php\$ {' '        fastcgi_pass   unix:/tmp/g.sock;' '    }' '}' \
    > \$PREFIX_NGINX/conf/vhost/d.com.conf
  ( vhost_rebind d.com ) >/dev/null 2>&1 || exit 1
  grep -qF \"unix:\$(_php_site_sock d.com)\" \$PREFIX_NGINX/conf/vhost/d.com.conf )"

# 16.5 rebind --shared：退回全局池并删池文件
ck "pool: rebind --shared 回退且删除池" "(
  load; _t_common; B=/tmp/iso9_\$\$; iso_sbx \$B; iso_stub
  ( create_vhost e.com 8080 \$B/www/e.com '' nginx ) >/dev/null 2>&1 || exit 1
  ( vhost_rebind e.com --shared ) >/dev/null 2>&1 || exit 1
  grep -qF \"unix:\$PHP_FPM_SOCK\" \$PREFIX_NGINX/conf/vhost/e.com.conf &&
  [ ! -f \"\$PREFIX_PHP/etc/php-fpm.d/\$(_php_site_slug e.com).conf\" ] )"

# 16.6 list 显示隔离状态
ck "pool: vhost list 显示 ISO 列与隔离统计" "(
  load; _t_common; B=/tmp/isoA_\$\$; iso_sbx \$B; iso_stub
  ( create_vhost f.com 8080 \$B/www/f.com '' nginx ) >/dev/null 2>&1 || exit 1
  out=\$(vhost_list 2>&1)
  printf '%s' \"\$out\" | grep -q 'ISO' && printf '%s' \"\$out\" | grep -q '已隔离' )"

# 16.7 关掉隔离后 list 应标 no
ck "pool: 未隔离站点在 list 中标 no" "(
  load; _t_common; B=/tmp/isoB_\$\$; iso_sbx \$B; iso_stub
  ( create_vhost g.com 8080 \$B/www/g.com '' nginx ) >/dev/null 2>&1 || exit 1
  ( vhost_rebind g.com --shared ) >/dev/null 2>&1 || exit 1
  out=\$(vhost_list 2>&1)
  printf '%s' \"\$out\" | grep 'g.com' | grep -q ' no ' )"

############### 17. lnamp scan ###############
sec "17. lnamp scan (webshell 巡检)"
scan_sbx(){
  export WWWROOT="$1/www"
  rm -rf "$1"; mkdir -p "$WWWROOT/app/uploads" "$WWWROOT/app/img" "$1/clean"
}
scan_fixtures(){
  # payload 用变量拼接，避免脚本里出现完整 webshell 字面量
  # （本机安全软件会实时删掉含典型一句话的文件，实测创建后立即消失）
  local E='ev''al' B='base''64_de''code' A='auto_pre''pend_file' Y='syst''em'
  local GP='$_GE''T' PP='$_PO''ST' RP='$_RE''QUEST'
  printf '<?php echo "hello";\n' > "$WWWROOT/app/index.php"
  printf '<?php $B($t);\n' > "$WWWROOT/app/lib.php"
  printf '<?php @%s(%s(%s["z"]));\n' "$E" "$B" "$RP" > "$WWWROOT/app/x.php"
  printf '<?php echo "test";\n' > "$WWWROOT/app/cmd.php"
  printf '<?php phpinfo();\n' > "$WWWROOT/app/uploads/1.php"
  printf 'GIF89a<?php %s(%s["c"]); ?>' "$Y" "$GP" > "$WWWROOT/app/img/a.gif"
  printf '%s = /tmp/x.php\n' "$A" > "$WWWROOT/app/.user.ini"
  printf '<?php echo "ok";\n' > "$1/clean/ok.php"; touch -d '30 days ago' "$1/clean/ok.php" 2>/dev/null || true
}

ck "scan: 命中 webshell 特征" "(
  load; _t_common; B=/tmp/sc1_\$\$; scan_sbx \$B; scan_fixtures \$B
  ( scan_main --path \$WWWROOT ) >/dev/null 2>&1; [ \$? -eq 1 ] )"

ck "scan: 报出具体命中文件" "(
  load; _t_common; B=/tmp/sc2_\$\$; scan_sbx \$B; scan_fixtures \$B
  out=\$(scan_main --path \$WWWROOT 2>&1)
  printf '%s' \"\$out\" | grep -q '命中高危特征' && printf '%s' \"\$out\" | grep -q 'x.php' )"

ck "scan: 上传目录里的 php 被单独点名" "(
  load; _t_common; B=/tmp/sc3_\$\$; scan_sbx \$B; scan_fixtures \$B
  out=\$(scan_main --path \$WWWROOT 2>&1)
  printf '%s' \"\$out\" | grep -q '上传目录不该有 PHP' )"

ck "scan: 图片马被识别" "(
  load; _t_common; B=/tmp/sc4_\$\$; scan_sbx \$B; scan_fixtures \$B
  out=\$(scan_main --path \$WWWROOT 2>&1)
  printf '%s' \"\$out\" | grep -q '图片马' )"

ck "scan: .user.ini 注入被识别" "(
  load; _t_common; B=/tmp/sc5_\$\$; scan_sbx \$B; scan_fixtures \$B
  out=\$(scan_main --path \$WWWROOT 2>&1)
  printf '%s' \"\$out\" | grep -q '自动插入配置' )"

ck "scan: 可疑文件名给出告警" "(
  load; _t_common; B=/tmp/sc6_\$\$; scan_sbx \$B; scan_fixtures \$B
  out=\$(scan_main --path \$WWWROOT 2>&1)
  printf '%s' \"\$out\" | grep -q '文件名疑似' )"

ck "scan: 干净目录 HIT=0 且退出码 0" "(
  load; _t_common; B=/tmp/sc7_\$\$; scan_sbx \$B; scan_fixtures \$B
  ( scan_main --path \$B/clean ) >/dev/null 2>&1; [ \$? -eq 0 ] )"

ck "scan: 合法 base64_decode 不误报" "(
  load; _t_common; B=/tmp/sc8_\$\$; scan_sbx \$B; scan_fixtures \$B
  out=\$(scan_main --path \$WWWROOT 2>&1 | sed -n '/== 1\\./,/== 2\\./p')
  ! printf '%s' \"\$out\" | grep -q 'lib.php' )"

ck "scan: 正常代码不命中（htmlspecialchars）" "(
  load; _t_common; B=/tmp/sc9_\$\$; scan_sbx \$B; scan_fixtures \$B
  out=\$(scan_main --path \$WWWROOT 2>&1 | sed -n '/== 1\\./,/== 2\\./p')
  ! printf '%s' \"\$out\" | grep -q 'index.php' )"

ck "scan: --help 返回 0" "(
  load; _t_common; ( scan_main --help ) >/dev/null 2>&1; [ \$? -eq 0 ] )"

# 参数错误必须注入 die(){ exit 1; }：_t_common 把 die 换成了 return 1，
# 那样参数循环不会退出（真实环境 die 是 exit，不存在此问题）
ck "scan: 未知参数报错" "(
  load; _t_common; die(){ exit 1; }; ( scan_main --nope ) >/dev/null 2>&1; [ \$? -ne 0 ] )"

ck "scan: 不存在的目录报错" "(
  load; _t_common; die(){ exit 1; }; ( scan_main --path /nonexistent-xyz ) >/dev/null 2>&1; [ \$? -ne 0 ] )"

ck "scan: --since 非数字报错" "(
  load; _t_common; die(){ exit 1; }; ( scan_main --since abc ) >/dev/null 2>&1; [ \$? -ne 0 ] )"

############### 18. 基础工具（tar/gzip/xz）与预检 ###############
# 真机案例：Rocky Linux 9.8 最小化安装没有 tar，安装器下载完源码后
# 在解包处报 "tar: command not found"，错误埋在编译日志里很难定位。
sec "18. 基础工具补装 (tar/gzip/xz) + precheck"
ck "dep: debian 下 xz -> xz-utils" "(
  load; _t_common; OS_FAMILY=debian; [ \"\$(_dep_name xz)\" = xz-utils ] )"

ck "dep: 首次调用先补装 tar/gzip/xz" "(
  load; OS_FAMILY=rhel; unset _LNAMP_BASE_TOOLS
  L=/tmp/deplog_\$\$.txt; : > \$L
  pkg_install(){ echo \"\$*\" >> \$L; }
  dep gcc >/dev/null 2>&1
  grep -q 'tar gzip xz' \$L )"

ck "dep: 第二次调用不重复装基础工具" "(
  load; OS_FAMILY=rhel; unset _LNAMP_BASE_TOOLS
  L=/tmp/deplog2_\$\$.txt; : > \$L
  pkg_install(){ echo \"\$*\" >> \$L; }
  dep gcc >/dev/null 2>&1; dep make >/dev/null 2>&1
  [ \"\$(grep -c 'tar gzip xz' \$L)\" = 1 ] )"

ck "dep: 基础工具装过之后不再调用 pkg_install 装 tar" "(
  load; OS_FAMILY=rhel; export _LNAMP_BASE_TOOLS=1
  L=/tmp/deplog3_\$\$.txt; : > \$L
  pkg_install(){ echo \"\$*\" >> \$L; }
  dep make >/dev/null 2>&1
  ! grep -q 'tar' \$L )"

ck "precheck: 缺解包工具时 FAIL 并给安装命令" "(
  load; _t_common; D=/tmp/pcempty_\$\$; mkdir -p \$D
  out=\$(PATH=\$D _pc_tools 2>&1)
  printf '%s' \"\$out\" | grep -q '缺少解包工具' &&
  printf '%s' \"\$out\" | grep -q 'install -y tar gzip' )"

ck "precheck: 缺编译工具只是 WARN" "(
  load; _t_common; OS_FAMILY=debian; D=/tmp/pcempty2_\$\$; mkdir -p \$D
  out=\$(PATH=\$D _pc_tools 2>&1)
  printf '%s' \"\$out\" | grep -q '缺少编译工具' )"

ck "precheck: 工具齐全时 OK" "(
  load; _t_common; OS_FAMILY=rhel
  command -v tar >/dev/null 2>&1 && command -v gzip >/dev/null 2>&1 && command -v xz >/dev/null 2>&1 || exit 0
  out=\$(_pc_tools 2>&1)
  printf '%s' \"\$out\" | grep -q '解包工具齐全' )"

############### 19. 重跑幂等性（中途失败后再跑不必从头编译） ###############
# 真机教训：221（Ubuntu 24，根分区仅 17G）在 MySQL 解压时磁盘满，重跑时
# nginx / php 又从头下载+编译（openssl 56MB 从 GitHub 走要 25 分钟），
# 最终多花了近 1 小时。缺的就是"已装同版本则跳过"。
sec "19. 重跑幂等 (already-installed skip)"
ck "nginx: 已装同版本跳过编译" "(
  load; _t_common; log(){ printf '%s\\n' \"\$*\"; }; SB=\$(mktemp -d); export PREFIX_NGINX=\$SB/nginx THREAD=1
  mkdir -p \$PREFIX_NGINX/sbin
  # 注意 -v 的输出被伪装成 Microsoft-IIS/10.0/<版本>，取版本号必须取最后一段
  printf '#!/bin/sh\\necho \"nginx version: Microsoft-IIS/10.0/1.30.6\"\\n' > \$PREFIX_NGINX/sbin/nginx
  chmod +x \$PREFIX_NGINX/sbin/nginx
  out=\$(_nginx_source 1.30.6 2>&1)
  printf '%s' \"\$out\" | grep -q '已安装' )"

ck "nginx: 版本不同则照常编译（不误跳过）" "(
  load; _t_common; log(){ printf '%s\\n' \"\$*\"; }; SB=\$(mktemp -d); export PREFIX_NGINX=\$SB/nginx THREAD=1
  mkdir -p \$PREFIX_NGINX/sbin
  printf '#!/bin/sh\\necho \"nginx version: Microsoft-IIS/10.0/1.28.0\"\\n' > \$PREFIX_NGINX/sbin/nginx
  chmod +x \$PREFIX_NGINX/sbin/nginx
  manifest_lookup(){ echo 'x|flavor=nginx'; }
  # 桩掉下载与 die：这条只验「不跳过」，不能真的去连网下载（真机上会顺带
  # 走到清理逻辑，历史上就是这里用裸 glob 把 ~ 删光的）
  fetch(){ return 1; }; die(){ return 1; }
  out=\$(_nginx_source 1.30.6 2>&1)
  ! printf '%s' \"\$out\" | grep -q '已安装' )"

# 回归：清理阶段的删除参数不能带裸 glob。${pcre}* 在 pcre 为空时会退化成 *，
# 配合 `cd ~` 就是"删掉 /root 下所有东西"（真机事故）。
ck "静态: 清理逻辑不出现裸 glob 删除" "(
  ! grep -qE 'safe_rm_rf[^#]*\"\$\{[a-z_]+\}\"\*' modules/*.sh )"

ck "php: 已装同版本(fpm)跳过编译" "(
  _skip_msys && exit 0        # Git Bash 上 chmod +x 无效，桩脚本拿不到可执行位
  load; _t_common; log(){ printf '%s\\n' \"\$*\"; }; SB=\$(mktemp -d); export PREFIX_PHP=\$SB/php
  mkdir -p \$PREFIX_PHP/bin \$PREFIX_PHP/sbin
  printf '#!/bin/sh\\necho 8.4.27\\n' > \$PREFIX_PHP/bin/php; chmod +x \$PREFIX_PHP/bin/php
  : > \$PREFIX_PHP/sbin/php-fpm; chmod +x \$PREFIX_PHP/sbin/php-fpm
  out=\$(install_php 8.4.27 fpm 2>&1)
  printf '%s' \"\$out\" | grep -q '已安装' )"

ck "php: 只有 cli 没有 php-fpm 时不算装好 fpm" "(
  _skip_msys && exit 0
  load; _t_common; log(){ printf '%s\\n' \"\$*\"; }; SB=\$(mktemp -d); export PREFIX_PHP=\$SB/php PREFIX_APACHE=\$SB/ap
  mkdir -p \$PREFIX_PHP/bin
  printf '#!/bin/sh\\necho 8.4.27\\n' > \$PREFIX_PHP/bin/php; chmod +x \$PREFIX_PHP/bin/php
  manifest_lookup(){ echo 'x|openssl=3.5.9'; }
  out=\$(install_php 8.4.27 fpm 2>&1)
  ! printf '%s' \"\$out\" | grep -q '已安装 (already installed)' )"

ck "mysql: 已装同版本跳过下载解压" "(
  load; _t_common; log(){ printf '%s\\n' \"\$*\"; }; SB=\$(mktemp -d); export PREFIX_MYSQL=\$SB/mysql OS_FAMILY=rhel
  ensure_mysql_user(){ :;}; db_ensure_runtime_libs(){ :;}
  _mysql_init_db(){ :;}; _mysql_register_service(){ :;}; _mysql_common_post(){ :;}
  mkdir -p \$PREFIX_MYSQL/bin
  printf '#!/bin/sh\\necho \"Ver 8.4.13 for Linux on x86_64\"\\n' > \$PREFIX_MYSQL/bin/mysqld
  chmod +x \$PREFIX_MYSQL/bin/mysqld
  out=\$(_mysql_binary 8.4.13 glibc2.28 2>&1)
  printf '%s' \"\$out\" | grep -q '跳过下载' )"

# PHP 7.2+ 的 sodium 已内置，但 php.sh 仍在调这三个函数；重构时它们只留在
# legacy/ 里，真机（221）上表现为 "command not found" 并被静默跳过。
ck "php 依赖函数齐全 (libsodium/argon2/libzip)" "(
  load; _t_common
  declare -F install_libsodium >/dev/null &&
  declare -F install_argon2    >/dev/null &&
  declare -F install_libzip_src >/dev/null )"

# 装不上也不能阻断 PHP 安装——它是增强项（影响 password_hash 的 argon2 算法），
# 不该让整个 PHP 装不出来；但必须明确告警，不能像重构遗漏时那样无声无息。
ck "argon2: 装不上也只告警不阻断" "(
  load; _t_common; fetch(){ return 1; }; make(){ return 1; }
  install_argon2 >/dev/null 2>&1; [ \$? -eq 0 ] )"

############### 20. vhost 残留清理（prune / del --file） ###############
# 真机反馈："只能建不能删，配置目录越堆越乱"。根因是解析不出域名的坏配置
# 在 list 里完全隐形、del 又只能按域名找 —— 于是永远清不掉。
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

sec "22. PHP 7.x 必须用 OpenSSL 1.1.1（不能用 3.x）"

# PHP 7.4 的 ext/openssl 在 OpenSSL 3.x 下编译失败（3.0 给若干 API 加了 const
# 限定，7.4 的 openssl.c 直接 "discards const qualifier" -> Error 1）。真机 224
# 上就是这样装不出 PHP 7.4 的，所以 7.x 固定配 1.1.1w 到独立前缀。
ck "manifest: PHP 7.4.33 配 OpenSSL 1.1.1（不是 3.x）" "(
  load; m=\$(manifest_lookup PHP 7.4.33)
  v=\$(echo \"\$m\" | tr ';|' '\\n' | grep '^openssl=' | cut -d= -f2)
  case \"\$v\" in 1.1.1*) exit 0;; *) exit 1;; esac )"

ck "manifest: PHP 8.x 仍用 OpenSSL 3.5.9" "(
  load; m=\$(manifest_lookup PHP 8.4.27); echo \"\$m\" | grep -q 'openssl=3.5.9' )"

ck "deps: 存在 install_php7_openssl（1.1.1 独立构建）" "(
  load; declare -F install_php7_openssl )"

ck "manifest: PREFIX_OPENSSL_11 已定义" "(
  load; [ -n \"\${PREFIX_OPENSSL_11}\" ] && case \"\${PREFIX_OPENSSL_11}\" in */openssl-1.1) exit 0;; *) exit 1;; esac )"

ck "php: 7.x 优先用系统 OpenSSL，仅 3.x 系统才自编 1.1.1" "(
  # 系统是 1.1.1/1.0.2 -> openssl_home=/usr（避免与系统 krb5/ldap 的 libcrypto 混用）；
  # 系统是 3.x -> 才 install_php7_openssl 并关掉 LDAP
  grep -q 'openssl_home=\"/usr\"' modules/php.sh &&
  grep -q '_sysossl=' modules/php.sh &&
  grep -q 'install_php7_openssl' modules/php.sh &&
  grep -q '_php7_no_ldap=1' modules/php.sh )"

ck "php: 7.x 自编 openssl 时不启用 LDAP（防两套 libcrypto）" "(
  grep -q 'ldap_opt=\"--without-ldap\"' modules/php.sh )"

ck "php: curl.cainfo 跟随实际 CA 位置（自编前缀或系统 bundle）" "(
  grep -q 'curl.cainfo = \${_ca}' modules/php.sh &&
  grep -q '/etc/pki/tls/certs/ca-bundle.crt' modules/php.sh )"

sec "23. fail2ban jail 配置格式（Debian 12 无 auth.log）"

# fail2ban 1.0.2 的 ini 解析器不剥离行内注释：写成
#   backend = systemd   # 说明文字
# 会把整串当成 backend 名，报 "Unknown backend systemd # ... Must be among
# ['pyinotify','gamin','polling','systemd']"，然后服务 exit 255 —— 真机 240
# （Debian 12）上就是这样把 fail2ban 弄挂的。
ck "fail2ban: backend 值不带行内注释" "(
  # 旧 bug 的写法是 echo \"backend  = systemd   # 说明\"，值里带 # 会被
  # fail2ban 当成 backend 名。这里精确匹配那种写法（注释文字本身不算）。
  ! grep -qE 'backend  = systemd +#' modules/fail2ban.sh &&
  grep -q 'echo \"backend  = systemd\"' modules/fail2ban.sh )"

ck "fail2ban: 无 auth.log 时回退 journald（探测三个候选文件）" "(
  load; grep -q '/var/log/auth.log /var/log/secure /var/log/messages' modules/fail2ban.sh )"

ck "fail2ban: debian 走 journald 时补 python3-systemd" "(
  load; grep -q 'python3-systemd' modules/fail2ban.sh )"

sec "24. vhost 对 mod_php 站点的判定"

# apache+mod_php 机器（234/197）上没有 php-fpm，旧逻辑只查 _php_fpm_available，
# 于是打出 "PHP=no"：提示像没开 PHP，实际 .php 能正常执行，站点却按"无 PHP"
# 处理（不接 PHP 解析），用户以为建站失败。
# 注：建站现在**一律不生成** index.php（默认首页是静态 HTML，见 §26），
# 这条只验"有没有 PHP"的判定，不验首页文件。
ck "vhost: 有 mod_php 时判定为 PHP=yes(modphp)" "(
  load; declare -F _php_modphp_available && grep -q 'php_kind=modphp' modules/vhost.sh )"

ck "vhost: 只有 fpm 形态才建独立池（mod_php 无池）" "(
  grep -q 'php_kind\" = fpm \]' modules/vhost.sh )"

sec "25. PHP7 / MySQL5.7 / Swoole 的版本适配回归"

# zip 的开关名在版本间改过（7.4/8.x 用 --with-zip，5.6 用 --enable-zip）。
# autoconf 对不认识的选项是**静默忽略**的，传错不会报错，只会扩展没编出来
# —— 真机 181 的 PHP 7.4 就这样丢了 zip，直到 verify 报 "扩展未加载: zip"。
ck "php: zip 开关按 configure --help 探测，不按版本猜" "(
  grep -qF '_ziphelp=' modules/php.sh && grep -qF -- '--with-zip' modules/php.sh )"

# MySQL 5.7 没有 data/mysql.ibd（那是 8.0 的数据字典），校验必须按版本分支
ck "mysql: 初始化校验按 8.x / 5.x 区分判据" "(
  grep -q 'mysql.ibd' modules/mysql.sh && grep -q 'mysql/\*.frm' modules/mysql.sh )"

ck "mysql: 已有数据目录时跳过 initialize（重跑幂等）" "(
  grep -q '跳过 initialize' modules/mysql.sh )"

# Swoole 的 PHP 版本门槛要看"本次选择"，否则老机器上装 7.4 后再装 8.3+swoole 会被误拦
ck "swoole: 版本门槛优先看本次选择的 PHP" "(
  grep -qF 'SEL_PHP%%' install.sh )"

# 自编 1.1.1 时 LDAP 与 Kerberos 都要关：两者都 -lkrb5/-lldap，会牵出系统
# libk5crypto 依赖的 libcrypto，与 -L 指向的自编库混链就是
# `undefined reference to EVP_KDF_derive@OPENSSL_1_1_1b`。
ck "php: 自编 1.1.1 时同时关闭 kerberos" "(
  grep -qF '|| cfg+=(--with-kerberos)' modules/php.sh &&
  ! grep -qE '^[[:space:]]*--with-kerberos$' modules/php.sh )"

# 编排阶段 precheck 要能提前告知"会额外编 OpenSSL、会关 LDAP/Kerberos"，
# 免得用户以为卡住了。
ck "precheck: PHP7 + 系统 OpenSSL 有明确提示" "(
  grep -q '需要 OpenSSL 1.1.1' modules/precheck.sh )"

# 端口在听 != 能握手：doctor 必须真读一次 banner（224/184 的故障就是这种）
ck "doctor: 真实探测 SSH banner（端口在听但读不到要报 FAIL）" "(
  grep -q '/dev/tcp/' modules/doctor.sh && grep -q '读不到 banner' modules/doctor.sh )"

sec "26. 默认首页不含 phpinfo + 数据库只监听回环"

# 建站默认生成 phpinfo 首页，等于每个新站点自带一个信息泄露页（PHP 版本、
# 编译参数、扩展清单、$_SERVER 路径与环境变量全公开），很多站上线后忘了删。
# 现在默认只给静态 HTML，验证 PHP 走临时探针。
ck "vhost: 建站不再生成 phpinfo/index.php" "(
  load; _t_common; B=/tmp/pr1_\$\$; iso_sbx \$B; iso_stub
  ( create_vhost h.com 8080 \$B/www/h.com yes nginx ) >/dev/null 2>&1 || exit 1
  [ ! -f \"\$B/www/h.com/index.php\" ] &&
  grep -q 'It works' \"\$B/www/h.com/index.html\" &&
  ! grep -q 'phpinfo' \"\$B/www/h.com/index.html\" )"

# 需要验证时用临时探针：文件名随机、验证完 --rm 能删净
ck "vhost: 临时探针可建可删（--rm 后不留文件）" "(
  load; _t_common; B=/tmp/pr2_\$\$; iso_sbx \$B; iso_stub
  export LNAMP_PROBE_STATE=\$B/probes
  ( create_vhost i.com 8080 \$B/www/i.com yes nginx ) >/dev/null 2>&1 || exit 1
  ( vhost_probe i.com ) >/dev/null 2>&1 || exit 1
  ls \$B/www/i.com/__lnamp_probe_*.php >/dev/null 2>&1 || exit 1
  ( _vhost_probe_rm ) >/dev/null 2>&1
  [ -z \"\$(find \$B/www -name '__lnamp_probe_*.php' 2>/dev/null)\" ] )"

ck "vhost: probe 子命令已接入（创建/列出/删除）" "(
  load; declare -F vhost_probe >/dev/null && declare -F _vhost_probe_rm >/dev/null &&
  grep -q 'probe|phpinfo|info)' modules/vhost.sh &&
  grep -q 'probe --rm' modules/vhost.sh )"

# 探针"验证后删除"必须有兜底：curl 超时/Ctrl-C/被 kill 都不能把文件留在站点里
ck "verify: 探针有三重删除兜底 (trap)" "(
  load; grep -qE 'trap .*VERIFY_PROBE' modules/verify.sh &&
  grep -q 'rm -f \"\$VERIFY_PROBE\"' modules/verify.sh )"

# 监听地址（bind-address）与防火墙是两件事：监听收在回环是第一道闸，防火墙是
# 第二道。默认放行 3306 与 3360（3360 多为第二个实例/自定义端口），且必须集中
# 在 db_open_ports 里，不能像老脚本那样散落在 nginx.sh 里硬编码。
ck "db: 默认放行 3306 与 3360（新增 3360）" "(
  load; _t_common; B=/tmp/pr6_\$\$; mkdir -p \$B
  open_ports(){ echo \"\$1\" >> \$B/fw; }
  [ \"\$(db_ports_list)\" = '3306,3360' ] || exit 1
  ( db_open_ports ) >/dev/null 2>&1
  grep -qx '3306,3360' \$B/fw )"

ck "db: LNAMP_DB_PORTS 可覆盖放行清单" "(
  load; _t_common; B=/tmp/pr7_\$\$; mkdir -p \$B
  open_ports(){ echo \"\$1\" >> \$B/fw; }
  [ \"\$(LNAMP_DB_PORTS='3306,33060' db_ports_list)\" = '3306,33060' ] || exit 1
  ( LNAMP_DB_PORTS='3306, 33060; /bin/rm -rf /' db_open_ports ) >/dev/null 2>&1
  grep -qx '3306,33060' \$B/fw )"

# 最严格场景要能一键关掉：只靠回环监听，防火墙一个端口都不开
ck "db: LNAMP_DB_OPEN_PORTS=no 时完全不放行" "(
  load; _t_common; B=/tmp/pr8_\$\$; mkdir -p \$B
  open_ports(){ echo \"\$1\" >> \$B/fw; }
  ( LNAMP_DB_OPEN_PORTS=no db_open_ports ) >/dev/null 2>&1
  [ ! -f \$B/fw ] )"

ck "db: 放行统一走 db_open_ports（nginx 不再硬编码 3306）" "(
  load; _noc(){ grep -v '^[[:space:]]*#' \"\$1\"; }
  [ \"\$(_noc modules/mysql.sh   | grep -c 'db_open_ports')\" -ge 2 ] &&
  [ \"\$(_noc modules/mariadb.sh | grep -c 'db_open_ports')\" -ge 2 ] &&
  ! _noc lib/common.sh | grep -q 'open_ports \"3306\"' &&
  ! _noc modules/nginx.sh | grep -q '3306' )"

# 包管理器装的库用的是发行版配置：MariaDB 官方 server.cnf 直接写 0.0.0.0，
# MySQL 社区 RPM 干脆不写（默认监听全部网卡）—— 安装后必须再收敛一次。
ck "db: db_enforce_bind_local 把 0.0.0.0 收敛到回环" "(
  load; _t_common; B=/tmp/pr3_\$\$; mkdir -p \$B/cnf.d
  export MY_CNF_PATH=\$B/my.cnf LNAMP_DB_CONF_DIRS=\$B/cnf.d
  printf '[mysqld]\nbind-address = 0.0.0.0\n' > \$MY_CNF_PATH
  printf '[mysqld]\nbind-address=0.0.0.0\n' > \$B/cnf.d/50-server.cnf
  systemctl(){ return 0; }; open_ports(){ :; }
  ( db_enforce_bind_local mysqld ) >/dev/null 2>&1
  grep -q '^bind-address = 127.0.0.1' \$MY_CNF_PATH &&
  grep -q '^bind-address = 127.0.0.1' \$B/cnf.d/zz-lnamp-bind.cnf &&
  grep -q '^# LNAMP' \$B/cnf.d/50-server.cnf )"

# 非回环必须显式声明，否则强制拉回 127.0.0.1（防止"改个环境变量就把库暴露了"）
ck "db: 未声明 LNAMP_DB_PUBLIC 时拒绝非回环监听" "(
  load; _t_common; B=/tmp/pr4_\$\$; mkdir -p \$B/cnf.d
  export MY_CNF_PATH=\$B/my.cnf LNAMP_DB_CONF_DIRS=\$B/cnf.d
  printf '[mysqld]\nbind-address = 127.0.0.1\n' > \$MY_CNF_PATH
  systemctl(){ return 0; }; open_ports(){ :; }
  ( MYSQL_BIND_ADDRESS=0.0.0.0 db_enforce_bind_local mysqld ) >/dev/null 2>&1
  grep -q '^bind-address = 127.0.0.1' \$MY_CNF_PATH )"

ck "db: 显式 LNAMP_DB_PUBLIC=yes 才允许非回环并放通" "(
  load; _t_common; B=/tmp/pr5_\$\$; mkdir -p \$B/cnf.d
  export MY_CNF_PATH=\$B/my.cnf LNAMP_DB_CONF_DIRS=\$B/cnf.d
  printf '[mysqld]\nbind-address = 127.0.0.1\n' > \$MY_CNF_PATH
  systemctl(){ return 0; }; open_ports(){ echo OPEN3306 >> \$B/fw; }
  ( MYSQL_BIND_ADDRESS=0.0.0.0 LNAMP_DB_PUBLIC=yes db_enforce_bind_local mysqld ) >/dev/null 2>&1
  grep -q '^bind-address = 0.0.0.0' \$MY_CNF_PATH && grep -q OPEN3306 \$B/fw )"

# 端口"在听"不等于"只给自己听"：配置之外还要实测一次监听地址
ck "verify/doctor: 检查 3306 的实际监听地址" "(
  load; grep -q 'db_listen_addr' modules/verify.sh &&
  grep -q 'db_listen_addr' modules/doctor.sh &&
  grep -q 'db_listen_is_local' lib/common.sh )"

# 老机器/手工放置的 phpinfo 也要能扫出来
ck "doctor: 巡检 phpinfo / 探针残留" "(
  load; grep -q '_doc_probe' modules/doctor.sh &&
  grep -q '__lnamp_probe_\*\.php' modules/doctor.sh )"

sec "27. 危险路径/删库/备份轮转/菜单越界/scan 排除"

# 建站流程后面会 chown -R www:www <网站根> 并建 php-fpm 池 —— 传 / 或 /etc
# 会把系统目录的属主改掉（sudo/sshd 直接废），只查"绝对路径+空白+.."挡不住。
ck "vhost: 网站根拒绝 / /etc 与单级目录" "(
  load; _t_common; die(){ exit 1; }   # 桩里的 die 只 return，守卫后还会往下走到 return 0
  ! ( _vh_webroot_guard / )            >/dev/null 2>&1 &&
  ! ( _vh_webroot_guard /etc )         >/dev/null 2>&1 &&
  ! ( _vh_webroot_guard /var/log )     >/dev/null 2>&1 &&
  ! ( _vh_webroot_guard /home )        >/dev/null 2>&1 &&
  ( _vh_webroot_guard /home/wwwroot/a.com ) >/dev/null 2>&1 )"

ck "vhost: 建站传 / 时不落盘（配置与目录都不写）" "(
  load; _t_common; die(){ exit 1; }; B=/tmp/s27a_\$\$; iso_sbx \$B; iso_stub
  ( create_vhost bad.com 8080 / yes nginx ) >/dev/null 2>&1 && exit 1
  [ -z \"\$(ls -A \$PREFIX_NGINX/conf/vhost 2>/dev/null)\" ] )"

# mail(第五参数注入 sendmail) / link(硬链接绕过权限) 仍禁用；
# putenv 不禁用（2026-10-27 决策：Composer 等管理工具依赖 putenv，禁用误伤 CLI，
# PHP7 喷 Warning、PHP8 报 Error）——防回退断言两向都查。
ck "php: disable_functions 含 mail/link 且不禁 putenv (Composer 依赖)" "(
  load; grep -q 'pcntl_exec,mail,link' modules/php.sh &&
  ! grep -q 'pcntl_exec,putenv' modules/php.sh &&
  grep -q 'LNAMP_KEEP_MAIL' modules/php.sh &&
  grep -q 'LNAMP_DISABLE_FUNCTIONS_EXTRA' modules/php.sh )"

# 非升级模式下 prefix/data/mysql 存在 = 有库，rm -rf prefix 就是删库
# 环境无关化：机器上装了 MySQL 后 PATH 里真有 mysqldump，原先
# "有 dump 工具就 exit 1"的跳过写法会当 FAIL 计；现在桩掉 mysqldump +
# 导出目录指向文件（导出必失败），无论机器装没装库都走确定的拒绝分支。
ck "db: 非升级模式拒绝删除已有数据目录" "(
  load; _t_common; B=/tmp/s27b_\$\$; mkdir -p \$B/mysql/data/mysql \$B/bin
  printf '#!/bin/sh\nexit 1\n' > \$B/bin/mysqldump; chmod +x \$B/bin/mysqldump
  export PATH=\$B/bin:\$PATH LNAMP_BACKUP_DIR=\$B/notadir; : > \$B/notadir
  ( LNAMP_UPGRADE=0 _db_guard_wipe \$B/mysql data ) >/dev/null 2>&1 && exit 1
  ( LNAMP_UPGRADE=1 _db_guard_wipe \$B/mysql data ) >/dev/null 2>&1 &&
  ( LNAMP_FORCE_DB_WIPE=yes _db_guard_wipe \$B/mysql data ) >/dev/null 2>&1 )"

ck "db: 全新安装分支先过删库保护" "(
  load; grep -q '_db_guard_wipe' lib/common.sh &&
  grep -q '_db_guard_wipe \"\$prefix\"' lib/common.sh )"

# 大包（MySQL 二进制 600MB+）在慢链路上是慢而不断：30s 读超时会把正常下载
# 误杀（真机实测 cdn.mysql.com 694MB 被误判失败），断点续传避免几百 MB 重来
ck "fetch: 大文件读超时 + 断点续传" "(
  load; grep -q 'read-timeout=180' lib/common.sh && grep -q '\-c -q -O' lib/common.sh )"

# web 面禁用 putenv/mail/link（审计要求）会误伤 CLI：Composer 依赖 putenv，
# PHP7 下 composer --version 都喷 "putenv() has been disabled" Warning（真机实测）。
# tune_php_ini 必须同时生成 php-cli.ini（仅 CLI SAPI 覆盖）放开 disable_functions。
ck "php: tune_php_ini 生成 php-cli.ini 放开 CLI disable_functions" "(
  load; _t_common; SB=\$(mktemp -d); export PREFIX_PHP=\$SB
  printf 'memory_limit = 128M\ndisable_functions =\n' > \$SB/php.ini
  MEM_MB=4096 MEMORY_LIMIT=256 tune_php_ini \$SB/php.ini >/dev/null 2>&1
  test -f \$SB/php-cli.ini && grep -q '^disable_functions =\$' \$SB/php-cli.ini
  SB2=\$(mktemp -d)
  printf 'memory_limit = 128M\ndisable_functions =\n' > \$SB2/php.ini
  DRY_RUN=1 MEM_MB=4096 MEMORY_LIMIT=256 tune_php_ini \$SB2/php.ini >/dev/null 2>&1
  ! test -f \$SB2/php-cli.ini )"

# 轮转只保留最近 N 份：dump 失败时先轮转，会把最后一份好包挤出去
ck "backup: 轮转排在完整性判断之后" "(
  load; f=\$(grep -n '_BK_FAIL' modules/backup.sh | grep 'gt 0' | head -1 | cut -d: -f1)
  p=\$(grep -n '_bk_prune' modules/backup.sh | tail -1 | cut -d: -f1)
  [ -n \"\$f\" ] && [ -n \"\$p\" ] && [ \"\$p\" -gt \"\$f\" ] )"

# 还原 Redis 是我们自己 stop 的，就得自己 start；否则业务侧只看到连接被拒
ck "restore: redis 还原后自动启动" "(
  load; s=\$(grep -n 'systemctl start redis' modules/backup.sh | head -1 | cut -d: -f1)
  v=\$(grep -n 'svcs redis' modules/backup.sh | head -1 | cut -d: -f1)
  [ -n \"\$s\" ] && [ -n \"\$v\" ] && [ \"\$v\" -gt \"\$s\" ] )"

# --only conf 只改配置不动库，此时换掉密码文件 = 口令与库永久不一致
ck "restore: --only conf 不覆盖凭据文件" "(
  load; grep -q 'with_creds' modules/backup.sh &&
  grep -q -- '--with-credentials' modules/backup.sh &&
  grep -q '凭据文件未还原' modules/backup.sh )"

# 拼接串里混着 INSTALL_PMA=no 这种非空值，"未选择任何组件"永远不触发
ck "install: 未选组件判断不再被 no 值掩盖" "(
  load; declare -F _has_any_selection >/dev/null &&
  ! grep -q 'SEL_NGINX\}\\\${SEL_APACHE}' install.sh &&
  ( SEL_NGINX=''; SEL_PHP=''; SEL_MYSQL=''; SEL_MARIADB=''; SEL_REDIS=''; SEL_PHPREDIS=''
    SEL_MEMCACHED=''; SEL_PHPMEMCACHED=''; SEL_SWOOLE=''; SEL_COMPOSER=''; SEL_NODE=''
    SEL_JAVA=''; SEL_APACHE=''
    INSTALL_PMA=no; INSTALL_ADMINER=no; INSTALL_TOMCAT=no; INSTALL_FAIL2BAN=no
    ! _has_any_selection ) &&
  ( INSTALL_FAIL2BAN=yes; _has_any_selection ) )"

# bash 负下标：输入 0 -> arr[-1] -> 静默选中最后一项
ck "menu: 序号 0 / 非数字 / 越界一律无效" "(
  load; _a=(x y z); _o=''
  ! _menu_pick _a 0 3 _o >/dev/null 2>&1 &&
  ! _menu_pick _a x 3 _o >/dev/null 2>&1 &&
  ! _menu_pick _a 4 3 _o >/dev/null 2>&1 &&
  _menu_pick _a 1 3 _o >/dev/null 2>&1 && [ \"\$_o\" = x ] &&
  _menu_pick _a 3 3 _o >/dev/null 2>&1 && [ \"\$_o\" = z ] )"

# 单引号被当字面量 -> find 收到 '*/node_modules'，排除与 --fast 全部静默失效
ck "scan: --fast 与 --exclude 真的生效" "(
  load; B=/tmp/s27c_\$\$; rm -rf \$B; mkdir -p \$B/site/{node_modules,vendor,cache,app}
  : > \$B/site/app/a.php; : > \$B/site/node_modules/n.php; : > \$B/site/vendor/v.php; : > \$B/site/cache/c.php
  _S_FAST=0; _S_EXCLUDES=''
  a=\$(_scan_find \$B/site -name '*.php' | sort | tr '\n' ' ')
  _S_FAST=1
  b=\$(_scan_find \$B/site -name '*.php' | sort | tr '\n' ' ')
  _S_FAST=0; _S_EXCLUDES='cache'
  c=\$(_scan_find \$B/site -name '*.php' | sort | tr '\n' ' ')
  rm -rf \$B
  case \"\$a\" in *node_modules*) exit 1 ;; esac
  case \"\$b\" in *vendor*) exit 1 ;; esac
  case \"\$c\" in *cache*) exit 1 ;; esac
  case \"\$a\" in *app/a.php*) : ;; *) exit 1 ;; esac
  [ \"\${#a}\" -gt \"\${#b}\" ] )"

# CLI --nodejs 在 CentOS 7 上不降级：装完才 die，白下载几百兆
ck "node: CLI 与菜单共用 glibc 回落" "(
  load; grep -q '_node_fallback_ver' modules/devtools.sh &&
  grep -q 'ver=\$(_node_fallback_ver' modules/devtools.sh &&
  grep -q '_node_fallback_ver' install.sh &&
  grep -q 'NODE_FALLBACK_OLDGLIBC' versions.conf &&
  # 函数里会先打一条 log_warn，所以只取最后一行
  ( OS_FAMILY=rhel OS_VER=7; [ \"\$(_node_fallback_ver 24.22.1 | tail -1)\" = 16.20.2 ] ) &&
  ( OS_FAMILY=rhel OS_VER=9; [ \"\$(_node_fallback_ver 24.22.1 | tail -1)\" = 24.22.1 ] ) )"

# 改配置的子命令没加锁：与安装/卸载并发时会互相覆盖
ck "lock: vhost/bench --apply/sysctl/mirror 已加锁" "(
  load; _lk(){ sed -n \"/\$1/,+6p\" install.sh | grep -q _lock_guard; }
  _lk 'vhost\" \\] \\|\\| \"\${1:-}\" = \"addvhost' &&
  _lk 'bench\" \\] \\|\\| \"\${1:-}\" = \"benchmark' &&
  _lk 'sysctl\" \\] \\|\\| \"\${1:-}\" = \"tune' &&
  _lk 'mirror\" \\] \\|\\| \"\${1:-}\" = \"registry' &&
  grep -q '\\[ \"\$a\" = \"--apply\" \\]' install.sh )"

############### 汇总 ###############
sec "汇总"
echo "  PASS=$PASS  FAIL=$FAIL"
[ "$FAIL" -gt 0 ] && { echo "  失败项:"; printf '    - %s\n' "${FAILED[@]}"; exit 1; }
echo "  ✅ 全部通过"
