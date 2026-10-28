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

# Apache 是否已加载 mod_php（源码装的 libphp*.so 或发行版模块目录）
_php_modphp_available() {
  ls "${PREFIX_APACHE}"/modules/libphp*.so >/dev/null 2>&1 && return 0
  ls /usr/lib64/httpd/modules/libphp*.so /usr/lib/apache2/modules/libphp*.so >/dev/null 2>&1
}

_php_fpm_available() {
  [ -x "${PREFIX_PHP}/sbin/php-fpm" ] || command -v php-fpm >/dev/null 2>&1
}

# 网站根"危险路径"守卫。
#
# 只查"绝对路径 + 空白 + .."是不够的：/ 和 /etc 同样能通过这三关，而建站流程后面
# 会 `chown -R www:www "$webroot"`、写 nginx/apache 配置、建 php-fpm 池并 chdir 过去
# —— 传一个 / 就把整台机器的属主改掉（sshd 读不了 host key、sudo 报 setuid 错误，
# 系统基本废掉），/etc 同理。这里补两道闸：系统目录黑名单 + 层级下限。
#
# 黑名单只列"放了站点也不会正常"的目录：/var/www、/srv、/opt、/data、/home 这些
# 常见站点根位置刻意放行，避免误伤正常部署。
_vh_webroot_guard() {
  local wr="$1" norm p
  norm=$(printf '%s' "$wr" | tr -s '/')      # /a//b -> /a/b
  norm="${norm%/}"; [ -n "$norm" ] || norm="/"
  [ "$norm" = "/" ] && die "vhost: 网站根目录不能是 / (would chown the whole filesystem): ${wr}"
  for p in /etc /boot /proc /sys /dev /run /selinux /bin /sbin /lib /lib32 /lib64 /libx32 \
           /root /usr/bin /usr/sbin /usr/lib /usr/lib32 /usr/lib64 /usr/libexec \
           /var/log /var/lib /var/run /var/spool; do
    case "$norm" in
      "$p"|"$p"/*) die "vhost: 网站根目录不能是系统目录 ${p} 及其子目录: ${wr}（会递归改属主，破坏系统）" ;;
    esac
  done
  # 层级下限：至少要 <顶层>/<一级>，例如 /home/wwwroot/example.com
  case "$norm" in
    /*/*) : ;;
    *) die "vhost: 网站根目录层级太浅（至少两级，如 ${WWWROOT:-/home/wwwroot}/<域名>）: ${wr}" ;;
  esac
  return 0
}

# create_vhost <域名> <端口> <网站根> [with_php:auto|yes|no] [server:nginx|apache]
create_vhost() {
  local domain="$1" port="${2:-80}" webroot="$3" with_php="${4:-auto}" ws_pref="${5:-}"
  [ -n "$domain" ] || die "vhost: 缺少域名 (domain required)"
  case "$port" in ''|*[!0-9]*) die "vhost: 端口必须为数字 (port must be numeric): ${port}" ;; esac
  [ "$port" -ge 1 ] && [ "$port" -le 65535 ] || die "vhost: 端口超出范围 1-65535: ${port}"

  # 域名校验必须在任何落盘动作之前：历史缺陷是非法域名（含空格/感叹号）也照样
  # 写出 vhost 文件，随后 nginx -t 失败 -> 整个 nginx 配置被污染，之后每次
  # reload/重启都失败 —— 一个错误输入拖垮整台机器的 Web 服务。
  case "$domain" in
    *[!A-Za-z0-9._*-]*) die "vhost: 非法域名 (invalid domain): ${domain}（只允许字母/数字/点/下划线/短横线；通配符只能写成 *.example.com）" ;;
    ''|.*|*.|*..*)      die "vhost: 非法域名 (invalid domain): ${domain}" ;;
  esac
  case "$domain" in
    *'*'*) case "$domain" in \*.*) : ;; *) die "vhost: 通配符只能写成 *.example.com 形式: ${domain}" ;; esac ;;
  esac
  [ "${#domain}" -le 253 ] || die "vhost: 域名过长 (max 253): ${domain}"

  [ -n "$webroot" ] || webroot="${WWWROOT}/${domain}"
  case "$webroot" in
    /*) : ;;
    *)  die "vhost: 网站根目录必须是绝对路径: ${webroot}" ;;
  esac
  case "$webroot" in
    *[[:space:]]*) die "vhost: 网站根目录不能含空白字符: ${webroot}" ;;
    *..*)          die "vhost: 网站根目录不能包含 '..': ${webroot}" ;;
  esac
  _vh_webroot_guard "$webroot"

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

  # PHP 解析方式要分两种：php-fpm（独立池）与 mod_php（Apache 模块）。
  # 只判断 _php_fpm_available 会让 mod_php 机器（234/197 这种 apache+mod_php）
  # 打出 "PHP=no" —— 明明 PHP 能跑，提示却像是没开，建站时也不生成 index.php。
  local php_kind=none
  if [ "$with_php" = auto ]; then
    if _php_fpm_available; then
      with_php=yes; php_kind=fpm
    elif [ "$ws" = apache ] && _php_modphp_available; then
      with_php=yes; php_kind=modphp
    else
      with_php=no; php_kind=none
    fi
  fi

  ensure_www_user 2>/dev/null || ensure_sysuser www 2>/dev/null || true
  safe_mkdir "$webroot" "${WWWLOGS}"
  # 默认首页就是静态 HTML —— **不生成 phpinfo()**。
  # phpinfo 会把 PHP 版本、编译参数、扩展清单、$_SERVER 里的路径与环境变量
  # 全部公开；建站就默认放一个，等于每个新站点自带一个信息泄露页（很多站
  # 上线后忘记删，扫描器第一件事就是找 phpinfo）。
  # 真要验证 PHP 是否可用，用临时探针：
  #   $0 vhost probe <域名>          # 放一个随机名探针并打印 URL
  #   $0 vhost probe --rm            # 验证完立刻删掉
  [ -f "${webroot}/index.html" ] || echo "<h1>It works: ${domain} (port ${port})</h1>" > "${webroot}/index.html"
  chown -R www:www "$webroot" 2>/dev/null || true

  # 每个站点一个独立 php-fpm 池：独立 socket + 独立 open_basedir。
  # 这一步失败**不阻断建站**（退回全局池 + 告警），否则一个 fpm 配置问题会让
  # 站点建不出来 —— 用户看到的是"建站失败"，实际原因却藏在 PHP 那边。
  local php_sock="$PHP_FPM_SOCK" pool_iso=no
  if [ "$with_php" = yes ] && [ "$php_kind" = fpm ]; then
    if _php_pool_ensure "$domain" "$webroot" "${LNAMP_OPEN_BASEDIR_EXTRA:-}"; then
      if [ -n "$_PHP_SITE_SOCK" ]; then php_sock="$_PHP_SITE_SOCK"; pool_iso=yes; fi
    else
      log_warn "站点池创建失败，退回全局 php-fpm 池 —— 该站点与其他站点之间**没有** open_basedir 隔离"
    fi
  fi

  log "创建 vhost: 域名=${domain} 端口=${port} 根目录=${webroot} PHP=${with_php}${php_kind:+(${php_kind})} (${ws})"
  case "$ws" in
    nginx)  _vhost_nginx  "$domain" "$port" "$webroot" "$with_php" "$php_sock" ;;
    apache) _vhost_apache "$domain" "$port" "$webroot" "$with_php" "$php_sock" ;;
  esac

  open_ports "$port"
  hr
  log_ok "vhost 已创建: http://${domain}:${port}/  (根目录 ${webroot})"
  log_ok "  配置文件: ${VHOST_CONF_PATH}"
  if [ "$with_php" = yes ]; then
    log_ok "  已启用 PHP 解析 (php-fpm Unix socket: ${php_sock})，请确认 php-fpm 已运行"
    log "  默认首页为静态 index.html；验证 PHP 请用临时探针（用完必删）:"
    log "    $0 vhost probe ${domain}     # 打印 URL"
    log "    $0 vhost probe --rm          # 验证后删除"
    if [ "$pool_iso" = yes ]; then
      log_ok "  已启用站点隔离: open_basedir=${webroot}:/tmp:… （读不到其他站点）"
    else
      log_warn "  未启用站点隔离：该站点与同机其他站点共用全局池，可互相读取源码"
    fi
  fi
  hr
}

# ---------------------------------------------------------------------------
# Nginx vhost
# ---------------------------------------------------------------------------
_vhost_nginx() {
  local domain="$1" port="$2" webroot="$3" with_php="$4" php_sock="${5:-$PHP_FPM_SOCK}"
  local nbin nconf vhdir
  if [ -f "${PREFIX_NGINX}/conf/nginx.conf" ]; then
    nbin="${PREFIX_NGINX}/sbin/nginx"; nconf="${PREFIX_NGINX}/conf/nginx.conf"; vhdir="${PREFIX_NGINX}/conf/vhost"
  else
    nbin="$(command -v nginx)"; nconf=/etc/nginx/nginx.conf; vhdir=/etc/nginx/conf.d
  fi
  safe_mkdir "$vhdir"

  # 确保 http{} 内 include 了 vhost 目录(源码安装的优化版 nginx.conf 已含相对 include；
  # 这里兼容相对/绝对两种写法，避免重复 include 造成 server 重复)
  local vhbase; vhbase=$(basename "$vhdir")
  if ! grep -qE "include[[:space:]]+\S*${vhbase}/\*\.conf" "$nconf" 2>/dev/null; then
    # 不用 sed：替换串里一旦出现路径（可能含 Windows 的 \2、或 & 号），
    # sed 会把它当反向引用/整段匹配，插入静默失效。awk 按行插入最稳。
    awk -v inc="    include ${vhdir}/*.conf;" '
      { print }
      /^[[:space:]]*http[[:space:]]*\{/ && !done { print inc; done=1 }
    ' "$nconf" > "${nconf}.lnamp.tmp" && mv -f "${nconf}.lnamp.tmp" "$nconf"
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
    # 上传/数据/缓存目录禁止执行 PHP。
    # 有上传功能的应用（CMS/论坛/图床/网盘）被打穿最高频的路径就是：传一个
    # shell.php，然后直接访问 /uploads/shell.php —— `location ~ \.php$` 是全局
    # 正则，会照常把它交给 php-fpm 执行。这类目录只该存静态资源与用户文件。
    # 必须写在下面的 `location ~ \.php$` **之前**：nginx 的正则 location 按出现
    # 顺序匹配，写在后面就永远轮不到这条。
    echo ""
    echo "    location ~* ^/(?:uploads?|uploadfiles?|data|runtime|attachments?|temp|tmp|cache|storage)/.*\\.(?:php[0-9]?|phtml|phar|pht|inc)\$ {"
    echo "        deny all;"
    echo "    }"
    # 隐藏文件与敏感文件：原模板只挡了 .ht*，.git/.env/.user.ini 都是可直接读的
    echo ""
    echo "    location ~* /\\.(?:git|svn|hg|env|htaccess|htpasswd|user\\.ini|project|settings\\.py|bash_history|DS_Store) {"
    echo "        deny all;"
    echo "    }"
    if [ "$with_php" = yes ]; then
      echo ""
      echo "    location ~ \\.php\$ {"
      echo "        try_files \$uri =404;"
      echo "        fastcgi_pass   unix:${php_sock};"
      echo "        fastcgi_index  index.php;"
      echo "        fastcgi_param  SCRIPT_FILENAME \$document_root\$fastcgi_script_name;"
      echo "        include        fastcgi_params;"
      echo "    }"
    fi
    echo ""
    echo "    # 静态资源缓存（敏感文件的禁令已在上方统一给出，这里只管缓存头）"
    if [ -f "${lnampdir}/static.conf" ]; then
      echo "    include ${lnampdir}/static.conf;"
    else
      echo "    location ~ .*\\.(gif|jpg|jpeg|png|bmp|swf|flv|ico|webp)\$ { expires 30d; access_log off; }"
      echo "    location ~ .*\\.(js|css)?\$ { expires 7d; access_log off; }"
    fi
    echo "}"
  } > "${VHOST_CONF_PATH}.new"

  # 先备份同域名的旧配置，再原子替换；测试失败必须回滚 —— 否则一个 test 不过
  # 的 vhost 会一直留在 include 目录里，之后每次 reload / 重启 nginx 都失败。
  # 旧配置备份统一放到归档目录（与 vhost del 一致）。
  # 原来写在 vhost/ 里变成 xxx.conf.bak.<ts>：虽然不匹配 *.conf 不会被 include，
  # 但目录会越堆越乱，而且混着一堆历史版本时很难一眼看出"哪些是有效站点"。
  local _bak=""
  if [ -f "$VHOST_CONF_PATH" ]; then
    local _arch; _arch=$(_vh_archive_dir)
    safe_mkdir "$_arch" 2>/dev/null || true
    _bak="${_arch}/$(basename "$VHOST_CONF_PATH").$(date +%Y%m%d_%H%M%S)"
    cp -f "$VHOST_CONF_PATH" "$_bak" 2>/dev/null || _bak=""
  fi
  mv -f "${VHOST_CONF_PATH}.new" "$VHOST_CONF_PATH"

  local _tout
  if _tout=$("$nbin" -t 2>&1); then
    systemctl reload nginx 2>/dev/null || "$nbin" -s reload 2>/dev/null || true
  else
    if [ -n "$_bak" ] && [ -f "$_bak" ]; then
      mv -f "$_bak" "$VHOST_CONF_PATH"
      log_warn "vhost: 配置测试失败，已回滚为原配置"
    else
      rm -f "$VHOST_CONF_PATH"
      log_warn "vhost: 配置测试失败，已删除本次生成的配置"
    fi
    VHOST_CONF_PATH=""
    "$nbin" -t >/dev/null 2>&1 || log_warn "回滚后 nginx -t 仍失败，请人工检查 ${nconf}"
    die "vhost: nginx 配置测试未通过（已回滚）。nginx 输出: $(printf '%s' "$_tout" | tail -2 | tr '\n' ' ')"
  fi
}

# ---------------------------------------------------------------------------
# Apache vhost
# ---------------------------------------------------------------------------
_vhost_apache() {
  local domain="$1" port="$2" webroot="$3" with_php="$4" php_sock="${5:-$PHP_FPM_SOCK}"
  local abin aconf vhdir
  if [ -f "${PREFIX_APACHE}/conf/httpd.conf" ]; then
    abin="${PREFIX_APACHE}/bin/apachectl"; aconf="${PREFIX_APACHE}/conf/httpd.conf"; vhdir="${PREFIX_APACHE}/conf/vhost"
  elif [ -f /etc/httpd/conf/httpd.conf ]; then
    abin="$(command -v apachectl || echo httpd)"; aconf=/etc/httpd/conf/httpd.conf; vhdir=/etc/httpd/conf.d
  else
    abin="$(command -v apachectl || command -v apache2ctl)"; aconf=/etc/apache2/apache2.conf; vhdir=/etc/apache2/sites-enabled
  fi
  safe_mkdir "$vhdir"

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
    # 上传/数据/缓存目录禁止执行 PHP（与 nginx 模板同一套名单，行为保持一致）
    echo "    # 上传/数据/缓存目录禁止执行 PHP（防止传 shell 直接访问）"
    echo "    <DirectoryMatch \"(?i)/(?:uploads?|uploadfiles?|data|runtime|attachments?|temp|tmp|cache|storage)/\">"
    echo "        <FilesMatch \"(?i)\\.(?:php[0-9]?|phtml|phar|pht|inc)\$\">"
    echo "            Require all denied"
    echo "        </FilesMatch>"
    echo "    </DirectoryMatch>"
    case "$php_method" in
      fpm)
        echo "    # PHP 经 php-fpm Unix socket 解析(MPM=${mpm}; 需 mod_proxy_fcgi)"
        echo "    <FilesMatch \\.php\$>"
        echo "        SetHandler \"proxy:unix:${php_sock}|fcgi://localhost\""
        echo "    </FilesMatch>"
        ;;
      modphp)
        echo "    # PHP 经 mod_php 解析(MPM=prefork)"
        echo "    <FilesMatch \\.php\$>"
        echo "        SetHandler application/x-httpd-php"
        echo "    </FilesMatch>"
        # mod_php 走 Apache 进程，没有 php-fpm 池可用，open_basedir 只能写在这里。
        # php_admin_value 不能被脚本 ini_set 覆盖（php_value 可以，等于没设）。
        echo "    # 站点隔离：mod_php 下用 VirtualHost 级 open_basedir（php_admin_value 不可被 ini_set 覆盖）"
        echo "    php_admin_value open_basedir \"${webroot}:/tmp:${PREFIX_PHP}/var/log:${PREFIX_PHP}/var/lib/php/sessions\""
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
  } > "${VHOST_CONF_PATH}.new"

  local _bak=""
  if [ -f "$VHOST_CONF_PATH" ]; then
    local _arch; _arch=$(_vh_archive_dir)
    safe_mkdir "$_arch" 2>/dev/null || true
    _bak="${_arch}/$(basename "$VHOST_CONF_PATH").$(date +%Y%m%d_%H%M%S)"
    cp -f "$VHOST_CONF_PATH" "$_bak" 2>/dev/null || _bak=""
  fi
  mv -f "${VHOST_CONF_PATH}.new" "$VHOST_CONF_PATH"

  local _tout
  if _tout=$("$abin" -t 2>&1 || "$abin" configtest 2>&1); then
    systemctl reload httpd 2>/dev/null || systemctl reload apache2 2>/dev/null || "$abin" -k graceful 2>/dev/null || "$abin" graceful 2>/dev/null || true
  else
    if [ -n "$_bak" ] && [ -f "$_bak" ]; then
      mv -f "$_bak" "$VHOST_CONF_PATH"
      log_warn "vhost: 配置测试失败，已回滚为原配置"
    else
      rm -f "$VHOST_CONF_PATH"
      log_warn "vhost: 配置测试失败，已删除本次生成的配置"
    fi
    VHOST_CONF_PATH=""
    die "vhost: apache 配置测试未通过（已回滚）。apache 输出: $(printf '%s' "$_tout" | tail -2 | tr '\n' ' ')"
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

# ===========================================================================
#  站点清单 / 删除 / 启停  (vhost list | del | disable | enable)
# ---------------------------------------------------------------------------
#  启停的实现方式：把文件名在  xxx.conf  <->  xxx.conf.disabled  之间切换。
#  为什么不用改配置内容：nginx 的 include 是 `vhost/*.conf`、apache 是
#  `IncludeOptional .../*.conf`，改后缀天然不匹配 —— 不碰内容就不会改坏配置，
#  而且 enable 时能一字节不差地还原。也不依赖 a2ensite/a2dissite 这类工具。
#
#  所有改动都遵循"先动、再 nginx -t、失败立即回滚"：一个启停操作不该让
#  整台机器的 Web 服务起不来（这是本项目在 vhost 创建上踩过的坑）。
# ===========================================================================

# 注意不要在这里直接赋值取环境变量：本文件在 install.sh 启动时 source，
# 那时调用方的 LNAMP_VHOST_ARCHIVE 还没设置。必须在使用处取值。
_VH_ARCHIVE_DEFAULT="/var/lib/lnamp/vhost-archive"
_vh_archive_dir() { printf '%s' "${LNAMP_VHOST_ARCHIVE:-$_VH_ARCHIVE_DEFAULT}"; }

# 可扫描的目标：每行 "webserver|配置目录|控制命令"
_vh_scan_targets() {
  if [ -f "${PREFIX_NGINX}/conf/nginx.conf" ]; then
    echo "nginx|${PREFIX_NGINX}/conf/vhost|${PREFIX_NGINX}/sbin/nginx"
  elif [ -f /etc/nginx/nginx.conf ]; then
    echo "nginx|/etc/nginx/conf.d|$(command -v nginx 2>/dev/null)"
  fi
  if [ -f "${PREFIX_APACHE}/conf/httpd.conf" ]; then
    echo "apache|${PREFIX_APACHE}/conf/vhost|${PREFIX_APACHE}/bin/apachectl"
  elif [ -f /etc/apache2/apache2.conf ]; then
    echo "apache|/etc/apache2/sites-enabled|$(command -v apache2ctl 2>/dev/null)"
  elif [ -f /etc/httpd/conf/httpd.conf ]; then
    echo "apache|/etc/httpd/conf.d|$(command -v apachectl 2>/dev/null)"
  fi
}

# 解析一个 vhost 文件 -> "domain|type|ports|root|state|ws|path"
# type: HTTP / HTTPS / HTTP+HTTPS     state: enabled / disabled
#
# 整份解析只用**一个** awk 进程。最初用十几个 sed/grep 逐字段取，单文件就要
# fork 十几次；vhost_del 一次调用会触发 3~5 轮全量扫描，在慢环境（Windows/
# Git Bash）直接卡到分钟级，看起来像死锁。awk 一次读完，成本与文件数线性相关。
_vh_probe_file() {
  local f="$1" ws="$2" state body
  case "$(basename "$f")" in
    *.conf.disabled) state=disabled ;;
    *)               state=enabled  ;;
  esac
  # 只让 awk 解析内容，**路径不进 awk**：awk -v 会把 Windows 路径里的 \U \A 之类
  # 当转义序列吃掉（实测 C:\Users\... 会变成 C:Users...），后续 mv/safe_rm_rf 拿到
  # 的就是个不存在的路径。路径统一由 bash 侧拼接，跨平台都安全。
  body=$(awk -v state="$state" -v ws="$ws" '
    {
      line=$0
      if (dom=="" && line ~ /^[ \t]*server_name[ \t]/) {
        sub(/^[ \t]*server_name[ \t]+/, "", line); sub(/;.*/, "", line); dom=line
      }
      if (dom=="" && line ~ /^[ \t]*ServerName[ \t]/) {
        sub(/^[ \t]*ServerName[ \t]+/, "", line); gsub(/[ \t\r]/, "", line); dom=line
      }
      if (line ~ /^[ \t]*listen[ \t]+[0-9]/) {
        l=line; sub(/^[ \t]*listen[ \t]+/, "", l)
        if (match(l, /^[0-9]+/)) {
          p=substr(l,1,RLENGTH)
          if (!(p in seen)) { seen[p]=1; ports=(ports=="" ? p : ports "," p) }
        }
      }
      if (line ~ /^[ \t]*<VirtualHost[ \t]*[^:]*:[0-9]/) {
        l=line; sub(/.*:/, "", l)
        if (match(l, /^[0-9]+/)) {
          p=substr(l,1,RLENGTH)
          if (!(p in seen)) { seen[p]=1; ports=(ports=="" ? p : ports "," p) }
        }
      }
      if (root=="" && line ~ /^[ \t]*root[ \t]/) {
        sub(/^[ \t]*root[ \t]+/, "", line); sub(/;.*/, "", line); root=line
      }
      if (root=="" && line ~ /^[ \t]*DocumentRoot[ \t]/) {
        sub(/^[ \t]*DocumentRoot[ \t]+/, "", line); gsub(/"/, "", line); sub(/[ \t\r]+$/, "", line); root=line
      }
      if (line ~ /^[ \t]*ssl_certificate[ \t]/) ssl=1
      if (line ~ /^[ \t]*SSLEngine[ \t]+on/)      ssl=1
    }
    END {
      if (dom == "") {
        # 解析不出域名的配置**不能丢**：以前这里 exit 1→调用方 continue，结果是
        # 这类坏文件在 list 里完全隐形、del 又只能按域名找，于是永远删不掉 ——
        # 真机配置目录"越堆越乱"有一半是这么攒出来的。
        printf "!bad|UNKNOWN|%s|%s|%s|%s\n", (ports=="" ? "-" : ports),
               (root=="" ? "-" : root), state, ws
        exit 0
      }
      extra=0
      if (dom ~ /[ \t]/) { n=split(dom, a, /[ \t]+/); extra=n-1; dom=a[1] }
      has80=0; has443=0
      m=split(ports, pp, ",")
      for (i=1;i<=m;i++) { if (pp[i]=="80") has80=1; if (pp[i]=="443") has443=1 }
      if (has443) ssl=1
      if (ssl && has80 && has443) typ="HTTP+HTTPS"
      else if (ssl)               typ="HTTPS"
      else                        typ="HTTP"
      printf "%s%s|%s|%s|%s|%s|%s\n", dom, (extra>0 ? " +" extra : ""), typ,
             (ports=="" ? "-" : ports), (root=="" ? "-" : root), state, ws
    }
  ' "$f") || return 1
  printf '%s|%s\n' "$body" "$f"
}

# 扫描结果缓存：一条命令里常要连扫两三次（定位域名 -> 拼报错列表），
# 每次都全量重扫是纯浪费。任何改名/删除动作之后必须调 _vh_cache_clear。
_VH_SCAN_CACHE=""
_vh_cache_clear() { _VH_SCAN_CACHE=""; }

# 扫描所有站点 -> 每条一行（格式见 _vh_probe_file）
_vh_scan_all() {
  if [ -n "$_VH_SCAN_CACHE" ]; then printf '%s\n' "$_VH_SCAN_CACHE"; return 0; fi
  local ws dir bin f line out=""
  while IFS='|' read -r ws dir bin; do
    [ -n "$dir" ] && [ -d "$dir" ] || continue
    for f in "$dir"/*.conf "$dir"/*.conf.disabled; do
      [ -f "$f" ] || continue
      case "$f" in *.bak.*) continue ;; esac
      line=$(_vh_probe_file "$f" "$ws") || continue
      out="$out$line
"
    done
  done <<< "$(_vh_scan_targets)"
  _VH_SCAN_CACHE="${out%$'\n'}"
  [ -n "$_VH_SCAN_CACHE" ] && printf '%s\n' "$_VH_SCAN_CACHE"
  return 0
}

# 按域名找所有匹配的配置（同一域名可能在 nginx 与 apache 各一份）
# $1 域名  $2 with_disabled(1=连禁用的也找)
_vh_find_by_domain() {
  local want="$1" inc_dis="${2:-0}" dom typ ports root state ws path
  _vh_scan_all | while IFS='|' read -r dom typ ports root state ws path; do
    [ -n "$dom" ] || continue
    [ "$inc_dis" = 1 ] || [ "$state" = "enabled" ] || continue
    case " $dom " in
      *" $want "*) echo "$ws|$path" ;;
    esac
  done
}

# 改完配置后的统一验证 + 重载。失败返回 1（由调用方回滚）
_vh_reload_ws() {
  local ws="$1" bin="$2"
  [ -n "$bin" ] || bin=$(command -v "$ws" 2>/dev/null)
  case "$ws" in
    nginx)
      "${PREFIX_NGINX}/sbin/nginx" -t >/dev/null 2>&1 || "$bin" -t >/dev/null 2>&1 || return 1
      systemctl reload nginx 2>/dev/null || "$bin" -s reload 2>/dev/null || true ;;
    apache)
      if [ -x "${PREFIX_APACHE}/bin/apachectl" ]; then
        "${PREFIX_APACHE}/bin/apachectl" -t >/dev/null 2>&1 || return 1
      else
        "$bin" -t >/dev/null 2>&1 || return 1
      fi
      systemctl reload httpd 2>/dev/null || systemctl reload apache2 2>/dev/null || true ;;
  esac
  # reload 是异步的：master 收到信号就返回，旧 worker 还会服务一小会儿。
  # 不等一下的话，紧跟其后的 curl/脚本拿到的是**上一份**配置的结果——
  # 实测"disable 后立刻访问仍是旧页面、enable 后立刻访问反而 404"，
  # 看起来像启停没生效，其实只是慢了一拍。0.3s 对交互无感。
  sleep 0.3 2>/dev/null || true
  return 0
}

_vh_bin_for_ws() {
  case "$1" in
    nginx)  if [ -x "${PREFIX_NGINX}/sbin/nginx" ]; then echo "${PREFIX_NGINX}/sbin/nginx"; else echo "$(command -v nginx 2>/dev/null)"; fi ;;
    apache) if [ -x "${PREFIX_APACHE}/bin/apachectl" ]; then echo "${PREFIX_APACHE}/bin/apachectl"; else echo "$(command -v apachectl 2>/dev/null || command -v apache2ctl 2>/dev/null)"; fi ;;
  esac
}

# ---------------------------------------------------------------------------
#  list
# ---------------------------------------------------------------------------
# WWWROOT 下没有对应配置引用的目录（孤儿目录）。
# web 是默认站点（phpMyAdmin/Adminer 所在），永远不算孤儿。
_vh_orphan_dirs() {
  [ -d "${WWWROOT}" ] || return 0
  local dom typ ports root state ws path d roots=""
  while IFS='|' read -r dom typ ports root state ws path; do
    [ -n "$root" ] && [ "$root" != "-" ] && roots="$roots$root
"
  done <<< "$(_vh_scan_all)"
  local real
  for d in "${WWWROOT}"/*; do
    [ -d "$d" ] || continue
    case "$(basename "$d")" in web|.well-known) continue ;; esac
    real=$d
    case "$roots" in
      *"$real
"*) continue ;;
    esac
    printf '%s\n' "$real"
  done
}

# 归档目录里已有的文件数（prune --archive-keep 用）
_vh_archive_count() {
  local a; a=$(_vh_archive_dir)
  [ -d "$a" ] && find "$a" -maxdepth 1 -type f 2>/dev/null | wc -l || echo 0
}

# 孤儿 php-fpm 池：站点配置已不存在，或池里的 chdir 目录已消失。
# 这类池是**硬错误**——`php-fpm -t` 会直接
#     ERROR: [pool X] the chdir path '...' does not exist
#     ERROR: FPM initialization failed
# 于是 reload / restart 全部失败，整台机器的 PHP 都起不来。
# （真机上删掉站点目录后就是这个状态：单个站点没了，全站 PHP 挂掉。）
_php_pool_orphans() {
  local d f slug dom dir doms x
  doms=$(_vh_scan_all | cut -d'|' -f1 | grep -v '^!bad$')
  for d in "${PREFIX_PHP}/etc/php-fpm.d" /etc/php-fpm.d; do
    [ -d "$d" ] || continue
    for f in "$d"/site_*.conf; do
      [ -f "$f" ] || continue
      slug=$(basename "$f" .conf)
      # 池文件头注释里有域名："; 由 lnamp 自动生成 —— 站点 a.demo 的独立 php-fpm 池"
      dom=$(sed -n 's/.*站点 \([^ ]*\) 的独立.*/\1/p' "$f" 2>/dev/null | head -1)
      if [ -z "$dom" ]; then
        # 没有注释（手工写的池）：按 slug 反查现有站点，找不到就算孤儿
        local match=0
        while IFS= read -r x; do
          [ -n "$x" ] || continue
          [ "$(_php_site_slug "$x")" = "$slug" ] && { match=1; break; }
        done <<< "$doms"
        [ "$match" = 1 ] || printf '%s\n' "$f"
        continue
      fi
      case " $doms " in *" $dom "*) ;; *) printf '%s\n' "$f"; continue ;; esac
      dir=$(sed -n 's/^[[:space:]]*chdir[[:space:]]*=[[:space:]]*//p' "$f" 2>/dev/null | head -1)
      [ -n "$dir" ] && [ ! -d "$dir" ] && printf '%s\n' "$f"
    done
  done
}

# 把孤儿池归档（不硬删）。stdout 只输出 "POOL|<原路径>" 供调用方做回滚，
# 人看的日志走 stderr —— 否则 $(...) 捕获时会混进日志文本。
_vh_pool_archive_orphans() {
  local archive="$1" ts="$2" list="$3" f
  [ -n "$list" ] || return 0
  while IFS= read -r f; do
    [ -n "$f" ] && [ -f "$f" ] || continue
    if mv -f "$f" "${archive}/$(basename "$f").${ts}" 2>/dev/null; then
      log "  已归档孤儿池: $(basename "$f")" >&2
      printf 'POOL|%s\n' "$f"
    else
      log_err "  归档失败: $f" >&2
    fi
  done <<< "$list"
}

vhost_list() {
  local only="${1:-}" rows
  _vh_cache_clear                      # 列表必须反映最新状态
  rows=$(_vh_scan_all | sort -t'|' -k1,1)

  if [ -z "$rows" ]; then
    log "还没有站点。创建: $0 vhost <域名> [端口] [根目录]"
    return 0
  fi

  echo
  printf '%s\n' "$(_c '1;37' "站点清单 (sites)")"
  # 表头用 ASCII：printf 的 %-Ns 按字节计宽，中文一个字 3 字节但只占 2 列，
  # 用中文表头会让整张表错位（当年第一次跑就错位了）
  printf '  %-12s %-10s %-30s %-30s %-5s %-9s %s\n' "TYPE" "PORTS" "DOMAIN" "ROOT" "ISO" "STATE" "NOTE"
  printf '  %-12s %-10s %-30s %-30s %-5s %-9s %s\n' "------------" "----------" "------------------------------" "------------------------------" "-----" "---------" "--------"

  local n=0 n_https=0 n_dis=0 n_iso=0 n_bad=0 n_noroot=0 dom typ ports root state ws path mark iso note domshow
  while IFS='|' read -r dom typ ports root state ws path; do
    [ -n "$dom" ] || continue
    n=$((n + 1))
    note=""; mark=""; iso="-"
    if [ "$dom" = "!bad" ]; then
      # 解析不出 server_name / ServerName：配置在，但没人知道它服务哪个域名，
      # reload 时却照样被 include —— 这类文件只能靠 prune 清理。
      domshow="(no-server-name)"; n_bad=$((n_bad + 1)); note="bad-conf"
    else
      domshow="$dom"
      case "$typ" in *HTTPS*) n_https=$((n_https + 1)) ;; esac
      if [ "$root" != "-" ] && [ ! -d "$root" ]; then
        n_noroot=$((n_noroot + 1)); note="no-root"; mark="  [!] 目录不存在"
      fi
      # 隔离判定：fastcgi_pass 指向站点自己的 socket 才算隔离；仍指向全局 socket
      # 说明这个站点能读到同机其他站点的源码（存量站点常见）。
      if grep -q 'unix:' "$path" 2>/dev/null; then
        if grep -qF "unix:${PHP_FPM_SOCK}" "$path" 2>/dev/null; then iso="no"; else iso="yes"; n_iso=$((n_iso + 1)); fi
      elif grep -q 'application/x-httpd-php' "$path" 2>/dev/null; then
        iso="php"
      fi
    fi
    [ "$state" = "disabled" ] && n_dis=$((n_dis + 1))
    [ -z "$note" ] && note="ok"
    printf '  %-12s %-10s %-30s %-30s %-5s %-9s %s%s\n' "$typ" "$ports" "$domshow" "$root" "$iso" "$state" "$note" "$mark"
  done <<< "$rows"

  local n_orphan n_arch
  n_orphan=$(_vh_orphan_dirs | wc -l)
  n_arch=$(_vh_archive_count)
  echo
  printf '  共 %d 个站点：HTTPS %d 个，已禁用 %d 个，已隔离 %d 个\n' "$n" "$n_https" "$n_dis" "$n_iso"
  printf '  异常：坏配置 %d 个（解析不出域名），根目录缺失 %d 个；孤儿目录 %d 个；归档 %d 个\n' \
         "$n_bad" "$n_noroot" "$n_orphan" "$n_arch"
  if [ "$n_bad" -gt 0 ] || [ "$n_noroot" -gt 0 ] || [ "$n_orphan" -gt 0 ]; then
    printf '  %s\n' "$(_c '1;33' "→ 建议执行: $0 vhost prune    （先看清单，再加 --yes 清理）")"
  fi
  echo "  NOTE: ok / bad-conf=解析不出域名 / no-root=根目录不存在（站点实际已不可用）"
  echo "  隔离: yes=独立 php-fpm 池(仅能读本站根)  no=共用全局池(可读其他站点)  -/php=纯静态或 mod_php"
  echo "  类型: HTTP=仅 80/自定义端口   HTTPS=含 443 或配置了证书   HTTP+HTTPS=80 与 443 双栈"
  echo "  del <域名> [--purge]   del --file <配置文件>   disable/enable <域名>   prune [--yes]   rebind <域名>|--all"
  return 0
}

# ---------------------------------------------------------------------------
#  disable / enable
# ---------------------------------------------------------------------------
_vh_toggle() {
  local action="$1" domain="$2" ws path new any=0 rc=0
  [ -n "$domain" ] || die "vhost ${action}: 需要域名，例如 $0 vhost ${action} example.com"

  local hits; hits=$(_vh_find_by_domain "$domain" 1)
  if [ -z "$hits" ]; then
    log_err "vhost ${action}: 没有找到域名 ${domain} 的站点配置"
    echo "  现有站点：" >&2
    _vh_scan_all | cut -d'|' -f1,5 | sed 's/^/    /' >&2
    return 1
  fi

  while IFS='|' read -r ws path; do
    [ -n "$path" ] || continue
    case "$action" in
      disable)
        case "$path" in
          *.conf.disabled) log "  已禁用，跳过: $(basename "$path")"; continue ;;
        esac
        new="${path}.disabled" ;;
      enable)
        case "$path" in
          *.conf.disabled) new="${path%.disabled}" ;;
          *) log "  已是启用状态，跳过: $(basename "$path")"; continue ;;
        esac ;;
    esac

    if [ "${DRY_RUN:-0}" = 1 ]; then
      log "  [dry-run] 将把 $(basename "$path") 改为 $(basename "$new")"
      any=1; continue
    fi

    mv -f "$path" "$new" 2>/dev/null || { log_err "  改名失败: $path"; rc=1; continue; }
    _vh_cache_clear
    if _vh_reload_ws "$ws" "$(_vh_bin_for_ws "$ws")"; then
      log_ok "  ${action} 成功 (${ws}): $(basename "$new")"
      any=1
    else
      # 配置测试失败必须回滚：否则一个启停动作会让此后每次 reload 都失败
      mv -f "$new" "$path" 2>/dev/null
      _vh_cache_clear
      log_err "  配置测试未通过，已回滚: $(basename "$path")"
      rc=1
    fi
  done <<< "$hits"

  [ "$any" = 1 ] && return "$rc"
  return "$rc"
}

vhost_disable() { _vh_toggle disable "${1:-}"; }
vhost_enable()  { _vh_toggle enable  "${1:-}"; }

# ---------------------------------------------------------------------------
#  del
# ---------------------------------------------------------------------------
vhost_del() {
  local domain="" purge=0 yes=0 file="" a
  while [ $# -gt 0 ]; do
    case "$1" in
      --purge)  purge=1; shift ;;
      -y|--yes) yes=1; shift ;;
      --file)   file="${2:-}"; shift 2 ;;
      -h|--help)
        echo "用法: $0 vhost del <域名> [--purge] [--yes]"
        echo "      $0 vhost del --file <配置文件> [--yes]    删除解析不出域名的坏配置"
        echo "  删除站点配置（先归档到 $(_vh_archive_dir)）；--purge 连站点目录一起删"
        echo "  批量清理残留请用: $0 vhost prune"
        return 0 ;;
      -*) die "vhost del: 未知参数 $1" ;;
      *)  [ -z "$domain" ] && domain="$1" || die "vhost del: 多余的参数 $1"; shift ;;
    esac
  done

  local hits
  if [ -n "$file" ]; then
    # 按文件删：专门对付 server_name 都写坏、域名无从查起的那种配置
    [ -f "$file" ] || die "vhost del: 文件不存在: $file"
    local ws="" tws tdir _
    while IFS='|' read -r tws tdir _; do
      case "$file" in "$tdir"/*) ws="$tws" ;; esac
    done <<< "$(_vh_scan_targets)"
    [ -n "$ws" ] || die "vhost del: 拒绝删除 ${file}（不在任何 vhost 配置目录内）"
    hits="$ws|$file"
    domain="${file##*/}"
    purge=0     # 没有可信的 root 解析，--purge 不适用
  else
    [ -n "$domain" ] || die "vhost del: 需要域名，例如 $0 vhost del example.com（或 --file <配置文件>）"
    hits=$(_vh_find_by_domain "$domain" 1)
  fi
  if [ -z "$hits" ]; then
    log_err "vhost del: 没有找到域名 ${domain} 的站点配置"
    echo "  现有站点：" >&2
    _vh_scan_all | cut -d'|' -f1,5 | sed 's/^/    /' >&2
    return 1
  fi

  # 站点根目录（取第一个能解析到的，用于 --purge 提示）
  local root="" ws path line
  while IFS='|' read -r ws path; do
    [ -n "$path" ] || continue
    line=$(_vh_probe_file "$path" "$ws") || continue
    root=$(printf '%s' "$line" | cut -d'|' -f4)
    [ -n "$root" ] && [ "$root" != "-" ] && break
  done <<< "$hits"

  hr
  log "将删除站点: ${domain}"
  while IFS='|' read -r ws path; do
    [ -n "$path" ] && echo "  配置  ${path}"
  done <<< "$hits"
  [ "$purge" = 1 ] && echo "  目录  ${root:-（未能解析根目录）}   ← 会被删除"
  hr

  if [ "$yes" != 1 ]; then
    if [ "$purge" = 1 ]; then
      log_warn "--purge 会删除站点目录及其全部文件，且不可恢复"
    fi
    ask_yes_no "确认删除站点 ${domain}？" || { log "已取消"; return 1; }
  fi

  # --purge 的安全闸：只允许删 WWWROOT 之下的目录
  if [ "$purge" = 1 ]; then
    if [ -z "$root" ] || [ "$root" = "-" ]; then
      log_warn "解析不到站点根目录，跳过目录删除"
      purge=0
    else
      case "$root" in
        "${WWWROOT}"/*) : ;;
        *) die "vhost del: 拒绝删除 ${root}（不在 ${WWWROOT} 之下）。如确需删除，请手动处理" ;;
      esac
    fi
  fi

  if [ "${DRY_RUN:-0}" = 1 ]; then
    log "  [dry-run] 将归档配置并重载；purge=${purge}"
    return 0
  fi

  # 先把配置挪走并验证，成功后才删目录（顺序反了就没法回滚）
  local arch_ok=1 moved="" rc=0 archive
  archive=$(_vh_archive_dir)
  safe_mkdir "$archive" 2>/dev/null || arch_ok=0
  while IFS='|' read -r ws path; do
    [ -n "$path" ] || continue
    local dst
    if [ "$arch_ok" = 1 ]; then
      dst="${archive}/$(basename "$path").$(date +%Y%m%d_%H%M%S)"
      mv -f "$path" "$dst" 2>/dev/null || { log_err "归档失败: $path"; rc=1; continue; }
      _vh_cache_clear
      moved="$moved
$ws|$dst|$path"
      log "  已归档: $dst"
    else
      # 归档目录不可用时不硬删，改用 .deleted 后缀（同样不被 include 匹配）
      mv -f "$path" "${path}.deleted" 2>/dev/null || { log_err "删除失败: $path"; rc=1; continue; }
      _vh_cache_clear
      moved="$moved
$ws|${path}.deleted|$path"
      log_warn "  归档目录不可用，已改名为 $(basename "$path").deleted"
    fi
  done <<< "$hits"

  # 逐个 web server 验证；有一个失败就把全部改动撤回
  local verify_fail=0
  while IFS='|' read -r ws path; do
    [ -n "$ws" ] || continue
    _vh_reload_ws "$ws" "$(_vh_bin_for_ws "$ws")" || verify_fail=1
  done <<< "$hits"

  if [ "$verify_fail" = 1 ]; then
    while IFS='|' read -r ws src orig; do
      [ -n "$orig" ] && [ -f "$src" ] && mv -f "$src" "$orig" 2>/dev/null
    done <<< "$moved"
    log_err "配置测试未通过，已恢复全部配置"
    return 1
  fi

  # 配置已生效且验证通过，此时才删目录
  if [ "$purge" = 1 ] && [ -n "$root" ] && [ "$root" != "-" ] && [ -d "$root" ]; then
    if safe_rm_rf "$root"; then
      log_ok "已删除站点目录: ${root}"
    else
      log_warn "站点目录删除失败: ${root}（请手动处理）"
    fi
  fi

  # 站点池一并清理。留下的空池不会被 include 冲突（文件名带域名哈希），但会
  # 一直占着一个 socket + 一份 open_basedir 白名单，巡检时容易让人误判站点还在。
  if _php_pool_remove "$domain" 2>/dev/null; then
    log_ok "已清理站点池: $(_php_site_slug "$domain")"
  fi

  log_ok "站点 ${domain} 已删除（配置归档在 ${archive}）"
  [ "$rc" = 0 ] || log_warn "有部分配置删除失败，见上方 [ERR]"
  return "$rc"
}

# ===========================================================================
#  prune —— 清理配置目录里的"历史残留"
# ---------------------------------------------------------------------------
#  为什么需要它：del 只能按域名删，而残留恰恰是"域名已经不可知"的那一类。
#  真机上攒下来的通常有四种：
#    1) bad-conf   解析不出 server_name / ServerName 的配置（reload 照样 include）
#    2) no-root    配置还在，但站点目录早就被删了（访问 404/502，看着像"站点还在"）
#    3) disabled   长期 .conf.disabled 堆着（--disabled 才清，默认不动）
#    4) orphan-dir 目录还在，配置没了（--purge-dirs 才删，默认只报告）
#  默认**只报告不动手**，加 --yes 才执行；配置一律先归档，不硬删。
# ===========================================================================
vhost_prune() {
  local yes=0 purge_dirs=0 incl_disabled=0 keep=60

  while [ $# -gt 0 ]; do
    case "$1" in
      --yes|-y)            yes=1; shift ;;
      --purge-dirs|--dirs) purge_dirs=1; shift ;;
      --disabled|--all)    incl_disabled=1; shift ;;
      --archive-keep)      keep="${2:-60}"; shift 2 ;;
      -h|--help)
        echo "用法: $0 vhost prune [--yes] [--purge-dirs] [--disabled] [--archive-keep N]"
        echo "  默认只列出可清理项，不动任何文件。"
        echo "  --yes            真正执行（配置归档到 $(_vh_archive_dir)，不硬删）"
        echo "  --purge-dirs     连孤儿目录一起删除（仅限 $WWWROOT 之下）"
        echo "  --disabled       把 .conf.disabled 也算作残留（默认不动，避免误删临时停用的站点）"
        echo "  --archive-keep N 归档目录只保留最近 N 个（默认 60）"
        return 0 ;;
      -*) die "vhost prune: 未知参数 $1" ;;
      *)  die "vhost prune: 多余参数 $1" ;;
    esac
  done

  _vh_cache_clear
  local rows; rows=$(_vh_scan_all)
  local bad="" noroot="" dis="" dom typ ports root state ws path one
  while IFS='|' read -r dom typ ports root state ws path; do
    [ -n "$path" ] || continue
    if [ "$dom" = "!bad" ]; then
      one="$ws|$path|"; bad="$bad$one
"
    elif [ "$root" != "-" ] && [ ! -d "$root" ]; then
      one="$ws|$path|$root"; noroot="$noroot$one
"
    elif [ "$incl_disabled" = 1 ] && [ "$state" = "disabled" ]; then
      one="$ws|$path|$root"; dis="$dis$one
"
    fi
  done <<< "$rows"
  bad="${bad%$'\n'}"; noroot="${noroot%$'\n'}"; dis="${dis%$'\n'}"

  local orphans; orphans=$(_vh_orphan_dirs)
  local pools; pools=$(_php_pool_orphans)
  local n_bad=0 n_noroot=0 n_dis=0 n_orph=0 n_pool=0 n_arch
  [ -n "$bad" ]     && n_bad=$(printf '%s\n' "$bad" | wc -l)
  [ -n "$noroot" ]  && n_noroot=$(printf '%s\n' "$noroot" | wc -l)
  [ -n "$dis" ]     && n_dis=$(printf '%s\n' "$dis" | wc -l)
  [ -n "$orphans" ] && n_orph=$(printf '%s\n' "$orphans" | wc -l)
  [ -n "$pools" ]   && n_pool=$(printf '%s\n' "$pools" | wc -l)
  n_arch=$(_vh_archive_count)
  local n_conf=$((n_bad + n_noroot + n_dis))

  hr
  log "残留扫描 (prune): 配置目录 + ${WWWROOT}"
  hr
  if [ "$n_bad" -gt 0 ]; then
    echo "  坏配置 bad-conf (${n_bad}) —— 解析不出域名，但 reload 时仍被 include"
    printf '%s\n' "$bad" | while IFS='|' read -r w p _; do echo "    ${w}  ${p}"; done
  fi
  if [ "$n_noroot" -gt 0 ]; then
    echo "  根目录缺失 no-root (${n_noroot}) —— 站点实际已不可用"
    printf '%s\n' "$noroot" | while IFS='|' read -r w p r; do
      echo "    ${w}  ${p}"; echo "      root=${r} (不存在)"
    done
  fi
  if [ "$n_dis" -gt 0 ]; then
    echo "  已禁用 disabled (${n_dis})"
    printf '%s\n' "$dis" | while IFS='|' read -r w p _; do echo "    ${w}  ${p}"; done
  fi
  if [ "$n_orph" -gt 0 ]; then
    echo "  孤儿目录 orphan-dir (${n_orph}) —— 没有任何配置引用"
    printf '%s\n' "$orphans" | while read -r one; do
      echo "    ${one}  ($(du -sh "$one" 2>/dev/null | cut -f1))"
    done
    [ "$purge_dirs" = 1 ] || echo "    （仅报告；加 --purge-dirs 才会删除）"
  fi
  if [ "$n_pool" -gt 0 ]; then
    echo "  孤儿池 pool-orphan (${n_pool}) —— 站点已删或 chdir 目录不存在"
    printf '%s\n' "$pools" | while read -r one; do echo "    ${one}"; done
    echo "    ⚠ 这类池会让 php-fpm -t 失败（chdir 不存在），进而 reload/restart 全挂"
  fi
  [ "$n_arch" -gt "$keep" ] && echo "  归档超量: ${n_arch} 个 > 保留 ${keep} 个，执行时会删掉最旧的"

  if [ "$n_conf" -eq 0 ] && [ "$n_orph" -eq 0 ] && [ "$n_pool" -eq 0 ] && [ "$n_arch" -le "$keep" ]; then
    hr
    log_ok "没有发现残留，配置目录是干净的"
    hr
    return 0
  fi
  hr

  if [ "$yes" != 1 ]; then
    log "以上仅为清单。确认执行: $0 vhost prune --yes $([ "$purge_dirs" = 1 ] && echo '--purge-dirs')"
    log "（配置会归档到 $(_vh_archive_dir)，不会硬删）"
    return 0
  fi
  if [ "${DRY_RUN:-0}" = 1 ]; then
    log "  [dry-run] 将归档 ${n_conf} 个配置；孤儿目录 ${n_orph} 个（purge_dirs=${purge_dirs}）；归档瘦身 ${n_arch}→${keep}"
    return 0
  fi

  # ---- 1) 归档残留配置（先不 reload：等池也清干净再一起验）----
  local archive moved="" pool_moved="" rc=0 w ts
  archive=$(_vh_archive_dir)
  ts=$(date +%Y%m%d_%H%M%S)
  safe_mkdir "$archive" 2>/dev/null || die "无法创建归档目录 ${archive}"
  if [ "$n_conf" -gt 0 ]; then
    # 用 here-string 而不是管道：管道里的 while 跑在子 shell，moved 传不出来，
    # 后面的 reload 就不知道该刷新哪个 web server（配置删了却没生效）。
    local grp dst
    for grp in "$bad" "$noroot" "$dis"; do
      [ -n "$grp" ] || continue
      while IFS='|' read -r w p r; do
        [ -n "$p" ] && [ -f "$p" ] || continue
        dst="${archive}/$(basename "$p").${ts}"
        if mv -f "$p" "$dst" 2>/dev/null; then
          moved="$moved$w|$dst|$p
"
          log "  已归档: $(basename "$p")"
        else
          log_err "  归档失败: $p"
          rc=1
        fi
      done <<< "$grp"
    done
    _vh_cache_clear
    log_ok "已归档 ${n_conf} 个残留配置"
  fi

  # ---- 2) 孤儿池必须在 reload 之前清掉 ----
  # 池的 chdir 指向已删目录时 `php-fpm -t` 直接失败，reload/restart 全挂——
  # 也就是说"清一个站点"会顺手把整机 PHP 弄停。所以先归档池，再 reload。
  if [ "$n_pool" -gt 0 ]; then
    pool_moved=$(_vh_pool_archive_orphans "$archive" "$ts" "$pools")
    log_ok "已归档 ${n_pool} 个孤儿池"
  fi

  # ---- 3) 孤儿目录（只在显式 --purge-dirs 时删，且必须在 WWWROOT 之下）----
  if [ "$purge_dirs" = 1 ] && [ -n "$orphans" ]; then
    while IFS= read -r one; do
      [ -d "$one" ] || continue
      case "$one" in
        # 同时接受 / 与 \ 分隔：产品只跑 Linux，但测试环境（Git Bash）会给
        # C://...//www//xxx 这种路径，只匹配 "/" 会让安全闸把孤儿目录全跳过。
        "${WWWROOT}"/*|"${WWWROOT}"\\*) : ;;
        *) log_warn "  跳过 ${one}（不在 ${WWWROOT} 之下）"; continue ;;
      esac
      if safe_rm_rf "$one"; then log_ok "  已删除目录: ${one}"; else log_warn "  删除失败: ${one}"; fi
    done <<< "$orphans"
  fi

  # ---- 4) 删完目录再扫一遍：chdir 指向刚删目录的池，现在才暴露出来 ----
  local pools2 pools2_n=0
  pools2=$(_php_pool_orphans)
  if [ -n "$pools2" ]; then
    pools2_n=$(printf '%s\n' "$pools2" | wc -l)
    pool_moved="$pool_moved
$(_vh_pool_archive_orphans "$archive" "$ts" "$pools2")"
    log_ok "已归档删目录后失效的池 ${pools2_n} 个"
  fi

  # ---- 5) 统一 reload + 校验（失败把配置和池一起撤回）----
  local wss verify_fail=0
  wss=$(printf '%s\n' "$moved" | cut -d'|' -f1 | sort -u)
  for w in $wss; do
    [ -n "$w" ] || continue
    _vh_reload_ws "$w" "$(_vh_bin_for_ws "$w")" || verify_fail=1
  done
  if [ "$n_pool" -gt 0 ] || [ "$pools2_n" -gt 0 ]; then
    local fpmbin="${PREFIX_PHP}/sbin/php-fpm" pidf fpm_pid=""
    if [ -x "$fpmbin" ]; then
      if "$fpmbin" -t >/dev/null 2>&1; then
        for pidf in "${PREFIX_PHP}/var/run/php-fpm.pid" /run/php-fpm/php-fpm.pid /var/run/php-fpm.pid; do
          [ -f "$pidf" ] && { fpm_pid=$(cat "$pidf" 2>/dev/null); break; }
        done
        if [ -n "$fpm_pid" ] && kill -USR2 "$fpm_pid" 2>/dev/null; then
          log_ok "php-fpm 已平滑重载"
        elif systemctl reload php-fpm >/dev/null 2>&1 || systemctl restart php-fpm >/dev/null 2>&1; then
          log_ok "php-fpm 已重载"
        else
          log_warn "php-fpm 未能重载，请手工检查"
        fi
      else
        log_err "php-fpm -t 仍未通过（还有残留池？）"
        verify_fail=1
      fi
    fi
  fi

  if [ "$verify_fail" = 1 ]; then
    printf '%s\n' "$moved" | while IFS='|' read -r _ src orig; do
      [ -n "$orig" ] && [ -f "$src" ] && mv -f "$src" "$orig" 2>/dev/null
    done
    printf '%s\n' "$pool_moved" | grep '^POOL|' | cut -d'|' -f2 | while read -r src; do
      [ -n "$src" ] && [ -f "${archive}/$(basename "$src").${ts}" ] && \
        mv -f "${archive}/$(basename "$src").${ts}" "$src" 2>/dev/null
    done
    _vh_cache_clear
    log_err "配置测试未通过，已恢复全部配置与池（本次未删除任何东西）"
    return 1
  fi

  # ---- 3) 归档瘦身：只留最近 keep 个 ----
  local total; total=$(_vh_archive_count)
  if [ "$total" -gt "$keep" ]; then
    local del_n=$((total - keep))
    ls -1t "$archive" 2>/dev/null | tail -n "$del_n" | while read -r one; do
      [ -n "$one" ] && rm -f "${archive}/${one}"
    done
    log_ok "  归档瘦身: 删除最旧的 ${del_n} 个（保留 ${keep} 个）"
  fi

  log_ok "清理完成。归档位置: ${archive}"
  return "$rc"
}

# ===========================================================================
#  站点隔离：vhost rebind <域名> | --all
# ---------------------------------------------------------------------------
#  存量站点是在"没有 per-site 池"的年代建的，fastcgi_pass 指向全局 socket，
#  升级安装器不会自动改它们（改配置有风险，且可能正跑着业务）。这个子命令
#  负责给它们补建独立池并切过去，或者用 --shared 退回去。
#
#  为什么不让 create_vhost 以外的路径自动改：改 fastcgi_pass 等于换 PHP 进程，
#  一旦新池起不来就是整站 500。所以做成显式命令，改前备份、改后 -t、失败回滚。
# ===========================================================================

_vh_rebind_one() {
  local domain="$1" shared="$2" ws path line ports root old_sock new_sock bak
  local hits; hits=$(_vh_find_by_domain "$domain" 0)
  if [ -z "$hits" ]; then log_err "  没有找到已启用的站点: ${domain}"; return 1; fi
  ws=$(printf '%s' "$hits" | head -1 | cut -d'|' -f1)
  path=$(printf '%s' "$hits" | head -1 | cut -d'|' -f2)

  line=$(_vh_probe_file "$path" "$ws") || { log_err "  解析失败: ${path}"; return 1; }
  ports=$(printf '%s' "$line" | cut -d'|' -f3)
  root=$(printf '%s' "$line" | cut -d'|' -f4)
  if [ -z "$root" ] || [ "$root" = "-" ]; then
    log_err "  解析不到站点根目录，无法确定 open_basedir 范围: ${domain}"; return 1
  fi

  if ! grep -q 'unix:' "$path" 2>/dev/null; then
    if grep -q 'application/x-httpd-php' "$path" 2>/dev/null; then
      log "  mod_php 站点（open_basedir 已写在 VirtualHost 里），跳过: ${domain}"
    else
      log "  该站点未使用 php-fpm，跳过: ${domain}"
    fi
    return 0
  fi

  old_sock=$(grep -o 'unix:[^;"|]*' "$path" 2>/dev/null | head -1 | sed 's/^unix://')
  if [ "$shared" = 1 ]; then
    new_sock="$PHP_FPM_SOCK"
  else
    _php_pool_ensure "$domain" "$root" "${LNAMP_OPEN_BASEDIR_EXTRA:-}" || return 1
    new_sock="$_PHP_SITE_SOCK"
  fi
  [ -n "$new_sock" ] || { log_err "  池创建失败: ${domain}"; return 1; }

  if [ "$old_sock" = "$new_sock" ]; then
    log "  已指向 $(basename "$new_sock")，无需改动: ${domain}"
    [ "$shared" = 1 ] && _php_pool_remove "$domain" 2>/dev/null
    return 0
  fi

  log "  ${domain}: $(basename "${old_sock:-?}") -> $(basename "$new_sock")  (根 ${root}，端口 ${ports})"
  if [ "${DRY_RUN:-0}" = 1 ]; then
    log "  [dry-run] 将改写 ${path} 的 socket"
    [ "$shared" = 1 ] && log "  [dry-run] 将删除该站点池"
    return 0
  fi

  bak="$(_vh_archive_dir)/$(basename "$path").$(date +%Y%m%d_%H%M%S)"
  safe_mkdir "$(_vh_archive_dir)" 2>/dev/null || true
  cp -f "$path" "$bak" 2>/dev/null || bak=""
  sed -i "s#unix:[^;\"|]*#unix:${new_sock}#g" "$path"
  _vh_cache_clear

  if _vh_reload_ws "$ws" "$(_vh_bin_for_ws "$ws")"; then
    [ "$shared" = 1 ] && _php_pool_remove "$domain" 2>/dev/null
    log_ok "  已生效: ${domain} -> $(basename "$new_sock")"
    return 0
  fi
  if [ -n "$bak" ] && [ -f "$bak" ]; then mv -f "$bak" "$path"; else log_err "  备份不可用，请手动检查 ${path}"; fi
  _vh_cache_clear
  log_err "  配置测试未通过，已回滚: ${domain}"
  return 1
}

vhost_rebind() {
  local domain="" all=0 shared=0 i=0 ok=0 bad=0 doms d
  while [ $# -gt 0 ]; do
    case "$1" in
      --all)    all=1; shift ;;
      --shared) shared=1; shift ;;
      -h|--help)
        echo "用法: $0 vhost rebind <域名> [--shared]"
        echo "      $0 vhost rebind --all [--shared]"
        echo "  给站点建独立 php-fpm 池并切换 socket（按站点 open_basedir 隔离）"
        echo "  --shared  退回全局池（关闭该站点的隔离）"
        echo "  --all     处理全部已启用站点"
        return 0 ;;
      -*) die "vhost rebind: 未知参数 $1"; shift ;;
      *)  [ -z "$domain" ] && domain="$1" || die "vhost rebind: 多余的参数 $1"; shift ;;
    esac
  done
  [ "$all" = 1 ] || [ -n "$domain" ] || {
    echo "用法: $0 vhost rebind <域名>|--all [--shared]" >&2; return 1; }

  if [ "$all" = 1 ]; then
    doms=$(_vh_scan_all | awk -F'|' '$5=="enabled" { split($1, a, " "); print a[1] }' | sort -u)
    [ -n "$doms" ] || { log "没有已启用的站点"; return 0; }
    # 批量时把所有池写完再统一 reload 一次 php-fpm
    [ "$shared" = 1 ] || export LNAMP_POOL_DEFER_RELOAD=1
    hr
    log "批量重绑 php-fpm 池（$(printf '%s\n' "$doms" | wc -l | tr -d ' ') 个站点，shared=${shared}）"
    while IFS= read -r d; do
      [ -n "$d" ] || continue
      if _vh_rebind_one "$d" "$shared"; then i=$((i + 1)); else bad=$((bad + 1)); fi
    done <<< "$doms"
    if [ "$shared" != 1 ] && [ "$i" -gt 0 ]; then
      if _php_fpm_test; then
        _php_fpm_reload && log_ok "php-fpm 已 reload，新池全部生效" || log_warn "reload php-fpm 失败"
      else
        log_err "php-fpm 配置测试失败: $(printf '%s' "$_PHP_FPM_ERR" | tail -2 | tr '\n' ' ')"
      fi
    fi
    unset LNAMP_POOL_DEFER_RELOAD
    hr
    log "完成: 成功 ${i}，失败 ${bad}"
    [ "$bad" = 0 ] && return 0 || return 1
  fi

  hr
  log "重绑站点池: ${domain}（shared=${shared}）"
  _vh_rebind_one "$domain" "$shared"
}


# ===========================================================================
#  一键 TLS：vhost ssl <域名>
# ---------------------------------------------------------------------------
#  目标：把已有的 80 站点变成 HTTPS（80+443 双栈），并且**不引入任何证书申请工具**。
#  证书来源优先级：
#    1) 显式 --cert/--key
#    2) 自动探测已有证书：certbot(/etc/letsencrypt/live/<d>) 或 acme.sh(~/.acme.sh/<d>)
#    3) --self-signed  自签（内网/测试；浏览器会告警）
#  没有证书时直接报错，并打印获取证书的命令示例 —— 装不装 acme.sh 由用户决定。
#
#  所有改动照旧走"临时文件 -> 备份 -> 原子替换 -> nginx -t -> 失败回滚"，
#  一个证书配错不该让整台机器的 Web 服务 reload 不进去。
# ===========================================================================

_VH_SSL_DEFAULT_HSTS=31536000

# 校验证书与私钥是同一对（RSA 用 modulus、ECDSA 没有 modulus，统一取公钥比对）
_vh_ssl_pair_ok() {
  local cert="$1" key="$2" a b
  command -v openssl >/dev/null 2>&1 || return 0    # 没 openssl 就跳过校验，不阻断
  a=$(openssl x509 -in "$cert" -noout -pubkey 2>/dev/null | openssl md5 2>/dev/null)
  b=$(openssl pkey -in "$key"  -pubout      2>/dev/null | openssl md5 2>/dev/null)
  [ -n "$a" ] && [ "$a" = "$b" ]
}

# 证书是否覆盖该域名（通配符由 openssl -checkhost 处理）
_vh_ssl_host_ok() {
  local cert="$1" domain="$2"
  command -v openssl >/dev/null 2>&1 || return 0
  openssl x509 -in "$cert" -noout -checkhost "$domain" 2>/dev/null | grep -q 'does match'
}

# 自动探测常见位置的既有证书 -> "cert|key"
_vh_ssl_guess() {
  local d="$1" p
  for p in "/etc/letsencrypt/live/${d}" "/root/.acme.sh/${d}_ecc" "/root/.acme.sh/${d}"; do
    if [ -f "$p/fullchain.pem" ] && [ -f "$p/privkey.pem" ]; then
      printf '%s|%s\n' "$p/fullchain.pem" "$p/privkey.pem"; return 0
    fi
    if [ -f "$p/fullchain.cer" ] && [ -f "${p}/${d}.key" ]; then
      printf '%s|%s\n' "$p/fullchain.cer" "${p}/${d}.key"; return 0
    fi
  done
  return 1
}

# 自签证书（10 年，带 SAN）
_vh_ssl_selfsign() {
  local domain="$1" dir="$2" cert="$3" key="$4"
  safe_mkdir "$dir" || return 1
  openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
    -subj "/CN=${domain}" -addext "subjectAltName=DNS:${domain}" \
    -keyout "$key" -out "$cert" >/dev/null 2>&1 || return 1
  chmod 600 "$key" 2>/dev/null || true
  chmod 644 "$cert" 2>/dev/null || true
  return 0
}

# 把原 server 块改造成 443 块：listen -> 443 ssl，server_name 后插入证书与套件参数
_vh_ssl_render_443() {
  local src="$1" cert="$2" key="$3" port="$4" hsts="$5"
  awk -v cert="$cert" -v key="$key" -v port="$port" -v hsts="$hsts" '
    BEGIN { ldone = 0; sdone = 0 }
    /^[ \t]*listen[ \t]/ {
      if (!ldone) { print "    listen       " port " ssl;"; ldone = 1 }
      next                                   # 其它 listen 行一律丢弃，避免重复监听
    }
    /^[ \t]*server_name[ \t]/ {
      print
      if (!sdone) {
        print "    ssl_certificate      " cert ";"
        print "    ssl_certificate_key  " key ";"
        print "    ssl_protocols        TLSv1.2 TLSv1.3;"
        print "    ssl_ciphers          HIGH:!aNULL:!MD5:!3DES;"
        print "    ssl_prefer_server_ciphers on;"
        print "    ssl_session_cache    shared:lnamp_ssl:10m;"
        print "    ssl_session_timeout  10m;"
        if (hsts != "") print "    add_header Strict-Transport-Security \"max-age=" hsts "\" always;"
        sdone = 1
      }
      next
    }
    { print }
  ' "$src"
}

# 80 端口跳转块
_vh_ssl_render_redirect() {
  local domain="$1" port="$2"
  cat <<EOF
server {
    listen       ${port};
    server_name  ${domain};
    return 301 https://\$host\$request_uri;
}
EOF
}

vhost_ssl_help() {
  cat <<EOF
用法: $0 vhost ssl <域名> [选项]

把已有的站点升级为 HTTPS（80+443 双栈）。本命令**不申请证书**，
只负责把 443 配置好、跳转配好、并验证通过。

证书来源（按优先级）:
  --cert <文件> --key <文件>   使用已有证书（fullchain + 私钥）
  （不加证书参数）             自动探测 certbot / acme.sh 已签发的证书
  --self-signed                生成自签证书（内网/测试，浏览器会告警）

其它选项:
  --port <端口>      HTTPS 端口，默认 443
  --no-redirect      保留 80 直接服务（默认把 80 全部 301 到 https）
  --hsts [秒数]      下发 HSTS 头，默认 31536000（一年）。慎用：一旦下发，
                     浏览器在有效期内不再允许降级到 http
  --force            站点已启用 HTTPS 时，重建 443 配置（证书续期后用）

没有证书时，可先用这些命令获取（本工具不代为安装）:
  certbot:  certbot certonly --webroot -w <站点根> -d <域名>
            （证书在 /etc/letsencrypt/live/<域名>/）
  acme.sh:  curl https://get.acme.sh | sh -s email=you@example.com
            ~/.acme.sh/acme.sh --issue -d <域名> -w <站点根>
            （证书在 ~/.acme.sh/<域名>/）
  拿到后直接:  $0 vhost ssl <域名> --cert <fullchain> --key <privkey>
  或放回默认位置后直接跑:  $0 vhost ssl <域名>
EOF
}

vhost_ssl() {
  local domain="" cert="" key="" self_signed=0 port=443 redirect=1 hsts="" force=0 a
  while [ $# -gt 0 ]; do
    case "$1" in
      --cert)  cert="${2:-}"; shift 2 ;;
      --cert=*) cert="${1#*=}"; shift ;;
      --key)   key="${2:-}";  shift 2 ;;
      --key=*) key="${1#*=}";  shift ;;
      --self-signed) self_signed=1; shift ;;
      --port)  port="${2:-}"; shift 2 ;;
      --port=*) port="${1#*=}"; shift ;;
      --no-redirect) redirect=0; shift ;;
      --redirect)    redirect=1; shift ;;
      --hsts)
        if [ -n "${2:-}" ] && [ "${2#-}" = "$2" ]; then hsts="$2"; shift 2; else hsts="$_VH_SSL_DEFAULT_HSTS"; shift; fi ;;
      --hsts=*) hsts="${1#*=}"; shift ;;
      --force) force=1; shift ;;
      -h|--help) vhost_ssl_help; return 0 ;;
      -*) die "vhost ssl: 未知参数 $1（见 --help）" ;;
      *)  [ -z "$domain" ] && domain="$1" || die "vhost ssl: 多余的参数 $1"; shift ;;
    esac
  done
  [ -n "$domain" ] || { vhost_ssl_help; return 1; }
  case "$port" in ''|*[!0-9]*) die "vhost ssl: --port 必须是数字" ;; esac
  case "$hsts" in ''|*[!0-9]*) [ -n "$hsts" ] && die "vhost ssl: --hsts 需要秒数（数字）" ;; esac

  # 1) 定位站点配置（必须是已启用的）
  local hits; hits=$(_vh_find_by_domain "$domain" 0)
  if [ -z "$hits" ]; then
    log_err "vhost ssl: 没有找到已启用的站点 ${domain}"
    echo "  先创建: $0 vhost ${domain} 80 ${WWWROOT}/${domain}" >&2
    return 1
  fi
  local ws path n=0
  while IFS='|' read -r ws path; do
    [ -n "$path" ] && n=$((n + 1))
  done <<< "$hits"
  if [ "$n" -gt 1 ]; then
    log_warn "该域名有 ${n} 份配置（nginx/apache 各一？），本命令只处理第一份"
  fi
  ws=$(printf '%s' "$hits" | head -1 | cut -d'|' -f1)
  path=$(printf '%s' "$hits" | head -1 | cut -d'|' -f2)

  case "$ws" in
    nginx) : ;;
    apache) die "vhost ssl: 目前只支持 nginx/freenginx 的站点（当前站点属于 apache）。
      Apache 请手动加 <VirtualHost *:${port}> + SSLEngine on 段，或先用 vhost del 后改用 nginx 建站" ;;
  esac

  # 2) 已有 443？
  local line; line=$(_vh_probe_file "$path" "$ws")
  local typ ports root
  typ=$(printf '%s' "$line" | cut -d'|' -f2)
  ports=$(printf '%s' "$line" | cut -d'|' -f3)
  root=$(printf '%s' "$line" | cut -d'|' -f4)
  local already_https=0
  case "$typ" in *HTTPS*) already_https=1 ;; esac
  if [ "$already_https" = 1 ] && [ "$force" != 1 ]; then
    log "站点 ${domain} 已启用 HTTPS（类型 ${typ}，端口 ${ports}）"
    log "  续期后要更新证书路径: $0 vhost ssl ${domain} --force --cert <新证书> --key <新私钥>"
    return 0
  fi

  # 3) 确定证书
  local certdir="${PREFIX_NGINX}/conf/ssl"
  if [ "$self_signed" = 1 ]; then
    cert="${certdir}/${domain}.crt"; key="${certdir}/${domain}.key"
    log "生成自签证书（10 年，SAN=${domain}）…"
    _vh_ssl_selfsign "$domain" "$certdir" "$cert" "$key" || die "vhost ssl: 自签证书生成失败（openssl 不可用？）"
    log_ok "自签证书: ${cert}"
    log_warn "自签证书浏览器会告警；对外站点请换成受信任证书"
  elif [ -z "$cert" ] || [ -z "$key" ]; then
    local g; g=$(_vh_ssl_guess "$domain")
    if [ -n "$g" ]; then
      cert=${g%%|*}; key=${g#*|}
      log "自动找到已有证书: ${cert}"
    else
      log_err "vhost ssl: 没有找到 ${domain} 的证书"
      echo "  三种做法：" >&2
      echo "    1) 用已有证书:  $0 vhost ssl ${domain} --cert <fullchain.pem> --key <privkey.pem>" >&2
      echo "    2) 先生成自签:  $0 vhost ssl ${domain} --self-signed   （内网/测试）" >&2
      echo "    3) 先申请证书再把文件放回默认位置：" >&2
      echo "       certbot certonly --webroot -w ${root} -d ${domain}    -> /etc/letsencrypt/live/${domain}/" >&2
      echo "       ~/.acme.sh/acme.sh --issue -d ${domain} -w ${root}    -> ~/.acme.sh/${domain}/" >&2
      echo "       然后重跑本命令即可自动识别" >&2
      return 1
    fi
  fi
  [ -f "$cert" ] || die "vhost ssl: 证书文件不存在: ${cert}"
  [ -f "$key" ]  || die "vhost ssl: 私钥文件不存在: ${key}"
  _vh_ssl_pair_ok "$cert" "$key" || die "vhost ssl: 证书与私钥不匹配（确认 --cert 是 fullchain、--key 是对应私钥）"
  if ! _vh_ssl_host_ok "$cert" "$domain"; then
    log_warn "证书看起来不包含域名 ${domain}（通配符或 SAN 不含它？）—— 浏览器会报证书错误"
  fi

  # 3.5) 已启用 HTTPS + --force：**只更新证书路径**，不重新渲染结构。
  # 原因：这时文件里是 "80跳转块 + 443块" 两段，若再走一遍 render_443，
  # 它会把第一个 listen(80) 也改成 443 —— 于是 443 上变成 `return 301 https://...`，
  # 等于自己跳自己（实测 --force 后自检返回 301）。续期本来就只需换证书路径。
  if [ "$already_https" = 1 ]; then
    local nb0; nb0=$(_vh_bin_for_ws nginx)
    local bak0="${_vh_archive_dir}/$(basename "$path").$(date +%Y%m%d_%H%M%S)"
    safe_mkdir "$(_vh_archive_dir)" 2>/dev/null || true
    cp -f "$path" "$bak0" 2>/dev/null || bak0=""
    sed -i "s@^\([[:space:]]*ssl_certificate[[:space:]]\+\).*@\1${cert};@"     "$path"
    sed -i "s@^\([[:space:]]*ssl_certificate_key[[:space:]]\+\).*@\1${key};@" "$path"
    local tout0
    if tout0=$("${PREFIX_NGINX}/sbin/nginx" -t 2>&1 || "$nb0" -t 2>&1); then
      systemctl reload nginx 2>/dev/null || "$nb0" -s reload 2>/dev/null || true
      sleep 0.3
      _vh_cache_clear
      log_ok "已更新证书路径（结构未改动）: ${cert}"
      echo "  站点: https://${domain}/"
      echo "  提示: 若要改 HTTPS 端口/跳转/HSTS 等结构，请 vhost del 后重建"
      return 0
    fi
    [ -n "$bak0" ] && [ -f "$bak0" ] && mv -f "$bak0" "$path"
    _vh_cache_clear
    die "vhost ssl: 更新证书后 nginx 配置测试失败（已回滚）: $(printf '%s' "$tout0" | tail -2 | tr '\n' ' ')"
  fi

  # 4) 生成新配置：443 块 + （可选）80 跳转块
  local vhdir; vhdir=$(dirname "$path")
  local tmp="${path}.ssl.new"
  local hport="${ports%%,*}"; [ -n "$hport" ] || hport=80
  [ "$hport" = "443" ] && hport=80

  if [ "${DRY_RUN:-0}" = 1 ]; then
    log "  [dry-run] 将把 ${path} 改为 443(ssl) + ${hport}$([ "$redirect" = 1 ] && echo ' 跳转')，证书 ${cert}"
    return 0
  fi

  {
    echo "# 由 lnamp vhost ssl 生成 $(date '+%F %T')"
    if [ "$redirect" = 1 ]; then
      echo "# ---- ${hport} -> https 跳转 ----"
      _vh_ssl_render_redirect "$domain" "$hport"
      echo ""
    else
      # --no-redirect：80 的原配置必须**原样保留**再追加 443 块。
      # （早期版本这里只写了 443 块，等于把原来的 80 站点整段删掉——HTTP 直接不可用。）
      echo "# ---- ${hport} (HTTP，保留原配置) ----"
      cat "$path"
      echo ""
    fi
    echo "# ---- ${port} (TLS) ----"
    _vh_ssl_render_443 "$path" "$cert" "$key" "$port" "$hsts"
  } > "$tmp"

  # 5) 备份 + 原子替换 + 测试 + 回滚（与 create_vhost 同一套）
  local archive; archive=$(_vh_archive_dir)
  safe_mkdir "$archive" 2>/dev/null || true
  local bak="${archive}/$(basename "$path").$(date +%Y%m%d_%H%M%S)"
  cp -f "$path" "$bak" 2>/dev/null || bak=""
  mv -f "$tmp" "$path"

  local nb; nb=$(_vh_bin_for_ws nginx)
  local tout
  if tout=$("${PREFIX_NGINX}/sbin/nginx" -t 2>&1 || "$nb" -t 2>&1); then
    systemctl reload nginx 2>/dev/null || "$nb" -s reload 2>/dev/null || true
    sleep 0.3
  else
    if [ -n "$bak" ] && [ -f "$bak" ]; then mv -f "$bak" "$path"; else rm -f "$path"; fi
    _vh_cache_clear
    die "vhost ssl: nginx 配置测试未通过（已回滚）。输出: $(printf '%s' "$tout" | tail -2 | tr '\n' ' ')"
  fi
  _vh_cache_clear

  log_ok "已启用 HTTPS: https://${domain}$([ "$port" != 443 ] && echo ":${port}")/"
  echo "  证书   : ${cert}"
  echo "  私钥   : ${key}"
  [ "$redirect" = 1 ] && echo "  跳转   : ${hport} -> https（301）" || echo "  跳转   : 无（80 仍直接服务）"
  if [ -n "$hsts" ]; then
    echo "  HSTS   : max-age=${hsts}（注意：有效期内浏览器不再允许降级到 http）"
  fi

  # 6) 自检：本机发一个 HTTPS 请求
  if command -v curl >/dev/null 2>&1; then
    local code; code=$(curl -sk --max-time 8 -o /dev/null -w '%{http_code}' -H "Host: ${domain}" "https://127.0.0.1:${port}/" 2>/dev/null)
    case "$code" in
      2??|3??) log_ok "本机 HTTPS 自检: ${code}" ;;
      ""|000)  log_warn "本机 HTTPS 自检无响应（端口 ${port} 未监听？防火墙？）" ;;
      *)       log_warn "本机 HTTPS 自检返回 ${code}（证书本身没问题，检查站点根目录/权限）" ;;
    esac
  fi

  echo
  echo "后续："
  echo "  · 云安全组/防火墙放行 ${port}: firewall-cmd --add-service=https --permanent && firewall-cmd --reload"
  echo "  · 证书到期前续期，拿到新文件后重跑: $0 vhost ssl ${domain} --force --cert <新fullchain> --key <新私钥>"
  echo "  · 查看状态: $0 vhost list（类型会显示 HTTPS / HTTP+HTTPS）"
  return 0
}

# ---------------------------------------------------------------------------
# ---------------------------------------------------------------------------
#  probe：临时 phpinfo 探针（仅用于部署验证，验证后必须删除）
#
#  建站不再默认生成 phpinfo 首页，但"PHP 到底通不通"总得有办法看一眼，
#  所以单独给一个**临时**探针，并且从机制上逼着它被删掉：
#    · 文件名随机后缀（扫不到常见的 /phpinfo.php、/i.php）
#    · 权限 0640 www:www（同机其他用户读不到）
#    · 记录进状态文件，$0 vhost probe --list 可查、--rm 一把删净
#    · systemd 机器上用 systemd-run 定时自毁（默认 15 分钟，防忘删）
#    · doctor 会把"站点目录里残留 phpinfo / probe 文件"当成安全项报出来
#  用法:
#    $0 vhost probe <域名>            放一个探针并打印 URL
#    $0 vhost probe --list            列出还没删的探针
#    $0 vhost probe --rm [域名]       删除探针（不给域名=全部）
# ---------------------------------------------------------------------------
LNAMP_PROBE_STATE="${LNAMP_PROBE_STATE:-/root/.lnamp_probes}"

# 站点根目录（优先按 vhost 配置扫描，找不到才回落到 WWWROOT/<域名>）
_vh_webroot_of() {
  local d="$1" root
  root=$(_vh_scan_all 2>/dev/null | awk -F'|' -v D="$d" '
    $1 ~ ("(^| )" D "( |$)") && $4 != "-" { print $4; exit }')
  if [ -n "$root" ]; then printf '%s' "$root"; else printf '%s' "${WWWROOT}/${d}"; fi
}

# 站点端口（vhost 配置可能是 "80,443" 双栈，取第一个）
_vh_port_of() {
  local d="$1" p
  p=$(_vh_scan_all 2>/dev/null | awk -F'|' -v D="$d" '
    $1 ~ ("(^| )" D "( |$)") && $3 != "" { print $3; exit }')
  printf '%s' "${p%%,*}"
}

_vh_probe_state_add() {   # <文件> <ttl分钟>
  local f="$1" ttl="${2:-0}"
  safe_mkdir "$(dirname "$LNAMP_PROBE_STATE")" 2>/dev/null
  printf '%s|%s|%s\n' "$f" "$(date +%s)" "$ttl" >> "$LNAMP_PROBE_STATE" 2>/dev/null
  chmod 600 "$LNAMP_PROBE_STATE" 2>/dev/null
}

# 只输出仍然存在的探针路径（顺带把已删记录从状态文件里清掉）
_vh_probe_state_list() {
  [ -f "$LNAMP_PROBE_STATE" ] || return 0
  local f keep=""
  while IFS='|' read -r f _rest; do
    [ -n "$f" ] || continue
    if [ -f "$f" ]; then printf '%s\n' "$f"; else continue; fi
  done < "$LNAMP_PROBE_STATE"
  # 重写状态文件：丢掉已不存在的记录
  while IFS='|' read -r f ts ttl; do
    [ -n "$f" ] && [ -f "$f" ] && keep="${keep}${f}|${ts}|${ttl}
"
  done < "$LNAMP_PROBE_STATE"
  printf '%s' "$keep" > "$LNAMP_PROBE_STATE" 2>/dev/null
}

vhost_probe() {
  local arg="${1:-}"
  case "$arg" in
    ''|-h|--help)   _vhost_probe_usage; return 0 ;;
    --list|list|ls) _vhost_probe_list;  return 0 ;;
    --rm|-r|rm|remove|del|clean) shift; _vhost_probe_rm "${1:-}"; return $? ;;
    --*)            die "vhost probe: 未知参数 ${arg}（--list 查看、--rm 删除）" ;;
  esac
  local domain="$1" ttl="${LNAMP_PROBE_TTL_MIN:-15}"
  case "$ttl" in ''|*[!0-9]*) ttl=0 ;; esac

  local webroot port rand file
  webroot=$(_vh_webroot_of "$domain")
  [ -d "$webroot" ] || die "vhost probe: 站点根目录不存在: ${webroot}（先建站，或确认域名已配置）"
  if ! _php_fpm_available && ! _php_modphp_available; then
    log_warn "未检测到 php-fpm / mod_php：探针页面可能被当源码下载或返回 502"
  fi
  rand=$(tr -dc 'a-z0-9' </dev/urandom 2>/dev/null | head -c 8)
  [ -n "$rand" ] || rand=$(date +%s | tail -c 9)
  file="${webroot}/__lnamp_probe_${rand}.php"
  printf '<?php phpinfo();\n' > "$file" || die "vhost probe: 写入失败: ${file}"
  chown www:www "$file" 2>/dev/null || true
  chmod 0640 "$file" 2>/dev/null || true
  port=$(_vh_port_of "$domain"); [ -n "$port" ] || port=80
  _vh_probe_state_add "$file" "$ttl"

  # 兜底自毁：忘了删也不会长期挂着。只在真 systemd 上做，容器里跳过。
  if [ "$ttl" -gt 0 ] 2>/dev/null && [ -d /run/systemd/system ] \
     && command -v systemd-run >/dev/null 2>&1; then
    if systemd-run --on-active="${ttl}min" --unit="lnamp-probe-clean-${rand}" \
         --description="LNAMP: remove phpinfo probe" /bin/rm -f "$file" >/dev/null 2>&1; then
      log "已安排 ${ttl} 分钟后自动删除 (systemd-run: lnamp-probe-clean-${rand})"
    fi
  fi

  hr
  log_ok "临时探针已创建: http://${domain}:${port}/$(basename "$file")"
  log_warn "phpinfo 会暴露 PHP 版本/扩展/绝对路径/环境变量 —— **验证完必须删除**"
  log "    $0 vhost probe --rm           # 删除全部探针"
  log "    $0 vhost probe --rm ${domain} # 只删这个站点的"
  hr
}

_vhost_probe_list() {
  local f ts ttl now age n=0
  now=$(date +%s)
  if [ -f "$LNAMP_PROBE_STATE" ]; then
    while IFS='|' read -r f ts ttl; do
      [ -n "$f" ] && [ -f "$f" ] || continue
      age=$(( (now - ${ts:-$now}) / 60 ))
      n=$((n+1))
      printf '  %s   已存在 %s 分钟%s\n' "$f" "$age" "${ttl:+, TTL ${ttl} 分钟}"
    done < "$LNAMP_PROBE_STATE"
  fi
  # 状态文件里没有、但按名字确实躺在站点根的探针也列出来
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    n=$((n+1)); printf '  %s   (未登记)\n' "$f"
  done < <(_vh_probe_find_stray 2>/dev/null)
  if [ "$n" = 0 ]; then log_ok "没有未清理的探针"
  else log_warn "有 ${n} 个未清理的探针 —— 删除: $0 vhost probe --rm"; fi
}

_vhost_probe_find_stray() {
  [ -d "${WWWROOT}" ] || return 0
  local st f
  st=$(_vh_probe_state_list 2>/dev/null)
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    case "$st" in *"$f"*) continue ;; esac
    printf '%s\n' "$f"
  done < <(find "${WWWROOT}" -maxdepth 3 -type f -name '__lnamp_probe_*.php' 2>/dev/null)
}

_vhost_probe_rm() {   # [域名]
  local want="${1:-}" f n=0
  while IFS= read -r f; do
    [ -n "$f" ] && [ -f "$f" ] || continue
    if [ -n "$want" ]; then
      case "$f" in *"/${want}/"*|*"/${want}_"*) ;; *) continue ;; esac
    fi
    rm -f "$f" 2>/dev/null && n=$((n+1)) && log "  已删除: ${f}"
  done < <(_vh_probe_state_list 2>/dev/null; _vh_probe_find_stray 2>/dev/null)
  if [ "$n" = 0 ]; then log_ok "没有需要清理的探针${want:+ (${want})}"; else log_ok "已删除 ${n} 个探针"; fi
  return 0
}

_vhost_probe_usage() {
  cat <<EOF
用法:
  $0 vhost probe <域名>        在站点根放一个临时 phpinfo 探针并打印 URL
  $0 vhost probe --list        列出尚未删除的探针
  $0 vhost probe --rm [域名]   删除探针（不给域名=全部）

说明:
  建站不会再生成 phpinfo 首页（那是长期在线的信息泄露页）。需要验证 PHP
  是否可用时才用这个临时探针，验证完请立即删除。
  探针文件名带随机后缀、权限 0640，并会在 systemd 机器上安排
  ${LNAMP_PROBE_TTL_MIN:-15} 分钟后自动删除（LNAMP_PROBE_TTL_MIN=0 关闭）。
EOF
}

vhost_usage() {
  cat <<EOF
用法:
  $0 vhost <域名> [端口] [根目录] [nginx|apache]   创建站点（HTTP）
  $0 vhost                            交互式创建
  $0 vhost list                       列出站点（类型/端口/根目录/启停状态/是否隔离）
  $0 vhost rebind <域名> [--shared]   给已有站点建独立 php-fpm 池（按站点 open_basedir 隔离）
  $0 vhost rebind --all [--shared]    对全部已启用站点执行；--shared 退回全局池
  $0 vhost disable <域名>             停用站点（改名为 .conf.disabled，不改内容）
  $0 vhost enable  <域名>             重新启用
  $0 vhost probe <域名>               临时 phpinfo 探针（部署验证用，**验证后 --rm 删掉**）
  $0 vhost probe --list|--rm [域名]   列出 / 删除探针
  $0 vhost ssl <域名>                 一键启用 HTTPS（用已有证书/自动探测/自签，不申请证书）
  $0 vhost del <域名> [--purge]       删除站点（配置先归档；--purge 连目录一起删）
  $0 vhost del --file <配置文件>      删除解析不出域名的坏配置
  $0 vhost del <域名> --yes           跳过确认（自动化场景）
  $0 vhost prune                      列出残留（坏配置/根目录缺失/孤儿目录/归档），不动手
  $0 vhost prune --yes [--purge-dirs] 清理残留（配置归档不硬删；--purge-dirs 连孤儿目录）
  $0 vhost prune --disabled           连 .conf.disabled 一起清（默认不动，怕误删临时停用）
  $0 vhost prune --archive-keep 30    归档只留最近 30 个

类型说明:
  HTTP        仅监听 80（或自定义端口），无证书
  HTTPS       配置了 ssl_certificate / SSLEngine on（或监听 443）
  HTTP+HTTPS  同时监听 80 与 443（双栈）

注: 本工具不申请证书。要上 HTTPS，请自行获取证书后把 443 server 段写进
    对应站点的 vhost 配置文件；启停/删除对它同样适用。
EOF
}

# 子命令入口：install.sh vhost [子命令|域名] [...]
vhost_main() {
  local sub="${1:-}"
  case "$sub" in
    list|ls)              shift; vhost_list "$@" ;;
    rebind|pool|iso)      shift; vhost_rebind "$@" ;;
    del|rm|delete|remove) shift; vhost_del "$@" ;;
    prune|clean|cleanup)  shift; vhost_prune "$@" ;;
    ssl|tls|https)        shift; vhost_ssl "$@" ;;
    disable|down|off)     shift; vhost_disable "$@" ;;
    enable|up|on)         shift; vhost_enable "$@" ;;
    probe|phpinfo|info)   shift; vhost_probe "$@" ;;
    -h|--help)            vhost_usage ;;
    *)                    _vhost_create "$@" ;;
  esac
}

_vhost_create() {
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
