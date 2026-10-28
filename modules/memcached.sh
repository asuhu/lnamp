#!/bin/bash
# ============================================================================
#  modules/memcached.sh  ——  Memcached 服务端 + PHP memcached 扩展
# ----------------------------------------------------------------------------
#  两个入口：
#    install_memcached <version> <mode>       服务端（source | pkg）
#    install_phpmemcached <version> <mode>    PHP 扩展（source，需 libmemcached）
#
#  安全默认：只监听 127.0.0.1，不开放防火墙端口 —— memcached 无认证机制，
#  暴露到公网等于把缓存直接送给任何人（历史上被用来放大 DDoS）。
#
#  内存上限取物理内存的 1/8（与 Redis 同一口径），下限 64MB、上限 4GB。
# ============================================================================

install_memcached() {
  local ver="$1" mode="$2"
  log "安装 Memcached ${ver}  形式(mode)=${mode}"
  case "$mode" in
    source) _memcached_source "$ver" ;;
    pkg)    _memcached_pkg ;;
    *)      die "memcached: 未知形式 ${mode}" ;;
  esac
}

# 计算 memcached 内存上限(MB)：MEM_MB/8，夹在 [64, 4096]
_memcached_mb() {
  [ -n "${MEM_MB:-}" ] || detect_mem
  local m=$(( MEM_MB / 8 ))
  [ "$m" -lt 64 ] && m=64
  [ "$m" -gt 4096 ] && m=4096
  echo "$m"
}

_memcached_source() {
  local ver="$1"
  # memcached 1.6 依赖 libevent
  if [ "$OS_FAMILY" = debian ]; then
    dep gcc gcc-c++ make libevent-dev wget
  else
    dep gcc gcc-c++ make libevent-devel wget
  fi
  ensure_sysuser memcached
  cd_src ~ "cd ~"

  local tarball="memcached-${ver}.tar.gz"
  fetch "$tarball" \
    "https://www.memcached.org/files/memcached-${ver}.tar.gz" \
    "https://github.com/memcached/memcached/archive/refs/tags/${ver}.tar.gz" \
    || die "下载失败 (download failed): ${tarball}"
  local d; d=$(tar -tzf "$tarball" 2>/dev/null | head -1 | cut -d/ -f1); [ -n "$d" ] || d="memcached-${ver}"
  tar -zxf "$tarball"; cd_src "$d" "cd memcached src"

  log_run "memcached: configure" ./configure --prefix="${PREFIX_MEMCACHED}" --enable-64bit
  log_run "memcached: make" make -j "${THREAD}" \
    && log_run "memcached: make install" make install
  # 干跑时二进制必然不存在，直接跳过校验，好让后面的配置/服务计划完整打印
  if [ "${DRY_RUN:-0}" != 1 ] && [ ! -x "${PREFIX_MEMCACHED}/bin/memcached" ]; then
    die "Memcached ${ver} 编译失败 (build failed)"
  fi

  local mb; mb=$(_memcached_mb)
  safe_mkdir "${PREFIX_MEMCACHED}/etc" "${PREFIX_MEMCACHED}/var"
  save_file "${PREFIX_MEMCACHED}/etc/memcached.conf" <<EOF
# 由 LNAMP 安装器生成 (managed by lnamp installer)
# memcached 无认证机制，务必只监听回环地址
-l 127.0.0.1
-p ${MEMCACHED_PORT}
-m ${mb}
-c 1024
-vv
# 日志走 systemd journal（journalctl -u memcached）
EOF
  log_run "memcached: 目录属主" chown -R memcached:memcached "${PREFIX_MEMCACHED}"

  save_file "${SYSTEMD_DIR}/memcached.service" <<EOF
[Unit]
Description=Memcached Memory Object Cache
After=network.target

[Service]
Type=simple
User=memcached
Group=memcached
ExecStart=${PREFIX_MEMCACHED}/bin/memcached -u memcached -l 127.0.0.1 -p ${MEMCACHED_PORT} -m ${mb} -c 1024
Restart=always
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF
  enable_service memcached
  register_path memcached "${PREFIX_MEMCACHED}/bin" memcached
  cd ~ && safe_rm_rf "$d" "$tarball"
  log_ok "Memcached ${ver} (source) 安装完成 (监听 127.0.0.1:${MEMCACHED_PORT}, -m ${mb}MB)"
}

_memcached_pkg() {
  local conf svc=memcached
  if [ "$OS_FAMILY" = debian ]; then
    pkg_update
    pkg_install memcached || die "memcached 安装失败（apt）"
    conf=/etc/memcached.conf
  else
    pkg_install epel-release >/dev/null 2>&1 || true
    pkg_install memcached || die "memcached 安装失败（EPEL 是否可用？）"
    conf=/etc/sysconfig/memcached
  fi
  local mb; mb=$(_memcached_mb)
  # 只改监听地址与内存上限，其余保持发行版默认
  if [ "$OS_FAMILY" = debian ]; then
    if [ -f "$conf" ]; then
      sed -i "s@^[[:space:]]*-l .*@-l 127.0.0.1@" "$conf"
      sed -i "s@^[[:space:]]*-m .*@-m ${mb}@"     "$conf"
    fi
  else
    save_file "$conf" <<EOF
PORT="11211"
USER="memcached"
MAXCONN="1024"
CACHESIZE="${mb}"
OPTIONS="-l 127.0.0.1"
EOF
  fi
  enable_service "$svc"
  log_ok "Memcached (${PM}) 安装完成 (监听 127.0.0.1:${MEMCACHED_PORT}, -m ${mb}MB)"
}

# ---------------------------------------------------------------------------
#  PHP memcached 扩展（pecl memcached）
#  依赖 libmemcached 库：RHEL 系 EPEL 的 libmemcached-devel，Debian 系 libmemcached-dev
#  PHP 5.6 只能用 2.2.0（3.x 要求 PHP 7.0+）
# ---------------------------------------------------------------------------
install_phpmemcached() {
  local ver="$1" mode="${2:-}"
  local phpize="${PREFIX_PHP}/bin/phpize" phpcfg="${PREFIX_PHP}/bin/php-config"
  # 干跑时 PHP 尚未安装（本次会装），放行以便打印下载/编译计划
  if { [ ! -x "$phpize" ] || [ ! -x "$phpcfg" ]; } && [ "${DRY_RUN:-0}" != 1 ]; then
    die "PHP memcached 扩展: 未检测到已编译的 PHP（${PREFIX_PHP}/bin）。请先安装 PHP，或在同一次运行中同时选择 PHP。"
  fi
  local major; major=$(php_major_version); [ -n "$major" ] || major=8
  if [ "$major" -le 5 ] && [ "$ver" != "2.2.0" ]; then
    log_warn "PHP ${major} 不支持 memcached ${ver}，自动改用 2.2.0"
    ver="2.2.0"
  fi
  if [ "$major" -ge 7 ] && [ "$ver" = "2.2.0" ]; then
    log_warn "PHP ${major} 建议用 memcached 3.x，2.2.0 为 PHP5 兼容版，继续但可能编译失败"
  fi

  log "编译 PHP memcached 扩展 ${ver}  (mode=${mode:-source})"
  if [ "$OS_FAMILY" = debian ]; then
    dep gcc gcc-c++ make autoconf pkg-config libmemcached-dev zlib1g-dev
  else
    pkg_install epel-release >/dev/null 2>&1 || true
    dep gcc gcc-c++ make autoconf pkgconfig libmemcached-devel zlib-devel
  fi

  cd_src ~ "cd ~"
  local tb="memcached-${ver}.tgz"
  fetch "$tb" "https://pecl.php.net/get/memcached-${ver}.tgz" \
    || die "下载失败 (download failed): ${tb}（pecl.php.net 不可达，可预放到 packages/）"
  # PECL 包首条目是 package.xml，源码目录在其后，故优先按 config.m4 定位源码目录
  local d; d=$(tar -tzf "$tb" 2>/dev/null | grep -m1 -E '^memcached-[^/]+/config\.m4$' | cut -d/ -f1)
  [ -n "$d" ] || d=$(tar -tzf "$tb" 2>/dev/null | awk -F/ 'NF>1 && $1!="package.xml" {print $1; exit}')
  [ -n "$d" ] || d="memcached-${ver}"
  tar -zxf "$tb"; cd_src "$d" "cd memcached ext src"

  log_run "php-memcached: phpize" "$phpize" \
    && log_run "php-memcached: configure" ./configure --with-php-config="$phpcfg" \
    && log_run "php-memcached: make" make -j "${THREAD}" \
    && log_run "php-memcached: make install" make install
  php_enable_ext memcached memcached.so
  cd ~ && safe_rm_rf "$d" "$tb"
  reload_php_runtime
  if [ "${DRY_RUN:-0}" = 1 ]; then
    log "  [dry-run] 将校验扩展是否加载: php -m | grep -qi '^memcached\$'"
    return 0
  fi
  if "${PREFIX_PHP}/bin/php" -m 2>/dev/null | grep -ci '^memcached$' >/dev/null; then
    log_ok "PHP memcached 扩展已启用"
  else
    log_warn "PHP memcached 扩展可能未编译成功，请检查上方日志（常见原因：缺 libmemcached-devel）"
  fi
}
