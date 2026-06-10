#!/bin/bash
# ============================================================================
#  modules/apache.sh  ——  Apache 安装模块
#  install_apache <version> <mode>     mode = source | pkg
#  按 meta 中的 mpm(prefork/event) 与 http2(on/off) 决定编译形态：
#    2.4.67 -> event MPM + HTTP2  (原 apache.sh)
#    2.4.58 -> event,   支持 HTTP2     (原 apache_openssl.sh)
# ============================================================================

install_apache() {
  local ver="$1" mode="$2" mpm_pick="${3:-}"
  log "安装 Apache ${ver}  形式(mode)=${mode}${mpm_pick:+  MPM=${mpm_pick}}"
  [ "$OS_FAMILY" = rhel ] && pkg_remove httpd || pkg_remove apache2
  case "$mode" in
    source) _apache_source "$ver" "$mpm_pick" ;;
    pkg)    _apache_pkg "$mpm_pick" ;;
    *)      die "apache: 未知形式 ${mode}" ;;
  esac
}

_apache_source() {
  local ver="$1" mpm_pick="${2:-}" meta mpm http2 apr aprutil openssl
  meta=$(manifest_lookup APACHE "$ver"); meta="${meta#*|}"
  mpm=$(meta_get "$meta" mpm); http2=$(meta_get "$meta" http2)
  apr=$(meta_get "$meta" apr); aprutil=$(meta_get "$meta" aprutil)
  openssl=$(meta_get "$meta" openssl)
  # 用户选择的 MPM 覆盖清单默认，并按版本校验
  [ -n "$mpm_pick" ] && mpm="$mpm_pick"
  mpm=$(_apache_validate_mpm "$ver" "$mpm")

  dep gcc gcc-c++ make wget pcre-devel expat-devel zlib-devel git net-tools
  ensure_www_user
  cd ~ || die "cd ~"

  log "下载 (download): httpd-${ver}, ${apr}, apr-util-${aprutil}"
  dl_url "http://archive.apache.org/dist/httpd/httpd-${ver}.tar.gz" "httpd-${ver}.tar.gz"
  dl_url "http://archive.apache.org/dist/apr/apr-${apr}.tar.gz"     "apr-${apr}.tar.gz"
  dl_url "http://archive.apache.org/dist/apr/apr-util-${aprutil}.tar.gz" "apr-util-${aprutil}.tar.gz"

  tar -zxf "httpd-${ver}.tar.gz"
  tar -zxf "apr-${apr}.tar.gz"        && cp -fr "apr-${apr}"        "httpd-${ver}/srclib/apr"
  tar -zxf "apr-util-${aprutil}.tar.gz" && cp -fr "apr-util-${aprutil}" "httpd-${ver}/srclib/apr-util"

  local cfg=(--prefix="${PREFIX_APACHE}"
             --enable-so --enable-rewrite --enable-ssl --enable-mods-shared=all
             --with-included-apr --with-mpm="${mpm}")

  if [ "$http2" = "on" ]; then
    # 2.4 event + HTTP2：需要新版 openssl 与 nghttp2
    _ensure_openssl "$openssl"
    install_nghttp2
    cfg+=(--enable-http2 --with-nghttp2="${PREFIX_NGHTTP2:-/usr/local/nghttp2}"
          --with-ssl=/usr/local/openssl)
  fi

  cd "httpd-${ver}" || die "cd httpd"
  ./configure "${cfg[@]}"
  make -j "${THREAD}" && make install
  [ -x "${PREFIX_APACHE}/bin/httpd" ] || die "Apache ${ver} 编译失败 (build failed)"

  # 基础配置：用户、ServerName、http2(可选)
  sed -i 's/^User .*/User www/;  s/^Group .*/Group www/' "${PREFIX_APACHE}/conf/httpd.conf"
  grep -q '^ServerName' "${PREFIX_APACHE}/conf/httpd.conf" || \
    echo 'ServerName localhost:80' >> "${PREFIX_APACHE}/conf/httpd.conf"

  # 默认站点根目录 -> /home/wwwroot/web
  mkdir -p "${WWWROOT}/web"
  [ -f "${WWWROOT}/web/index.html" ] || echo "<h1>It works (default site)</h1>" > "${WWWROOT}/web/index.html"
  sed -i "s@^DocumentRoot .*@DocumentRoot \"${WWWROOT}/web\"@" "${PREFIX_APACHE}/conf/httpd.conf"
  sed -i "s@^<Directory \"${PREFIX_APACHE}/htdocs\">@<Directory \"${WWWROOT}/web\">@" "${PREFIX_APACHE}/conf/httpd.conf"
  chown -R www:www "${WWWROOT}/web" 2>/dev/null || true

  # vhost 支持：启用所需模块 + 建立 vhost 目录并 include
  _apache_enable_vhost
  _apache_write_mpm_tuning "$mpm"

  _apache_register_service
  open_ports "80,443,8080,8443"
  register_path apache "${PREFIX_APACHE}/bin" httpd apachectl apxs

  cd ~ && rm -rf "httpd-${ver}"* "apr-${apr}"* "apr-util-${aprutil}"*
  log_ok "Apache ${ver} (${mpm}, http2=${http2}) 安装完成"
}

_apache_pkg() {
  local mpm_pick="${1:-}"
  if [ "$OS_FAMILY" = debian ]; then
    pkg_update
    pkg_install apache2
    [ -x /usr/sbin/apache2 ] || die "Apache (apt) 安装失败"
    a2enmod ssl rewrite proxy proxy_fcgi expires deflate headers >/dev/null 2>&1
    # 切换 MPM(Debian: a2dismod/a2enmod mpm_*)
    if [ -n "$mpm_pick" ]; then
      a2dismod mpm_prefork mpm_worker mpm_event >/dev/null 2>&1
      a2enmod "mpm_${mpm_pick}" >/dev/null 2>&1 && log_ok "Apache MPM 已切换为 ${mpm_pick}"
    fi
    enable_service apache2
  else
    pkg_install epel-release httpd mod_ssl
    [ -x /usr/sbin/httpd ] || die "Apache (${PM}) 安装失败"
    # 切换 MPM(RHEL: /etc/httpd/conf.modules.d/00-mpm.conf 注释切换)
    if [ -n "$mpm_pick" ] && [ -f /etc/httpd/conf.modules.d/00-mpm.conf ]; then
      sed -i 's@^LoadModule mpm_@#LoadModule mpm_@' /etc/httpd/conf.modules.d/00-mpm.conf
      sed -i "s@^#\(LoadModule mpm_${mpm_pick}_module\)@\1@" /etc/httpd/conf.modules.d/00-mpm.conf
      log_ok "Apache MPM 已切换为 ${mpm_pick}"
    fi
    enable_service httpd
  fi
  open_ports "80,443,8080,8443"
  log_ok "Apache (${PM}) 安装完成"
}

# 校验 MPM：Apache 2.4 支持 prefork/worker/event，非法值回退 event
_apache_validate_mpm() {
  local mpm="${2:-}"
  case "$mpm" in prefork|worker|event) echo "$mpm" ;; *) echo event ;; esac
}

# 写入所选 MPM 的调优块(include 进 httpd.conf)
_apache_write_mpm_tuning() {
  local mpm="$1" hc="${PREFIX_APACHE}/conf/httpd.conf"
  mkdir -p "${PREFIX_APACHE}/conf/lnamp"
  local f="${PREFIX_APACHE}/conf/lnamp/mpm.conf"
  case "$mpm" in
    prefork) cat > "$f" <<'EOF'
<IfModule mpm_prefork_module>
    StartServers             5
    MinSpareServers          5
    MaxSpareServers         10
    MaxRequestWorkers      150
    MaxConnectionsPerChild 10000
</IfModule>
EOF
      ;;
    *) cat > "$f" <<EOF
<IfModule mpm_${mpm}_module>
    StartServers             3
    MinSpareThreads         25
    MaxSpareThreads         75
    ThreadsPerChild         25
    MaxRequestWorkers      400
    MaxConnectionsPerChild 10000
</IfModule>
EOF
      ;;
  esac
  grep -qE '^[[:space:]]*Include(Optional)?[[:space:]]+conf/lnamp/mpm\.conf' "$hc" || \
    echo 'IncludeOptional conf/lnamp/mpm.conf' >> "$hc"
  log_ok "Apache MPM=${mpm}，调优写入 conf/lnamp/mpm.conf"
}

# 编译指定版本 openssl 到 /usr/local/openssl (供 2.4 / php 复用)
_ensure_openssl() {
  build_openssl_prefix "$1"
}

# 启用 vhost 所需模块，并建立 conf/vhost 目录、在 httpd.conf 中 include
_apache_enable_vhost() {
  local hc="${PREFIX_APACHE}/conf/httpd.conf"
  mkdir -p "${PREFIX_APACHE}/conf/vhost"
  local m
  for m in proxy_module proxy_fcgi_module rewrite_module expires_module deflate_module headers_module; do
    sed -i "s@^#\(LoadModule ${m} \)@\1@" "$hc"
  done
  grep -qE '^[[:space:]]*IncludeOptional[[:space:]]+conf/vhost/\*\.conf' "$hc" || \
    echo 'IncludeOptional conf/vhost/*.conf' >> "$hc"
  log_ok "Apache 已启用 vhost 支持 (proxy_fcgi/rewrite/expires/deflate/headers, include conf/vhost/*.conf)"
}

_apache_register_service() {
  cat > "${SYSTEMD_DIR}/httpd.service" <<EOF
[Unit]
Description=Apache HTTP Server (source)
After=network.target

[Service]
Type=forking
ExecStart=${PREFIX_APACHE}/bin/apachectl start
ExecReload=${PREFIX_APACHE}/bin/apachectl graceful
ExecStop=${PREFIX_APACHE}/bin/apachectl stop
PrivateTmp=true

[Install]
WantedBy=multi-user.target
EOF
  enable_service httpd
}
