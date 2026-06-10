#!/bin/bash
# ============================================================================
#  modules/vhost.sh  ——  创建虚拟主机 (vhost)，自定义监听端口，仅 HTTP(不含 https)
#  用法:
#    install.sh vhost <域名> [端口] [网站根目录]
#    install.sh vhost            # 不带参数 -> 交互输入
#  自动检测已安装的 Web 服务器(nginx 优先，其次 apache)，写入对应 vhost 配置、
#  建站点目录与测试页、放行端口并 reload。若检测到 PHP-FPM 则加 PHP 解析。
# ============================================================================

VHOST_CONF_PATH=""

_have_nginx() { [ -x "${PREFIX_NGINX}/sbin/nginx" ] || command -v nginx >/dev/null 2>&1; }
_have_apache() { [ -x "${PREFIX_APACHE}/bin/httpd" ] || command -v httpd >/dev/null 2>&1 || command -v apache2 >/dev/null 2>&1; }

_detect_webserver() {
  if _have_nginx; then echo nginx
  elif _have_apache; then echo apache
  fi
}

_php_fpm_available() {
  [ -x "${PREFIX_PHP}/sbin/php-fpm" ] || command -v php-fpm >/dev/null 2>&1
}

# create_vhost <域名> <端口> <网站根> [with_php:auto|yes|no] [server:nginx|apache]
create_vhost() {
  local domain="$1" port="${2:-80}" webroot="$3" with_php="${4:-auto}" ws_pref="${5:-}"
  [ -n "$domain" ] || die "vhost: 缺少域名 (domain required)"
  case "$port" in ''|*[!0-9]*) die "vhost: 端口必须为数字 (port must be numeric): ${port}" ;; esac
  [ "$port" -ge 1 ] && [ "$port" -le 65535 ] || die "vhost: 端口超出范围 1-65535: ${port}"
  [ -n "$webroot" ] || webroot="${WWWROOT}/${domain}"

  local ws
  if [ -n "$ws_pref" ]; then
    case "$ws_pref" in
      nginx)  _have_nginx  || die "vhost: 指定了 nginx 但未检测到已安装的 nginx" ; ws=nginx ;;
      apache) _have_apache || die "vhost: 指定了 apache 但未检测到已安装的 apache"; ws=apache ;;
      *)      die "vhost: 未知 Web 服务器 '${ws_pref}' (应为 nginx 或 apache)" ;;
    esac
  else
    ws=$(_detect_webserver)
    [ -n "$ws" ] || die "vhost: 未检测到已安装的 Nginx 或 Apache，请先安装 Web 服务器"
    if _have_nginx && _have_apache; then
      log "检测到同时安装了 nginx 与 apache，默认使用 ${ws}（可加第 4 个参数 nginx|apache 指定）"
    fi
  fi

  if [ "$with_php" = auto ]; then
    if _php_fpm_available; then with_php=yes; else with_php=no; fi
  fi

  ensure_www_user 2>/dev/null || ensure_sysuser www 2>/dev/null || true
  mkdir -p "$webroot" "${WWWLOGS}"
  [ -f "${webroot}/index.html" ] || echo "<h1>It works: ${domain} (port ${port})</h1>" > "${webroot}/index.html"
  if [ "$with_php" = yes ] && [ ! -f "${webroot}/index.php" ]; then
    echo "<?php phpinfo();" > "${webroot}/index.php"
  fi
  chown -R www:www "$webroot" 2>/dev/null || true

  log "创建 vhost: 域名=${domain} 端口=${port} 根目录=${webroot} PHP=${with_php} (${ws})"
  case "$ws" in
    nginx)  _vhost_nginx  "$domain" "$port" "$webroot" "$with_php" ;;
    apache) _vhost_apache "$domain" "$port" "$webroot" "$with_php" ;;
  esac

  open_ports "$port"
  hr
  log_ok "vhost 已创建: http://${domain}:${port}/  (根目录 ${webroot})"
  log_ok "  配置文件: ${VHOST_CONF_PATH}"
  [ "$with_php" = yes ] && log_ok "  已启用 PHP 解析 (php-fpm Unix socket: ${PHP_FPM_SOCK})，请确认 php-fpm 已运行"
  hr
}

# ---------------------------------------------------------------------------
# Nginx vhost
# ---------------------------------------------------------------------------
_vhost_nginx() {
  local domain="$1" port="$2" webroot="$3" with_php="$4"
  local nbin nconf vhdir
  if [ -f "${PREFIX_NGINX}/conf/nginx.conf" ]; then
    nbin="${PREFIX_NGINX}/sbin/nginx"; nconf="${PREFIX_NGINX}/conf/nginx.conf"; vhdir="${PREFIX_NGINX}/conf/vhost"
  else
    nbin="$(command -v nginx)"; nconf=/etc/nginx/nginx.conf; vhdir=/etc/nginx/conf.d
  fi
  mkdir -p "$vhdir"

  # 确保 http{} 内 include 了 vhost 目录(源码安装的优化版 nginx.conf 已含相对 include；
  # 这里兼容相对/绝对两种写法，避免重复 include 造成 server 重复)
  local vhbase; vhbase=$(basename "$vhdir")
  if ! grep -qE "include[[:space:]]+\S*${vhbase}/\*\.conf" "$nconf" 2>/dev/null; then
    sed -i "0,/^http {/s##http {\n    include ${vhdir}/*.conf;#" "$nconf"
  fi

  VHOST_CONF_PATH="${vhdir}/${domain}.conf"
  local lnampdir="${vhdir%/*}/lnamp"   # conf/lnamp (与 vhost 同级)
  {
    echo "server {"
    echo "    listen       ${port};"
    echo "    server_name  ${domain};"
    echo "    root         ${webroot};"
    echo "    index        index.php index.html index.htm;"
    echo "    access_log   ${WWWLOGS}/${domain}.log;"
    echo "    error_log    ${WWWLOGS}/${domain}.error.log warn;"
    echo ""
    echo "    # 安全加固(可选，注释掉则关闭)"
    [ -f "${lnampdir}/security.conf" ] && echo "    include ${lnampdir}/security.conf;" || echo "    # include ${lnampdir}/security.conf;"
    echo ""
    echo "    location / {"
    echo "        try_files \$uri \$uri/ /index.php?\$args;"
    echo "    }"
    echo ""
    echo "    location = /nginx_status {"
    echo "        stub_status on; access_log off; allow 127.0.0.1; deny all;"
    echo "    }"
    if [ "$with_php" = yes ]; then
      echo ""
      echo "    location ~ \\.php\$ {"
      echo "        try_files \$uri =404;"
      echo "        fastcgi_pass   unix:${PHP_FPM_SOCK};"
      echo "        fastcgi_index  index.php;"
      echo "        fastcgi_param  SCRIPT_FILENAME \$document_root\$fastcgi_script_name;"
      echo "        include        fastcgi_params;"
      echo "    }"
    fi
    echo ""
    echo "    # 静态资源缓存 + 隐藏文件/上传目录加固"
    if [ -f "${lnampdir}/static.conf" ]; then
      echo "    include ${lnampdir}/static.conf;"
    else
      echo "    location ~ .*\\.(gif|jpg|jpeg|png|bmp|swf|flv|ico|webp)\$ { expires 30d; access_log off; }"
      echo "    location ~ .*\\.(js|css)?\$ { expires 7d; access_log off; }"
      echo "    location ~ /\\.ht { deny all; }"
    fi
    echo "}"
  } > "$VHOST_CONF_PATH"

  if "$nbin" -t; then
    systemctl reload nginx 2>/dev/null || "$nbin" -s reload 2>/dev/null || true
  else
    die "vhost: nginx 配置测试失败，请检查 ${VHOST_CONF_PATH}"
  fi
}

# ---------------------------------------------------------------------------
# Apache vhost
# ---------------------------------------------------------------------------
_vhost_apache() {
  local domain="$1" port="$2" webroot="$3" with_php="$4"
  local abin aconf vhdir
  if [ -f "${PREFIX_APACHE}/conf/httpd.conf" ]; then
    abin="${PREFIX_APACHE}/bin/apachectl"; aconf="${PREFIX_APACHE}/conf/httpd.conf"; vhdir="${PREFIX_APACHE}/conf/vhost"
  elif [ -f /etc/httpd/conf/httpd.conf ]; then
    abin="$(command -v apachectl || echo httpd)"; aconf=/etc/httpd/conf/httpd.conf; vhdir=/etc/httpd/conf.d
  else
    abin="$(command -v apachectl || command -v apache2ctl)"; aconf=/etc/apache2/apache2.conf; vhdir=/etc/apache2/sites-enabled
  fi
  mkdir -p "$vhdir"

  # 检测当前 Apache 的 MPM（与安装时选择保持同步）
  local mpm; mpm=$(_apache_current_mpm "$abin")
  # PHP 解析方式按 MPM 同步：prefork 且已装 mod_php -> mod_php；否则(worker/event) -> php-fpm socket
  local php_method=none
  if [ "$with_php" = yes ]; then
    if [ "$mpm" = prefork ] && _apache_mod_php_loaded "$aconf"; then
      php_method=modphp
    elif _php_fpm_available; then
      php_method=fpm
    elif _apache_mod_php_loaded "$aconf"; then
      php_method=modphp
    fi
  fi

  if ! grep -qE "Include(Optional)?[[:space:]]+.*$(basename "$vhdir")/\*\.conf" "$aconf" 2>/dev/null; then
    echo "IncludeOptional ${vhdir}/*.conf" >> "$aconf"
  fi
  if [ "$port" != "80" ] && ! grep -qE "^[[:space:]]*Listen[[:space:]]+${port}\b" "$aconf" 2>/dev/null; then
    echo "Listen ${port}" >> "$aconf"
  fi

  VHOST_CONF_PATH="${vhdir}/${domain}.conf"
  {
    echo "# Apache MPM=${mpm}  PHP=${php_method}"
    echo "<VirtualHost *:${port}>"
    echo "    ServerName ${domain}"
    echo "    DocumentRoot \"${webroot}\""
    echo "    DirectoryIndex index.php index.html index.htm"
    echo "    <Directory \"${webroot}\">"
    echo "        Options +FollowSymLinks -Indexes"
    echo "        AllowOverride All"
    echo "        Require all granted"
    echo "    </Directory>"
    echo "    # 禁止访问隐藏文件(.git/.env/.htaccess 等)"
    echo "    <FilesMatch \"^\\.\">"
    echo "        Require all denied"
    echo "    </FilesMatch>"
    case "$php_method" in
      fpm)
        echo "    # PHP 经 php-fpm Unix socket 解析(MPM=${mpm}; 需 mod_proxy_fcgi)"
        echo "    <FilesMatch \\.php\$>"
        echo "        SetHandler \"proxy:unix:${PHP_FPM_SOCK}|fcgi://localhost\""
        echo "    </FilesMatch>"
        ;;
      modphp)
        echo "    # PHP 经 mod_php 解析(MPM=prefork)"
        echo "    <FilesMatch \\.php\$>"
        echo "        SetHandler application/x-httpd-php"
        echo "    </FilesMatch>"
        ;;
    esac
    echo "    # 静态资源缓存"
    echo "    <IfModule mod_expires.c>"
    echo "        ExpiresActive On"
    echo "        ExpiresByType image/jpeg \"access plus 30 days\""
    echo "        ExpiresByType image/png  \"access plus 30 days\""
    echo "        ExpiresByType image/gif  \"access plus 30 days\""
    echo "        ExpiresByType image/x-icon \"access plus 30 days\""
    echo "        ExpiresByType image/svg+xml \"access plus 30 days\""
    echo "        ExpiresByType text/css \"access plus 7 days\""
    echo "        ExpiresByType application/javascript \"access plus 7 days\""
    echo "    </IfModule>"
    echo "    # 输出压缩"
    echo "    <IfModule mod_deflate.c>"
    echo "        AddOutputFilterByType DEFLATE text/html text/plain text/css text/xml application/javascript application/json"
    echo "    </IfModule>"
    echo "    ErrorLog  \"${WWWLOGS}/${domain}-error.log\""
    echo "    CustomLog \"${WWWLOGS}/${domain}-access.log\" common"
    echo "</VirtualHost>"
  } > "$VHOST_CONF_PATH"

  if "$abin" -t 2>/dev/null || "$abin" configtest 2>/dev/null; then
    systemctl reload httpd 2>/dev/null || systemctl reload apache2 2>/dev/null || "$abin" -k graceful 2>/dev/null || "$abin" graceful 2>/dev/null || true
  else
    die "vhost: apache 配置测试失败，请检查 ${VHOST_CONF_PATH}"
  fi
}

# 读取 Apache 当前 MPM（httpd -V 的 "Server MPM:" 行）
_apache_current_mpm() {
  local abin="$1" out
  out=$("$abin" -V 2>/dev/null | grep -i 'Server MPM' | awk -F: '{print tolower($2)}' | tr -d ' ')
  case "$out" in prefork|worker|event) echo "$out" ;; *) echo unknown ;; esac
}

# 是否已加载 mod_php（PHP 以 apache 模块方式安装）
_apache_mod_php_loaded() {
  local aconf="$1"
  grep -qiE '^[[:space:]]*LoadModule[[:space:]]+php[0-9_]*_module' "$aconf" 2>/dev/null
}

# 子命令入口：install.sh vhost [域名] [端口] [根目录] [nginx|apache]
vhost_main() {
  local domain="${1:-}" port="${2:-}" webroot="${3:-}" server="${4:-}"
  if [ -z "$domain" ]; then
    read -rp "请输入域名 (domain，可为 IP 或 _): " domain
    read -rp "监听端口 (port，默认 80): " port
    read -rp "网站根目录 (默认 ${WWWROOT}/<域名>): " webroot
    if _have_nginx && _have_apache; then
      read -rp "Web 服务器 (nginx/apache，默认 nginx): " server
    fi
  fi
  [ -n "$port" ] || port=80
  create_vhost "$domain" "$port" "$webroot" auto "$server"
}
