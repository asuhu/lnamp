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

  # 同版本已在位就跳过：源码装一次要重下 openssl(56MB) + 编译 10 分钟，
  # 任何一次中途失败的重跑都会从头再来（221 上因此多花了近 1 小时）。
  # 版本取 nginx -v 里**最后一个**三段版本号：安装器会把 Server 伪装成
  # "Microsoft-IIS/10.0/<版本>"，取第一个会拿到伪装的 10.0 而误判。
  # 另外 ver 可能带 flavor 前缀（freenginx-1.31.4 / tengine-3.1.0），
  # 而 nginx -v 只报纯版本号，必须先去掉前缀再比 —— 否则永远不相等，
  # 每次都白编译一遍（229 上就这么重来过一次）。
  local vplain="${ver#freenginx-}"
  vplain="${vplain#tengine-}"
  if [ -x "${PREFIX_NGINX}/sbin/nginx" ]; then
    local cur; cur=$("${PREFIX_NGINX}/sbin/nginx" -v 2>&1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | tail -1)
    if [ "$cur" = "$vplain" ] || [ "$cur" = "$ver" ]; then
      log "Nginx ${ver} 已安装 (already installed): ${PREFIX_NGINX}/sbin/nginx —— 跳过下载与编译"
      return 0
    fi
  fi

  openssl=$(meta_get "$meta" openssl); pcre=$(meta_get "$meta" pcre); zlib=$(meta_get "$meta" zlib)
  modules=$(meta_get "$meta" modules)   # 附加 configure 参数，逗号分隔

  dep gcc gcc-c++ make automake libtool zlib-devel git net-tools unzip perl wget
  ensure_www_user
  cd_src ~ "cd ~"

  # 依赖：zlib / pcre / openssl —— 优先本地缓存/自己的镜像(fetch 内置)，官方上游兜底，本地编译进 nginx
  log "下载依赖 (deps): zlib-${zlib} ${pcre} openssl-${openssl}"
  # zlib：官方当前版在 zlib.net 根目录，历史版在 fossils/ 子目录，两者都给以兼容旧/新版本
  fetch "zlib-${zlib}.tar.gz" \
    "https://zlib.net/zlib-${zlib}.tar.gz" \
    "https://zlib.net/fossils/zlib-${zlib}.tar.gz" \
    || die "下载失败 (download failed): zlib-${zlib}.tar.gz"
  # pcre2：codeload 与 github.com 同源但独立主机（部分网络只墙 github.com），官方 Release 兜底。
  # 注意 tag "pcre2-10.47" 以仓库名开头，codeload 归档根目录是 pcre2-pcre2-10.47/
  # （与 release 包的 pcre2-10.47/ 不同），故解压后用 untar_as 规范目录名。
  fetch "${pcre}.tar.gz" \
    "https://codeload.github.com/PCRE2Project/pcre2/tar.gz/refs/tags/${pcre}" \
    "https://github.com/PCRE2Project/pcre2/releases/download/${pcre}/${pcre}.tar.gz" \
    || die "下载失败 (download failed): ${pcre}.tar.gz"
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
  untar_as "${pcre}.tar.gz" "${pcre}" || die "解包失败 (extract failed): ${pcre}.tar.gz"
  tar -zxf "openssl-src.tar.gz"; local osslsrc; osslsrc=$(tar -tzf openssl-src.tar.gz 2>/dev/null | head -1 | cut -d/ -f1)
  [ -z "$osslsrc" ] && osslsrc=$(ls -d openssl-${openssl%.*}* 2>/dev/null | head -1)
  tar -zxf "$tarball"

  local h="$HOME/${srcdir}"
  # 保留原仓库对源码的优化（IIS 伪装 + autoindex 文件名长度），nginx/tengine 同构，安全应用
  _nginx_apply_optimizations "$h" "$flavor"

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

  cd_src "$h" "cd ${flavor} src"
  # nginx 的 --with-openssl 会让 make 阶段自行编译 OpenSSL，其 Configure 需要
  # perl IPC::Cmd（CentOS 7 基础镜像缺失，见 common.sh 注释）
  ensure_perl_ipc_cmd || log_warn "perl IPC::Cmd 不可用，OpenSSL 编译可能失败"
  log_run "configure" ./configure "${cfg[@]}"
  log_run "make" make -j "${THREAD}" && log_run "make install" make install

  [ -x "${PREFIX_NGINX}/sbin/nginx" ] || die "${flavor} ${ver} 编译失败 (build failed)"
  log_run "nginx: 目录属主" chown -R www:www "${PREFIX_NGINX}"

  _nginx_write_conf
  _nginx_register_service
  _nginx_logrotate
  open_ports "80,443,8080,8081"

  register_path nginx "${PREFIX_NGINX}/sbin" nginx
  # 清理现场。**绝不能**直接写 safe_rm_rf "${pcre}"* —— 一旦 pcre/zlib 为空
  # （清单缺字段、或测试里 manifest_lookup 被桩），"${pcre}"* 会退化成裸的 *，
  # 在 ~ 下就是"删掉 /root 里的所有东西"。真机上因此把 /root/lnamp 整个删过。
  # 一律先判空再拼参数。
  cd ~ || return 0
  local _rm=("$srcdir" "$tarball" "openssl-src.tar.gz")
  [ -n "$pcre" ]    && _rm+=("${pcre}"*)
  [ -n "$zlib" ]    && _rm+=("zlib-${zlib}"*)
  [ -n "$osslsrc" ] && _rm+=("${osslsrc}")
  safe_rm_rf "${_rm[@]}"
  log_ok "${flavor} ${ver} (source) 安装完成"
}

# 原仓库对 nginx 源码的优化（伪装成 IIS、加大 autoindex 文件名长度）。
# 采用“按内容匹配”而非固定行号/空白，确保对 nginx / tengine / freenginx 各 flavor 都能可靠生效。
_nginx_apply_optimizations() {
  local h="$1" flavor="${2:-nginx}"
  # 1) src/core/nginx.h: 版本签名与 NGINX_VAR 伪装为 IIS
  if [ -f "$h/src/core/nginx.h" ]; then
    if [ "$flavor" = freenginx ]; then
      # freenginx 1.31+ 重构：源码不再写字面量 "nginx/"，改为 NGINX_NAME 宏
      #   #define NGINX_NAME "freenginx"      -> Server 头 / 错误页 / 版本号全走这个宏
      #   只改它一处即可覆盖三处展示位，等价于 nginx flavor 的三条 sed。
      sed -i 's@^#define NGINX_NAME[[:space:]].*"freenginx"@#define NGINX_NAME         "Microsoft-IIS"@' "$h/src/core/nginx.h"
      grep -q '^#define NGINX_NAME[[:space:]]*"Microsoft-IIS"' "$h/src/core/nginx.h" \
        || log_warn "freenginx: NGINX_NAME 伪装未生效（上游宏名可能变化）"
    else
      sed -i 's@"nginx/" NGINX_VERSION@"Microsoft-IIS/10.0/" NGINX_VERSION@' "$h/src/core/nginx.h"
    fi
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
    ensure_epel
    save_file /etc/yum.repos.d/nginx.repo <<EOF
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
  open_ports "80,443,8080,8081"
  log_ok "Nginx (${PM}) 安装完成"
}

# ---------------------------------------------------------------------------
# 写入优化后的 nginx.conf（参考 conf/nginx.conf：worker/事件/gzip/fastcgi/
# open_file_cache 调优 + server_tokens off + 加固默认站点 + include vhost/*.conf）
_nginx_write_conf() {
  safe_mkdir "${PREFIX_NGINX}/conf/vhost" "${PREFIX_NGINX}/conf/lnamp" "${WWWLOGS}" "${WWWROOT}/web"
  echo "<h1>It works (default site)</h1>" > "${WWWROOT}/web/index.html"

  # 安全加固片段（vhost 可按需 include）
  save_file "${PREFIX_NGINX}/conf/lnamp/security.conf" <<'SEC'
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
  save_file "${PREFIX_NGINX}/conf/lnamp/static.conf" <<'STA'
location ~ .*\.(gif|jpg|jpeg|png|bmp|swf|flv|ico|webp)$ { expires 30d; access_log off; }
location ~ .*\.(js|css)?$ { expires 7d; access_log off; }
location = /favicon.ico { log_not_found off; access_log off; }
location ~ /\.            { deny all; }
location ~* /(?:uploads|files)/.*\.php$ { deny all; }
STA

  save_file "${PREFIX_NGINX}/conf/nginx.conf" <<EOF
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
  save_file "${SYSTEMD_DIR}/nginx.service" <<EOF
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
  safe_mkdir "${WWWLOGS}"
  # USR1 让 nginx 重新打开日志文件（不中断服务）
  setup_logrotate nginx "${WWWLOGS}/*.log" \
    '[ -e /var/run/nginx.pid ] && kill -USR1 `cat /var/run/nginx.pid`'
}
