#!/bin/bash
# ============================================================================
#  modules/nginx.sh  ——  Nginx 安装模块
#  install_nginx <version> <mode>     mode = source | pkg
#  合并了原 nginx.sh (源码) 与 yum_nginx.sh (包管理器) 两个脚本，按形式分发。
# ============================================================================

install_nginx() {
  local ver="$1" mode="$2"
  log "安装 Nginx ${ver}  形式(mode)=${mode}"
  pkg_remove nginx
  [ "$OS_FAMILY" = rhel ] && pkg_remove httpd
  case "$mode" in
    source) _nginx_source "$ver" ;;
    pkg)    _nginx_pkg ;;
    *)      die "nginx: 未知形式 ${mode}" ;;
  esac
}

# ---------------------------------------------------------------------------
# 源码编译 (compile from source) —— 支持 nginx 与 tengine 两种 flavor
# ---------------------------------------------------------------------------
_nginx_source() {
  local ver="$1" meta flavor openssl pcre zlib modules
  meta=$(manifest_lookup NGINX "$ver"); meta="${meta#*|}"
  flavor=$(meta_get "$meta" flavor); [ -z "$flavor" ] && flavor=nginx
  openssl=$(meta_get "$meta" openssl); pcre=$(meta_get "$meta" pcre); zlib=$(meta_get "$meta" zlib)
  modules=$(meta_get "$meta" modules)   # 附加 configure 参数，逗号分隔

  dep gcc gcc-c++ make automake libtool zlib-devel git net-tools unzip perl wget
  ensure_www_user
  cd ~ || die "cd ~"

  # 依赖：zlib / pcre / openssl —— 均从镜像下载并本地编译进 nginx
  log "下载依赖 (deps): zlib-${zlib} ${pcre} openssl-${openssl}"
  dl "zlib-${zlib}.tar.gz"
  dl "${pcre}.tar.gz"
  dl_openssl "$openssl" "openssl-src.tar.gz"

  # 按 flavor 决定源码包与目录名
  local srcdir tarball
  if [ "$flavor" = tengine ]; then
    local tver="${ver#tengine-}"          # tengine-3.1.0 -> 3.1.0
    srcdir="tengine-${tver}"; tarball="${srcdir}.tar.gz"
    log "下载 Tengine ${tver}"
    fetch "$tarball" \
      "http://tengine.taobao.org/download/${tarball}" \
      "https://github.com/alibaba/tengine/archive/refs/tags/${tver}.tar.gz" \
      || die "下载失败 (download failed): ${tarball}"
  elif [ "$flavor" = freenginx ]; then
    local fver="${ver#freenginx-}"        # freenginx-1.30.1 -> 1.30.1
    srcdir="freenginx-${fver}"; tarball="${srcdir}.tar.gz"
    log "下载 freenginx ${fver}"
    fetch "$tarball" \
      "https://freenginx.org/download/${tarball}" \
      || die "下载失败 (download failed): ${tarball}"
  else
    srcdir="nginx-${ver}"; tarball="${srcdir}.tar.gz"
    fetch "$tarball" "http://nginx.org/download/nginx-${ver}.tar.gz" \
      || die "下载失败 (download failed): ${tarball}"
  fi

  tar -zxf "zlib-${zlib}.tar.gz"
  tar -zxf "${pcre}.tar.gz"
  tar -zxf "openssl-src.tar.gz"; local osslsrc; osslsrc=$(tar -tzf openssl-src.tar.gz 2>/dev/null | head -1 | cut -d/ -f1)
  [ -z "$osslsrc" ] && osslsrc=$(ls -d openssl-${openssl%.*}* 2>/dev/null | head -1)
  tar -zxf "$tarball"

  local h="$HOME/${srcdir}"
  # 保留原仓库对源码的优化（IIS 伪装 + autoindex 文件名长度），nginx/tengine 同构，安全应用
  _nginx_apply_optimizations "$h"

  # 组装 configure 参数（base 通用 + 附加模块）
  local cfg=(--prefix="${PREFIX_NGINX}" --user=www --group=www
    --with-openssl="$HOME/${osslsrc}" --with-pcre="$HOME/${pcre}" --with-zlib="$HOME/zlib-${zlib}"
    --with-http_stub_status_module --with-http_secure_link_module
    --with-threads --with-file-aio
    --with-http_v2_module --with-http_ssl_module
    --with-http_gzip_static_module --with-http_gunzip_module
    --with-http_realip_module --with-http_flv_module --with-http_mp4_module
    --with-http_sub_module --with-http_dav_module
    --with-stream --with-stream=dynamic --with-stream_ssl_module
    --with-stream_realip_module --with-stream_ssl_preread_module)
  # 附加模块（如 Tengine 的 --with-http_upstream_check_module）
  if [ -n "$modules" ]; then
    local m; for m in ${modules//,/ }; do cfg+=("$m"); done
  fi

  cd "$h" || die "cd ${flavor} src"
  ./configure "${cfg[@]}"
  make -j "${THREAD}" && make install

  [ -x "${PREFIX_NGINX}/sbin/nginx" ] || die "${flavor} ${ver} 编译失败 (build failed)"
  chown -R www:www "${PREFIX_NGINX}"

  _nginx_write_conf
  _nginx_register_service
  _nginx_logrotate
  open_ports "80,443,8080,8081,3306"

  register_path nginx "${PREFIX_NGINX}/sbin" nginx
  cd ~ && rm -rf "$srcdir" "$tarball" "${pcre}"* "zlib-${zlib}"* "${osslsrc}" openssl-src.tar.gz
  log_ok "${flavor} ${ver} (source) 安装完成"
}

# 原仓库对 nginx 源码的优化（伪装成 IIS、加大 autoindex 文件名长度）。
# 采用“按内容匹配”而非固定行号/空白，确保对 nginx / tengine / freenginx 各 flavor 都能可靠生效。
_nginx_apply_optimizations() {
  local h="$1"
  # 1) src/core/nginx.h: 版本签名与 NGINX_VAR 伪装为 IIS
  if [ -f "$h/src/core/nginx.h" ]; then
    sed -i 's@"nginx/" NGINX_VERSION@"Microsoft-IIS/10.0/" NGINX_VERSION@' "$h/src/core/nginx.h"
    sed -i 's@^#define NGINX_VAR[[:space:]].*"NGINX"@#define NGINX_VAR          "Microsoft-IIS"@' "$h/src/core/nginx.h"
  fi
  # 2) 错误页脚 <center>nginx</center> -> Microsoft-IIS
  [ -f "$h/src/http/ngx_http_special_response.c" ] && \
    sed -i 's@>nginx<@>Microsoft-IIS<@g' "$h/src/http/ngx_http_special_response.c"
  # 3) server_tokens off 时的 Server 头: "Server: nginx" -> Microsoft-IIS
  [ -f "$h/src/http/ngx_http_header_filter_module.c" ] && \
    sed -i 's@"Server: nginx"@"Server: Microsoft-IIS"@g' "$h/src/http/ngx_http_header_filter_module.c"
  if [ -f "$h/src/http/modules/ngx_http_autoindex_module.c" ]; then
    sed -i 's/^#define NGX_HTTP_AUTOINDEX_PREALLOCATE  50/#define NGX_HTTP_AUTOINDEX_PREALLOCATE  150/' "$h/src/http/modules/ngx_http_autoindex_module.c"
    sed -i 's/^#define NGX_HTTP_AUTOINDEX_NAME_LEN     50/#define NGX_HTTP_AUTOINDEX_NAME_LEN     150/' "$h/src/http/modules/ngx_http_autoindex_module.c"
  fi
  # 复制 nginx man 手册页（若存在）
  if [ -f "$h/man/nginx.8" ]; then
    cp -f "$h/man/nginx.8" /usr/share/man/man8/ 2>/dev/null && gzip -f /usr/share/man/man8/nginx.8 2>/dev/null
  fi
}

# ---------------------------------------------------------------------------
# 包管理器安装 (OS package manager)
# ---------------------------------------------------------------------------
_nginx_pkg() {
  if [ "$OS_FAMILY" = debian ]; then
    pkg_update
    pkg_install nginx
    [ -x /usr/sbin/nginx ] || die "Nginx (apt) 安装失败"
  else
    pkg_install epel-release
    cat > /etc/yum.repos.d/nginx.repo <<EOF
[nginx-stable]
name=nginx stable repo
baseurl=http://nginx.org/packages/centos/${OS_VER}/\$basearch/
gpgcheck=0
enabled=1
EOF
    pkg_install nginx
    [ -x /usr/sbin/nginx ] || die "Nginx (${PM}) 安装失败"
  fi
  enable_service nginx
  open_ports "80,443,8080,8081,3306"
  log_ok "Nginx (${PM}) 安装完成"
}

# ---------------------------------------------------------------------------
# 写入优化后的 nginx.conf（参考 conf/nginx.conf：worker/事件/gzip/fastcgi/
# open_file_cache 调优 + server_tokens off + 加固默认站点 + include vhost/*.conf）
_nginx_write_conf() {
  mkdir -p "${PREFIX_NGINX}/conf/vhost" "${PREFIX_NGINX}/conf/lnamp" "${WWWLOGS}" "${WWWROOT}/web"
  echo "<h1>It works (default site)</h1>" > "${WWWROOT}/web/index.html"

  # 安全加固片段（vhost 可按需 include）
  cat > "${PREFIX_NGINX}/conf/lnamp/security.conf" <<'SEC'
if ($http_user_agent ~* (ApacheBench|webbench|HttpClient|Scrapy)) { return 444; }
if ($http_user_agent ~ "FeedDemon|Indy Library|WinHttp|Alexa Toolbar|AhrefsBot|Python-urllib|Java|ZmEu|CrawlDaddy|Microsoft URL Control|^$") { return 444; }
if ($request_uri ~* (.*)\.(bak|mdb|db|sql|conf|ini|cnf)$) { return 444; }
if ($request_method !~ ^(GET|HEAD|POST)$) { return 403; }
if ($query_string ~ "[a-zA-Z0-9_]=http://") { return 444; }
if ($query_string ~ "[a-zA-Z0-9_]=(\.\.//?)+") { return 444; }
if ($request_uri ~* "[+|(%20)](select|delete|update|insert)[+|(%20)]") { return 444; }
if ($query_string ~ "(<|%3C).*script.*(>|%3E)") { return 444; }
SEC

  # 静态资源缓存 + 隐藏文件/上传目录加固（vhost 内 include）
  cat > "${PREFIX_NGINX}/conf/lnamp/static.conf" <<'STA'
location ~ .*\.(gif|jpg|jpeg|png|bmp|swf|flv|ico|webp)$ { expires 30d; access_log off; }
location ~ .*\.(js|css)?$ { expires 7d; access_log off; }
location = /favicon.ico { log_not_found off; access_log off; }
location ~ /\.            { deny all; }
location ~* /(?:uploads|files)/.*\.php$ { deny all; }
STA

  cat > "${PREFIX_NGINX}/conf/nginx.conf" <<EOF
user www www;
worker_processes auto;
worker_cpu_affinity auto;

error_log ${WWWLOGS}/error_nginx.log warn;
pid /var/run/nginx.pid;
worker_rlimit_nofile 51200;

events {
    use epoll;
    worker_connections 51200;
    multi_accept on;
}

http {
    include       mime.types;
    default_type  application/octet-stream;

    log_format  main  '\$remote_addr - \$remote_user [\$time_local] "\$request" '
                      '\$status \$body_bytes_sent "\$http_referer" "\$http_user_agent" "\$http_x_forwarded_for"';

    server_names_hash_bucket_size 128;
    client_header_buffer_size     32k;
    large_client_header_buffers   4 32k;
    client_max_body_size          1024m;
    client_body_buffer_size       10m;

    sendfile        on;
    tcp_nopush      on;
    tcp_nodelay     on;
    keepalive_timeout 120;
    server_tokens   off;

    fastcgi_connect_timeout 300;
    fastcgi_send_timeout    300;
    fastcgi_read_timeout    300;
    fastcgi_buffer_size     64k;
    fastcgi_buffers         4 64k;
    fastcgi_busy_buffers_size     128k;
    fastcgi_temp_file_write_size  128k;

    gzip on;
    gzip_buffers      16 8k;
    gzip_comp_level   6;
    gzip_http_version 1.1;
    gzip_min_length   256;
    gzip_proxied      any;
    gzip_vary         on;
    gzip_types text/plain text/css text/xml text/javascript application/javascript
               application/x-javascript application/json application/xml application/rss+xml
               application/atom+xml image/svg+xml font/opentype application/vnd.ms-fontobject;
    gzip_disable "MSIE [1-6]\\.(?!.*SV1)";

    open_file_cache max=1000 inactive=20s;
    open_file_cache_valid    30s;
    open_file_cache_min_uses 5;
    open_file_cache_errors   on;

    # 默认站点：/home/wwwroot/web（phpMyAdmin 等默认放这里）
    server {
        listen 80 default_server;
        server_name _;
        root ${WWWROOT}/web;
        index index.php index.html index.htm;
        access_log ${WWWLOGS}/default.log;
        location / {
            try_files \$uri \$uri/ /index.php?\$args;
        }
        location ~ \\.php\$ {
            try_files \$uri =404;
            fastcgi_pass   unix:${PHP_FPM_SOCK};
            fastcgi_index  index.php;
            fastcgi_param  SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
            include        fastcgi_params;
        }
        location ~ /\\.ht { deny all; }
    }

    include vhost/*.conf;
}
EOF
  chown -R www:www "${PREFIX_NGINX}/conf" 2>/dev/null || true
  log_ok "已写入优化的 nginx.conf (gzip/fastcgi/open_file_cache 调优, server_tokens off, 默认站点加固, include vhost/*.conf)"
}

# ---------------------------------------------------------------------------
# 注册服务 (systemd)
# ---------------------------------------------------------------------------
_nginx_register_service() {
  cat > "${SYSTEMD_DIR}/nginx.service" <<EOF
[Unit]
Description=nginx - high performance web server
After=network-online.target remote-fs.target nss-lookup.target
Wants=network-online.target

[Service]
Type=forking
PIDFile=/var/run/nginx.pid
ExecStartPre=${PREFIX_NGINX}/sbin/nginx -t -c ${PREFIX_NGINX}/conf/nginx.conf
ExecStart=${PREFIX_NGINX}/sbin/nginx -c ${PREFIX_NGINX}/conf/nginx.conf
ExecReload=${PREFIX_NGINX}/sbin/nginx -s reload
ExecStop=${PREFIX_NGINX}/sbin/nginx -s stop
PrivateTmp=true
LimitNOFILE=51200

[Install]
WantedBy=multi-user.target
EOF
  enable_service nginx
}

_nginx_logrotate() {
  if [ "$OS_FAMILY" = debian ]; then pkg_install logrotate cron >/dev/null 2>&1
  else pkg_install logrotate cronie >/dev/null 2>&1; fi
  mkdir -p "${WWWLOGS}"
  cat > /etc/logrotate.d/nginx <<EOF
${WWWLOGS}/*log {
    daily
    rotate 30
    missingok
    dateext
    notifempty
    sharedscripts
    postrotate
        [ -e /var/run/nginx.pid ] && kill -USR1 \`cat /var/run/nginx.pid\`
    endscript
}
EOF
}
