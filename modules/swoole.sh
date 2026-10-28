#!/bin/bash
# ============================================================================
#  modules/swoole.sh  ——  Swoole PHP 扩展（Hyperf / Laravel Octane 运行时）
# ----------------------------------------------------------------------------
#  用已装 PHP 的 phpize 从源码编译，装入 ${PREFIX_PHP}/etc/php.d/swoole.ini。
#  前置条件：PHP >= 8.0（Swoole 6.x 的硬性要求），否则直接拒绝并说明原因。
#
#  用法: install_swoole <version> <mode>      mode 目前只有 source
# ============================================================================

install_swoole() {
  local ver="$1" mode="$2"
  case "${mode:-source}" in
    source) _swoole_source "$ver" ;;
    *)      die "swoole: 只支持 source 形式，收到: ${mode}" ;;
  esac
}

_swoole_source() {
  local ver="$1"
  local phpize="${PREFIX_PHP}/bin/phpize" phpcfg="${PREFIX_PHP}/bin/php-config"
  # 干跑时 PHP 还没装（本次会装），此时放行以便打印计划
  if { [ ! -x "$phpize" ] || [ ! -x "$phpcfg" ]; } && [ "${DRY_RUN:-0}" != 1 ]; then
    die "Swoole: 未检测到已编译的 PHP（${PREFIX_PHP}/bin）。请先安装 PHP，或在同一次运行中同时选择 PHP 与 Swoole。"
  fi

  # PHP 版本门限（清单里 php_min，缺省 8.0）
  local meta php_min phpver
  meta=$(manifest_lookup SWOOLE "$ver"); meta="${meta#*|}"
  php_min=$(meta_get "$meta" php_min); [ -n "$php_min" ] || php_min="8.0"
  phpver=$(php_bin_version)
  if [ -n "$phpver" ] && ! ver_ge "$phpver" "$php_min"; then
    die "Swoole ${ver} 需要 PHP >= ${php_min}，当前为 ${phpver}。请升级 PHP（--php 8.3.36）后再装，或改用 PHP 7 时代的 Swoole 5.x。"
  fi

  log "编译 Swoole 扩展 ${ver}  (PHP ${phpver:-未知}, mode=source)"
  if [ "$OS_FAMILY" = debian ]; then
    dep gcc gcc-c++ make autoconf pkg-config libssl-dev
  else
    dep gcc gcc-c++ make autoconf pkgconfig openssl-devel
  fi

  # Swoole 6.x 是 C++14 项目：CentOS 7 自带 gcc 4.8.5 的 libstdc++ 没有 C++14
  # 的库特性（std::exchange 等），把 -std=c++14 换成 -std=c++1y 也编译不过
  # （缺的是库而不是语言特性）。系统 g++ 不够用时自动接入 SCL devtoolset
  # （RHEL 7 官方的工具链升级路径，gcc 7~11）。
  local dt_enable=""
  if ! _cxx14_ok "$(command -v g++ || true)"; then
    dt_enable=$(ensure_cxx14_toolchain) \
      || die_with_log "没有可用的 C++14 编译器（Swoole ${ver} 需要）。RHEL/CentOS 7 可安装 SCL devtoolset-11；或改用不要求 C++14 的旧版 Swoole。"
    [ -n "$dt_enable" ] && log "使用 SCL 工具链编译: ${dt_enable}"
  fi

  cd_src ~ "cd ~"
  local tb="swoole-${ver}.tar.gz"
  # PECL 优先（pecl.php.net 独立于 GitHub），codeload 次之（与 github.com 同源但独立主机），
  # 官方 GitHub 归档兜底
  fetch "$tb" \
    "https://pecl.php.net/get/swoole-${ver}.tgz" \
    "https://codeload.github.com/swoole/swoole-src/tar.gz/refs/tags/v${ver}" \
    "https://github.com/swoole/swoole-src/archive/refs/tags/v${ver}.tar.gz" \
    || die "下载失败 (download failed): ${tb}（GitHub 不可达，可预放到 packages/）"
  # 目录探测：PECL 包首条目是 package.xml，需按构建文件定位源码目录；
  # codeload 归档（tag v6.2.3 去 v 后不以仓库名开头）根目录为 swoole-src-<ver>/
  local d; d=$(tar -tzf "$tb" 2>/dev/null | grep -m1 -E '^[^/]+/config\.m4$' | cut -d/ -f1)
  [ -n "$d" ] || d=$(tar -tzf "$tb" 2>/dev/null | awk -F/ 'NF>1 && $1!="package.xml" {print $1; exit}')
  [ -n "$d" ] || d="swoole-src-${ver}"
  tar -zxf "$tb"; cd_src "$d" "cd swoole src"

  # Swoole 6.3 起 OpenSSL 默认启用并移除了 --enable-openssl；
  # 传未知开关会让 configure 直接报错，所以按版本决定是否显式传。
  local cfg=(--with-php-config="$phpcfg")
  if ! ver_ge "$ver" "6.3.0"; then
    cfg+=(--enable-openssl)
  fi
  # OpenSSL 版本对齐：swoole 6.x 需要 ≥ 1.1.0 的 API（OPENSSL_init_ssl 等常量），
  # 而 CentOS 7 的 openssl-devel 是 1.0.2 —— 链系统库会在 src/protocol/ssl.cc
  # 直接编译失败（"OPENSSL_INIT_LOAD_CONFIG was not declared"）。PHP 8 是用安装器
  # 自编的 OpenSSL 3.0.20（${OPENSSL_PREFIX:-/usr/local/openssl}）编的，swoole
  # 必须链同一个：头文件/ABI 才对得上，运行时也能顺着 php 的 RPATH 找到 .so。
  # 实现：把自编 OpenSSL 的 pkgconfig 目录前置，configure 的 PKG_CHECK_MODULES
  # 就会拿到正确的 -I/-L（不用 --with-openssl-dir：phpize 默认 PHP_LIBDIR=lib，
  # 而我们的库在 lib64，指过去反而链不到）。
  local ossl="${OPENSSL_PREFIX:-/usr/local/openssl}"
  if [ -d "$ossl" ]; then
    export PKG_CONFIG_PATH="$ossl/lib64/pkgconfig:$ossl/lib/pkgconfig:${PKG_CONFIG_PATH:-}"
    log "OpenSSL: swoole 链接 ${ossl}（与 PHP 一致，避免链到系统旧版 OpenSSL）"
  fi
  # 编译+安装放进子 shell：devtoolset 的 enable 脚本（PATH/LD_LIBRARY_PATH）
  # 只影响这一次构建，不污染安装器后续步骤。
  (
    [ -n "$dt_enable" ] && . "$dt_enable"
    log_run "swoole: phpize" "$phpize" || exit 1
    log_run "swoole: configure" ./configure "${cfg[@]}" || exit 1
    # 链接期两处兜底（追加进 LDFLAGS，保留 configure 的原有值）：
    # ① devtoolset g++ 编出的 .so 依赖新版 libstdc++（GLIBCXX_3.4.2x），系统
    #    libstdc++ 只到 3.4.19 且 devtoolset g++ 不写 rpath —— 静态链入 C++
    #    运行时，产物对系统 libstdc++ 零依赖，不会 "symbol lookup error"；
    # ② 显式 rpath 指向自编 OpenSSL 的 lib64/lib，php-fpm/php 加载 swoole.so
    #    时找 libssl.so.3/libcrypto.so.3 必达（不依赖可执行 RPATH 的传递）。
    local extra=""
    [ -n "$dt_enable" ] && extra="-static-libstdc++ -static-libgcc "
    [ -d "$ossl" ] && extra="${extra}-Wl,-rpath,${ossl}/lib64 -Wl,-rpath,${ossl}/lib "
    if [ -n "$extra" ] && [ -f Makefile ]; then
      sed -i "s|^LDFLAGS = |LDFLAGS = ${extra}|" Makefile
    fi
    log_run "swoole: make" make -j "${THREAD}" || exit 1
    log_run "swoole: make install" make install || exit 1
  ) || die_with_log "Swoole ${ver} 编译失败 (swoole build failed)，详见构建日志"
  php_enable_ext swoole swoole.so
  cd ~ && safe_rm_rf "$d" "$tb"
  reload_php_runtime
  if [ "${DRY_RUN:-0}" = 1 ]; then
    log "  [dry-run] 将校验扩展是否加载: php -m | grep -qi '^swoole\$'"
    return 0
  fi

  if "${PREFIX_PHP}/bin/php" -m 2>/dev/null | grep -ci '^swoole$' >/dev/null; then
    local sv; sv=$("${PREFIX_PHP}/bin/php" -r 'echo defined("SWOOLE_VERSION")?SWOOLE_VERSION:"?";' 2>/dev/null)
    log_ok "Swoole 扩展已启用 (SWOOLE_VERSION=${sv:-?})"
    log "  提示：Hyperf 建议 php.ini 里设 swoole.use_shortname=Off；Octane 直接 php artisan octane:start 即可"
  else
    # 编译"成功"但扩展加载不了：头号原因就是 libstdc++ 符号版本不匹配。
    # 必须按组件失败处理 —— 静默留下一个加载不了的扩展比报错更糟。
    die_with_log "Swoole 扩展编译后无法加载（php -m 无 swoole）。常见原因：libstdc++ 符号版本不匹配，可检查: ldd ${PREFIX_PHP}/lib/php/extensions/*/swoole.so"
  fi
}
