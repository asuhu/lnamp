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
  local v=nghttp2-1.70.0
  cd ~ || return 1
  # 官方 Release 包必须排在 codeload 前面：codeload 给的是**git 仓库快照**，
  # 里面没有 configure（autotools 产物不进 git），拿到它必然在 ./configure 处
  # 报 "No such file or directory"，而真正的 release 包（含 configure）才是可编译的。
  # （真机复现：247 上连续两次都在 nghttp2 这一步失败，apache 装不出来。）
  fetch "${v}.tar.gz" \
    "https://github.com/nghttp2/nghttp2/releases/download/v1.70.0/${v}.tar.gz" \
    "https://codeload.github.com/nghttp2/nghttp2/tar.gz/refs/tags/v1.70.0" \
    || die "下载失败 (download failed): ${v}.tar.gz"
  # codeload 归档根目录是 nghttp2-v1.70.0（tag 带 v 前缀），与 release 包的 nghttp2-1.70.0 不同，
  # 故用 untar_as 规范目录名后再 cd。
  untar_as "${v}.tar.gz" "$v" || die "解包失败 (extract failed): ${v}.tar.gz"
  cd_src "$v" "cd nghttp2"
  # 兜底：万一拿到的是 git 快照（无 configure），用 autoreconf 生成。
  # 比直接失败好——至少不因为下载源顺序/缓存里放了历史包就卡死。
  if [ ! -x ./configure ]; then
    log_warn "源码包内没有 configure（git 快照？），尝试 autoreconf 生成"
    log_run "autoreconf" autoreconf -i || die "autoreconf 失败，无法生成 configure"
  fi
  log_run "configure" ./configure --prefix="${PREFIX_NGHTTP2}"
  log_run "make" make -j "${THREAD}" && log_run "make install" make install
  save_file "${LDSO_CONF_DIR}/nghttp2.conf" <<< "${PREFIX_NGHTTP2}/lib"
  log_run "ldconfig" ldconfig
  cd ~ && safe_rm_rf "$v" "${v}.tar.gz"
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
  cd_src "$d" "cd openssl"
  # OpenSSL 3.x Configure 依赖 perl IPC::Cmd（CentOS 7 基础镜像缺失）
  ensure_perl_ipc_cmd || die_with_log "perl IPC::Cmd 不可用且无法自动安装，OpenSSL 无法编译"
  # rpath 写进 openssl 二进制：不注册全局 ld.so.conf（会 shadow 系统 libcrypto.so.3），
  # 但自编二进制必须能找到自己前缀的库，否则运行时会错链到系统 openssl
  # （如 rocky9 系统 3.5.x，版本错配）。
  local _ossl_rpath="-Wl,-rpath,/usr/local/openssl/lib64 -Wl,-rpath,/usr/local/openssl/lib"
  log "编译 OpenSSL ${ov} ... (日志: ${BUILD_LOG})"
  log_run "openssl ${ov} config"      env LDFLAGS="${_ossl_rpath}" ./config --prefix=/usr/local/openssl --openssldir=/usr/local/openssl shared zlib-dynamic \
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
  # 注意：不可把 /usr/local/openssl/{lib,lib64} 写进全局 ld.so.conf.d！
  # 自编 OpenSSL 3.x 与系统 openssl-libs 的 libcrypto.so.3 soname 相同，
  # 全局注册会让 ldconfig 缓存中自编库优先于系统库，shadow 掉 rpm/dnf/pkg-config
  # 等系统程序依赖的 libcrypto.so.3（如 Rocky9 系统库含 OPENSSL_3.4.0 符号而
  # 自编 3.0.20 不含，导致 "version OPENSSL_3.4.0 not found" 级联损坏）。
  # 需要它的组件（PHP）在编译时通过 -Wl,-rpath 自带搜索路径，见 php.sh。
  # 同时清理旧版安装器可能写下的配置，保证重装/升级时自我修正。
  if [ -e "${LDSO_CONF_DIR}/openssl.conf" ]; then
    log "  清理旧版全局 openssl 库注册: ${LDSO_CONF_DIR}/openssl.conf"
    safe_rm_rf "${LDSO_CONF_DIR}/openssl.conf"
  fi
  # /usr/local/lib：自编译 libsodium/argon2 等位于此，RHEL 默认不在 ld.so 搜索
  # 路径（Debian 的 libc.conf 自带）。这些库 soname 与系统库不同名，注册无 shadow
  # 风险；openssl 因同名冲突绝不能注册，由 PHP 的 rpath 解决。
  save_file "${LDSO_CONF_DIR}/lnamp-local-libs.conf" <<< "/usr/local/lib"
  log_run "ldconfig" ldconfig
  cd ~ && safe_rm_rf "$d" openssl-src.tar.gz
  log_ok "OpenSSL ${ov} 安装完成: $(/usr/local/openssl/bin/openssl version 2>/dev/null)"
}

# PHP 用 OpenSSL：编译到 /usr/local/openssl，并下载 CA 证书
install_php_openssl() {
  build_openssl_prefix "$1"
  # CA 证书（curl.cainfo / openssl.cafile 用）
  if [ "${DRY_RUN:-0}" = 1 ]; then
    log "  [dry-run] 将下载 CA 证书 -> /usr/local/openssl/cert.pem"
    return 0
  fi
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
    safe_rm_rf "openssl-${ov}"; tar -zxf "openssl-${ov}.tar.gz" || die "openssl 1.0.2 解包失败"
    cd_src "openssl-${ov}" "cd openssl-1.0.2"
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
    save_file "${LDSO_CONF_DIR}/openssl-1.0.conf" <<< "${pre}/lib"
    log_run "ldconfig" ldconfig
    cd ~ && safe_rm_rf "openssl-${ov}" "openssl-${ov}.tar.gz"
    log_ok "OpenSSL ${ov} (PHP5.6 专用) 安装完成: $(${pre}/bin/openssl version 2>/dev/null)"
  fi
  # CA 证书（curl.cainfo / openssl.cafile 用）：放在该 PHP 实际链接的前缀下。
  # 原实现写死 /usr/local/openssl（共享 OpenSSL3 目录），纯 5.6 机器上那里可能
  # 根本没有这个文件，curl.cainfo 指过去等于没配。
  if [ "${DRY_RUN:-0}" = 1 ]; then
    log "  [dry-run] 将确保 CA 证书存在: ${pre}/cert.pem"
    return 0
  fi
  [ -s "${pre}/cert.pem" ] || {
    safe_mkdir "$pre"
    wget --no-check-certificate -4 -O "${pre}/cert.pem" https://curl.se/ca/cacert.pem 2>/dev/null \
      || log_warn "cacert.pem 下载失败，可稍后手动放置到 ${pre}/cert.pem"
  }
}

# PHP 7.x 专用：编译 OpenSSL 1.1.1w 到独立前缀 ${PREFIX_OPENSSL_11}
# ----------------------------------------------------------------------------
# 为什么必须单独一份：PHP 7.4 的 ext/openssl 不支持 OpenSSL 3.x —— 3.0 起
# EVP_PKEY_get0_RSA()/RSA_public_decrypt() 等加了 const 限定，7.4 的 openssl.c
# 直接编译失败：
#   ext/openssl/openssl.c:5960: warning: passing argument 4 of 'RSA_public_decrypt'
#                                discards 'const' qualifier
#   make: *** [Makefile:751: ext/openssl/openssl.lo] Error 1
# 完整支持 OpenSSL 3 的是 PHP 8.1+，所以 7.x 固定用 1.1.1。
# 1.1.1 的 soname 是 libssl.so.1.1 / libcrypto.so.1.1，与 3.x 的 .so.3 不同名，
# 注册进 ldconfig 不会 shadow 系统库（同 1.0.2 的处理方式）。
install_php7_openssl() {
  local pre="${PREFIX_OPENSSL_11:-/usr/local/openssl-1.1}" ov="1.1.1w"
  if ls "${pre}"/lib*/libcrypto.* >/dev/null 2>&1 && [ -x "${pre}/bin/openssl" ]; then
    log "OpenSSL 1.1.1 (PHP7 专用) 已安装: $(${pre}/bin/openssl version 2>/dev/null)"
  else
    cd ~ || return 1
    fetch "openssl-${ov}.tar.gz" \
      "https://www.openssl.org/source/openssl-${ov}.tar.gz" \
      "https://github.com/openssl/openssl/releases/download/OpenSSL_1_1_1w/openssl-${ov}.tar.gz" \
      || die "下载失败 (download failed): openssl-${ov}.tar.gz"
    safe_rm_rf "openssl-${ov}"; tar -zxf "openssl-${ov}.tar.gz" || die "openssl 1.1.1 解包失败"
    cd_src "openssl-${ov}" "cd openssl-1.1.1"
    log "编译 OpenSSL ${ov} -> ${pre} (PHP7 专用) ... (日志: ${BUILD_LOG})"
    log_run "openssl1.1 config" ./config --prefix="${pre}" --openssldir="${pre}" shared zlib-dynamic -fPIC \
      || die_with_log "OpenSSL ${ov} 配置失败"
    log_run "openssl1.1 make"    make -j "${THREAD}" \
      || die_with_log "OpenSSL ${ov} 编译失败"
    log_run "openssl1.1 install" make install_sw \
      || die_with_log "OpenSSL ${ov} 安装失败"
    ls "${pre}"/lib*/libcrypto.* >/dev/null 2>&1 || die_with_log "OpenSSL ${ov} 安装失败(未找到 libcrypto)"
    # 刻意**不**把 ${pre}/lib 注册进全局 ld.so.conf：PHP 编译时已写死
    # rpath（-Wl,-rpath,${pre}/lib），运行时能找到自己的 libssl.so.1.1；
    # 注册进全局没有收益，却让 ldconfig 在安装中途重建一次缓存 —— 这是"装到
    # openssl 阶段后机器开始出怪问题"时最该先排除的变量。
    cd ~ && safe_rm_rf "openssl-${ov}" "openssl-${ov}.tar.gz"
    log_ok "OpenSSL ${ov} (PHP7 专用) 安装完成: $(${pre}/bin/openssl version 2>/dev/null)"
  fi
  # CA 证书（php.ini 的 curl.cainfo / openssl.cafile 指到这里）
  if [ "${DRY_RUN:-0}" = 1 ]; then
    log "  [dry-run] 将确保 CA 证书存在: ${pre}/cert.pem"
    return 0
  fi
  [ -s "${pre}/cert.pem" ] || {
    safe_mkdir "$pre"
    wget --no-check-certificate -4 -O "${pre}/cert.pem" https://curl.se/ca/cacert.pem 2>/dev/null \
      || log_warn "cacert.pem 下载失败，可稍后手动放置到 ${pre}/cert.pem"
  }
}

install_phpredis_pick() {
  local ver="$1"
  if { [ ! -x "${PREFIX_PHP}/bin/php" ] || [ ! -x "${PREFIX_PHP}/bin/phpize" ]; } && [ "${DRY_RUN:-0}" != 1 ]; then
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
  if [ ! -x "$phpize" ] && [ "${DRY_RUN:-0}" != 1 ]; then
    log_warn "未找到 phpize，跳过 phpredis"; return 0
  fi
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
    "https://pecl.php.net/get/redis-${rv}.tgz" \
    "https://codeload.github.com/phpredis/phpredis/tar.gz/refs/tags/${rv}" \
    "https://github.com/phpredis/phpredis/archive/refs/tags/${rv}.tar.gz" \
    || { log_warn "phpredis 下载失败，跳过"; return 0; }
  # 目录探测：GitHub 归档首条目即 phpredis-<ver>/；PECL 镜像包首条目是 package.xml，
  # 源码目录在其后（redis-<ver>/），故优先按 config.m4 定位源码目录，再退到首个非 package.xml 目录。
  local d; d=$(tar -tzf "phpredis-${rv}.tar.gz" 2>/dev/null | grep -m1 -E '^(phpredis|redis)-[^/]+/config\.m4$' | cut -d/ -f1)
  [ -n "$d" ] || d=$(tar -tzf "phpredis-${rv}.tar.gz" 2>/dev/null | awk -F/ 'NF>1 && $1!="package.xml" {print $1; exit}')
  [ -n "$d" ] || d="phpredis-${rv}"
  tar -zxf "phpredis-${rv}.tar.gz"; cd_src "$d" "cd phpredis src"
  # ---- 旧版 gcc（<5，如 CentOS 7 的 4.8.5）兼容处理 ----
  # 1) gcc<5 默认语言标准是 gnu89，需显式 C99（源码含 for 循环内声明等 C99 语法）；
  # 2) phpredis 6.x common.h 的 REDIS_NODISCARD 检测链会被 PHP 自带头文件破坏：
  #    zend_portability.h 等对没有原生 __has_attribute 的编译器定义了
  #    "#define __has_attribute(x) 0"，令 defined(__has_attribute) 恒真但取值为 0，
  #    REDIS_NODISCARD 永不定义，编译报
  #    "expected '=', ',', ';', 'asm' or '__attribute__' before 'int'"。
  #    令该分支恒假即可回落到 "#elif defined(__GNUC__)" 正常定义属性。
  local mk_args=(-j "${THREAD}") _ccmajor
  _ccmajor=$(cc -dumpversion 2>/dev/null | cut -d. -f1)
  [ -n "$_ccmajor" ] || _ccmajor=$(gcc -dumpversion 2>/dev/null | cut -d. -f1)
  case "$(cc --version 2>/dev/null | head -1)" in
    *clang*|*Clang*) _ccmajor=99 ;;  # clang 自带 __has_attribute 且默认 C11+，无需补丁
  esac
  [ -n "$_ccmajor" ] || _ccmajor=99
  if [ "$_ccmajor" -lt 5 ] 2>/dev/null; then
    log "  检测到旧版 gcc ${_ccmajor}.x：应用 phpredis C99/属性兼容补丁"
    mk_args+=("CFLAGS=-std=gnu99 -g -O2")
    sed -i 's|^#[[:space:]]*if defined(__has_attribute)[[:space:]]*$|#    if 0|' \
      common.h 2>/dev/null || true
  fi
  log_run "phpredis: phpize" "$phpize" \
    && log_run "phpredis: configure" ./configure --with-php-config="$phpcfg" \
    && log_run "phpredis: make" make "${mk_args[@]}" \
    && log_run "phpredis: make install" make install
  # 写入扫描目录使扩展生效（绝对路径）并重启 php-fpm 使 web 端生效
  php_enable_ext redis redis.so
  cd ~ && safe_rm_rf "$d" "phpredis-${rv}.tar.gz"
  reload_php_runtime
  # 干跑下 PHP 根本没编译，php -m 必然查不到，跳过校验免得误报
  if [ "${DRY_RUN:-0}" = 1 ]; then
    log "  [dry-run] 将校验扩展是否加载: php -m | grep -qi '^redis\$'"
    return 0
  fi
  "${PREFIX_PHP}/bin/php" -m 2>/dev/null | grep -ci '^redis$' >/dev/null \
    && log_ok "phpredis 扩展已启用" || log_warn "phpredis 编译可能未成功，请检查"
}

# ---- PHP 的 sodium / argon2 / libzip 依赖 --------------------------------
# 真机（221，Ubuntu 24）安装 PHP 8.4 时日志里出现
#   install_libsodium: command not found / install_argon2: command not found /
#   install_libzip_src: command not found
# 模块化重构时这三个函数只留在 legacy/ 里，新 modules/ 没搬过来，php.sh 却还在调。
# 没有 set -e，所以不会立刻中断，而是"静默跳过依赖"——这正是最难查的一类问题：
# PHP 照样编译完，但 password_hash() 没有 argon2i/argon2id，上线后才发现。
#
# 现在的处理：
#   1) 优先用系统包（快、稳）；
#   2) 系统包没有才源码编译（仅 argon2/libzip 需要，sodium 不必）；
#   3) 都失败只 warn 不 die —— 这几个是"增强项"，不该让整个 PHP 装不出来，
#      但必须明确告警，不能像以前那样无声无息。
# 注意：PHP 7.2+ 的 sodium 已并入核心（ext/sodium 内置），不再依赖外部 libsodium，
# 所以 install_libsodium 只是历史遗留调用，装不上也不影响 sodium 扩展可用。
_php_dep_pkg() {  # <debian包名> <rhel包名>
  if [ "${OS_FAMILY:-}" = debian ]; then pkg_install "$1"; else pkg_install "$2"; fi
}

install_libsodium() {
  if [ "${DRY_RUN:-0}" = 1 ]; then
    log "  [dry-run] 将确保 libsodium 可用（PHP 7.2+ 的 sodium 已内置，仅作兼容检查）"
    return 0
  fi
  if [ -f /usr/local/include/sodium.h ] || [ -f /usr/include/sodium.h ]; then
    log "libsodium 已可用 (system) —— PHP 7.2+ 的 sodium 扩展已内置，无需外部库"; return 0
  fi
  _php_dep_pkg libsodium-dev libsodium-devel \
    || log_warn "libsodium 开发包安装失败：不影响 PHP（sodium 扩展自 7.2 起内置）"
}

install_argon2() {
  local v="${1:-argon2-20190702}"
  if [ "${DRY_RUN:-0}" = 1 ]; then
    log "  [dry-run] 将确保 libargon2 可用（password_hash 的 argon2 算法依赖）"
    return 0
  fi
  if [ -f /usr/local/include/argon2.h ] || [ -f /usr/include/argon2.h ]; then
    log "libargon2 已可用 (system)"; return 0
  fi
  if _php_dep_pkg libargon2-dev libargon2-devel; then
    [ -f /usr/include/argon2.h ] && { log_ok "libargon2 已安装 (pkg)"; return 0; }
  fi
  # 源码兜底：官方 release 包自带 Makefile，不需要 configure
  log_warn "系统包未提供 libargon2，改为源码编译 ${v}"
  ( cd ~ || exit 1
    fetch "${v}.tar.gz" \
      "https://github.com/P-H-C/phc-winner-argon2/releases/download/20190702/${v}.tar.gz" \
      "https://codeload.github.com/P-H-C/phc-winner-argon2/tar.gz/refs/tags/20190702" \
      || exit 1
    tar -zxf "${v}.tar.gz" || exit 1
    cd "${v}" || exit 1
    log_run "argon2 make" make -j "${THREAD}" && log_run "argon2 install" make install
    [ -d /usr/local/lib/pkgconfig ] || mkdir -p /usr/local/lib/pkgconfig
    cp -f libargon2.pc /usr/local/lib/pkgconfig/ 2>/dev/null || true
    ldconfig 2>/dev/null || true )
  if [ -f /usr/local/include/argon2.h ]; then
    log_ok "libargon2 已安装 (source)"; return 0
  fi
  log_warn "libargon2 安装失败：password_hash() 将不支持 argon2i / argon2id"
  return 0
}

install_libzip_src() {
  if [ "${DRY_RUN:-0}" = 1 ]; then
    log "  [dry-run] 将确保 libzip 可用（zip 扩展依赖）"
    return 0
  fi
  # zip 扩展要求 libzip >= 0.11；系统包够新就直接用
  local have=0
  if command -v pkg-config >/dev/null 2>&1; then
    pkg-config --atleast-version=0.11 libzip 2>/dev/null && have=1
  fi
  [ "$have" = 1 ] || { [ -f /usr/include/zip.h ] || [ -f /usr/local/include/zip.h ]; } && have=1
  if [ "$have" = 1 ]; then
    log "libzip 已可用 (system)"; return 0
  fi
  _php_dep_pkg libzip-dev libzip-devel \
    || log_warn "libzip 开发包安装失败：PHP 的 zip 扩展可能不可用"
  return 0
}
