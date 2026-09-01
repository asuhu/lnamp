#!/bin/bash
# ============================================================================
#  modules/deps.sh  ——  编译期公共依赖 (shared build-time dependencies)
#  原先 nghttp2 在 function.sh、libsodium/argon2 在各 php 脚本里重复出现，
#  这里统一一份，apache.sh 与 php.sh 共用。
# ============================================================================

install_nghttp2() {
  PREFIX_NGHTTP2=/usr/local/nghttp2
  if [ -e "${PREFIX_NGHTTP2}/include/nghttp2/nghttp2.h" ]; then
    log "nghttp2 已安装 (already installed)"; return 0
  fi
  local v=nghttp2-1.41.0
  cd ~ || return 1
  dl "so/${v}.tar.gz"
  tar -zxf "${v}.tar.gz"; cd "$v" || die "cd nghttp2"
  ./configure --prefix="${PREFIX_NGHTTP2}"
  make -j "${THREAD}" && make install
  echo "${PREFIX_NGHTTP2}/lib" > /etc/ld.so.conf.d/nghttp2.conf; ldconfig
  cd ~ && rm -rf "$v" "${v}.tar.gz"
  [ -e "${PREFIX_NGHTTP2}/include/nghttp2/nghttp2.h" ] || die "nghttp2 安装失败"
}

# PHP 用 OpenSSL：编译指定版本到 /usr/local/openssl
# 编译 OpenSSL 到 /usr/local/openssl（Apache2.4 与 PHP 共用）
# 关键修正：OpenSSL 3.x 在 64 位系统通常安装到 lib64/，旧代码只查 lib/libcrypto.a
# 会误判“安装失败”。这里 lib 与 lib64 都检测，并用 install_sw 跳过冗长的文档安装。
build_openssl_prefix() {
  local ov="$1"
  if ls /usr/local/openssl/lib*/libcrypto.* >/dev/null 2>&1 && [ -x /usr/local/openssl/bin/openssl ]; then
    log "OpenSSL 已安装 (already installed): $(/usr/local/openssl/bin/openssl version 2>/dev/null)"
    return 0
  fi
  cd ~ || return 1
  dl_openssl "$ov" "openssl-src.tar.gz"
  local d; d=$(tar -tzf openssl-src.tar.gz 2>/dev/null | head -1 | cut -d/ -f1)
  tar -zxf openssl-src.tar.gz
  cd "$d" || die "cd openssl"
  log "编译 OpenSSL ${ov} ... (日志: ${BUILD_LOG})"
  log_run "openssl ${ov} config"      ./config --prefix=/usr/local/openssl --openssldir=/usr/local/openssl shared zlib-dynamic \
    || die_with_log "openssl ${ov} 配置失败 (configure failed)"
  log_run "openssl ${ov} make"        make -j "${THREAD}" \
    || die_with_log "openssl ${ov} 编译失败 (make failed)"
  # install_sw=只装库/头/程序(不装 html/man 文档，快很多)；install_ssldirs=装 openssl.cnf 等
  log_run "openssl ${ov} install_sw"  make install_sw \
    || die_with_log "openssl ${ov} 安装失败 (make install_sw failed)"
  log_run "openssl ${ov} ssldirs"     make install_ssldirs || true
  # 校验：lib 或 lib64 下存在 libcrypto.*
  if ! ls /usr/local/openssl/lib*/libcrypto.* >/dev/null 2>&1; then
    die_with_log "openssl ${ov} 安装失败 (未找到 libcrypto，检查 lib/lib64)"
  fi
  printf '/usr/local/openssl/lib\n/usr/local/openssl/lib64\n' > /etc/ld.so.conf.d/openssl.conf
  ldconfig
  cd ~ && rm -rf "$d" openssl-src.tar.gz
  log_ok "OpenSSL ${ov} 安装完成: $(/usr/local/openssl/bin/openssl version 2>/dev/null)"
}

# PHP 用 OpenSSL：编译到 /usr/local/openssl，并下载 CA 证书
install_php_openssl() {
  build_openssl_prefix "$1"
  # CA 证书（curl.cainfo / openssl.cafile 用）
  wget --no-check-certificate -4 -O /usr/local/openssl/cert.pem https://curl.se/ca/cacert.pem 2>/dev/null \
    || log_warn "cacert.pem 下载失败，可稍后手动放置到 /usr/local/openssl/cert.pem"
}

# PHP 5.6 专用：编译 OpenSSL 1.0.2u 到独立前缀 ${PREFIX_OPENSSL_10}
# ----------------------------------------------------------------------------
# 为什么单独一份：PHP 5.6 无法链接 OpenSSL 3.x（API 不兼容），必须用 1.0.2。
# 若写进共享的 /usr/local/openssl 会与 nginx/apache 使用的 OpenSSL3 互相破坏，
# 因此装到 /usr/local/openssl-1.0，PHP 5.6 用 --with-openssl 指向此处即可。
# 1.0.2 的运行库 soname 为 libssl.so.1.0.0 / libcrypto.so.1.0.0，与 3.x 的
# libssl.so.3 不同名，可在 ldconfig 中并存，不影响其它组件。
install_php56_openssl() {
  local pre="${PREFIX_OPENSSL_10:-/usr/local/openssl-1.0}" ov="1.0.2u"
  if ls "${pre}"/lib*/libcrypto.* >/dev/null 2>&1 && [ -x "${pre}/bin/openssl" ]; then
    log "OpenSSL 1.0.2 (PHP5.6 专用) 已安装: $(${pre}/bin/openssl version 2>/dev/null)"
  else
    cd ~ || return 1
    # 镜像/本地缓存优先(fetch 内置)，官方 old 源 → GitHub Release 资产兜底
    fetch "openssl-${ov}.tar.gz" \
      "https://www.openssl.org/source/old/1.0.2/openssl-${ov}.tar.gz" \
      "https://github.com/openssl/openssl/releases/download/OpenSSL_1_0_2u/openssl-${ov}.tar.gz" \
      || die "下载失败 (download failed): openssl-${ov}.tar.gz"
    rm -rf "openssl-${ov}"; tar -zxf "openssl-${ov}.tar.gz" || die "openssl 1.0.2 解包失败"
    cd "openssl-${ov}" || die "cd openssl-1.0.2"
    log "编译 OpenSSL ${ov} -> ${pre} (PHP5.6 专用) ... (日志: ${BUILD_LOG})"
    # 1.0.x 用 ./config；shared 生成动态库；-fPIC 保证可被 PHP 扩展链接
    log_run "openssl1.0 config" ./config --prefix="${pre}" --openssldir="${pre}" shared zlib-dynamic -fPIC \
      || die_with_log "OpenSSL ${ov} 配置失败"
    # 注意：1.0.2 并行编译偶发依赖问题，这里用单线程更稳
    log_run "openssl1.0 make"   make \
      || die_with_log "OpenSSL ${ov} 编译失败"
    log_run "openssl1.0 install" make install_sw \
      || die_with_log "OpenSSL ${ov} 安装失败"
    ls "${pre}"/lib*/libcrypto.* >/dev/null 2>&1 || die_with_log "OpenSSL ${ov} 安装失败(未找到 libcrypto)"
    echo "${pre}/lib" > /etc/ld.so.conf.d/openssl-1.0.conf; ldconfig
    cd ~ && rm -rf "openssl-${ov}" "openssl-${ov}.tar.gz"
    log_ok "OpenSSL ${ov} (PHP5.6 专用) 安装完成: $(${pre}/bin/openssl version 2>/dev/null)"
  fi
  # CA 证书（curl.cainfo / openssl.cafile 用），沿用共享路径
  [ -f /usr/local/openssl/cert.pem ] || {
    mkdir -p /usr/local/openssl
    wget --no-check-certificate -4 -O /usr/local/openssl/cert.pem https://curl.se/ca/cacert.pem 2>/dev/null \
      || log_warn "cacert.pem 下载失败，可稍后手动放置到 /usr/local/openssl/cert.pem"
  }
}

# PHP7.2+ 密码哈希依赖
install_libsodium() {
  local v=libsodium-1.0.19
  [ -e /usr/local/lib/libsodium.so ] && return 0
  cd ~ || return 1
  # 镜像(含 so/ 子目录)与本地缓存已由 fetch 自动优先，这里只给官方源兜底
  fetch "${v}.tar.gz" \
    "https://download.libsodium.org/libsodium/releases/${v}.tar.gz" \
    || die "下载失败 (download failed): ${v}.tar.gz"
  # 官方发布包解压目录可能是 libsodium-stable（并非 libsodium-1.0.19），从包内探测真实目录
  local d; d=$(tar -tzf "${v}.tar.gz" 2>/dev/null | head -1 | cut -d/ -f1)
  [ -n "$d" ] || d="$v"
  tar -zxf "${v}.tar.gz"; cd "$d" || die "cd libsodium ($d)"
  ./configure && make -j "${THREAD}" && make install; ldconfig
  cd ~ && rm -rf "$d" "${v}.tar.gz"
}

install_argon2() {
  local v="$1"   # argon2-20171227 / argon2-20190702
  [ -e /usr/local/lib/libargon2.so ] && return 0
  cd ~ || return 1
  dl "so/${v}.tar.gz"
  tar -zxf "${v}.tar.gz"; cd "phc-winner-${v}" 2>/dev/null || cd "$v" 2>/dev/null || return 1
  make && make install PREFIX=/usr/local; ldconfig
  cd ~ && rm -rf "$v"* "phc-winner-${v}"*
}

# 独立组件入口：单独安装 phpredis（需先安装 PHP）。ver 来自清单选择。
install_phpredis_pick() {
  local ver="$1"
  if [ ! -x "${PREFIX_PHP}/bin/php" ] || [ ! -x "${PREFIX_PHP}/bin/phpize" ]; then
    die "phpredis: 未检测到已编译的 PHP（${PREFIX_PHP}/bin）。请先安装 PHP，或在同一次运行中同时选择 PHP 与 phpredis。"
  fi
  local major; major=$("${PREFIX_PHP}/bin/php" -r 'echo PHP_MAJOR_VERSION;' 2>/dev/null)
  [ -n "$major" ] || major=8
  install_phpredis "$major" "$ver"
}

# phpredis 扩展：用已安装 PHP 的 phpize 从源码编译。
# 用法: install_phpredis <php主版本号> [phpredis版本]
#   未显式给版本时：PHP8 默认 6.2.0，PHP7 默认 5.3.7。
install_phpredis() {
  local major="$1" rv="$2"
  local phpize="${PREFIX_PHP}/bin/phpize" phpcfg="${PREFIX_PHP}/bin/php-config"
  [ -x "$phpize" ] || { log_warn "未找到 phpize，跳过 phpredis"; return 0; }
  # phpredis 版本与 PHP 主版本匹配：
  #   PHP8 -> 6.3.0 ; PHP7 -> 5.3.7 ; PHP5 -> 4.3.0(最后一个支持 PHP5 的分支)
  if [ -z "$rv" ]; then
    if   [ "$major" -ge 8 ]; then rv="6.3.0"
    elif [ "$major" -ge 7 ]; then rv="5.3.7"
    else                          rv="4.3.0"
    fi
  fi
  log "编译 phpredis 扩展 (build phpredis ${rv})"
  cd ~ || return 1
  fetch "phpredis-${rv}.tar.gz" \
    "https://github.com/phpredis/phpredis/archive/refs/tags/${rv}.tar.gz" \
    || { log_warn "phpredis 下载失败，跳过"; return 0; }
  local d; d=$(tar -tzf "phpredis-${rv}.tar.gz" 2>/dev/null | head -1 | cut -d/ -f1)
  [ -n "$d" ] || d="phpredis-${rv}"
  tar -zxf "phpredis-${rv}.tar.gz"; cd "$d" || return 0
  "$phpize" && ./configure --with-php-config="$phpcfg" && make -j "${THREAD}" && make install
  # 写入扫描目录使扩展生效（绝对路径）并重启 php-fpm 使 web 端生效
  php_enable_ext redis redis.so
  cd ~ && rm -rf "$d" "phpredis-${rv}.tar.gz"
  reload_php_runtime
  "${PREFIX_PHP}/bin/php" -m 2>/dev/null | grep -qi '^redis$' \
    && log_ok "phpredis 扩展已启用" || log_warn "phpredis 编译可能未成功，请检查"
}
