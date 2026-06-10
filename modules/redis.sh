#!/bin/bash
# ============================================================================
#  modules/redis.sh  ——  Redis 安装模块
#  install_redis <version> <mode>     mode = source | pkg
#  source -> 源码编译，安装到 /usr/local/redis，systemd 管理
#  pkg    -> 包管理器安装 (rhel: epel redis ; debian: redis-server)
#  注：安装 PHP 时会自动编译 phpredis 扩展，这里只负责 Redis 服务本身。
# ============================================================================

install_redis() {
  local ver="$1" mode="$2"
  log "安装 Redis ${ver}  形式(mode)=${mode}"
  case "$mode" in
    source) _redis_source "$ver" ;;
    pkg)    _redis_pkg ;;
    *)      die "redis: 未知形式 ${mode}" ;;
  esac
}

_redis_source() {
  local ver="$1"
  dep gcc gcc-c++ make wget pkgconfig
  ensure_sysuser redis
  cd ~ || die "cd ~"

  local tarball="redis-${ver}.tar.gz"
  fetch "$tarball" \
    "https://download.redis.io/releases/redis-${ver}.tar.gz" \
    "https://github.com/redis/redis/archive/refs/tags/${ver}.tar.gz" \
    || die "下载失败 (download failed): ${tarball}"
  local d; d=$(tar -tzf "$tarball" 2>/dev/null | head -1 | cut -d/ -f1); [ -n "$d" ] || d="redis-${ver}"
  tar -zxf "$tarball"; cd "$d" || die "cd redis src"

  make -j "${THREAD}" && make install PREFIX="${PREFIX_REDIS}"
  [ -x "${PREFIX_REDIS}/bin/redis-server" ] || die "Redis ${ver} 编译失败 (build failed)"

  detect_mem
  # 目录：配置/数据日志(var)/运行时(pid)
  mkdir -p "${PREFIX_REDIS}/etc" "${PREFIX_REDIS}/var" /var/run/redis
  cp -f redis.conf "${PREFIX_REDIS}/etc/redis.conf"
  local rc="${PREFIX_REDIS}/etc/redis.conf"
  sed -i 's@^pidfile.*@pidfile /var/run/redis/redis.pid@'           "$rc"
  sed -i "s@^logfile.*@logfile ${PREFIX_REDIS}/var/redis.log@"      "$rc"
  sed -i "s@^dir .*@dir ${PREFIX_REDIS}/var@"                       "$rc"
  sed -i 's@^daemonize no@daemonize yes@'                           "$rc"
  sed -i 's@^#\? *bind .*@bind 127.0.0.1@'                          "$rc"
  # maxmemory = 物理内存的 1/8（沿用常见做法：MEM_MB/8 再乘 1e6 字节）
  local redis_maxmemory="$(( MEM_MB / 8 ))000000"
  if ! grep -q '^maxmemory ' "$rc"; then
    if grep -q '^# *maxmemory <bytes>' "$rc"; then
      sed -i "s@^# *maxmemory <bytes>@# maxmemory <bytes>\nmaxmemory ${redis_maxmemory}@" "$rc"
    else
      echo "maxmemory ${redis_maxmemory}" >> "$rc"
    fi
  fi
  # 自动生成随机密码并写入配置（启动前设置，立即生效）
  redis_set_random_password "$rc"
  chown -R redis:redis "${PREFIX_REDIS}" /var/run/redis

  # daemonize yes -> systemd 用 forking 类型并管理 pidfile；RuntimeDirectory 自动建 /run/redis
  cat > "${SYSTEMD_DIR}/redis.service" <<EOF
[Unit]
Description=Redis In-Memory Data Store
After=network.target

[Service]
Type=forking
User=redis
Group=redis
RuntimeDirectory=redis
RuntimeDirectoryMode=0755
PIDFile=/var/run/redis/redis.pid
ExecStart=${PREFIX_REDIS}/bin/redis-server ${rc}
ExecStop=${PREFIX_REDIS}/bin/redis-cli shutdown
Restart=always
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF
  enable_service redis
  open_ports "6379"
  # 全部 redis 可执行文件软链到系统 PATH（redis-server/redis-cli/redis-benchmark/...）
  register_path redis "${PREFIX_REDIS}/bin" redis-server redis-cli
  ln -fs "${PREFIX_REDIS}"/bin/* /usr/local/bin/ 2>/dev/null
  cd ~ && rm -rf "$d" "$tarball"
  log_ok "Redis ${ver} (source) 安装完成 (监听 127.0.0.1:6379, maxmemory=${redis_maxmemory})"
}

_redis_pkg() {
  local conf svc
  if [ "$OS_FAMILY" = debian ]; then
    pkg_update
    pkg_install redis-server
    svc=redis-server; conf=/etc/redis/redis.conf
  else
    pkg_install epel-release
    pkg_install redis
    svc=redis
    conf=/etc/redis/redis.conf; [ -f "$conf" ] || conf=/etc/redis.conf
  fi
  # 自动生成随机密码
  redis_set_random_password "$conf"
  enable_service "$svc"
  open_ports "6379"
  log_ok "Redis (${PM}) 安装完成"
}

# 在指定 redis 配置文件里设置随机密码，并保存/打印
redis_set_random_password() {
  local conf="$1" pass; pass=$(gen_password)
  if [ ! -f "$conf" ]; then
    log_warn "未找到 Redis 配置 ${conf}，已跳过自动设密码"
    return 0
  fi
  if grep -qiE '^[[:space:]]*#?[[:space:]]*requirepass' "$conf"; then
    sed -i "s|^[[:space:]]*#\?[[:space:]]*requirepass.*|requirepass ${pass}|I" "$conf"
  else
    printf '\nrequirepass %s\n' "$pass" >> "$conf"
  fi
  ( umask 077; printf 'Redis 密码 (password): %s\n生成时间 (generated): %s\n' "$pass" "$(date)" > /root/.redis_password )
  chmod 600 /root/.redis_password 2>/dev/null
  REDIS_PASS="$pass"; export REDIS_PASS
  hr
  log_ok "Redis 已自动设置随机密码"
  log_ok "  密码 (password): ${pass}"
  log_ok "  已保存到 (saved to): /root/.redis_password  (chmod 600)"
  log_ok "  客户端连接示例: redis-cli -a '${pass}'"
  hr
}
