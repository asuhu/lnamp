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

  # 已装同版本且形态一致就跳过：源码编译 PHP 要 10~20 分钟和 1G+ 临时空间，
  # 中途失败重跑（磁盘满、断网、某个扩展编译失败）时全都白费。
  # 形态必须区分：fpm 看 php-fpm 二进制，mod_php 看 apache 的 libphp 模块，
  # 否则"已装 fpm 又要 apache"会被误判成已装。
  if [ -x "${PREFIX_PHP}/bin/php" ] \
     && [ "$("${PREFIX_PHP}/bin/php" -r 'echo PHP_VERSION;' 2>/dev/null)" = "$ver" ]; then
    if [ "$mode" = fpm ] && [ -x "${PREFIX_PHP}/sbin/php-fpm" ]; then
      log "PHP ${ver} (fpm) 已安装 (already installed) —— 跳过下载与编译"
      return 0
    fi
    if [ "$mode" = apache ] && ls "${PREFIX_APACHE}"/modules/libphp*.so >/dev/null 2>&1; then
      log "PHP ${ver} (mod_php) 已安装 (already installed) —— 跳过下载与编译"
      return 0
    fi
  fi

  if [ "$major" -lt 7 ]; then
    log_warn "PHP ${ver} 已 EOL(官方停止维护)，仅建议用于承载老旧遗留应用；最佳运行环境为 CentOS/RHEL 7。"
  fi

  _php_base_deps "$major"

  # ---- OpenSSL：PHP7/8 用共享 OpenSSL3；PHP5.6 用独立 OpenSSL 1.0.2 ----
  # 同时决定是否需要 sodium/argon2（仅 PHP7.2+ 支持）。
  local openssl_home
  if [ "$major" -ge 8 ]; then
    install_php_openssl "$openssl"
    openssl_home="/usr/local/openssl"
    install_libsodium
    install_argon2 "$(meta_get "$meta" argon2 || echo argon2-20190702)"
    # PHP 8.x zip 扩展要求 libzip >= 0.11；CentOS 7 的 0.10.1 过旧时源码编译
    install_libzip_src
  elif [ "$major" -ge 7 ]; then
    # PHP 7.x 不支持 OpenSSL 3.x（ext/openssl 用了 3.0 改了 const 签名的 API，
    # 编译直接 Error 1）。但"自编一份 1.1.1"还有个更隐蔽的坑：链接期会出现
    # 两套 libcrypto —— 系统的 libkrb5/libldap 依赖发行版自带的那份，而
    # -L 把 -lcrypto 指到自编版本，符号版本节点对不上：
    #   libk5crypto.so: undefined reference to `EVP_KDF_derive@OPENSSL_1_1_1b'
    # （真机 181 因此卡在 bz2 探测，报的却是 "bz2 module requires libbz2"，
    #  极具误导性）。所以：系统 OpenSSL 是 1.1.1 / 1.0.2 就直接用系统的；
    # 只有系统是 3.x 时才自编 1.1.1，并且此时不同时启用 LDAP —— 否则
    # 必然又会把两套 libcrypto 混在一个链接里。
    local _sysossl _php7_no_ldap=0
    _sysossl=$(openssl version 2>/dev/null | awk '{print $2}')
    case "$_sysossl" in
      1.1.1*|1.0.2*)
        openssl_home="/usr"
        log "PHP 7.x 使用系统 OpenSSL ${_sysossl}（与系统 krb5/ldap 共用同一份 libcrypto）"
        ;;
      *)
        install_php7_openssl
        openssl_home="${PREFIX_OPENSSL_11:-/usr/local/openssl-1.1}"
        _php7_no_ldap=1
        log_warn "系统 OpenSSL 为 ${_sysossl:-未知}，PHP 7.x 改用独立 1.1.1；为避免链接期混用两套 libcrypto，本次不启用 LDAP 扩展"
        ;;
    esac
    install_libsodium
    install_argon2 "$(meta_get "$meta" argon2 || echo argon2-20190702)"
    install_libzip_src
  else
    install_php56_openssl
    openssl_home="${PREFIX_OPENSSL_10:-/usr/local/openssl-1.0}"
    # PHP5.6 不支持 sodium/argon2，跳过依赖与对应 configure 开关
  fi

  # tune_php_ini 是独立函数，用它决定 curl.cainfo / openssl.cafile 指向哪个前缀
  PHP_OPENSSL_HOME="$openssl_home"; export PHP_OPENSSL_HOME

  cd_src ~ "cd ~"
  fetch "php-${ver}.tar.gz" "https://www.php.net/distributions/php-${ver}.tar.gz" \
    || die "下载失败 (download failed): php-${ver}.tar.gz"
  tar -zxf "php-${ver}.tar.gz"
  cd_src "php-${ver}" "cd php src"

  # 让 configure 通过 pkg-config 找到我们自编译的 openssl / libsodium / argon2
  # （PHP5.6 用旧式 --with-openssl=DIR，不依赖 pkg-config，但保留 /usr/local/lib 供其它库）
  if [ "$major" -ge 7 ] && [ "$openssl_home" = "/usr" ]; then
    export PKG_CONFIG_PATH="/usr/local/lib/pkgconfig:/usr/local/lib/x86_64-linux-gnu/pkgconfig:${PKG_CONFIG_PATH:-}"
  elif [ "$major" -ge 7 ]; then
    export PKG_CONFIG_PATH="${openssl_home}/lib/pkgconfig:${openssl_home}/lib64/pkgconfig:/usr/local/openssl/lib/pkgconfig:/usr/local/openssl/lib64/pkgconfig:/usr/local/lib/pkgconfig:/usr/local/lib/x86_64-linux-gnu/pkgconfig:${PKG_CONFIG_PATH:-}"
  else
    export PKG_CONFIG_PATH="/usr/local/lib/pkgconfig:/usr/local/lib/x86_64-linux-gnu/pkgconfig:${PKG_CONFIG_PATH:-}"
  fi

  # ---- configure 参数：通用基础集 + SAPI + 版本差异 ----
  # 说明：把 openssl / sodium / argon2 / libxml / intl 这些“版本差异项”从基础集里
  #       拆出来按主版本追加，PHP5.6 与 PHP7/8 各取所需。
  # RHEL 系 64 位库位于 /usr/lib64，而 PHP configure 的 ldap 检查默认只搜 /usr/lib，
  # 不显式指定路径会报 "Cannot find ldap libraries in /usr/lib"（Debian 系库路径
  # 在 autoconf 的默认搜索范围内，无需处理）。
  # --with-ldap=DIR 语义是安装前缀（头文件找 DIR/include、库找 DIR/$PHP_LIBDIR），
  # 因此这里要把库目录 /usr/lib64 反推为前缀 /usr，直接传 /usr/lib64 会报
  # "Cannot find ldap.h"。
  local ldap_opt="--with-ldap" ldap_sasl_opt="--with-ldap-sasl" _ld="" _pfx="" libdir_opt=""
  if [ "$OS_FAMILY" = rhel ]; then
    _ld=$(dirname "$(ls /usr/lib64/libldap*.so* /usr/lib/libldap*.so* 2>/dev/null | head -1)" 2>/dev/null)
    if [ -n "$_ld" ]; then
      case "$_ld" in
        */lib|*/lib64) _pfx="${_ld%/*}" ;;
        *)              _pfx="$_ld" ;;
      esac
      ldap_opt="--with-ldap=${_pfx}"
    fi
    _ld=$(dirname "$(ls /usr/lib64/libsasl2*.so* /usr/lib/libsasl2*.so* 2>/dev/null | head -1)" 2>/dev/null)
    [ -n "$_ld" ] && ldap_sasl_opt="--with-ldap-sasl"
    # RHEL 系 64 位库在 /usr/lib64，PHP 默认 PHP_LIBDIR=lib 会导致 ldap 等库
    # 检查去 /usr/lib 找而失败（"Cannot find ldap libraries in /usr/lib"），
    # --with-libdir=lib64 是 PHP 官方提供的方式
    libdir_opt="--with-libdir=lib64"
  fi

  # PHP7 在 3.x 系统上自编 1.1.1 时不能碰 LDAP（见上），用 --without-ldap 关掉
  if [ "${_php7_no_ldap:-0}" = "1" ]; then
    ldap_opt="--without-ldap"; ldap_sasl_opt="--without-ldap"
  fi

  local cfg=(--prefix="${PREFIX_PHP}"
    --with-config-file-path="${PREFIX_PHP}/etc"
    --with-config-file-scan-dir="${PREFIX_PHP}/etc/php.d"
    --with-curl --with-gettext
    --with-pdo-sqlite
    $libdir_opt
    "$ldap_opt" "$ldap_sasl_opt" --with-xsl --with-zlib
    --with-iconv --with-gmp --with-snmp=shared
    --enable-sockets --enable-pdo --enable-bcmath --enable-mbregex --enable-mbstring
    --enable-pcntl --enable-shmop --enable-soap --enable-sysvsem --enable-xml
    --enable-opcache --enable-calendar --enable-exif
    --enable-mysqlnd --enable-fileinfo --disable-debug)

  if [ "$major" -ge 7 ]; then
    # PHP7/8：新式 openssl(pkg-config) + sodium/argon2 + intl + libxml + mysqli/pdo(默认mysqlnd)
    cfg+=($([ "$openssl_home" = "/usr" ] && echo --with-openssl || echo "--with-openssl=${openssl_home}")
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

  # kerberos：--with-kerberos 会引入 -lkrb5 -> libk5crypto -> 系统 libcrypto。
  # 当 PHP7 在 3.x 系统上自编 1.1.1（_php7_no_ldap=1）时，这会把两套 libcrypto
  # 拉进同一次链接，正是 libk5crypto 报 `EVP_KDF_derive@OPENSSL_1_1_1b`
  # 未定义的来源；此时连同 LDAP 一起关掉，宁可少两个不常用扩展也不能编译不过。
  [ "${_php7_no_ldap:-0}" = "1" ] || cfg+=(--with-kerberos)

  # SAPI 形式
  case "$mode" in
    fpm)    cfg+=(--enable-fpm --with-fpm-user=www --with-fpm-group=www) ;;
    apache) cfg+=(--with-apxs2="${PREFIX_APACHE}/bin/apxs") ;;
    *)      die "php: 未知形式 ${mode}" ;;
  esac

  # bz2：8.x 的探测走 pkg-config，`--with-bz2` 即可；
  # 7.x / 5.6 走的是旧式 AC_CHECK_LIB(bz2, BZ2_bzerror)，在 Rocky 8 上会莫名失败 ——
  # 真机 181 报 "bz2 module requires libbz2 >= 1.0.0"，但 bzip2-devel 已装、
  # /usr/include/bzlib.h 在、手工 `gcc -lbz2` 也能链接通过。显式给目录会走
  # config.m4 的另一条分支（PHP_CHECK_LIBRARY + 显式 -L），实测可过。
  if [ "$major" -ge 8 ]; then cfg+=(--with-bz2); else cfg+=(--with-bz2=/usr); fi

  # zip 的开关在各版本间改过名（8.x 用 --with-zip；7.4 实际也认 --with-zip，
  # 5.6 及更早才是 --enable-zip）。autoconf 对**不认识的选项是静默忽略**的，
  # 于是传错名字不会报错，只会"扩展没编出来、安装照常成功" —— 真机 181 的
  # PHP 7.4 就因此丢了 zip（自检才发现 "PHP 扩展未加载: zip"）。
  # 这里直接问 configure 支持哪个，别再按版本猜。
  local _ziphelp=""
  _ziphelp=$(./configure --help 2>/dev/null)
  if printf '%s' "$_ziphelp" | grep -q -- '--with-zip'; then
    cfg+=(--with-zip)
  elif printf '%s' "$_ziphelp" | grep -q -- '--enable-zip'; then
    cfg+=(--enable-zip)
  elif [ "$major" -ge 7 ]; then
    # configure 不可用（没解压好/没执行位）时按已知事实兜底：7.4/8.x 都是 --with-zip
    cfg+=(--with-zip)
  else
    cfg+=(--enable-zip)
  fi
  # gd：PHP8 / 7.4 用新式；PHP7.0–7.3 / 5.6 用旧式。
  #   ★ 旧式开关必须【显式给出目录 =/usr】：不带路径时 configure 找不到库会【静默跳过】该编码器,
  #     导致 imagejpeg() / imagewebp() 根本不存在 —— 这正是本项目「图库打开报 HTTP 500」的根因。
  #   ★ WebP：PHP5.6 的 GD 经 libvpx(--with-vpx-dir)，PHP7.0–7.3 经 libwebp(--with-webp-dir)，
  #           PHP7.4/8 用 --with-webp。按开发库是否存在 best-effort 启用；缺失只影响 WebP。
  if [ "$major" -ge 8 ] || [ "${major}.${minor}" = "7.4" ]; then
    cfg+=(--enable-gd --with-jpeg --with-freetype)
    if _have_header webp/decode.h; then cfg+=(--with-webp)
    else log_warn "未找到 libwebp 开发库(libwebp-devel)，GD 不含 WebP；JPEG/PNG 不受影响"; fi
  else
    cfg+=(--with-gd
          --with-jpeg-dir=/usr
          --with-png-dir=/usr
          --with-freetype-dir=/usr
          --with-zlib-dir=/usr)
    if [ "$major" -lt 7 ]; then
      if _have_header vpx/vpx_image.h vpx/vpxenc.h; then cfg+=(--with-vpx-dir=/usr)
      else log_warn "未找到 libvpx 开发库(libvpx-devel)，PHP5.6 的 GD 不含 WebP；JPEG/PNG 不受影响"; fi
    else
      if _have_header webp/decode.h; then cfg+=(--with-webp-dir=/usr)
      else log_warn "未找到 libwebp 开发库(libwebp-devel)，GD 不含 WebP；JPEG/PNG 不受影响"; fi
    fi
  fi

  # ---- 编译标志 ----
  # PHP5.6 在 GCC>=10（默认 -fno-common）下会因重复符号编译失败，追加 -fcommon；
  # 同时把 5.6 专属 openssl 1.0.2 的头/库目录喂给编译器，确保 --with-openssl 能探测到。
  # PHP7/8：自编 OpenSSL 3.x 用 rpath 写进二进制（不注册全局 ld.so.conf，避免
  # shadow 系统 libcrypto.so.3，详见 deps.sh build_openssl_prefix 注释）；
  # RHEL8+ 的 gcc/binutils 默认启用 PIE，PHP 的 mbstring IFUNC 符号要求显式
  # -fPIE/-pie 才能链接可执行文件（否则报 STT_GNU_IFUNC ... can not be used）。
  local _cflags="" _ldflags=""
  if [ "$major" -lt 7 ]; then
    local gccmaj; gccmaj=$(gcc -dumpversion 2>/dev/null | cut -d. -f1)
    [ -n "$gccmaj" ] && [ "$gccmaj" -ge 10 ] 2>/dev/null && _cflags="-fcommon ${_cflags}"
    _cflags="-I${openssl_home}/include ${_cflags}"
    _ldflags="-L${openssl_home}/lib -Wl,-rpath,${openssl_home}/lib ${_ldflags}"
  elif [ "$major" -lt 8 ]; then
    if [ "$openssl_home" = "/usr" ]; then
      # 用系统 OpenSSL：绝不能加 -L/-I 指向自编前缀，否则 -lcrypto 会和
      # 系统 krb5/ldap 依赖的那份打架（见 7.x 分支的注释）
      _cflags=""
      _ldflags="-Wl,-rpath,/usr/local/lib"
    else
      # 自编 1.1.1（系统是 3.x 的情况）：显式给头/库目录并写 rpath，
      # 否则运行期会去加载系统 libssl.so.3（版本错配）
      _cflags="-I${openssl_home}/include"
      _ldflags="-L${openssl_home}/lib -Wl,-rpath,${openssl_home}/lib -Wl,-rpath,/usr/local/lib"
    fi
    if [ "$OS_FAMILY" = rhel ]; then
      _cflags="${_cflags} -fPIE"
      _ldflags="${_ldflags} -pie"
    fi
  else
    _ldflags="-Wl,-rpath,/usr/local/openssl/lib64 -Wl,-rpath,/usr/local/openssl/lib -Wl,-rpath,/usr/local/lib"
    if [ "$OS_FAMILY" = rhel ]; then
      _cflags="-fPIE"
      _ldflags="${_ldflags} -pie"
    fi
  fi

  log_run "php: configure" env CFLAGS="${_cflags}" CXXFLAGS="${_cflags}" LDFLAGS="${_ldflags}" \
    ./configure "${cfg[@]}"
  log_run "make" make -j "${THREAD}" && log_run "make install" make install
  [ -x "${PREFIX_PHP}/bin/php" ] || die "PHP ${ver} 编译失败 (build failed)"

  # ---- GD 编码器自检：确认 imagejpeg / imagewebp 真被编入(本项目图床等缩略图功能依赖) ----
  # 把过去「静默地没有编码器 → 运行时才 500」提前暴露为安装日志里的明确告警。
  if "${PREFIX_PHP}/bin/php" -r 'exit(extension_loaded("gd")?0:1);' 2>/dev/null; then
    local _gj _gw
    _gj=$("${PREFIX_PHP}/bin/php" -r 'echo function_exists("imagejpeg")?1:0;' 2>/dev/null)
    _gw=$("${PREFIX_PHP}/bin/php" -r 'echo function_exists("imagewebp")?1:0;' 2>/dev/null)
    log_ok "GD 编码器：JPEG=$([ "$_gj" = 1 ] && echo 有 || echo 无)  WebP=$([ "$_gw" = 1 ] && echo 有 || echo 无)"
    [ "$_gj" = 1 ] || log_warn "GD 缺 JPEG 编码器(imagejpeg)——依赖缩略图的程序会报 500。请确认 libjpeg-turbo-devel 已安装后重装 PHP"
    [ "$_gw" = 1 ] || log_warn "GD 缺 WebP 编码器(imagewebp)——不影响 JPEG;如需 WebP,PHP5.6 装 libvpx-devel、PHP7.0+ 装 libwebp-devel 后重装 PHP"
  else
    log_warn "未检测到 GD 扩展,缩略图功能将不可用(图床会自动回退原图)"
  fi

  # ---- php.ini：以 production 为基础，按模板优化 ----
  safe_mkdir "${PREFIX_PHP}/etc/php.d"
  backup_file "${PREFIX_PHP}/etc/php.ini"
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
    _php_logrotate_module      # mod_php 模式同样需要日志轮转
  fi

  register_path php "${PREFIX_PHP}/bin" php php-config phpize pecl pear
  [ -x "${PREFIX_PHP}/sbin/php-fpm" ] && ln -sf "${PREFIX_PHP}/sbin/php-fpm" /usr/local/bin/php-fpm

  # ImageMagick(imagick) 扩展：按选择安装（PHP_IMAGICK=yes 时）
  if [ "${PHP_IMAGICK:-}" = yes ]; then
    _php_install_imagick "$ver" "$major"
  fi

  cd ~ && safe_rm_rf "php-${ver}" "php-${ver}.tar.gz"
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
  safe_rm_rf "imagick-${iv}"; tar -zxf "imagick-${iv}.tgz" || die "imagick 解包失败"
  cd_src "imagick-${iv}" "cd imagick"
  log_run "imagick phpize"    "$phpize"
  log_run "imagick configure" ./configure "${imagick_cfg[@]}" \
    || die_with_log "imagick configure 失败"
  log_run "imagick make"      make -j "${THREAD}" \
    || die_with_log "imagick 编译失败 (可能缺少 ImageMagick 开发库)"
  log_run "imagick install"   make install || die_with_log "imagick 安装失败"
  # 写入扩展启用文件（绝对路径）并重启 php-fpm 使 web 端生效
  php_enable_ext imagick imagick.so
  cd ~ && safe_rm_rf "imagick-${iv}" "imagick-${iv}.tgz"
  reload_php_runtime
  if "${PREFIX_PHP}/bin/php" -m 2>/dev/null | grep -ci '^imagick$' >/dev/null; then
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
  # libtool-ltdl-devel：--with-modules 必须，否则 configure 直接报
  #   "libltdl is required for modules and OpenCL builds" 并失败
  dep gcc gcc-c++ make pkgconfig libtool libtool-ltdl-devel \
      libpng-devel libjpeg-devel libtiff-devel libwebp-devel \
      freetype-devel libxml2-devel bzip2-devel zlib-devel ghostscript
  cd ~ || return 1
  # codeload 与 github.com 同源但独立主机（部分网络只墙 github.com，且 imagemagick.org
  # 的 archive 目录已迁走，老路径 404）；tag 以仓库名开头，归档根目录即 ImageMagick-<ver>/
  fetch "ImageMagick-${v}.tar.gz" \
    "https://codeload.github.com/ImageMagick/ImageMagick/tar.gz/refs/tags/${v}" \
    "https://imagemagick.org/archive/releases/ImageMagick-${v}.tar.gz" \
    "https://imagemagick.org/archive/ImageMagick-${v}.tar.gz" \
    "https://github.com/ImageMagick/ImageMagick/archive/refs/tags/${v}.tar.gz" \
    || die_with_log "ImageMagick ${v} 下载失败"
  safe_rm_rf "ImageMagick-${v}"; tar -zxf "ImageMagick-${v}.tar.gz" || die "ImageMagick 解包失败"
  cd_src "ImageMagick-${v}" "cd ImageMagick"
  log_run "IM configure" ./configure --prefix="${pre}" --with-modules --enable-shared --disable-static \
      --with-bzlib --with-png --with-jpeg --with-tiff --with-webp --with-freetype --with-xml \
    || die_with_log "ImageMagick configure 失败"
  log_run "IM make"    make -j "${THREAD}" || die_with_log "ImageMagick 编译失败"
  log_run "IM install" make install        || die_with_log "ImageMagick 安装失败"
  save_file "${LDSO_CONF_DIR}/imagemagick.conf" <<< "${pre}/lib"
  log_run "ldconfig" ldconfig
  # magick 命令行也软链到 PATH，便于使用
  ln -fs "${pre}/bin/magick" /usr/local/bin/magick 2>/dev/null || true
  cd ~ && safe_rm_rf "ImageMagick-${v}" "ImageMagick-${v}.tar.gz"
  log_ok "ImageMagick ${v} 源码安装完成: $(${pre}/bin/magick -version 2>/dev/null | head -1)"
}

_php_base_deps() {
  if [ "$OS_FAMILY" = debian ]; then
    pkg_update
    pkg_install build-essential
  else
    ensure_epel
    pkg_install yum-utils 2>/dev/null || log_warn "yum-utils 安装失败（部分源码构建步骤可能受影响）"
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
      ensure_epel
      dep libmcrypt libmcrypt-devel mhash mhash-devel gd-devel 2>/dev/null || true
    else
      dep libmcrypt-devel libmhash-dev libgd-dev 2>/dev/null || true
    fi
    # PHP5.6 的 GD 经 libvpx 提供 WebP 编码(imagewebp);装上开发库后 configure 才会启用 --with-vpx-dir。
    dep libvpx-devel 2>/dev/null || log_warn "libvpx 开发库安装失败,PHP5.6 的 WebP 缩略图将不可用(不影响 JPEG)"
  fi
}

# 探测给定开发头文件是否存在(任一命中即返回真),供 GD 的 WebP 等可选编码器按需启用,
# 避免在缺库时硬加 --with-vpx-dir/--with-webp-dir 造成 configure 失败。
_have_header() {
  local h
  for h in "$@"; do
    [ -f "/usr/include/${h}" ] && return 0
    [ -f "/usr/local/include/${h}" ] && return 0
  done
  return 1
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
  # 注意：这里**不能**用 `sed s@^output_buffering =@A\nB@` 这种"插一行"的写法。
  # sed 只替换每行的第一次，而第一次执行后文件里就有两行以 output_buffering 开头，
  # 下一次执行这两行各自再插一行 -> 行数**翻倍**。重复安装 N 次就是 2^N 行：
  # 真机上 php.ini 被撑到 738MB / 3355 万行，PHP 解析它直接烧满 CPU（启动不动）。
  # 用幂等的 _ini_set（有则替换、无则追加），永远只有一行。
  _ini_set "$ini" output_buffering On
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
  #  mail / link 是补齐的两项：
  #    mail   —— 第五个参数会拼进 sendmail 命令行，历史上是 -C/-X 任意文件写入的入口
  #    link   —— 硬链接可把只读文件"链接"到可写目录，绕过属主/权限检查
  #  mail 会影响 WordPress 的 wp_mail（默认走 mail()）：确需发信的站点用
  #  LNAMP_KEEP_MAIL=yes 保留，另需追加的用 LNAMP_DISABLE_FUNCTIONS_EXTRA=函数名,函数名
  #  putenv 不再禁用（2026-10-27 决策）：Composer 等管理工具的正常运行依赖 putenv，
  #  禁用会误伤 CLI（PHP7 喷 "putenv() has been disabled" Warning、PHP8 直接 Error，
  #  实测连 composer --version 都挂）；收益/代价不成比例，故从列表移除。
  local _df="passthru,exec,system,chroot,chgrp,chown,shell_exec,proc_open,proc_get_status,ini_alter,ini_restore,dl,pfsockopen,openlog,syslog,readlink,symlink,stream_socket_server,popen,pcntl_exec,mail,link"
  [ "${LNAMP_KEEP_MAIL:-no}" = yes ] && _df=$(printf '%s' "$_df" | sed 's/,mail,/,/')
  [ -n "${LNAMP_DISABLE_FUNCTIONS_EXTRA:-}" ] && _df="${_df},${LNAMP_DISABLE_FUNCTIONS_EXTRA}"
  sed -i "s@^disable_functions.*@disable_functions = ${_df}@" "$ini"
  # CA 证书：自编 openssl 用前缀下的 cert.pem（deps 里会下载）；
  # 用系统 OpenSSL 时（PHP7 在 RHEL8/Ubuntu20 走这条）改用系统 CA bundle，
  # 否则会指向 /usr/cert.pem 这种不存在的路径，curl 的 HTTPS 直接失效。
  local _ossl_home="${PHP_OPENSSL_HOME:-/usr/local/openssl}" _ca=""
  for _ca in "${_ossl_home}/cert.pem" /etc/pki/tls/certs/ca-bundle.crt \
             /etc/ssl/certs/ca-certificates.crt; do
    [ -s "$_ca" ] && break
    _ca=""
  done
  if [ -n "$_ca" ]; then
    sed -i "s@^;curl.cainfo.*@curl.cainfo = ${_ca}@"     "$ini"
    sed -i "s@^;openssl.cafile.*@openssl.cafile = ${_ca}@" "$ini"
  else
    log_warn "未找到可用的 CA 证书包，curl.cainfo 保持注释（HTTPS 校验会失败）"
  fi
  [ -e /usr/sbin/sendmail ] && sed -i 's@^;sendmail_path.*@sendmail_path = /usr/sbin/sendmail -t -i@' "$ini"
  [ -d "${_ossl_home}/certs" ] && sed -i "s@^;openssl.capath.*@openssl.capath = ${_ossl_home}@" "$ini"
  sed -i 's@^;realpath_cache_size.*@realpath_cache_size = 2M@'              "$ini"

  # ---- PHP 错误日志：写到绝对、可写的路径（否则相对名 php_errors.log 在
  #      php-fpm(以 www 运行) 的工作目录下往往写不进/找不到，表现为"不记录错误") ----
  ensure_www_user 2>/dev/null || true
  local logdir="${PREFIX_PHP}/var/log"
  local errlog="${logdir}/php_errors.log"
  local opclog="${logdir}/opcache_error.log"
  safe_mkdir "$logdir"
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

  # ---- php-cli.ini：CLI 专用覆盖，放开 disable_functions ----
  # 审计禁用的 mail/link 等防的是 webshell（php-fpm/mod_php 的 web 面），
  # 但 CLI 是管理员本地入口，威胁模型完全不同；Composer 等管理工具需要
  # 完整函数集（历史上 putenv 被禁时实测 PHP7 下 composer --version 都会喷
  # "putenv() has been disabled" Warning，把 verify 的版本比对打挂）。
  # php-cli.ini 与 php.ini 同目录、仅 CLI SAPI 自动加载，同指令覆盖 php.ini；
  # web 面（php-fpm/mod_php）仍按 php.ini 禁用，安全收口不受影响。
  local _cli_ini="$(dirname "$ini")/php-cli.ini"
  if [ "${DRY_RUN:-0}" = 1 ]; then
    log "  [dry-run] 将写入 CLI 专用配置: ${_cli_ini} (disable_functions 放开，仅 CLI 生效)"
  else
    cat > "$_cli_ini" <<'EOF'
; LNAMP: CLI 专用配置（仅 php-cli SAPI 自动加载，覆盖 php.ini）
; web 面（php-fpm/mod_php）仍按 php.ini 禁用危险函数；CLI 是管理员本地入口，
; 放开 disable_functions 以便 Composer 等管理工具正常运行（依赖 putenv 等）。
[PHP]
disable_functions =
EOF
    chmod 644 "$_cli_ini" 2>/dev/null || true
    log "已写入 CLI 专用配置: ${_cli_ini} (disable_functions 放开，仅 CLI 生效)"
  fi
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
  safe_mkdir "$(dirname "${PHP_FPM_SOCK}")" "${PREFIX_PHP}/var/run" "${PREFIX_PHP}/var/log"
  ensure_www_user 2>/dev/null || true
  chown -R www:www "${PREFIX_PHP}/var/log" 2>/dev/null || true

  # ---- FPM 错误日志：主进程日志用绝对路径；pool 显式指定 error_log 并捕获 worker 输出 ----
  #  否则 PHP 脚本产生的 warning/fatal 可能既不进 php.ini 的 error_log、也不进 FPM 主日志。
  _ini_set "$fpmconf" "error_log" "${PREFIX_PHP}/var/log/php-fpm.log"
  _ini_set "$www" "catch_workers_output" "yes"
  _ini_set "$www" "php_admin_value[error_log]" "${PREFIX_PHP}/var/log/php_errors.log"
  _ini_set "$www" "php_admin_flag[log_errors]" "on"

  # ---- 主池(默认站点)的 open_basedir ----
  #  没有这一行时，PHP 进程能 open() 整个文件系统：/etc/shadow、其他用户家目录、
  #  ~/.ssh、所有站点的 config.php 全部可读。open_basedir 是**进程级**限制，
  #  只能写在池里（php.ini 里写是对所有池生效的全局值，per-site 池需要各自的）。
  #
  #  这里给的是"整个站点根目录"而不是 ${WWWROOT}/web —— 主池历史上服务所有未拆池
  #  的站点，收得太紧会让升级后老站点直接 500（站点根不在白名单里）。真正的按站点
  #  隔离由 vhost 创建的独立池完成（见下方 per-site pool）。
  #  需要更严时可以:
  #    LNAMP_MAIN_OPEN_BASEDIR=/home/wwwroot/web   只允许默认站点
  #    LNAMP_SKIP_MAIN_OPEN_BASEDIR=1              完全不设（不推荐）
  if [ "${LNAMP_SKIP_MAIN_OPEN_BASEDIR:-0}" != 1 ]; then
    local _mainbd="${LNAMP_MAIN_OPEN_BASEDIR:-${WWWROOT}}"
    if [ -n "$_mainbd" ]; then
      safe_mkdir "${WWWROOT}" 2>/dev/null || true
      _ini_set "$www" "php_admin_value[open_basedir]" \
        "${_mainbd}:/tmp:${PREFIX_PHP}/var/log:${PREFIX_PHP}/var/lib/php/sessions"
      # session.save_path 要在白名单内且可写，否则 session 静默失效
      safe_mkdir "${PREFIX_PHP}/var/lib/php/sessions" 2>/dev/null || true
      chown www:www "${PREFIX_PHP}/var/lib/php/sessions" 2>/dev/null || true
    fi
  fi

  # systemd 单元：RuntimeDirectory=php 保证每次启动自动创建 /run/php
  local rundir; rundir="$(basename "$(dirname "${PHP_FPM_SOCK}")")"
  save_file "${SYSTEMD_DIR}/php-fpm.service" <<EOF
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

  # 日志轮转：php_errors.log / opcache_error.log / php-fpm.log
  # 日志由 www 属主，轮转后需保持可写，故加 su www www
  setup_logrotate php-fpm "${PREFIX_PHP}/var/log/*.log" "" "su www www"
}

# ===========================================================================
#  按站点隔离的 php-fpm 池 (per-site pool)
# ---------------------------------------------------------------------------
#  为什么需要：全局只有一个池时所有站点共用一个 open_basedir 范围。A 站点被
#  传了 webshell，攻击者可以直接读 /home/wwwroot/B/config.php 拿到 B 的数据库
#  口令 —— 一个站被打穿等于全部站被打穿。open_basedir 是**进程级**配置，只有
#  拆池才能按站点分别生效（php.ini 里设只能全局，全站互相可读，等于没设）。
#
#  做法：每个站点一份 php-fpm.d/<slug>.conf，独立 unix socket + 独立
#  open_basedir / session 目录 / 错误日志 / 慢日志；vhost 的 fastcgi_pass 指向它。
#  所有池仍然跑 www 用户 —— 目标是"读不到别的站点"，不是多租户强隔离
#  （那需要每站点一个系统用户 + 独立进程属主，会连带改站点属主，风险大得多）。
#
#  几个真机上踩过的点：
#   · open_basedir 必须包含 session.save_path 与 error_log 所在目录，否则 PHP
#     写会话/日志时被拒，表现为"登录状态莫名其妙丢失、错误日志是空的"，而且
#     **不报错**。当初排查了很久才发现是 open_basedir 把 /usr/local/php/var/log
#     挡在外面。
#   · /tmp 必须放行：upload_tmp_dir、sys_temp_dir 默认都在 /tmp。
#   · pool 名只能含 [A-Za-z0-9_]。域名里的点/短横线要替换，并且必须再拼一个
#     哈希后缀，否则 a-b.com 和 a.b.com 会归一化成同一个池名，两个站点抢一个
#     socket —— 表现为"其中一个站点打开是另一个站点的内容"。
#   · 建池顺序必须是：写文件 -> php-fpm -t -> reload -> 等 socket 出现 -> 再切
#     vhost。反过来会出现 reload 与 nginx 切换之间的窗口，站点 502。
# ===========================================================================

_PHP_FPM_ERR=""

_php_pool_dir() { printf '%s' "${LNAMP_FPM_POOL_DIR:-${PREFIX_PHP}/etc/php-fpm.d}"; }

# 域名 -> slug（只含 [A-Za-z0-9_]）。同一域名永远得到同一 slug，可反查。
_php_site_slug() {
  local d="$1" base h
  base=$(printf '%s' "$d" | tr -c 'A-Za-z0-9' '_' | cut -c1-28)
  h=$(printf '%s' "$d" | cksum | awk '{print $1}')
  printf 'site_%s_%s' "$base" "$h"
}

_php_site_sock() {
  printf '%s/%s.sock' "$(dirname "${PHP_FPM_SOCK}")" "$(_php_site_slug "$1")"
}

_php_site_sessdir() {
  printf '%s/var/lib/php/sessions/%s' "${PREFIX_PHP}" "$(_php_site_slug "$1")"
}

_php_fpm_bin() {
  if [ -x "${PREFIX_PHP}/sbin/php-fpm" ]; then printf '%s' "${PREFIX_PHP}/sbin/php-fpm"
  else command -v php-fpm 2>/dev/null; fi
}

# 校验 fpm 配置（含所有 pool）。没有 php-fpm 时视为通过，不阻断建站。
_php_fpm_test() {
  local bin conf out
  bin=$(_php_fpm_bin); [ -n "$bin" ] || return 0
  conf="${PREFIX_PHP}/etc/php-fpm.conf"
  if [ -f "$conf" ]; then
    out=$("$bin" -t -y "$conf" 2>&1) || { _PHP_FPM_ERR="$out"; return 1; }
  else
    out=$("$bin" -t 2>&1) || { _PHP_FPM_ERR="$out"; return 1; }
  fi
  _PHP_FPM_ERR=""
  return 0
}

_php_fpm_reload() {
  if [ "${DRY_RUN:-0}" = 1 ]; then log "  [dry-run] 将 reload php-fpm"; return 0; fi
  systemctl reload php-fpm 2>/dev/null && return 0
  systemctl reload php8-fpm 2>/dev/null && return 0
  local pid="${PREFIX_PHP}/var/run/php-fpm.pid"
  if [ -f "$pid" ]; then
    kill -USR2 "$(cat "$pid" 2>/dev/null)" 2>/dev/null && return 0
  fi
  return 1
}

# 生成 pool 配置（只写文件，不 reload）。
# $1 域名  $2 站点根  [$3 额外允许路径，冒号分隔]
_php_pool_write() {
  local domain="$1" webroot="$2" extra="${3:-}"
  local slug sock sess logdir inidir bd
  slug=$(_php_site_slug "$domain")
  sock=$(_php_site_sock "$domain")
  sess=$(_php_site_sessdir "$domain")
  logdir="${PREFIX_PHP}/var/log"
  inidir=$(_php_pool_dir)
  [ -n "$domain" ] && [ -n "$webroot" ] || { log_err "_php_pool_write: 缺少域名或站点根"; return 1; }

  bd="${webroot}:/tmp:${logdir}:${sess}"
  [ -n "$extra" ] && bd="${bd}:${extra}"

  safe_mkdir "$inidir" "$logdir" "$sess" "$(dirname "$sock")" || return 1
  chown www:www "$sess" "${logdir}/${slug}.error.log" 2>/dev/null || true
  chmod 0700 "$sess" 2>/dev/null || true
  : >> "${logdir}/${slug}.error.log" 2>/dev/null || true
  : >> "${logdir}/${slug}.slow.log"  2>/dev/null || true
  chown www:www "${logdir}/${slug}.error.log" "${logdir}/${slug}.slow.log" 2>/dev/null || true

  {
    echo "; 由 lnamp 自动生成 —— 站点 ${domain} 的独立 php-fpm 池"
    echo "; 重新生成: \$0 vhost rebind ${domain}    关闭隔离: \$0 vhost rebind ${domain} --shared"
    echo "[${slug}]"
    echo "user = www"
    echo "group = www"
    echo ""
    echo "listen = ${sock}"
    echo "listen.owner = www"
    echo "listen.group = www"
    echo "listen.mode = 0660"
    echo ""
    echo "; ondemand：闲置即回收，多站点时比 dynamic 省内存（代价是首个请求略慢）"
    echo "pm = ondemand"
    echo "pm.max_children = ${LNAMP_POOL_MAX_CHILDREN:-8}"
    echo "pm.process_idle_timeout = 10s"
    echo "pm.max_requests = 500"
    echo ""
    echo "chdir = ${webroot}"
    echo "catch_workers_output = yes"
    echo "request_terminate_timeout = 300s"
    echo "; 只允许执行 .php，避免 .phtml/.phar 之类被当脚本跑"
    echo "security.limit_extensions = .php"
    echo ""
    echo "; ---- 站点隔离：读不到本站根之外（/tmp 与本站日志、会话目录除外）----"
    echo "php_admin_value[open_basedir] = ${bd}"
    echo "php_admin_value[session.save_path] = ${sess}"
    echo "php_admin_value[upload_tmp_dir] = /tmp"
    echo "php_admin_value[sys_temp_dir] = /tmp"
    echo ""
    echo "php_admin_value[error_log] = ${logdir}/${slug}.error.log"
    echo "php_admin_flag[log_errors] = on"
    echo "slowlog = ${logdir}/${slug}.slow.log"
    echo "request_slowlog_timeout = 5s"
  } > "${inidir}/${slug}.conf.new" || return 1

  mv -f "${inidir}/${slug}.conf.new" "${inidir}/${slug}.conf" || return 1
  return 0
}

# 写 + 校验 + reload + 等 socket。成功时把 socket 路径放进全局 _PHP_SITE_SOCK。
# 注意不能用 stdout 返回：函数内部有 log_*（走 stdout），调用方 $(...) 会把它
# 一起吞进去，得到多行"路径"。
_php_pool_ensure() {
  local domain="$1" webroot="$2" extra="${3:-}" sock i
  _PHP_SITE_SOCK=""
  sock=$(_php_site_sock "$domain")

  if [ "${DRY_RUN:-0}" = 1 ]; then
    log "  [dry-run] 将生成站点池 $(_php_pool_dir)/$(_php_site_slug "$domain").conf (socket ${sock})"
    _PHP_SITE_SOCK="$sock"; return 0
  fi

  # 没有 php-fpm 就别写池：写了也没进程监听，还会让后面的"等 socket"白等 5 秒
  if [ -z "$(_php_fpm_bin)" ]; then
    log_warn "未找到 php-fpm 可执行文件，跳过站点池创建（该站点无 open_basedir 隔离）"
    return 1
  fi

  _php_pool_write "$domain" "$webroot" "$extra" || { log_err "站点池写入失败: ${domain}"; return 1; }

  if ! _php_fpm_test; then
    rm -f "$(_php_pool_dir)/$(_php_site_slug "$domain").conf"
    log_err "站点池配置未通过 php-fpm -t，已撤销: ${domain}"
    [ -n "$_PHP_FPM_ERR" ] && printf '%s\n' "$_PHP_FPM_ERR" | tail -3 | sed 's/^/    /' >&2
    return 1
  fi

  # 批量场景（vhost rebind --all）由调用方最后统一 reload 一次，避免每个站点
  # 都 reload 一遍 php-fpm（10 个站点就是 10 次 master 重载 + 10 次 socket 等待）
  if [ "${LNAMP_POOL_DEFER_RELOAD:-0}" = 1 ]; then
    _PHP_SITE_SOCK="$sock"; return 0
  fi

  _php_fpm_reload || log_warn "reload php-fpm 失败（服务未运行？），站点池已写入但可能未生效"

  i=0
  while [ "$i" -lt 50 ]; do
    [ -S "$sock" ] && break
    sleep 0.1; i=$((i + 1))
  done
  if [ ! -S "$sock" ]; then
    log_warn "等待 socket 超时: ${sock}（php-fpm 可能未运行；启动后站点会自动恢复）"
  fi

  _PHP_SITE_SOCK="$sock"
  return 0
}

# 删除站点池（归档，不硬删）。没有则静默返回 0。
_php_pool_remove() {
  local domain="$1" slug f arch dst
  slug=$(_php_site_slug "$domain")
  f="$(_php_pool_dir)/${slug}.conf"
  [ -f "$f" ] || return 0
  if [ "${DRY_RUN:-0}" = 1 ]; then
    log "  [dry-run] 将删除站点池: ${f}"
    return 0
  fi
  arch="${LNAMP_VHOST_ARCHIVE:-/var/lib/lnamp/vhost-archive}"
  if safe_mkdir "$arch" 2>/dev/null; then
    dst="${arch}/${slug}.conf.$(date +%Y%m%d_%H%M%S)"
    if mv -f "$f" "$dst" 2>/dev/null; then
      log "  已归档站点池: ${dst}"
    else
      rm -f "$f" 2>/dev/null || return 1
    fi
  else
    rm -f "$f" 2>/dev/null || return 1
  fi
  if _php_fpm_test; then _php_fpm_reload || true
  else log_warn "删除站点池后 php-fpm -t 失败（保留现场，请手动检查）"; fi
  return 0
}

# 读取某个池实际生效的 open_basedir（供 doctor/verify 校验）
_php_pool_open_basedir() {
  local domain="$1" f
  f="$(_php_pool_dir)/$(_php_site_slug "$domain").conf"
  [ -f "$f" ] || return 1
  awk -F'=[[:space:]]*' '/^[[:space:]]*php_admin_value\[open_basedir\]/{print $2; exit}' "$f"
}

# PHP 以 Apache 模块(mod_php)形式运行时的日志轮转（错误日志路径同 fpm 模式）
_php_logrotate_module() {
  setup_logrotate php-fpm "${PREFIX_PHP}/var/log/*.log" "" "su www www"
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
