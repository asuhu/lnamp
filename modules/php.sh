#!/bin/bash
# ============================================================================
#  modules/php.sh  ——  PHP 安装模块
#  install_php <version> <mode>     mode = fpm | apache
#  版本: 5.6 / 7.4 / 8.2 / 8.3 / 8.4 / 8.5
#  fpm    -> php-fpm，配合 Nginx
#  apache -> mod_php (--with-apxs2)，作为 Apache 模块
#  合并了原 php5/php7/php73/php74/php82 + php7apache 等脚本，并自动编译 phpredis。
#
#  PHP 5.6.40（EOL）自动适配：独立 OpenSSL 1.0.2、跳过 sodium/argon2、
#  旧式 GD/zip/libxml 开关、启用 mcrypt、现代 GCC 追加 -fcommon、不启用 intl。
#  详见 versions.conf 中 PHP 段落的说明。
# ============================================================================

install_php() {
  local ver="$1" mode="$2"
  local major="${ver%%.*}" minor
  minor="$(echo "$ver" | cut -d. -f2)"
  local meta openssl min_mem ext mcrypt_meta
  meta=$(manifest_lookup PHP "$ver"); meta="${meta#*|}"
  openssl=$(meta_get "$meta" openssl); min_mem=$(meta_get "$meta" min_mem);
  mcrypt_meta=$(meta_get "$meta" mcrypt || echo off)

  detect_mem
  if [ "${min_mem:-0}" -gt 0 ] && [ "$MEM_MB" -lt "$min_mem" ]; then
    die "PHP ${ver} 需要至少 ${min_mem}MB 内存 (current ${MEM_MB}MB)"
  fi
  log "安装 PHP ${ver}  形式(mode)=${mode}  memory_limit=${MEMORY_LIMIT}M"
  if [ "$major" -lt 7 ]; then
    log_warn "PHP ${ver} 已 EOL(官方停止维护)，仅建议用于承载老旧遗留应用；最佳运行环境为 CentOS/RHEL 7。"
  fi

  _php_base_deps "$major"

  # ---- OpenSSL：PHP7/8 用共享 OpenSSL3；PHP5.6 用独立 OpenSSL 1.0.2 ----
  # 同时决定是否需要 sodium/argon2（仅 PHP7.2+ 支持）。
  local openssl_home
  if [ "$major" -ge 7 ]; then
    install_php_openssl "$openssl"
    openssl_home="/usr/local/openssl"
    install_libsodium
    install_argon2 "$(meta_get "$meta" argon2 || echo argon2-20190702)"
  else
    install_php56_openssl
    openssl_home="${PREFIX_OPENSSL_10:-/usr/local/openssl-1.0}"
    # PHP5.6 不支持 sodium/argon2，跳过依赖与对应 configure 开关
  fi

  cd ~ || die "cd ~"
  fetch "php-${ver}.tar.gz" "https://www.php.net/distributions/php-${ver}.tar.gz" \
    || die "下载失败 (download failed): php-${ver}.tar.gz"
  tar -zxf "php-${ver}.tar.gz"
  cd "php-${ver}" || die "cd php src"

  # 让 configure 通过 pkg-config 找到我们自编译的 openssl / libsodium / argon2
  # （PHP5.6 用旧式 --with-openssl=DIR，不依赖 pkg-config，但保留 /usr/local/lib 供其它库）
  if [ "$major" -ge 7 ]; then
    export PKG_CONFIG_PATH="/usr/local/openssl/lib/pkgconfig:/usr/local/openssl/lib64/pkgconfig:/usr/local/lib/pkgconfig:${PKG_CONFIG_PATH}"
  else
    export PKG_CONFIG_PATH="/usr/local/lib/pkgconfig:${PKG_CONFIG_PATH}"
  fi

  # ---- configure 参数：通用基础集 + SAPI + 版本差异 ----
  # 说明：把 openssl / sodium / argon2 / libxml / intl 这些“版本差异项”从基础集里
  #       拆出来按主版本追加，PHP5.6 与 PHP7/8 各取所需。
  local cfg=(--prefix="${PREFIX_PHP}"
    --with-config-file-path="${PREFIX_PHP}/etc"
    --with-config-file-scan-dir="${PREFIX_PHP}/etc/php.d"
    --with-curl --with-gettext --with-kerberos
    --with-pdo-sqlite
    --with-ldap --with-ldap-sasl --with-xsl --with-zlib --with-bz2
    --with-iconv --with-gmp --with-snmp=shared
    --enable-sockets --enable-pdo --enable-bcmath --enable-mbregex --enable-mbstring
    --enable-pcntl --enable-shmop --enable-soap --enable-sysvsem --enable-xml
    --enable-opcache --enable-calendar --enable-exif
    --enable-mysqlnd --enable-fileinfo --disable-debug)

  if [ "$major" -ge 7 ]; then
    # PHP7/8：新式 openssl(pkg-config) + sodium/argon2 + intl + libxml + mysqli/pdo(默认mysqlnd)
    cfg+=(--with-openssl=/usr/local/openssl
          --with-password-argon2 --with-sodium=/usr/local
          --with-libxml --with-mysqli --with-pdo-mysql --with-pear
          --enable-intl --enable-static)
  else
    # PHP5.6：旧式 openssl=DIR、libxml-dir、mysqlnd 显式、旧式 iconv-dir；
    #         不启用 intl(系统 ICU 过新与 5.6 不兼容)；额外 5.x 专属开关。
    cfg+=(--with-openssl="${openssl_home}"
          --with-libxml-dir=/usr
          --with-mysql=mysqlnd --with-mysqli=mysqlnd --with-pdo-mysql=mysqlnd
          --with-iconv-dir=/usr/local --with-mhash --with-xmlrpc
          --enable-wddx --enable-ftp --enable-gd-native-ttf
          --disable-rpath --without-pear)
    # mcrypt：仅当系统提供 libmcrypt 开发库时启用（新发行版可能已移除）
    if [ "${mcrypt_meta}" = on ] && _php56_has_mcrypt; then
      cfg+=(--with-mcrypt)
    else
      [ "${mcrypt_meta}" = on ] && log_warn "未找到 libmcrypt 开发库，PHP5.6 将不启用 mcrypt 扩展"
    fi
  fi

  # SAPI 形式
  case "$mode" in
    fpm)    cfg+=(--enable-fpm --with-fpm-user=www --with-fpm-group=www) ;;
    apache) cfg+=(--with-apxs2="${PREFIX_APACHE}/bin/apxs") ;;
    *)      die "php: 未知形式 ${mode}" ;;
  esac

  # zip / gd 按版本差异（PHP 8 用新式 --with-zip；7.4 及以下用 --enable-zip）
  if [ "$major" -ge 8 ]; then cfg+=(--with-zip); else cfg+=(--enable-zip); fi
  # gd：PHP8 与 7.4 用新式(--enable-gd --with-jpeg --with-freetype)；7.3/5.6 用旧式(--with-gd ...)
  if [ "$major" -ge 8 ] || [ "${major}.${minor}" = "7.4" ]; then
    cfg+=(--enable-gd --with-jpeg --with-freetype)
  else
    cfg+=(--with-gd --with-jpeg-dir --with-freetype-dir --with-png-dir)
  fi

  # ---- 编译标志 ----
  # PHP5.6 在 GCC>=10（默认 -fno-common）下会因重复符号编译失败，追加 -fcommon；
  # 同时把 5.6 专属 openssl 1.0.2 的头/库目录喂给编译器，确保 --with-openssl 能探测到。
  local _cflags="" _ldflags=""
  if [ "$major" -lt 7 ]; then
    local gccmaj; gccmaj=$(gcc -dumpversion 2>/dev/null | cut -d. -f1)
    [ -n "$gccmaj" ] && [ "$gccmaj" -ge 10 ] 2>/dev/null && _cflags="-fcommon ${_cflags}"
    _cflags="-I${openssl_home}/include ${_cflags}"
    _ldflags="-L${openssl_home}/lib -Wl,-rpath,${openssl_home}/lib ${_ldflags}"
  fi

  CFLAGS="${_cflags}" CXXFLAGS="${_cflags}" LDFLAGS="${_ldflags}" ./configure "${cfg[@]}"
  make -j "${THREAD}" && make install
  [ -x "${PREFIX_PHP}/bin/php" ] || die "PHP ${ver} 编译失败 (build failed)"

  # ---- php.ini：以 production 为基础，按模板优化 ----
  mkdir -p "${PREFIX_PHP}/etc/php.d"
  cp -f php.ini-production "${PREFIX_PHP}/etc/php.ini"
  tune_php_ini "${PREFIX_PHP}/etc/php.ini"

  # 启用编译出来的共享扩展（在 php-fpm 启动前写好，避免 phpinfo 看不到）
  # opcache 是 Zend 扩展，必须用 zend_extension 加载
  php_enable_ext opcache opcache.so zend
  {
    echo "opcache.enable=1"
    echo "opcache.enable_cli=0"
    echo "opcache.memory_consumption=128"
    echo "opcache.max_accelerated_files=10000"
    echo "opcache.validate_timestamps=1"
    echo "opcache.revalidate_freq=60"
  } >> "${PREFIX_PHP}/etc/php.d/opcache.ini"
  # snmp 以 shared 方式编译，需显式启用
  local _extdir; _extdir=$("${PREFIX_PHP}/bin/php-config" --extension-dir 2>/dev/null)
  [ -n "$_extdir" ] && [ -f "${_extdir}/snmp.so" ] && php_enable_ext snmp snmp.so

  if [ "$mode" = "fpm" ]; then
    _php_setup_fpm
  else
    _php_setup_apache_module "$major"
  fi

  register_path php "${PREFIX_PHP}/bin" php php-config phpize pecl pear
  [ -x "${PREFIX_PHP}/sbin/php-fpm" ] && ln -sf "${PREFIX_PHP}/sbin/php-fpm" /usr/local/bin/php-fpm

  # ImageMagick(imagick) 扩展：按选择安装（PHP_IMAGICK=yes 时）
  if [ "${PHP_IMAGICK:-}" = yes ]; then
    _php_install_imagick "$ver" "$major"
  fi

  cd ~ && rm -rf "php-${ver}" "php-${ver}.tar.gz"
  log_ok "PHP ${ver} (${mode}) 安装完成"
  log "提示: phpredis 扩展已独立为单独组件，请用 --phpredis 选择安装（或交互菜单中选择）。"
}

# 编译并启用 ImageMagick(imagick) 扩展（适配所有 PHP 版本）
# imagick 版本：PHP<8.4 用 3.7.0；PHP>=8.4 用 3.8.1（可在 versions.conf 调整 IMAGICK_*）
# imagick 可链接系统 ImageMagick 6 或 7；ImageMagick 官方对 PHP 扩展仍推荐 IM6 以求最大兼容。
_php_install_imagick() {
  local ver="$1" major="$2" minor iv
  minor="$(echo "$ver" | cut -d. -f2)"
  if [ "$major" -lt 7 ]; then
    iv="3.4.4"   # imagick 3.4.4 是最后一个兼容 PHP5 的版本(3.5+ 需要 PHP7+)
  elif [ "$major" -ge 8 ] && [ "$minor" -ge 4 ]; then
    iv="${IMAGICK_VERSION_PHP84:-3.8.0}"
  else
    iv="${IMAGICK_VERSION:-3.7.0}"
  fi
  log "安装 ImageMagick(imagick ${iv}) 扩展 ..."
  local phpize="${PREFIX_PHP}/bin/phpize" phpcfg="${PREFIX_PHP}/bin/php-config"
  [ -x "$phpize" ] || { log_warn "未找到 phpize，跳过 imagick"; return 0; }
  # ImageMagick 来源：源码编译最新版，或发行版包
  local imagick_cfg=(--with-php-config="$phpcfg")
  if [ "${IMAGEMAGICK_SOURCE:-}" = yes ]; then
    _build_imagemagick_source
    export PKG_CONFIG_PATH="${PREFIX_IMAGEMAGICK}/lib/pkgconfig:${PKG_CONFIG_PATH:-}"
    imagick_cfg+=(--with-imagick="${PREFIX_IMAGEMAGICK}")
  else
    # 系统库：ImageMagick + 开发头文件
    dep ImageMagick ImageMagick-devel
  fi
  cd ~ || return 1
  # 源码：pecl 官方 + 镜像兜底
  fetch "imagick-${iv}.tgz" "https://pecl.php.net/get/imagick-${iv}.tgz" \
    || die_with_log "imagick ${iv} 下载失败"
  rm -rf "imagick-${iv}"; tar -zxf "imagick-${iv}.tgz" || die "imagick 解包失败"
  cd "imagick-${iv}" || die "cd imagick"
  log_run "imagick phpize"    "$phpize"
  log_run "imagick configure" ./configure "${imagick_cfg[@]}" \
    || die_with_log "imagick configure 失败"
  log_run "imagick make"      make -j "${THREAD}" \
    || die_with_log "imagick 编译失败 (可能缺少 ImageMagick 开发库)"
  log_run "imagick install"   make install || die_with_log "imagick 安装失败"
  # 写入扩展启用文件（绝对路径）并重启 php-fpm 使 web 端生效
  php_enable_ext imagick imagick.so
  cd ~ && rm -rf "imagick-${iv}" "imagick-${iv}.tgz"
  reload_php_runtime
  if "${PREFIX_PHP}/bin/php" -m 2>/dev/null | grep -qi '^imagick$'; then
    log_ok "ImageMagick(imagick ${iv}) 已启用"
  else
    log_warn "imagick 已编译但未在 php -m 中检测到，请检查 ${PREFIX_PHP}/etc/php.d/imagick.ini"
  fi
}

# 从源码编译 ImageMagick 到 PREFIX_IMAGEMAGICK（供 imagick 链接）
_build_imagemagick_source() {
  local v="${IMAGEMAGICK_VERSION}" pre="${PREFIX_IMAGEMAGICK}"
  if [ -x "${pre}/bin/magick" ]; then
    log "ImageMagick 源码版已安装: $(${pre}/bin/magick -version 2>/dev/null | head -1)"
    return 0
  fi
  log "从源码编译 ImageMagick ${v} -> ${pre} ..."
  # 常用图像格式 delegate 开发库 + PDF/PS 支持(ghostscript)
  dep gcc gcc-c++ make pkgconfig libpng-devel libjpeg-devel libtiff-devel libwebp-devel \
      freetype-devel libxml2-devel bzip2-devel zlib-devel ghostscript
  cd ~ || return 1
  fetch "ImageMagick-${v}.tar.gz" \
    "https://imagemagick.org/archive/releases/ImageMagick-${v}.tar.gz" \
    "https://imagemagick.org/archive/ImageMagick-${v}.tar.gz" \
    "https://github.com/ImageMagick/ImageMagick/archive/refs/tags/${v}.tar.gz" \
    || die_with_log "ImageMagick ${v} 下载失败"
  rm -rf "ImageMagick-${v}"; tar -zxf "ImageMagick-${v}.tar.gz" || die "ImageMagick 解包失败"
  cd "ImageMagick-${v}" || die "cd ImageMagick"
  log_run "IM configure" ./configure --prefix="${pre}" --with-modules --enable-shared --disable-static \
      --with-bzlib --with-png --with-jpeg --with-tiff --with-webp --with-freetype --with-xml \
    || die_with_log "ImageMagick configure 失败"
  log_run "IM make"    make -j "${THREAD}" || die_with_log "ImageMagick 编译失败"
  log_run "IM install" make install        || die_with_log "ImageMagick 安装失败"
  echo "${pre}/lib" > /etc/ld.so.conf.d/imagemagick.conf; ldconfig
  # magick 命令行也软链到 PATH，便于使用
  ln -fs "${pre}/bin/magick" /usr/local/bin/magick 2>/dev/null || true
  cd ~ && rm -rf "ImageMagick-${v}" "ImageMagick-${v}.tar.gz"
  log_ok "ImageMagick ${v} 源码安装完成: $(${pre}/bin/magick -version 2>/dev/null | head -1)"
}

_php_base_deps() {
  if [ "$OS_FAMILY" = debian ]; then
    pkg_update
    pkg_install build-essential
  else
    pkg_install epel-release yum-utils 2>/dev/null
    # RHEL/Rocky 8/9 的部分 -devel 包在 CRB/PowerTools 仓库
    if [ "$OS_VER" -ge 8 ]; then
      pkg_install dnf-plugins-core 2>/dev/null
      dnf config-manager --set-enabled crb       >/dev/null 2>&1 || \
      dnf config-manager --set-enabled powertools >/dev/null 2>&1 || true
    fi
  fi
  dep gcc gcc-c++ make autoconf wget git re2c bison pkgconfig \
    libxml2-devel curl-devel libjpeg-devel libpng-devel freetype-devel \
    bzip2-devel gmp-devel zlib-devel libxslt-devel libcurl-devel \
    readline-devel oniguruma-devel sqlite-devel libzip-devel libwebp-devel \
    krb5-devel openldap-devel cyrus-sasl-devel net-snmp-devel libicu-devel

  # PHP 5.6 额外依赖：mcrypt(libmcrypt+mhash) 与 gd 开发库。
  # RHEL 系的 libmcrypt/mhash 位于 EPEL；较新发行版可能已不再提供，探测失败则跳过。
  if [ "${1:-8}" -lt 7 ] 2>/dev/null; then
    if [ "$OS_FAMILY" = rhel ]; then
      pkg_install epel-release 2>/dev/null
      dep libmcrypt libmcrypt-devel mhash mhash-devel gd-devel 2>/dev/null || true
    else
      dep libmcrypt-devel libmhash-dev libgd-dev 2>/dev/null || true
    fi
  fi
}

# 探测系统是否具备 libmcrypt 开发头文件（供 PHP5.6 决定是否 --with-mcrypt）。
_php56_has_mcrypt() {
  local h
  for h in /usr/include/mcrypt.h /usr/local/include/mcrypt.h \
           /usr/include/*/mcrypt.h; do
    [ -f "$h" ] && return 0
  done
  return 1
}

# 幂等设置 php.ini 指令：无论原来是被注释(;key=)、已存在还是缺失，统一改成 key = val
_ini_set() {
  local ini="$1" key="$2" val="$3" kre vesc
  kre=$(printf '%s' "$key"  | sed 's/[][\.^$*/]/\\&/g')
  vesc=$(printf '%s' "$val" | sed -e 's/\\/\\\\/g' -e 's/@/\\@/g' -e 's/&/\\&/g')
  if grep -Eq "^[[:space:];]*${kre}[[:space:]]*=" "$ini"; then
    sed -i -E "s@^[[:space:];]*${kre}[[:space:]]*=.*@${key} = ${vesc}@" "$ini"
  else
    printf '%s = %s\n' "$key" "$val" >> "$ini"
  fi
}

# 按给定模板优化 php.ini（内存分级 + 安全/常用项）
tune_php_ini() {
  local ini="$1"
  [ -n "$MEM_MB" ] || detect_mem
  # memory_limit：基础值用内存分级(MEMORY_LIMIT)，再按模板对 >1000M 覆盖
  sed -i "s@^memory_limit.*@memory_limit = ${MEMORY_LIMIT}M@" "$ini"
  if   [ "$MEM_MB" -gt 1000 ] && [ "$MEM_MB" -le 2500 ]; then
    sed -i "s@^memory_limit.*@memory_limit = 64M@"  "$ini"
  elif [ "$MEM_MB" -gt 2500 ] && [ "$MEM_MB" -le 3500 ]; then
    sed -i "s@^memory_limit.*@memory_limit = 128M@" "$ini"
  elif [ "$MEM_MB" -gt 3500 ]; then
    sed -i "s@^memory_limit.*@memory_limit = 256M@" "$ini"
  fi
  sed -i 's@^output_buffering =@output_buffering = On\noutput_buffering =@' "$ini"
  sed -i 's@^;cgi.fix_pathinfo.*@cgi.fix_pathinfo=0@'                        "$ini"
  sed -i 's@^short_open_tag = Off@short_open_tag = On@'                      "$ini"
  sed -i 's@^expose_php = On@expose_php = Off@'                              "$ini"
  sed -i 's@^request_order.*@request_order = "CGP"@'                        "$ini"
  sed -i 's@^;date.timezone.*@date.timezone = Asia/Shanghai@'               "$ini"
  sed -i 's@^post_max_size.*@post_max_size = 100M@'                         "$ini"
  sed -i 's@^upload_max_filesize.*@upload_max_filesize = 50M@'              "$ini"
  sed -i 's@^max_execution_time.*@max_execution_time = 60@'                 "$ini"
  # 禁用危险函数（仅列真实存在的高危函数；不含 chmod ——
  #  chmod 是 Twig 缓存/Composer/WordPress/Laravel 等大量框架的正常依赖，
  #  禁用它会触发形如 "Call to undefined function Twig\Cache\chmod()" 的报错）。
  #  已剔除原列表中的无效/笔误项(eval 无法用此法禁用；fsocket/popepassthru/multi_exec
  #  并非真实函数)与会误伤主流框架的项(parse_ini_file/show_source)。
  sed -i 's@^disable_functions.*@disable_functions = passthru,exec,system,chroot,chgrp,chown,shell_exec,proc_open,proc_get_status,ini_alter,ini_restore,dl,pfsockopen,openlog,syslog,readlink,symlink,stream_socket_server,popen,pcntl_exec@' "$ini"
  sed -i 's@^;curl.cainfo.*@curl.cainfo = /usr/local/openssl/cert.pem@'     "$ini"
  sed -i 's@^;openssl.cafile.*@openssl.cafile = /usr/local/openssl/cert.pem@' "$ini"
  [ -e /usr/sbin/sendmail ] && sed -i 's@^;sendmail_path.*@sendmail_path = /usr/sbin/sendmail -t -i@' "$ini"
  sed -i 's@^;openssl.capath.*@openssl.capath = /usr/local/openssl@'        "$ini"
  sed -i 's@^;realpath_cache_size.*@realpath_cache_size = 2M@'              "$ini"

  # ---- PHP 错误日志：写到绝对、可写的路径（否则相对名 php_errors.log 在
  #      php-fpm(以 www 运行) 的工作目录下往往写不进/找不到，表现为"不记录错误") ----
  ensure_www_user 2>/dev/null || true
  local logdir="${PREFIX_PHP}/var/log"
  local errlog="${logdir}/php_errors.log"
  local opclog="${logdir}/opcache_error.log"
  mkdir -p "$logdir"
  : >> "$errlog"; : >> "$opclog"
  chown -R www:www "$logdir" 2>/dev/null || true
  chmod 0755 "$logdir" 2>/dev/null; chmod 0644 "$errlog" "$opclog" 2>/dev/null
  _ini_set "$ini" log_errors On                # 确保开启错误记录
  _ini_set "$ini" error_log "$errlog"          # 绝对路径，www 可写
  _ini_set "$ini" error_reporting "E_ALL & ~E_DEPRECATED & ~E_STRICT"
  _ini_set "$ini" log_errors_max_len 0         # 不截断错误信息
  # display_errors 保持 Off（生产安全）；开发调试可临时改为 On。
  _ini_set "$ini" display_errors Off
  _ini_set "$ini" display_startup_errors Off
  _ini_set "$ini" opcache.error_log "$opclog"

  log "已按模板优化 php.ini (memory_limit 见上, timezone=Asia/Shanghai, 错误日志=${errlog}, 安全函数已禁用等)"
}

_php_setup_fpm() {
  cp -f "${PREFIX_PHP}/etc/php-fpm.conf.default" "${PREFIX_PHP}/etc/php-fpm.conf" 2>/dev/null
  if [ -f "${PREFIX_PHP}/etc/php-fpm.d/www.conf.default" ]; then
    cp -f "${PREFIX_PHP}/etc/php-fpm.d/www.conf.default" "${PREFIX_PHP}/etc/php-fpm.d/www.conf"
  fi
  local www="${PREFIX_PHP}/etc/php-fpm.d/www.conf"
  local fpmconf="${PREFIX_PHP}/etc/php-fpm.conf"
  # 运行身份 www；监听方式改为 Unix socket（取代 127.0.0.1:9000）
  sed -i "s/^user = .*/user = www/; s/^group = .*/group = www/" "$www"
  sed -i "s#^;\?listen = .*#listen = ${PHP_FPM_SOCK}#" "$www"
  sed -i "s/^;\?listen.owner = .*/listen.owner = www/" "$www"
  sed -i "s/^;\?listen.group = .*/listen.group = www/" "$www"
  sed -i "s/^;\?listen.mode = .*/listen.mode = 0660/" "$www"
  # 确保 socket 与 pid / 日志 目录存在，并让 www 可写日志目录
  mkdir -p "$(dirname "${PHP_FPM_SOCK}")" "${PREFIX_PHP}/var/run" "${PREFIX_PHP}/var/log"
  ensure_www_user 2>/dev/null || true
  chown -R www:www "${PREFIX_PHP}/var/log" 2>/dev/null || true

  # ---- FPM 错误日志：主进程日志用绝对路径；pool 显式指定 error_log 并捕获 worker 输出 ----
  #  否则 PHP 脚本产生的 warning/fatal 可能既不进 php.ini 的 error_log、也不进 FPM 主日志。
  _ini_set "$fpmconf" "error_log" "${PREFIX_PHP}/var/log/php-fpm.log"
  _ini_set "$www" "catch_workers_output" "yes"
  _ini_set "$www" "php_admin_value[error_log]" "${PREFIX_PHP}/var/log/php_errors.log"
  _ini_set "$www" "php_admin_flag[log_errors]" "on"

  # systemd 单元：RuntimeDirectory=php 保证每次启动自动创建 /run/php
  local rundir; rundir="$(basename "$(dirname "${PHP_FPM_SOCK}")")"
  cat > "${SYSTEMD_DIR}/php-fpm.service" <<EOF
[Unit]
Description=PHP FastCGI Process Manager
After=network.target

[Service]
Type=simple
RuntimeDirectory=${rundir}
RuntimeDirectoryMode=0755
PIDFile=${PREFIX_PHP}/var/run/php-fpm.pid
ExecStart=${PREFIX_PHP}/sbin/php-fpm --nodaemonize --fpm-config ${PREFIX_PHP}/etc/php-fpm.conf
ExecReload=/bin/kill -USR2 \$MAINPID

[Install]
WantedBy=multi-user.target
EOF
  enable_service php-fpm
  log_ok "php-fpm 已配置为 Unix socket 监听: ${PHP_FPM_SOCK} (owner/group=www, mode=0660)"
}

_php_setup_apache_module() {
  local major="$1"
  # mod_php 的共享库名与内部模块符号名随 PHP 主版本不同：
  #   PHP5 -> libphp5.so / php5_module
  #   PHP7 -> libphp7.so / php7_module
  #   PHP8 -> libphp.so  / php_module
  # LoadModule 的模块名必须与库内符号一致，否则 Apache 启动会报 "Can't locate API module"。
  local so="libphp${major}.so" modname="php${major}_module"
  if [ "$major" -ge 8 ]; then so="libphp.so"; modname="php_module"; fi
  # 让 Apache 解析 PHP
  local conf="${PREFIX_APACHE}/conf/httpd.conf"
  grep -q "${so}" "$conf" 2>/dev/null || \
    echo "LoadModule ${modname} modules/${so}" >> "$conf"
  cat >> "$conf" <<'EOF'

<FilesMatch \.php$>
    SetHandler application/x-httpd-php
</FilesMatch>
DirectoryIndex index.php index.html
EOF
  "${PREFIX_APACHE}/bin/apachectl" restart 2>/dev/null || true
}
