#!/bin/bash
# ============================================================================
#  modules/redis.sh  ——  Redis 安装模块
#  install_redis <version> <mode>     mode = source | pkg
#  source -> 源码编译，安装到 /usr/local/redis，systemd 管理
#  pkg    -> 包管理器安装 (rhel: epel redis ; debian: redis-server)
#  注：安装 PHP 时会自动编译 phpredis 扩展，这里只负责 Redis 服务本身。
# ============================================================================

# 按实际构建产物裁剪 redis.conf 里的 loadmodule 行。
#   <redis.conf> <源码目录>
# Redis 8.x 的 conf 模板末尾带 "loadmodule ./modules/<name>.so" 段，这些 .so 需要
# cmake / rust-cargo 等额外工具链；编不出来却仍让 Redis 加载 => 启动即 abort。
# 策略：编出来的拷到 ${PREFIX_REDIS}/modules 并改绝对路径；缺失的注释掉并告警。
_redis_fix_loadmodules() {
  local rc="$1" src="$2" line p name abs
  [ -f "$rc" ] || return 0
  if [ "${DRY_RUN:-0}" = 1 ]; then
    log "  [dry-run] 将按实际产物裁剪 ${rc} 中的 loadmodule"
    return 0
  fi
  local tmp="${rc}.modules.$$"
  : > "$tmp" || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      loadmodule\ *)
        p=$(printf '%s' "$line" | awk '{print $2}')
        abs=""
        if [ -e "$p" ]; then
          abs="$p"
        elif [ -n "$src" ] && [ -e "$src/$p" ]; then
          name=$(basename "$p")
          safe_mkdir "${PREFIX_REDIS}/modules"
          cp -f "$src/$p" "${PREFIX_REDIS}/modules/$name" 2>/dev/null \
            && abs="${PREFIX_REDIS}/modules/$name"
        fi
        if [ -n "$abs" ]; then
          printf 'loadmodule %s\n' "$abs" >> "$tmp"
        else
          log_warn "Redis 模块 ${p:-?} 未构建成功，已在配置中禁用该 loadmodule（模块缺失不影响 Redis 核心功能）" >&2
          printf '# [lnamp] 模块未构建，已禁用: %s\n' "$line" >> "$tmp"
        fi
        continue ;;
    esac
    printf '%s\n' "$line" >> "$tmp"
  done < "$rc"
  mv -f "$tmp" "$rc"
  return 0
}

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
  cd_src ~ "cd ~"

  local tarball="redis-${ver}.tar.gz"
  fetch "$tarball" \
    "https://download.redis.io/releases/redis-${ver}.tar.gz" \
    "https://github.com/redis/redis/archive/refs/tags/${ver}.tar.gz" \
    || die "下载失败 (download failed): ${tarball}"
  local d; d=$(tar -tzf "$tarball" 2>/dev/null | head -1 | cut -d/ -f1); [ -n "$d" ] || d="redis-${ver}"
  tar -zxf "$tarball"; cd_src "$d" "cd redis src"

  # Redis 8.x 把 bloom / search / json / timeseries 等模块纳入源码树，默认 `make`
  # 会连模块一起编译；这些模块各自需要 cmake、rust/cargo 等额外工具链，缺失时
  # **核心其实已编好但 make 整体返回失败**。此时回落到只编核心
  # （`make build redis` —— scripts/build.sh 的 redis|core|none 语义），
  # 保证 Redis 本身装得上；模块缺失不影响 Redis 核心功能。
  # --redis-modules：连内置模块一起编。模块（bloom/search/json/timeseries）需要
  # cmake + Rust(cargo) 工具链，缺了必然失败 —— 提前检查并给出可执行的安装指引，
  # 别让它编到一半才报一堆 Rust 错误。
  if [ "${REDIS_MODULES:-0}" = 1 ]; then
    # 不只是"有没有"，还要看**版本够不够**（实测坑）：
    #   · redisearch 要求 cmake >= 3.25，Ubuntu 22.04 仓库只有 3.22.1 -> 直接判失败；
    #   · redisjson 的 Cargo.lock 是新格式，cargo 1.75 会报 "failed to parse lock file"。
    local miss=() _cm _cg
    _cm=$(cmake --version 2>/dev/null | head -1 | awk '{print $3}')
    _cg=$(cargo --version 2>/dev/null | awk '{print $2}')
    command -v cmake >/dev/null 2>&1 || miss+=(cmake)
    command -v cargo >/dev/null 2>&1 || miss+=(cargo)
    if command -v cmake >/dev/null 2>&1 && ! ver_ge "${_cm:-0}" "3.25"; then
      miss+=("cmake>=3.25(当前 ${_cm})")
    fi
    if command -v cargo >/dev/null 2>&1 && ! ver_ge "${_cg:-0}" "1.78"; then
      miss+=("cargo>=1.78(当前 ${_cg})")
    fi
    if [ ${#miss[@]} -gt 0 ]; then
      die "已指定 --redis-modules，但工具链不满足: ${miss[*]}。参考做法：
       cmake 3.25+：pip3 install -U cmake（或 Kitware 官方 apt 源）
       Rust 1.78+ ：curl https://sh.rustup.rs -sSf | sh -s -- -y --profile minimal
                    （发行版自带的 cargo 通常过旧，务必用 rustup；国内可加
                     RUSTUP_DIST_SERVER=https://mirrors.ustc.edu.cn/rust-static）
     装好后重跑本命令；不加 --redis-modules 则只编核心（默认，功能不受影响）。"
    fi
    log "按 --redis-modules 要求：连同内置模块一起编译（耗时较长）"
    log_run "make (with modules)" make -j "${THREAD}" || die_with_log "Redis 内置模块编译失败（可去掉 --redis-modules 只编核心）"
  else
    # 默认**直接只编核心**，不再"先试全量、失败再回落"：
    #   机器上装了 cmake + Rust 时，全量构建会先去拉 crates.io / GitHub（可能很慢
    #   甚至拉不动），白白多花十几分钟才失败。核心功能不需要模块，直接走确定性路径。
    log "默认只编译 Redis 核心（内置模块需 --redis-modules，见 --help）"
    log_run "make build redis" make -j "${THREAD}" build redis || die_with_log "Redis 核心编译失败"
  fi

  # 模块产物校验（只在显式要求时较真；默认构建只提示）
  local _so_n=0
  _so_n=$(find . -maxdepth 3 -name '*.so' -type f 2>/dev/null | wc -l | tr -d ' ')
  if [ "${REDIS_MODULES:-0}" = 1 ]; then
    [ "$_so_n" -gt 0 ] || die "Redis 模块编译未产出任何 .so，请检查上方 make 输出"
    log_ok "Redis 模块产物: ${_so_n} 个 .so（bloom/search/json/timeseries）"
  elif [ "$_so_n" -gt 0 ]; then
    log_ok "Redis 模块产物: ${_so_n} 个 .so 已编译"
  fi
  log_run "make install" make install PREFIX="${PREFIX_REDIS}" || true
  [ -x "${PREFIX_REDIS}/bin/redis-server" ] || die "Redis ${ver} 编译失败 (build failed)"

  detect_mem
  # 目录：配置/数据日志(var)/运行时(pid)
  safe_mkdir "${PREFIX_REDIS}/etc" "${PREFIX_REDIS}/var" /var/run/redis
  local rc="${PREFIX_REDIS}/etc/redis.conf"
  # maxmemory = 物理内存的 1/8（沿用常见做法：MEM_MB/8 再乘 1e6 字节）
  local redis_maxmemory="$(( MEM_MB / 8 ))000000"
  local redis_maxmemory_hint="$(( MEM_MB / 8 ))M"
  # 记住旧密码：否则重装会重新生成 requirepass，把线上客户端全部踢掉。
  # 判定条件不是"是否升级"，而是"配置里是否已有密码"：
  #   - 升级模式(LNAMP_UPGRADE=1)：显式保留；
  #   - 非升级但已有旧配置（重复安装 / 修复安装）：同样保留。
  #     重新生成密码会让所有已配置的客户端（PHPRedis/WordPress 等）连接失败，
  #     而用户重装通常只是修问题，并不想换密码。
  #   - 只有全新安装（配置不存在或没有密码）才生成新密码。
  local oldpass=""
  if [ -f "$rc" ]; then
    oldpass=$(sed -n 's/^[[:space:]]*requirepass[[:space:]]\+//p' "$rc" 2>/dev/null | head -1 | tr -d '\r')
    # 配置里只有注释掉的示例密码（foobared）时视为"无密码"
    case "$oldpass" in ""|foobared) oldpass="" ;; esac
  fi
  # 配置文件不在了但凭据文件还在（典型：uninstall 保留数据 -> 重装）：
  # 沿用凭据里的密码，保证保留下来的数据与既有客户端配置仍然匹配。
  if [ -z "$oldpass" ]; then
    local _cf="${REDIS_CRED_FILE:-${HOME:-/root}/.redis_password}"
    if [ -f "$_cf" ]; then
      oldpass=$(sed -n 's/.*password):[[:space:]]*\([^[:space:]]*\).*/\1/p; s/.*password:[[:space:]]*\([^[:space:]]*\).*/\1/p' "$_cf" 2>/dev/null | head -1 | tr -d '\r ')
    fi
    case "$oldpass" in ""|foobared) oldpass="" ;; esac
    [ -n "$oldpass" ] && log "沿用已有凭据文件里的 Redis 密码（重装不换密码）"
  fi
  # 干跑保护（重要）：下面的 cp/sed 会直接作用于线上配置文件
  # ${PREFIX_REDIS}/etc/redis.conf。干跑里如果照做，线上运行中的 Redis
  # 会被改写配置（尤其 requirepass），而干跑不会重启服务 ->
  # 配置里的密码与运行中进程持有的密码不一致 -> 客户端全部 WRONGPASS。
  # 因此干跑只打印将要做的配置改写，绝不碰真实文件。
  if [ "${DRY_RUN:-0}" = 1 ]; then
    log "  [dry-run] 将生成 Redis 配置: ${rc}"
    log "  [dry-run]   pidfile=/var/run/redis/redis.pid logfile=${PREFIX_REDIS}/var/redis.log dir=${PREFIX_REDIS}/var"
    if [ -f "$rc" ]; then
      log "  [dry-run]   已存在配置 -> 保留用户的 bind/maxmemory/protected-mode 等自定义，仅校正 pidfile/logfile/dir/daemonize"
    else
      log "  [dry-run]   全新配置 -> bind=127.0.0.1 protected-mode=yes maxmemory=${redis_maxmemory_hint}"
    fi
    log "  [dry-run]   requirepass：$( [ -n "$oldpass" ] && echo '保留原密码' || echo '生成随机密码' )"
  else
  # 首次安装：用原始模板生成配置。
  # 已有配置（重装/升级）：**不覆盖**用户配置。
  #   否则会把用户改过的 maxmemory / bind / protected-mode / 其它业务参数
  #   一律打回模板默认值，属于破坏性操作；密码也可能因此丢失。
  local _fresh_conf=0
  if [ ! -f "$rc" ]; then
    cp -f redis.conf "$rc"
    _fresh_conf=1
  else
    log_ok "已存在 Redis 配置，保留原有配置项（不覆盖用户的 maxmemory/bind 等自定义）"
  fi
  # 以下几项是"安装器必须管理"的运行参数（与用户业务配置无关），
  # 每次安装都校正；bind / protected-mode / maxmemory 属于用户可调项，
  # 仅在首次生成配置时设置，重装时保留用户已有的取值。
  sed -i 's@^pidfile.*@pidfile /var/run/redis/redis.pid@'           "$rc"
  sed -i "s@^logfile.*@logfile ${PREFIX_REDIS}/var/redis.log@"      "$rc"
  sed -i "s@^dir .*@dir ${PREFIX_REDIS}/var@"                       "$rc"
  sed -i 's@^daemonize no@daemonize yes@'                           "$rc"
  if [ "$_fresh_conf" = 1 ]; then
    # bind：原始模板里有若干条 bind 示例行（部分是注释），
    # 直接 sed 替换会留下多条生效的 bind（如 4 条 "bind 127.0.0.1"），
    # 配置含义混乱。这里统一"删掉所有 bind 行，再写唯一一条生效的"。
    sed -i '/^[[:space:]]*#\?[[:space:]]*bind[[:space:]]/d' "$rc"
    printf 'bind 127.0.0.1\n' >> "$rc"
    # 显式开启 protected-mode（与 bind 127.0.0.1 + requirepass 三重防护，避免未授权访问）
    if grep -qiE '^[[:space:]]*#?[[:space:]]*protected-mode' "$rc"; then
      sed -i 's@^[[:space:]]*#\?[[:space:]]*protected-mode.*@protected-mode yes@I' "$rc"
    else
      echo "protected-mode yes" >> "$rc"
    fi
    # maxmemory = 物理内存的 1/8（沿用常见做法：MEM_MB/8 再乘 1e6 字节）
    if ! grep -q '^maxmemory ' "$rc"; then
      if grep -q '^# *maxmemory <bytes>' "$rc"; then
        sed -i "s@^# *maxmemory <bytes>@# maxmemory <bytes>\nmaxmemory ${redis_maxmemory}@" "$rc"
      else
        echo "maxmemory ${redis_maxmemory}" >> "$rc"
      fi
    fi
  fi
  # 自动生成随机密码并写入配置（启动前设置，立即生效）
  if [ -n "$oldpass" ]; then
    # 保留旧密码。必须"写死一行"而不是靠 sed 替换：
    # 上一步 cp -f 用原始 redis.conf 覆盖了配置，而原始模板里的 requirepass
    # 可能只有注释行、也可能干脆没有该行，sed 匹配不到就会静默丢密码 ->
    # Redis 变成无密码（比密码不一致更危险：任何人都能连上）。
    # 这里先删掉所有 requirepass 行（含注释行），再明确追加一行，保证结果唯一。
    sed -i '/^[[:space:]]*#\?[[:space:]]*requirepass/d' "$rc"
    printf '\nrequirepass %s\n' "$oldpass" >> "$rc"
    log_ok "保留原有 Redis 密码（不重新生成，线上客户端不受影响）"
  else
    redis_set_random_password "$rc"
  fi
  fi   # end of non-dry-run config rewrite

  # Redis 8.x 的 redis.conf 末尾自带 ">>> BEGIN: loadmodule paths <<<" 段，
  # 指向源码树里 bloom/search/json/timeseries 的 .so（相对路径 ./modules/...）。
  # 这些模块需要 cmake、rust/cargo 等额外工具链，编不出来时 .so 不存在 ——
  # 而 **loadmodule 一个不存在的模块会让 Redis 直接 abort、服务永远起不来**
  # （日志: "Can't load module from ./modules/redisbloom/redisbloom.so: server aborting"）。
  # 因此按实际产物裁剪：编出来的拷到 ${PREFIX_REDIS}/modules 并改成绝对路径，
  # 没编出来的注释掉并告警——宁可少几个模块，也不能让 Redis 起不来。
  _redis_fix_loadmodules "$rc" "$(pwd)"

  log_run "redis: 目录属主" chown -R redis:redis "${PREFIX_REDIS}" /var/run/redis

  # daemonize yes -> systemd 用 forking 类型并管理 pidfile；RuntimeDirectory 自动建 /run/redis
  save_file "${SYSTEMD_DIR}/redis.service" <<EOF
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
# 用 SIGTERM 让 redis 自行优雅关闭（会落盘后退出）。
# 不用 'redis-cli shutdown'：设了 requirepass 后该命令需认证，不带密码会失败，
# 导致 systemctl stop 不可靠；而 SIGTERM 无需认证、最稳妥。
ExecStop=/bin/kill -s TERM \$MAINPID
TimeoutStopSec=30
Restart=always
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF
  enable_service redis
  open_ports "6379"
  # 一致性自愈：确认"配置里的 requirepass"就是"运行中的实例实际接受的密码"。
  # 若不一致（例如配置被外部改写、或上一轮安装改过配置但服务没重启），
  # 运行中的实例仍持有旧密码，客户端会一律 WRONGPASS —— 此时重启一次即可对齐。
  redis_verify_auth "$rc"
  # 日志轮转：redis.conf 里 logfile 指向 ${PREFIX_REDIS}/var/redis.log
  setup_logrotate redis "${PREFIX_REDIS}/var/*.log" "" "su redis redis"
  # 全部 redis 可执行文件软链到系统 PATH（redis-server/redis-cli/redis-benchmark/...）
  register_path redis "${PREFIX_REDIS}/bin" redis-server redis-cli
  ln -fs "${PREFIX_REDIS}"/bin/* /usr/local/bin/ 2>/dev/null
  cd ~ && safe_rm_rf "$d" "$tarball"
  log_ok "Redis ${ver} (source) 安装完成 (监听 127.0.0.1:6379, maxmemory=${redis_maxmemory})"
}

_redis_pkg() {
  local conf svc
  if [ "$OS_FAMILY" = debian ]; then
    pkg_update
    pkg_install redis-server
    svc=redis-server; conf=/etc/redis/redis.conf
  else
    ensure_epel
    pkg_install redis
    svc=redis
    conf=/etc/redis/redis.conf; [ -f "$conf" ] || conf=/etc/redis.conf
  fi
  # 自动生成随机密码 + 确保 protected-mode（发行版默认通常已为 yes，这里再确认一次）
  # 干跑保护：pkg 分支的 sed 直接作用于线上 /etc/redis/redis.conf，
  # 干跑时绝不能改（否则会污染正在运行的实例）。redis_set_random_password 内部已自带干跑保护。
  redis_set_random_password "$conf"
  if [ "${DRY_RUN:-0}" != 1 ] && [ -f "$conf" ]; then
    if grep -qiE '^[[:space:]]*#?[[:space:]]*protected-mode' "$conf"; then
      sed -i 's@^[[:space:]]*#\?[[:space:]]*protected-mode.*@protected-mode yes@I' "$conf"
    else
      echo "protected-mode yes" >> "$conf"
    fi
  fi
  enable_service "$svc"
  open_ports "6379"
  # 一致性自愈（pkg 分支同source 分支）
  redis_verify_auth "$conf"
  # 日志轮转：发行版默认日志路径（debian: /var/log/redis/redis-server.log；rhel: /var/log/redis/redis.log）
  setup_logrotate redis "/var/log/redis/*.log" "" "su redis redis"
  log_ok "Redis (${PM}) 安装完成"
}

# 一致性自愈：确认"配置里的 requirepass"就是"运行中的实例实际接受的密码"。
# 背景：配置里的 requirepass 与运行中进程持有的密码若不一致，
# 客户端一律 WRONGPASS（服务在监听、但谁都连不上），且现象极难排查。
# 这里用 redis-cli 带配置密码探活；认证失败则重启一次服务让新配置生效。
redis_verify_auth() {
  local conf="$1" rcli pass
  [ "${DRY_RUN:-0}" = 1 ] && return 0
  command -v systemctl >/dev/null 2>&1 || return 0
  [ -f "$conf" ] || return 0
  rcli="${PREFIX_REDIS}/bin/redis-cli"
  [ -x "$rcli" ] || rcli=$(command -v redis-cli 2>/dev/null)
  [ -n "$rcli" ] || return 0
  pass=$(sed -n 's/^[[:space:]]*requirepass[[:space:]]\+//p' "$conf" 2>/dev/null | head -1 | tr -d '\r')
  [ -n "$pass" ] || return 0
  # 服务还没起来时不误报（可能仍在启动中）
  systemctl is-active --quiet redis 2>/dev/null || \
    systemctl is-active --quiet redis-server 2>/dev/null || return 0
  if "$rcli" -h 127.0.0.1 -p 6379 -a "$pass" --no-auth-warning PING 2>/dev/null | grep -q PONG; then
    return 0
  fi
  log_warn "Redis 配置密码与运行中实例不一致，正在重启服务使其生效..."
  systemctl restart redis 2>/dev/null || systemctl restart redis-server 2>/dev/null
  sleep 2
  if "$rcli" -h 127.0.0.1 -p 6379 -a "$pass" --no-auth-warning PING 2>/dev/null | grep -q PONG; then
    log_ok "Redis 服务已重启，配置密码已生效"
  else
    log_warn "Redis 重启后仍无法用配置密码认证，请检查 ${conf} 与 redis 服务日志"
  fi
}

# 在指定 redis 配置文件里设置随机密码，并保存/打印
# 干跑保护（重要）：干跑模式绝不能真实改写配置。
# 否则会出现致命不一致：配置文件里的 requirepass 被换成新密码，
# 但运行中的 Redis 进程仍持有旧密码（干跑不会重启服务），
# 结果是配置密码 != 运行时密码 -> 客户端一律 WRONGPASS，服务形同瘫痪。
redis_set_random_password() {
  local conf="$1" pass
  # 凭据文件路径可注入（测试时指向临时目录，避免污染真实 /root）。
  # 兜底也按 HOME 拼：root 登录时仍是 /root/.redis_password；
  # 测试/沙箱里 HOME 被改到临时目录，即使忘了注入 REDIS_CRED_FILE 也不会
  # 把线上的 /root/.redis_password 覆盖成桩密码（曾真实发生过）。
  local credfile="${REDIS_CRED_FILE:-${HOME:-/root}/.redis_password}"
  if [ "${DRY_RUN:-0}" = 1 ]; then
    log "  [dry-run] 将为 Redis 生成随机密码并写入 ${conf}，同时保存到 ${credfile}"
    return 0
  fi
  pass=$(gen_password)
  if [ ! -f "$conf" ]; then
    log_warn "未找到 Redis 配置 ${conf}，已跳过自动设密码"
    return 0
  fi
  # 写入 requirepass：先删掉所有已有的 requirepass 行（含注释掉的示例行），
  # 再明确追加一行。这样不依赖"模板里恰好有 requirepass 占位行"，
  # 避免 sed 匹配不到时密码被静默丢弃 -> Redis 变成无密码。
  sed -i '/^[[:space:]]*#\?[[:space:]]*requirepass/d' "$conf"
  printf '\nrequirepass %s\n' "$pass" >> "$conf"
  ( umask 077; printf 'Redis 密码 (password): %s\n生成时间 (generated): %s\n' "$pass" "$(date)" > "$credfile" )
  chmod 600 "$credfile" 2>/dev/null
  REDIS_PASS="$pass"; export REDIS_PASS
  hr
  log_ok "Redis 已自动设置随机密码"
  log_ok "  密码 (password): ${pass}"
  log_ok "  已保存到 (saved to): ${credfile}  (chmod 600)"
  log_ok "  客户端连接示例: redis-cli -a '${pass}'"
  hr
}
