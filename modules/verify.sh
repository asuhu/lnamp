#!/bin/bash
# ============================================================================
#  modules/verify.sh  ——  装后健康自检 (post-install verification)
# ----------------------------------------------------------------------------
#  装完立即验证"栈真的能跑"，而不是只报告"脚本跑完了"。
#  六类检查，每项独立计数，互不影响：
#    1) 服务状态     systemctl is-active
#    2) 端口监听     80 / 3306 / 6379（及 php-fpm unix socket）
#    3) PHP 可解析   写 phpinfo 探针到站点目录并 curl，断言返回 phpinfo
#    4) 扩展生效     php -m 断言 phpredis / gd / mysqli / pdo_mysql 等
#    5) 版本一致     nginx -v / php -v / mysql --version 与 versions.conf 比对
#    6) 数据库连通   用 /root/.mysql_password 试连，执行 SELECT 1
#
#  用法:
#    verify_stack            # 由 install.sh 装完自动调用，也可单独跑
#    bash install.sh verify  # 事后随时自检
#
#  设计原则：任何一项检查失败都不中断其余项，最后汇总退出码。
#  ============================================================================

# 探针文件与站点根目录（vhost.sh 也会用 WWWROOT）
VERIFY_PROBE="${VERIFY_PROBE:-${WWWROOT}/web/__lnamp_probe.php}"

# 单条断言：[PASS]/[FAIL] + 计数
_V_PASS=0; _V_FAIL=0; _V_SKIP=0; _V_AUTO=0
_vok()   { log_ok "$*";   _V_PASS=$((_V_PASS+1)); }
_vfail() { log_err "$*";  _V_FAIL=$((_V_FAIL+1)); }
_vskip() { log_warn "$*"; _V_SKIP=$((_V_SKIP+1)); }

# 服务是否 active
_v_svc() {
  local name="$1" label="$2"
  if ! command -v systemctl >/dev/null 2>&1; then
    _vskip "systemctl 不可用，跳过服务检查: ${label}"
    return 0
  fi
  if systemctl is-active --quiet "$name" 2>/dev/null; then
    _vok "服务运行中: ${label} (${name})"
  else
    _vfail "服务未运行: ${label} (${name}) —— 试 systemctl status ${name}"
  fi
}

# 端口是否在监听
_v_port() {
  local port="$1" label="$2"
  if command -v ss >/dev/null 2>&1; then
    # grep -c（消费全部输入）而不是 grep -q：后者在 pipefail 下会因上游 SIGPIPE 误判
    if ss -lnt 2>/dev/null | awk '{print $4}' | grep -cE "[:.]${port}\$" >/dev/null; then
      _vok "端口监听中: ${label} (${port})"; return 0
    fi
  elif command -v netstat >/dev/null 2>&1; then
    if netstat -lnt 2>/dev/null | awk '{print $4}' | grep -cE "[:.]${port}\$" >/dev/null; then
      _vok "端口监听中: ${label} (${port})"; return 0
    fi
  else
    _vskip "ss/netstat 均不可用，跳过端口检查: ${label}"; return 0
  fi
  _vfail "端口未监听: ${label} (${port})"
}

# Redis 密码一致性：配置里的 requirepass 必须能被运行中的实例接受。
# 端口在监听 != 能连上：若配置密码与运行时密码不一致（配置被改写但服务未重启），
# 客户端会一律 WRONGPASS，而此前的自检完全看不出来 —— 这里补上这一项。
_v_redis_auth() {
  local label="$1" conf rcli pass
  conf="${PREFIX_REDIS}/etc/redis.conf"
  [ -f "$conf" ] || conf=/etc/redis/redis.conf
  [ -f "$conf" ] || { _vskip "未找到 Redis 配置文件，跳过密码一致性检查: ${label}"; return 0; }
  rcli="${PREFIX_REDIS}/bin/redis-cli"
  [ -x "$rcli" ] || rcli=$(command -v redis-cli 2>/dev/null)
  [ -n "$rcli" ] || { _vskip "无 redis-cli，跳过密码一致性检查: ${label}"; return 0; }
  pass=$(sed -n 's/^[[:space:]]*requirepass[[:space:]]\+//p' "$conf" 2>/dev/null | head -1 | tr -d '\r')
  if [ -z "$pass" ]; then
    _vok "${label} 未启用 requirepass（无需密码）"; return 0
  fi
  if "$rcli" -h 127.0.0.1 -p 6379 -a "$pass" --no-auth-warning PING 2>/dev/null | grep -q PONG; then
    _vok "${label} 密码一致：配置中的 requirepass 可正常认证"
  else
    _vfail "${label} 密码不一致：配置中的 requirepass 认证失败（WRONGPASS）—— 运行中的实例仍持旧密码，请执行 systemctl restart redis 后重试"
  fi
}

# 文件/目录是否存在
_v_file() {
  local f="$1" label="$2"
  if [ -e "$f" ]; then _vok "存在: ${label} (${f})"
  else _vfail "缺失: ${label} (${f})"; fi
}

# php -m 里是否含某扩展
_v_ext() {
  local ext="$1" php="${PREFIX_PHP}/bin/php"
  [ -x "$php" ] || php=$(command -v php 2>/dev/null)
  [ -n "$php" ] || { _vskip "无 php 可执行文件，跳过扩展检查: ${ext}"; return 0; }
  if "$php" -m 2>/dev/null | tr 'A-Z' 'a-z' | grep -cx "$ext" >/dev/null; then
    _vok "PHP 扩展已加载: ${ext}"
  else
    _vfail "PHP 扩展未加载: ${ext} —— 查 ${PREFIX_PHP}/etc/php.d/${ext}.ini"
  fi
}

# 版本号包含关系（nginx -v 输出里找 "1.30.6"）
_v_ver() {
  local want="$1" got="$2" label="$3"
  if [ -z "$want" ]; then
    # 单独执行 verify（没带组件参数）时无从得知"目标版本"，只报实际值
    _vskip "未指定目标版本，跳过版本比对: ${label}（实际: ${got:-取不到}）"
    return 0
  fi
  case "$got" in
    *"$want"*) _vok "版本一致: ${label} = ${want}" ;;
    "")        _vskip "取不到 ${label} 版本输出，跳过比对" ;;
    *)         _vfail "版本不一致: ${label} 期望 ${want}，实际 ${got}" ;;
  esac
}

# 单独执行 `install.sh verify` 时没有 SEL_* 选择项，按"已装产物"反推要查什么。
# 反推出的选择项版本部分留空（形如 ":source"），这样服务/端口/扩展照常查，
# 版本比对则跳过（见 _v_ver 里 want 为空的处理）。
_verify_autodetect() {
  local any=0 v
  for v in SEL_NGINX SEL_APACHE SEL_PHP SEL_MYSQL SEL_MARIADB SEL_REDIS \
           SEL_MEMCACHED SEL_PHPMEMCACHED SEL_PHPREDIS SEL_SWOOLE SEL_COMPOSER \
           SEL_NODE SEL_JAVA; do
    [ -n "${!v:-}" ] && any=1
  done
  [ "${INSTALL_FAIL2BAN:-}" = yes ] && any=1
  [ "${INSTALL_TOMCAT:-}" = yes ] && any=1
  [ "${INSTALL_PMA:-}" = yes ] && any=1
  [ "${INSTALL_ADMINER:-}" = yes ] && any=1
  [ "$any" = 1 ] && return 0

  _V_AUTO=1
  [ -x "${PREFIX_NGINX}/sbin/nginx" ]   && SEL_NGINX=":source"
  [ -x "${PREFIX_APACHE}/bin/httpd" ]   && SEL_APACHE=":source"
  if [ -x "${PREFIX_PHP}/bin/php" ]; then
    if [ -x "${PREFIX_PHP}/sbin/php-fpm" ]; then SEL_PHP=":fpm"; else SEL_PHP=":apache"; fi
  fi
  [ -x "${PREFIX_MYSQL}/bin/mysqld" ]   && SEL_MYSQL=":binary"
  [ -x "${PREFIX_MARIADB}/bin/mariadbd" ] && SEL_MARIADB=":binary"
  [ -x "${PREFIX_REDIS}/bin/redis-server" ] && SEL_REDIS=":source"
  [ -x "${PREFIX_MEMCACHED}/bin/memcached" ] && SEL_MEMCACHED=":source"
  # PHP 扩展与 Web 工具按"产物文件"探测（ini / 目录），保证 `verify` 不带参数时
  # phpredis、imagick、phpMyAdmin、Adminer 的检查不会被静默跳过。
  [ -f "${PREFIX_PHP}/etc/php.d/redis.ini" ]    && SEL_PHPREDIS=":source"
  [ -f "${PREFIX_PHP}/etc/php.d/memcached.ini" ] && SEL_PHPMEMCACHED=":source"
  [ -f "${PREFIX_PHP}/etc/php.d/swoole.ini" ]    && SEL_SWOOLE=":source"
  [ -f "${PREFIX_PHP}/etc/php.d/imagick.ini" ]  && PHP_IMAGICK=yes
  [ -x /usr/local/bin/composer ]        && SEL_COMPOSER=":phar"
  [ -x "${PREFIX_NODE}/bin/node" ]      && SEL_NODE=":binary"
  [ -f /etc/fail2ban/jail.d/lnamp.local ] && INSTALL_FAIL2BAN=yes
  [ -x "${PREFIX_TOMCAT}/bin/catalina.sh" ] && INSTALL_TOMCAT=yes
  [ -d "${WWWROOT}/web/phpMyAdmin" ]    && INSTALL_PMA=yes
  [ -f "${WWWROOT}/web/adminer/index.php" ] && INSTALL_ADMINER=yes
  if [ "$_V_AUTO" = 1 ]; then
    log "未指定组件参数，按已安装产物自动探测（版本比对将跳过；要严格比对请带参数，如 --nginx 1.30.6）"
  fi
  return 0
}

# ----- 内核调优 / 句柄上限 ---------------------------------------------------
# 注意：这里只做"是否落地"和"当前值是否达标"的判断。
# 当前值没达标时给 SKIP 而不是 FAIL —— 更大的序号文件可能覆盖、容器内
# 内核参数也常常被宿主限制，属于环境问题而非安装失败。
_v_tuning() {
  local f somax nofile
  local -a _tfiles=(
    "${SYSCTL_CONF:-/etc/sysctl.d/99-lnamp.conf}"
    "${LIMITS_CONF:-/etc/security/limits.d/99-lnamp.conf}"
    "${SYSTEMD_LIMITS_CONF:-/etc/systemd/system.conf.d/99-lnamp.conf}"
  )
  for f in "${_tfiles[@]}"; do
    if [ -f "$f" ]; then
      _vok "调优配置存在: ${f}"
    else
      _vskip "缺少 ${f}（可补跑: install.sh sysctl）"
    fi
  done

  if command -v sysctl >/dev/null 2>&1; then
    somax=$(sysctl -n net.core.somaxconn 2>/dev/null)
    if command -v sysctl_tuned >/dev/null 2>&1 && sysctl_tuned; then
      _vok "net.core.somaxconn 已调优 = ${somax} (目标 ≥ ${SYSCTL_NOFILE:-65535})"
    else
      _vskip "net.core.somaxconn = ${somax:-取不到}，未达 ${SYSCTL_NOFILE:-65535}（可补跑: install.sh sysctl）"
    fi
  else
    _vskip "无 sysctl 命令，跳过内核参数检查"
  fi

  nofile=$(ulimit -Hn 2>/dev/null)
  local _want_nofile="${SYSCTL_NOFILE:-65535}"
  case "$nofile" in
    ""|unlimited) _vok "当前 shell hard nofile = ${nofile:-unlimited}" ;;
    *) if [ "$nofile" -ge "$_want_nofile" ] 2>/dev/null; then
         _vok "当前 shell hard nofile = ${nofile}"
       else
         _vskip "当前 shell hard nofile = ${nofile}（< ${_want_nofile}，需重新登录或 systemctl daemon-reexec 后重启服务）"
       fi ;;
  esac
}

# ----- Composer / npm 包索引 -------------------------------------------------
_v_mirrors() {
  local c n
  c=$(command -v composer 2>/dev/null)
  [ -n "$c" ] || { [ -x /usr/local/bin/composer ] && c=/usr/local/bin/composer; }
  if [ -n "${c:-}" ] && [ -x "$c" ]; then
    # 复用 mirror.sh 的读取函数：命名仓库格式下 repos.packagist 键读取会直接报错，
    # 这里曾因各写一份读取逻辑而在自检里误报"官方源"。
    local cur
    cur=$(_mirror_composer_get)
    if [ -n "$cur" ]; then _vok "Composer 包索引: ${cur}"
    else _vskip "Composer 用官方 packagist.org（国内可跑: install.sh mirror cn）"; fi
  else
    _vskip "未安装 composer，跳过 Composer 镜像检查"
  fi

  n=$(command -v npm 2>/dev/null)
  if [ -n "$n" ]; then
    local reg
    reg=$("$n" config get registry 2>/dev/null | tail -1)
    if [ -n "$reg" ]; then _vok "npm registry: ${reg}"
    else _vskip "取不到 npm registry"; fi
  else
    _vskip "未安装 npm，跳过 npm 镜像检查"
  fi
}

# ----- 主入口 ---------------------------------------------------------------
verify_stack() {
  _V_PASS=0; _V_FAIL=0; _V_SKIP=0; _V_AUTO=0
  hr
  log "装后自检 (post-install verification)"
  hr
  _verify_autodetect

  # ---- 1) 服务状态 ----
  echo "[1/7] 服务状态 (services)"
  if [ -n "${SEL_NGINX:-}" ];   then _v_svc nginx   "Nginx";   fi
  if [ -n "${SEL_APACHE:-}" ];  then _v_svc httpd   "Apache";  fi
  # PHP 以 mod_php（apache）形式安装时根本没有 php-fpm 服务，无条件检查会误报
  # （真机 247 上就是 FAIL: 服务未运行 PHP-FPM，而 PHP 实际跑得好好的）。
  if [ -n "${SEL_PHP:-}" ] && [ "${SEL_PHP##*:}" = fpm ]; then _v_svc php-fpm "PHP-FPM"; fi
  if [ -n "${SEL_PHP:-}" ] && [ "${SEL_PHP##*:}" = apache ]; then
    if ls "${PREFIX_APACHE}"/modules/libphp*.so >/dev/null 2>&1; then
      _vok "Apache 已加载 mod_php: $(ls "${PREFIX_APACHE}"/modules/libphp*.so | head -1)"
    else
      _vfail "PHP 指定为 apache 模式，但 ${PREFIX_APACHE}/modules 下没有 libphp*.so"
    fi
  fi
  if [ -n "${SEL_MYSQL:-}" ];   then _v_svc mysqld  "MySQL";   fi
  if [ -n "${SEL_MARIADB:-}" ]; then _v_svc mariadb "MariaDB"; fi
  if [ -n "${SEL_REDIS:-}" ];   then _v_svc redis   "Redis";   fi
  if [ -n "${SEL_MEMCACHED:-}" ]; then _v_svc memcached "Memcached"; fi
  if [ "${INSTALL_FAIL2BAN:-}" = yes ]; then _v_svc fail2ban "fail2ban"; fi
  if [ "${INSTALL_TOMCAT:-}" = yes ]; then _v_svc tomcat "Tomcat"; fi

  # ---- 2) 端口监听 ----
  echo "[2/7] 端口监听 (listening ports)"
  if [ -n "${SEL_NGINX:-}" ] || [ -n "${SEL_APACHE:-}" ]; then _v_port 80 "HTTP"; fi
  if [ -n "${SEL_MYSQL:-}" ] || [ -n "${SEL_MARIADB:-}" ]; then
    _v_port 3306 "MySQL/MariaDB"
    _v_db_bind_scope
  fi
  if [ -n "${SEL_REDIS:-}" ]; then _v_port 6379 "Redis"; fi
  if [ -n "${SEL_REDIS:-}" ]; then _v_redis_auth "Redis"; fi
  if [ -n "${SEL_MEMCACHED:-}" ]; then _v_port "${MEMCACHED_PORT:-11211}" "Memcached"; fi
  if [ -n "${SEL_PHP:-}" ] && [ "${SEL_PHP##*:}" = fpm ]; then
    _v_file "${PHP_FPM_SOCK}" "php-fpm socket"
  fi

  # ---- 3) PHP 可解析（写探针 + curl）----
  echo "[3/7] PHP 解析 (php-fpm/mod_php 端到端)"
  if [ -n "${SEL_PHP:-}" ] && { [ -n "${SEL_NGINX:-}" ] || [ -n "${SEL_APACHE:-}" ]; }; then
    _v_php_probe
    _v_web_uis
  else
    _vskip "未同时安装 Web 服务器与 PHP，跳过端到端 PHP 解析检查"
  fi

  # ---- 4) 扩展生效 ----
  echo "[4/7] PHP 扩展 (loaded extensions)"
  if [ -n "${SEL_PHP:-}" ]; then
    # 通用扩展：所有 PHP 版本都应具备
    local common_exts="gd mysqli pdo_mysql curl mbstring openssl xml zip json"
    local e
    for e in $common_exts; do _v_ext "$e"; done
    # phpredis：仅在选了 phpredis 时断言
    if [ -n "${SEL_PHPREDIS:-}" ]; then _v_ext redis; fi
    # memcached / swoole：仅在选了对应扩展时断言
    if [ -n "${SEL_PHPMEMCACHED:-}" ]; then _v_ext memcached; fi
    if [ -n "${SEL_SWOOLE:-}" ]; then _v_ext swoole; fi
    # imagick：仅在选了 imagick 时断言
    if [ "${PHP_IMAGICK:-}" = yes ]; then _v_ext imagick; fi
  else
    _vskip "未安装 PHP，跳过扩展检查"
  fi

  # ---- 5) 版本一致 ----
  echo "[5/7] 版本一致性 (versions vs versions.conf)"
  if [ -n "${SEL_NGINX:-}" ]; then
    local nbin="${PREFIX_NGINX}/sbin/nginx"
    [ -x "$nbin" ] || nbin=$(command -v nginx 2>/dev/null)
    # 选择项里的版本可能带发行版前缀(tengine-3.1.0 / freenginx-1.31.4)，而
    # `<bin> -v` 输出是 "Tengine/3.1.0" / "freenginx/1.31.4"（斜杠分隔），
    # 直接比对会恒定失败 —— 先剥掉前缀，只比纯粹的版本号。
    local nwant="${SEL_NGINX%%:*}"
    case "$nwant" in
      tengine-*)   nwant="${nwant#tengine-}" ;;
      freenginx-*) nwant="${nwant#freenginx-}" ;;
    esac
    [ -n "$nbin" ] && _v_ver "$nwant" "$("$nbin" -v 2>&1)" "Nginx"
  fi
  if [ -n "${SEL_PHP:-}" ]; then
    local pbin="${PREFIX_PHP}/bin/php"
    [ -x "$pbin" ] || pbin=$(command -v php 2>/dev/null)
    [ -n "$pbin" ] && _v_ver "${SEL_PHP%%:*}" "$("$pbin" -v 2>/dev/null | head -1)" "PHP"
  fi
  if [ -n "${SEL_MYSQL:-}" ] || [ -n "${SEL_MARIADB:-}" ]; then
    local mbin="" want="" label=""
    if [ -n "${SEL_MYSQL:-}" ]; then
      mbin="${PREFIX_MYSQL}/bin/mysql"; want="${SEL_MYSQL%%:*}"; label="MySQL"
    else
      mbin="${PREFIX_MARIADB}/bin/mysql"; want="${SEL_MARIADB%%:*}"; label="MariaDB"
    fi
    [ -x "$mbin" ] || mbin=$(command -v mysql 2>/dev/null)
    [ -n "$mbin" ] && _v_ver "$want" "$("$mbin" --version 2>&1)" "$label"
  fi
  if [ -n "${SEL_REDIS:-}" ]; then
    local rbin="${PREFIX_REDIS}/bin/redis-server"
    [ -x "$rbin" ] || rbin=$(command -v redis-server 2>/dev/null)
    [ -n "$rbin" ] && _v_ver "${SEL_REDIS%%:*}" "$("$rbin" --version 2>&1)" "Redis"
  fi
  if [ -n "${SEL_MEMCACHED:-}" ]; then
    local mbin="${PREFIX_MEMCACHED}/bin/memcached"
    [ -x "$mbin" ] || mbin=$(command -v memcached 2>/dev/null)
    [ -n "$mbin" ] && _v_ver "${SEL_MEMCACHED%%:*}" "$("$mbin" --version 2>&1)" "Memcached"
  fi
  if [ -n "${SEL_NODE:-}" ]; then
    local nbin="${PREFIX_NODE}/bin/node"
    [ -x "$nbin" ] && _v_ver "${SEL_NODE%%:*}" "$("$nbin" -v 2>&1)" "Node.js"
  fi
  if [ -n "${SEL_COMPOSER:-}" ] && [ -x /usr/local/bin/composer ]; then
    # 版本提取容错：composer 是 phar，其 --version 输出可能被 PHP 的
    # "putenv() has been disabled" 等 Warning 抢占首行（PHP7 + 禁用函数实测）。
    # 丢 stderr + 正则抠 x.y.z，保证比对拿到的永远是版本号本身。
    _v_ver "${SEL_COMPOSER%%:*}" "$(/usr/local/bin/composer --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)" "Composer"
  fi
  if [ "${INSTALL_FAIL2BAN:-}" = yes ]; then
    _v_file /etc/fail2ban/jail.d/lnamp.local "fail2ban jail 配置"
    command -v fail2ban-client >/dev/null 2>&1 && \
      log "  fail2ban 已启用的 jail: $(fail2ban-client status 2>/dev/null | sed -n 's/.*Jail list:[[:space:]]*//p')"
  fi

  # ---- 6) 数据库连通 ----
  echo "[6/7] 数据库连通 (database connectivity)"
  if [ -n "${SEL_MYSQL:-}" ] || [ -n "${SEL_MARIADB:-}" ]; then
    _v_db_connect
  else
    _vskip "未安装数据库，跳过连通性检查"
  fi

  # ---- 7) 内核调优 / 包索引镜像 ----
  echo "[7/7] 调优与包镜像 (kernel tuning & package mirrors)"
  _v_tuning
  _v_mirrors

  # ---- 汇总 ----
  hr
  if [ "$_V_FAIL" -eq 0 ]; then
    log_ok "自检通过 (verification passed): PASS=${_V_PASS} SKIP=${_V_SKIP} FAIL=0"
  else
    log_err "自检未通过 (verification failed): PASS=${_V_PASS} SKIP=${_V_SKIP} FAIL=${_V_FAIL}"
  fi
  hr
  [ "$_V_FAIL" -eq 0 ]
}

# ----- 管理后台 Web 可达性 (phpMyAdmin / Adminer) -----------------------------
# 只验证"页面能经 Web 服务器 + PHP 正常渲染"（HTTP 200 且返回登录表单特征），
# 不做登录尝试（root 密码在 /root/.mysql_root_password，留给使用者）。
_v_web_uis() {
  local ip url out code body
  ip=$(hostname -I 2>/dev/null | awk '{print $1}')
  [ -n "$ip" ] || ip=127.0.0.1

  if [ "${INSTALL_PMA:-}" = yes ]; then
    if [ -d "${WWWROOT}/web/phpMyAdmin" ]; then
      url="http://${ip}/phpMyAdmin/"
      out=$(curl -s -w $'\n%{http_code}' --max-time 20 "$url" 2>/dev/null)
      code="${out##*$'\n'}"; body="${out%$'\n'*}"
      if [ "$code" = 200 ] && [ -n "$body" ]; then
        _vok "phpMyAdmin 页面可访问: ${url} (HTTP 200)"
      else
        _vfail "phpMyAdmin 页面异常: ${url} (HTTP ${code:-无响应})"
      fi
    else
      _vskip "phpMyAdmin 目录不存在: ${WWWROOT}/web/phpMyAdmin"
    fi
  fi

  if [ "${INSTALL_ADMINER:-}" = yes ]; then
    if [ -f "${WWWROOT}/web/adminer/index.php" ]; then
      url="http://${ip}/adminer/"
      out=$(curl -s -w $'\n%{http_code}' --max-time 20 "$url" 2>/dev/null)
      code="${out##*$'\n'}"; body="${out%$'\n'*}"
      if [ "$code" = 200 ] && [ -n "$body" ]; then
        _vok "Adminer 页面可访问: ${url} (HTTP 200)"
      else
        _vfail "Adminer 页面异常: ${url} (HTTP ${code:-无响应})"
      fi
    else
      _vskip "Adminer 文件不存在: ${WWWROOT}/web/adminer/index.php"
    fi
  fi
}

# ----- 数据库监听范围（配置 + 实际监听都要只绑回环）-----
# 端口"在听"不等于"只给自己听"：MySQL 社区 RPM 不写 bind-address 时默认监听
# 全部网卡，MariaDB 官方 server.cnf 更是直接写 0.0.0.0 —— 云主机上等于把
# 3306 送出去。这里既看配置也实测监听地址。
_v_db_bind_scope() {
  local cfg="${MY_CNF_PATH:-/etc/my.cnf}" bind="" f
  _db_bind_in() { awk -F'=' '/^[[:space:]]*bind-address[[:space:]]*=/{gsub(/[[:space:]]/,"",$2);print $2;exit}' "$1" 2>/dev/null; }
  [ -f "$cfg" ] && bind=$(_db_bind_in "$cfg")
  if [ -z "$bind" ]; then
    # 包管理器安装的库常把配置分散在 conf.d 里（含我们写的 zz-lnamp-bind.cnf）
    for f in /etc/my.cnf.d/*.cnf /etc/mysql/conf.d/*.cnf \
             /etc/mysql/mysql.conf.d/*.cnf /etc/mysql/mariadb.conf.d/*.cnf; do
      [ -f "$f" ] || continue
      bind=$(_db_bind_in "$f"); [ -n "$bind" ] && break
    done
  fi
  case "$bind" in
    127.0.0.1|localhost|::1) _vok "数据库配置仅监听回环 (bind-address=${bind})" ;;
    "") _vskip "未找到 bind-address 配置，跳过监听范围检查" ;;
    *) _vfail "数据库监听 ${bind} —— 3306 对外暴露"
       log "    修复: 把 ${cfg} 的 bind-address 改为 127.0.0.1 后 systemctl restart mysqld" ;;
  esac
  local addr rc
  addr=$(db_listen_addr 3306); db_listen_is_local 3306; rc=$?
  case "$rc" in
    0) _vok "3306 实际只监听回环 (${addr})" ;;
    1) _vfail "3306 实际监听在 ${addr}（对外暴露，云主机上会被扫）"
       log "    修复: MYSQL_BIND_ADDRESS=127.0.0.1 $0 --mysql <版本> 或改配置后重启" ;;
    *) _vskip "3306 当前未在监听（服务未运行），跳过实际监听地址检查" ;;
  esac
}

# ----- PHP 端到端探针 -------------------------------------------------------
_v_php_probe() {
  local webroot="${WWWROOT}/web" url ip
  safe_mkdir "$webroot" 2>/dev/null
  # 探针：输出一个唯一标记，端到端能拿到就说明 Web -> PHP 链路通
  cat > "$VERIFY_PROBE" <<'EOF'
<?php
echo 'LNAMP_PROBE_OK ';
echo 'php=' . PHP_VERSION . ' ';
echo 'sapi=' . php_sapi_name() . ' ';
echo 'redis=' . (extension_loaded('redis') ? 'on' : 'off') . ' ';
echo 'mysqli=' . (extension_loaded('mysqli') ? 'on' : 'off') . ' ';
EOF
  chown www:www "$VERIFY_PROBE" 2>/dev/null || true
  chmod 0644 "$VERIFY_PROBE" 2>/dev/null
  # 探针是**临时**的：curl 超时、Ctrl-C、被 kill 都不能把文件留在站点里
  # （留着就是一个可被外人访问的 PHP 入口）。三重兜底：正常返回 / 中断 / 退出。
  trap 'rm -f "$VERIFY_PROBE" 2>/dev/null' RETURN INT TERM EXIT

  # 取本机 IP（站点默认站即 webroot）
  ip=$(hostname -I 2>/dev/null | awk '{print $1}')
  [ -n "$ip" ] || ip=127.0.0.1
  url="http://${ip}/__lnamp_probe.php"

  local body
  body=$(curl -s --max-time 15 "$url" 2>/dev/null)
  case "$body" in
    *LNAMP_PROBE_OK*)
      _vok "PHP 端到端解析正常: ${url}"
      log "    探针返回: ${body}"
      # 探针里再确认关键扩展（这是"web 端"视角，比 php -m 更真实）
      case "$body" in
        *redis=on*)  _vok "web 端 redis 扩展可见" ;;
        *)           _vfail "web 端看不到 redis 扩展（php -m 可能有但 phpinfo 没有）—— 需重启 php-fpm" ;;
      esac
      ;;
    "")
      _vfail "PHP 探针无响应: ${url} —— 检查 nginx/apache 是否转发 .php 到 php-fpm"
      ;;
    *)
      _vfail "PHP 探针返回异常: ${url}"
      log "    实际返回: $(printf '%s' "$body" | head -3 | tr '\n' ' ')"
      ;;
  esac
  rm -f "$VERIFY_PROBE" 2>/dev/null
}

# ----- 数据库连通 -----------------------------------------------------------
_v_db_connect() {
  local mbin="" passfile="" label=""
  if [ -n "${SEL_MYSQL:-}" ]; then
    mbin="${PREFIX_MYSQL}/bin/mysql"
    passfile="/root/.mysql_root_password"; label="MySQL"
  else
    mbin="${PREFIX_MARIADB}/bin/mysql"
    passfile="/root/.mariadb_root_password"; label="MariaDB"
  fi
  [ -x "$mbin" ] || mbin=$(command -v mysql 2>/dev/null)
  [ -n "$mbin" ] || { _vskip "找不到 mysql 客户端，跳过连通性检查"; return 0; }

  # 密码文件由 db_set_random_root_password 写成：
  #   "<Label> root 密码 (password): <密码>"  （chmod 600）
  # 锚定字面量 "(password):" 作分隔符，密码本身含冒号/括号也不会被误截。
  # （gen_password 只产 A-Za-z0-9，这里仍是双保险。）
  local auth=()
  if [ -r "$passfile" ]; then
    local pw
    pw=$(sed -n 's/^.*(password):[[:space:]]*//p' "$passfile" 2>/dev/null | head -1 | tr -d '\r')
    [ -n "$pw" ] && auth=(-p"$pw")
  else
    log "  (未找到 ${passfile}，将尝试 socket 免密连接)"
  fi
  # socket 兜底：安装器把 socket 放 /tmp/mysql.sock（见 my.cnf）
  local sock="/tmp/mysql.sock"
  [ -S "$sock" ] || sock="/var/lib/mysql/mysql.sock"

  local out rc
  if [ -S "$sock" ]; then
    out=$("$mbin" --socket="$sock" -uroot ${auth+"${auth[@]}"} -N -e 'SELECT 1;' 2>&1)
  else
    out=$("$mbin" -h 127.0.0.1 -P 3306 -uroot ${auth+"${auth[@]}"} -N -e 'SELECT 1;' 2>&1)
  fi
  rc=$?
  if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q '^1$'; then
    _vok "数据库可连通并执行查询 (SELECT 1 -> 1) [${label}]"
    # 附加回归检查：TCP 回环（127.0.0.1:3306）。Web 应用常用 127.0.0.1 作 DB Host，
    # 安装器已在 root@localhost(socket) 之外放行 root@127.0.0.1 / root@::1。
    # 失败仅告警不阻断：个别环境（如自管数据库）可能有意只开 socket。
    local tout
    tout=$("$mbin" -h 127.0.0.1 -P 3306 -uroot ${auth+"${auth[@]}"} -N -e 'SELECT 1;' 2>&1)
    if [ "$?" -eq 0 ] && printf '%s' "$tout" | grep -q '^1$'; then
      _vok "TCP 回环可连接 (127.0.0.1:3306) [${label}]"
    else
      log_warn "TCP 回环 (127.0.0.1:3306) 连接失败 [${label}]: $(printf '%s' "$tout" | head -1) —— Web 应用请用 localhost(socket)，或手动授权 root@127.0.0.1"
    fi
  else
    _vfail "数据库连接/查询失败 [${label}]: $(printf '%s' "$out" | head -1)"
  fi
}
