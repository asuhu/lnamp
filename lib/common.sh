#!/bin/bash
# ============================================================================
#  lib/common.sh  ——  公共函数库 (Shared helpers)
# ----------------------------------------------------------------------------
#  把原来分散在 20+ 个脚本里反复出现的逻辑集中到这里：
#  系统检测 / 内存分级 / 下载(带镜像回落) / 防火墙 / www 用户 / 日志 / 清单解析
#
#  Centralises logic that was copy-pasted across 20+ original scripts:
#  OS detection, memory tiers, download-with-fallback, firewall, www user,
#  logging, and version-manifest parsing.
# ============================================================================

# ----- 颜色输出 / coloured logging -----------------------------------------
_c() { printf '\033[%sm%s\033[0m' "$1" "$2"; }
log()      { echo -e "$(_c '0;36' '[*]') $*"; }
log_ok()   { echo -e "$(_c '0;32' '[OK]') $*"; }
log_warn() { echo -e "$(_c '0;33' '[!]') $*"; }
log_err()  { echo -e "$(_c '0;31' '[ERR]') $*" >&2; }
die()      { log_err "$*"; exit 1; }

# 70 字符分隔线
hr() { printf '%.0s-' {1..70}; echo; }

# 统一的编译日志：重型命令(configure/make 等)的 stdout+stderr 全部写入该文件
BUILD_LOG="${BUILD_LOG:-/tmp/lnamp_build.log}"
export BUILD_LOG

# 运行一条命令并把 stdout+stderr(2>&1) 追加到 BUILD_LOG；返回该命令的退出码。
# 用法: log_run <说明> <命令...>
log_run() {
  local desc="$1"; shift
  { echo; echo "==== [$(date '+%F %T')] ${desc}"; echo "+ $*"; } >> "$BUILD_LOG"
  "$@" >> "$BUILD_LOG" 2>&1
}

# 编译失败时，把日志末尾打印出来(会被上层 tee 记入组件日志)，再退出。
die_with_log() {
  local msg="$1"
  log_err "$msg —— 以下为构建日志末尾 (tail ${BUILD_LOG}):"
  tail -n 25 "$BUILD_LOG" 2>/dev/null | sed 's/^/    /' >&2
  die "$msg"
}

# CPU 线程数 (用于 make -j)
THREAD=$(nproc 2>/dev/null || grep -c "^processor" /proc/cpuinfo 2>/dev/null || echo 1)
export THREAD

# ----- 系统检测 / OS detection ---------------------------------------------
# 设置全局:
#   OS_ID       发行版 id (centos/rhel/rocky/almalinux/ubuntu/debian)
#   OS_FAMILY   系统家族 (rhel | debian)
#   OS_VER      主版本号 (7/8/9 或 22/24)
#   PM          包管理器 (yum | dnf | apt-get)
#   HAS_SYSTEMD 是否使用 systemd (1/0)
#   SYSTEMD_DIR 本地 systemd unit 目录
# 支持矩阵: CentOS/RHEL 7、Rocky/Alma/RHEL 8 9、Ubuntu 22 24
detect_os() {
  if [ -r /etc/os-release ]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    OS_ID="${ID:-unknown}"
    OS_VER="${VERSION_ID%%.*}"
    OS_PRETTY="${PRETTY_NAME:-$OS_ID $OS_VER}"
  else
    # 仅 CentOS/RHEL 6 及更早缺少 /etc/os-release —— 已不再支持
    die "无法识别系统：缺少 /etc/os-release。已停止支持 CentOS/RHEL 6 (no longer supported)"
  fi

  case "$OS_ID" in
    centos|rhel|rocky|almalinux|fedora|ol) OS_FAMILY=rhel ;;
    ubuntu|debian)                         OS_FAMILY=debian ;;
    *) die "不支持的发行版 (unsupported distro): ${OS_ID}" ;;
  esac

  # 明确拒绝 RHEL 系 6 及更早版本
  if [ "$OS_FAMILY" = rhel ] && [ "$OS_VER" -lt 7 ]; then
    die "已停止支持 CentOS/RHEL ${OS_VER} (no longer supported)。请使用 RHEL 7/8/9 系。"
  fi

  # 支持矩阵提示（矩阵外不阻止，尽力而为）
  case "${OS_FAMILY}:${OS_VER}" in
    rhel:7|rhel:8|rhel:9|debian:20|debian:22|debian:24) : ;;
    *) log_warn "未在测试矩阵内 (${OS_ID} ${OS_VER})，将尽力而为 (best-effort)";;
  esac

  # 包管理器：debian->apt；rhel 8+ ->dnf；rhel 7 ->yum
  if [ "$OS_FAMILY" = debian ]; then PM=apt-get
  elif [ "$OS_VER" -ge 8 ]; then PM=dnf
  else PM=yum
  fi

  [ -d /run/systemd/system ] && HAS_SYSTEMD=1 || HAS_SYSTEMD=0
  SYSTEMD_DIR=/etc/systemd/system   # 本地自定义 unit 的标准位置（各 systemd 发行版通用）

  export OS_ID OS_FAMILY OS_VER PM HAS_SYSTEMD SYSTEMD_DIR OS_PRETTY
  log "系统 (System): ${OS_PRETTY}  ->  family=${OS_FAMILY} ver=${OS_VER} pm=${PM} systemd=${HAS_SYSTEMD}"
}

# ----- 包管理抽象 / package manager abstraction ----------------------------
pkg_update() {
  case "$PM" in
    apt-get) DEBIAN_FRONTEND=noninteractive apt-get update -y >/dev/null 2>&1 || true ;;
    dnf|yum) $PM -y makecache >/dev/null 2>&1 || true ;;
  esac
}

pkg_install() {
  [ $# -gt 0 ] || return 0
  case "$PM" in
    apt-get) DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "$@" ;;
    dnf|yum) $PM -y install "$@" ;;
  esac
}

pkg_remove() {
  [ $# -gt 0 ] || return 0
  case "$PM" in
    apt-get) DEBIAN_FRONTEND=noninteractive apt-get remove -y "$@" >/dev/null 2>&1 || true ;;
    dnf|yum) $PM -y remove "$@"               >/dev/null 2>&1 || true ;;
  esac
}

# 把“逻辑依赖名(以 RHEL 命名为基准)”翻译成当前发行版的实际包名。
_dep_name() {
  local n="$1"
  if [ "$OS_FAMILY" = debian ]; then
    case "$n" in
      gcc-c++)                   echo g++ ;;
      pcre-devel)                echo libpcre3-dev ;;
      pcre|pcre2)                echo libpcre3 ;;
      zlib-devel)                echo zlib1g-dev ;;
      openssl-devel)             echo libssl-dev ;;
      libxml2-devel)             echo libxml2-dev ;;
      curl-devel|libcurl-devel)  echo libcurl4-openssl-dev ;;
      libjpeg-devel)             echo libjpeg-dev ;;
      libpng-devel)              echo libpng-dev ;;
      freetype-devel)            echo libfreetype6-dev ;;
      bzip2-devel)               echo libbz2-dev ;;
      gmp-devel)                 echo libgmp-dev ;;
      libxslt-devel)             echo libxslt1-dev ;;
      readline-devel)            echo libreadline-dev ;;
      oniguruma|oniguruma-devel) echo libonig-dev ;;
      sqlite-devel)              echo libsqlite3-dev ;;
      libzip-devel)              echo libzip-dev ;;
      libwebp-devel)             echo libwebp-dev ;;
      libtiff-devel)             echo libtiff-dev ;;
      expat-devel)               echo libexpat1-dev ;;
      ncurses-devel)             echo libncurses-dev ;;
      libaio-devel)              echo libaio-dev ;;
      libmcrypt-devel)           echo libmcrypt-dev ;;
      mhash-devel)               echo libmhash-dev ;;
      ImageMagick)               echo imagemagick ;;
      ImageMagick-devel)         echo libmagickwand-dev ;;
      pkgconfig)                 echo pkg-config ;;
      krb5-devel)                echo libkrb5-dev ;;
      openldap-devel)            echo libldap2-dev ;;
      cyrus-sasl-devel)          echo libsasl2-dev ;;
      net-snmp-devel)            echo libsnmp-dev ;;
      libicu-devel)              echo libicu-dev ;;
      perl-Module-Install)       echo "" ;;        # debian 无对应，跳过
      ncurses-compat-libs)       echo "" ;;        # 仅 rhel 需要
      *)                         echo "$n" ;;
    esac
  else
    case "$n" in
      libjpeg-devel) echo libjpeg-turbo-devel ;;
      *)             echo "$n" ;;
    esac
  fi
}

# 翻译并安装一组逻辑依赖。用法: dep gcc gcc-c++ openssl-devel ...
dep() {
  local out=() n m
  for n in "$@"; do m=$(_dep_name "$n"); [ -n "$m" ] && out+=("$m"); done
  pkg_install "${out[@]}"
}

require_root() {
  [ "$(id -u)" = "0" ] || die "必须以 root 运行 (You must be root)"
}

# ----- 内存分级 / memory tier ----------------------------------------------
# 设置 MEM_MB / MEM_LEVEL / MEMORY_LIMIT (PHP memory_limit, MB)。
# 这段逻辑原本在每个 php*.sh 里被复制了 6 次。
detect_mem() {
  MEM_MB=$(free -m | awk '/Mem/ {print $2}')
  if   [ "$MEM_MB" -le 640 ];  then MEM_LEVEL="<640M"; MEMORY_LIMIT=64
  elif [ "$MEM_MB" -le 1280 ]; then MEM_LEVEL=1G;  MEMORY_LIMIT=128
  elif [ "$MEM_MB" -le 2500 ]; then MEM_LEVEL=2G;  MEMORY_LIMIT=192
  elif [ "$MEM_MB" -le 3500 ]; then MEM_LEVEL=3G;  MEMORY_LIMIT=256
  elif [ "$MEM_MB" -le 4500 ]; then MEM_LEVEL=4G;  MEMORY_LIMIT=320
  elif [ "$MEM_MB" -le 8000 ]; then MEM_LEVEL=6G;  MEMORY_LIMIT=384
  else                              MEM_LEVEL=8G;  MEMORY_LIMIT=448
  fi
  export MEM_MB MEM_LEVEL MEMORY_LIMIT
}

# ----- 下载 (重试 + 超时 + 镜像回落) / robust download ---------------------
# 策略：对每个候选 URL 用 wget 重试 3 次(带超时)；官方源全部失败后，
#       自动追加镜像站(按文件名)再试。任一成功即返回 0；全部失败返回 1。
#
# fetch <输出文件名> <url1> [url2 ...]
#   调用方给出官方候选源，fetch 末尾会自动补上 MIRROR_PRIMARY / MIRROR_FALLBACK
#   下的同名文件作为兜底。这样“官方三次失败/超时 → 自动转镜像站”。
fetch() {
  local out="$1"; shift
  [ -n "$out" ] || { log_err "fetch: 缺少输出文件名"; return 1; }
  local base; base=$(basename "$out")
  local urls=("$@" "${MIRROR_PRIMARY}/${base}" "${MIRROR_FALLBACK}/${base}")
  local u
  for u in "${urls[@]}"; do
    [ -n "$u" ] || continue
    log "下载尝试 (try, 最多3次/超时30s): ${u}"
    if wget -4 --no-check-certificate \
            --tries=3 --timeout=30 --waitretry=5 --no-dns-cache \
            -q -O "$out" "$u"; then
      log_ok "下载成功 (downloaded): ${base}  <= ${u}"
      return 0
    fi
    log_warn "失败/超时，换下一个源 (failed/timeout, next source)"
  done
  rm -f "$out" 2>/dev/null
  return 1
}

# dl <镜像相对路径> [输出名]   —— 镜像优先(primary→fallback)，全部失败则退出
dl() {
  local path="$1" out="${2:-$(basename "$1")}"
  fetch "$out" "${MIRROR_PRIMARY}/${path}" "${MIRROR_FALLBACK}/${path}" \
    || die "下载失败 (download failed): ${path}"
}

# dl_url <官方URL> [输出名]   —— 官方源(3次/超时) → 自动回落镜像(按文件名)，全部失败退出
dl_url() {
  local url="$1" out="${2:-$(basename "$1")}"
  fetch "$out" "$url" || die "下载失败 (download failed): ${url}"
}

# dl_openssl <版本> [输出名]  —— OpenSSL 源码：GitHub 官方 Release → 镜像站
dl_openssl() {
  local ov="$1" out="${2:-openssl-${ov}.tar.gz}"
  fetch "$out" \
    "https://github.com/openssl/openssl/releases/download/openssl-${ov}/openssl-${ov}.tar.gz" \
    "${MIRROR_PRIMARY}/openssl-${ov}.tar.gz" "${MIRROR_FALLBACK}/openssl-${ov}.tar.gz" \
    || die "下载失败 (download failed): openssl-${ov}.tar.gz"
}

# ----- 随机密码 / random password ------------------------------------------
# 生成 16 位随机密码(仅字母数字，避免 SQL/shell 转义问题)
gen_password() {
  local p=""
  if command -v openssl >/dev/null 2>&1; then
    p=$(openssl rand -base64 32 2>/dev/null | tr -dc 'A-Za-z0-9' | head -c 16)
  fi
  [ -n "$p" ] && [ ${#p} -ge 12 ] || p=$(LC_ALL=C tr -dc 'A-Za-z0-9' < /dev/urandom 2>/dev/null | head -c 16)
  echo "$p"
}

# 等待数据库 socket 就绪(最多 ~40s)
_db_wait_socket() {
  local sock="$1" i
  for i in $(seq 1 40); do [ -S "$sock" ] && return 0; sleep 1; done
  return 1
}

# 为 MySQL/MariaDB 自动设置随机 root 密码并保存。
# 用法: db_set_random_root_password <client二进制> <凭据文件> <标签>
#   依赖：服务已启动、root 初始为空密码(由 *-install-db / --initialize-insecure 产生)。
db_set_random_root_password() {
  local client="$1" credfile="$2" label="$3" sock=/tmp/mysql.sock
  local pass; pass=$(gen_password)
  if ! _db_wait_socket "$sock"; then
    log_warn "${label} 未就绪，自动设密码已跳过；可稍后手动执行 mysql_secure_installation"
    return 0
  fi
  # MySQL 5.7/8 与 MariaDB 11 通用：root 初始为空/socket 认证，下面两种写法二选一成功即可
  if "$client" --socket="$sock" -uroot --connect-expired-password \
        -e "ALTER USER 'root'@'localhost' IDENTIFIED BY '${pass}'; FLUSH PRIVILEGES;" 2>/dev/null \
   || "$client" --socket="$sock" -uroot \
        -e "SET PASSWORD FOR 'root'@'localhost' = PASSWORD('${pass}'); FLUSH PRIVILEGES;" 2>/dev/null; then
    ( umask 077; printf '%s root 密码 (password): %s\n生成时间 (generated): %s\n' \
        "$label" "$pass" "$(date)" > "$credfile" ); chmod 600 "$credfile" 2>/dev/null
    DB_ROOT_PASS="$pass"; export DB_ROOT_PASS
    hr
    log_ok "${label} 已自动设置随机 root 密码"
    log_ok "  用户 (user): root"
    log_ok "  密码 (password): ${pass}"
    log_ok "  已保存到 (saved to): ${credfile}  (chmod 600)"
    hr
  else
    log_warn "${label} 自动设置 root 密码失败，请手动执行 mysql_secure_installation"
  fi
}

# ----- MySQL/MariaDB 配置生成 + 内存调优 -----------------------------------
# 生成 /etc/my.cnf。按 flavor(mysql/mariadb) 与版本自动取舍那些在 MySQL 8.x
# 已被移除/更名的指令（query_cache_*、expire_logs_days、innodb_log_files_in_group），
# 否则 mysqld 会拒绝启动。
# 用法: write_my_cnf <basedir> <datadir> <flavor> <version>
write_my_cnf() {
  local basedir="$1" datadir="$2" flavor="$3" ver="$4"
  local major="${ver%%.*}"

  # query cache：仅 MySQL 5.x 与 MariaDB 支持；MySQL 8.x 已移除
  local qcache=""
  if [ "$flavor" = mariadb ] || { [ "$flavor" = mysql ] && [ "$major" -lt 8 ]; }; then
    qcache=$'query_cache_type = 1\nquery_cache_size = 8M\nquery_cache_limit = 2M'
  fi
  # binlog 过期：MySQL 8.x 用 binlog_expire_logs_seconds（天数已移除）；其余用 expire_logs_days
  local binlog_expire innodb_loggrp=""
  if [ "$flavor" = mysql ] && [ "$major" -ge 8 ]; then
    binlog_expire="binlog_expire_logs_seconds = 8553600"   # 99 天
  else
    binlog_expire="expire_logs_days = 99"
    innodb_loggrp="innodb_log_files_in_group = 3"          # 8.x 已废弃，仅旧版/MariaDB 写入
  fi

  cat > /etc/my.cnf <<EOF
[client]
port = 3306
socket = /tmp/mysql.sock

[mysqld]
port = 3306
socket = /tmp/mysql.sock
basedir = ${basedir}
datadir = ${datadir}
pid-file = ${datadir}/mysql.pid
user = mysql
bind-address = 0.0.0.0
server-id = 1
init-connect = 'SET NAMES utf8mb4'
character-set-server = utf8mb4
skip-name-resolve
#skip-networking
back_log = 300
max_connections = 6000
max_connect_errors = 6000
open_files_limit = 65535
table_open_cache = 128
max_allowed_packet = 1024M
binlog_cache_size = 1M
max_heap_table_size = 8M
tmp_table_size = 16M
read_buffer_size = 2M
read_rnd_buffer_size = 8M
sort_buffer_size = 8M
join_buffer_size = 8M
key_buffer_size = 4M
myisam_sort_buffer_size = 8M
thread_cache_size = 8
${qcache}
ft_min_word_len = 4
log_bin = mysql-bin
binlog_format = mixed
${binlog_expire}
log_error = ${datadir}/mysql-error.log
slow_query_log = 1
long_query_time = 1
slow_query_log_file = ${datadir}/mysql-slow.log
performance_schema = 0
explicit_defaults_for_timestamp
lower_case_table_names = 1
skip-external-locking
default_storage_engine = InnoDB
#default-storage-engine = MyISAM
innodb_file_per_table = 1
innodb_open_files = 500
innodb_buffer_pool_size = 256M
innodb_write_io_threads = 4
innodb_read_io_threads = 4
innodb_thread_concurrency = 0
innodb_purge_threads = 1
innodb_flush_log_at_trx_commit = 2
innodb_log_buffer_size = 2M
innodb_log_file_size = 32M
${innodb_loggrp}
innodb_max_dirty_pages_pct = 90
innodb_lock_wait_timeout = 120
bulk_insert_buffer_size = 8M
interactive_timeout = 28800
wait_timeout = 28800

[mysqldump]
quick
max_allowed_packet = 1024M
EOF

  tune_my_cnf /etc/my.cnf
}

# 按内存大小调优 my.cnf 关键缓冲参数（沿用常见 LNMP 分级；<=1.5G 用基础值）
tune_my_cnf() {
  local cnf="$1"
  [ -n "$MEM_MB" ] || detect_mem
  local tcs qcs msb kbs ibp tts toc
  if   [ "$MEM_MB" -gt 1500 ] && [ "$MEM_MB" -le 2500 ]; then
    tcs=16; qcs=16M; msb=16M; kbs=16M;  ibp=128M;  tts=32M;  toc=256
  elif [ "$MEM_MB" -gt 2500 ] && [ "$MEM_MB" -le 3500 ]; then
    tcs=32; qcs=32M; msb=32M; kbs=64M;  ibp=512M;  tts=64M;  toc=512
  elif [ "$MEM_MB" -gt 3500 ]; then
    tcs=64; qcs=64M; msb=64M; kbs=256M; ibp=1024M; tts=128M; toc=1024
  else
    return 0   # <=1500M 保持基础配置
  fi
  sed -i "s@^thread_cache_size.*@thread_cache_size = ${tcs}@"             "$cnf"
  sed -i "s@^query_cache_size.*@query_cache_size = ${qcs}@"               "$cnf"
  sed -i "s@^myisam_sort_buffer_size.*@myisam_sort_buffer_size = ${msb}@" "$cnf"
  sed -i "s@^key_buffer_size.*@key_buffer_size = ${kbs}@"                 "$cnf"
  sed -i "s@^innodb_buffer_pool_size.*@innodb_buffer_pool_size = ${ibp}@" "$cnf"
  sed -i "s@^tmp_table_size.*@tmp_table_size = ${tts}@"                   "$cnf"
  sed -i "s@^table_open_cache.*@table_open_cache = ${toc}@"               "$cnf"
  log "已按内存(${MEM_MB}MB)调优数据库参数 (innodb_buffer_pool_size=${ibp} 等)"
}

# ----- www 用户 / service / firewall ----------------------------------------
# 创建系统用户 (无登录 shell)，自动选取 nologin 路径 (debian 在 /usr/sbin)。
ensure_sysuser() {
  local u="$1" nologin
  nologin=$(command -v nologin || echo /sbin/nologin)
  id -u "$u" >/dev/null 2>&1 || useradd -M -s "$nologin" "$u"
}
ensure_www_user() { ensure_sysuser www; }

# 开放端口，自动区分:
#   debian     -> ufw (仅当已启用)
#   rhel 7/8/9 -> firewalld (仅当运行中)
open_ports() {
  local p
  if [ "$OS_FAMILY" = debian ]; then
    if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -qi active; then
      for p in ${1//,/ }; do ufw allow "${p}/tcp" >/dev/null 2>&1; done
    fi
    return 0
  fi
  if systemctl is-active firewalld >/dev/null 2>&1; then
    for p in ${1//,/ }; do
      firewall-cmd --zone=public --add-port="${p}/tcp" --permanent >/dev/null 2>&1
    done
    firewall-cmd --reload >/dev/null 2>&1
  fi
}

# 注册并启用/启动服务 (systemd)。
# 用法: enable_service <名字>  (期望 unit 已写入 ${SYSTEMD_DIR}/<名>.service)
enable_service() {
  local name="$1"
  chmod 644 "${SYSTEMD_DIR}/${name}.service" 2>/dev/null
  systemctl daemon-reload
  systemctl enable "${name}.service" 2>/dev/null
  systemctl restart "${name}.service" 2>/dev/null || systemctl start "${name}.service" 2>/dev/null
}

# 在扫描目录写入扩展启用 ini（用 php-config 的绝对扩展目录，避免 extension_dir 不一致）
# 用法: php_enable_ext <ini名> <so文件> [zend]   zend=用 zend_extension(如 opcache)
php_enable_ext() {
  local name="$1" so="$2" zend="${3:-}" extdir ini key
  extdir=$("${PREFIX_PHP}/bin/php-config" --extension-dir 2>/dev/null)
  mkdir -p "${PREFIX_PHP}/etc/php.d"
  ini="${PREFIX_PHP}/etc/php.d/${name}.ini"
  key=extension; [ "$zend" = zend ] && key=zend_extension
  if [ -n "$extdir" ] && [ -f "${extdir}/${so}" ]; then
    echo "${key}=${extdir}/${so}" > "$ini"
  else
    echo "${key}=${so}" > "$ini"   # 回退：裸文件名(依赖 extension_dir)
  fi
}

# 重新加载 PHP 运行时（php-fpm / mod_php），使后续新增的扩展在 web 端(phpinfo)生效。
# 安装顺序上，php-fpm 可能在装扩展前已启动，必须重启才会重新读取 php.d/*.ini。
reload_php_runtime() {
  command -v systemctl >/dev/null 2>&1 || return 0
  if systemctl is-active --quiet php-fpm 2>/dev/null; then
    systemctl restart php-fpm 2>/dev/null && log "php-fpm 已重启以加载新扩展"
  fi
  systemctl is-active --quiet httpd   2>/dev/null && systemctl reload httpd   2>/dev/null && log "httpd 已重载以加载新扩展"
  systemctl is-active --quiet apache2 2>/dev/null && systemctl reload apache2 2>/dev/null && log "apache2 已重载以加载新扩展"
  return 0
}


# ----- 注册到系统 PATH / register into system PATH ------------------------
# 让源码/二进制安装的程序像系统命令一样直接调用（如 nginx -V、php -v）。
# 做两件事：
#   1) 写 /etc/profile.d/lnamp-<name>.sh —— 新登录 shell 自动加入该 bin 目录；
#   2) 把主要可执行文件软链到 /usr/local/bin（该目录已在默认 PATH 中），
#      当前 shell 立即可用，无需重新登录。
# 用法: register_path <name> <bindir> [主程序名...]
register_path() {
  local name="$1" bindir="$2"; shift 2
  [ -d "$bindir" ] || { log_warn "register_path: 目录不存在 ${bindir}"; return 0; }
  cat > "/etc/profile.d/lnamp-${name}.sh" <<EOF
export PATH=${bindir}:\$PATH
EOF
  chmod 644 "/etc/profile.d/lnamp-${name}.sh"
  mkdir -p /usr/local/bin
  local b
  for b in "$@"; do
    [ -x "${bindir}/${b}" ] && ln -sf "${bindir}/${b}" "/usr/local/bin/${b}"
  done
  case ":${PATH}:" in *":${bindir}:"*) : ;; *) export PATH="${bindir}:${PATH}" ;; esac
  hash -r 2>/dev/null || true
  log_ok "已加入系统 PATH (registered): ${bindir}  -> 可直接运行: $*"
}

# ----- 清单解析 / manifest parsing -----------------------------------------
# 在 <COMPONENT>_VERSIONS 数组里查找某版本，返回 "modes|meta"。
# 用法: entry=$(manifest_lookup NGINX 1.26.2)
manifest_lookup() {
  local comp="$1" ver="$2" arr line
  arr="${comp}_VERSIONS[@]"
  for line in "${!arr}"; do
    if [ "${line%%|*}" = "$ver" ]; then
      echo "${line#*|}"   # 去掉版本号，留下 "modes|meta"
      return 0
    fi
  done
  return 1
}

# 取得某版本支持的安装形式 (逗号分隔)。
manifest_modes() { local e; e=$(manifest_lookup "$1" "$2") || return 1; echo "${e%%|*}"; }

# 从 meta 字段取键值，如 meta_get "openssl=3.3.1;pcre=..." openssl -> 3.3.1
meta_get() {
  local meta="$1" key="$2" kv
  for kv in ${meta//;/ }; do
    [ "${kv%%=*}" = "$key" ] && { echo "${kv#*=}"; return 0; }
  done
  return 1
}

# 校验 "版本:形式" 选择是否合法 (版本存在 & 形式被支持)。
# 用法: validate_choice NGINX 1.26.2 source
validate_choice() {
  local comp="$1" ver="$2" mode="$3" modes
  modes=$(manifest_modes "$comp" "$ver") || die "${comp} 无此版本 (unknown version): ${ver}"
  [[ ",${modes}," == *",${mode},"* ]] || \
    die "${comp} ${ver} 不支持形式 '${mode}' (unsupported mode). 可用: ${modes}"
}

# 列出某组件全部可选版本+形式 (供菜单/帮助使用)。
list_versions() {
  local comp="$1" arr line ver modes meta
  arr="${comp}_VERSIONS[@]"
  for line in "${!arr}"; do
    ver="${line%%|*}"; modes="$(echo "$line" | cut -d'|' -f2)"; meta="$(echo "$line" | cut -d'|' -f3)"
    printf '    %-10s 形式(modes): %-18s %s\n' "$ver" "$modes" "$meta"
  done
}

# 解析 "版本:形式" 字符串，缺省时回落到组件默认值。
# 设置全局 PICK_VER / PICK_MODE。用法: parse_pick NGINX "1.26.2:source"
parse_pick() {
  local comp="$1" spec="$2" defv defm modes
  defv_var="${comp}_DEFAULT";      defv="${!defv_var}"
  defm_var="${comp}_DEFAULT_MODE"; defm="${!defm_var}"
  PICK_VER="${spec%%:*}"
  [ -z "$PICK_VER" ] && PICK_VER="$defv"
  modes=$(manifest_modes "$comp" "$PICK_VER") || die "${comp} 无此版本 (unknown version): ${PICK_VER}"
  if [[ "$spec" == *:* ]]; then
    PICK_MODE="${spec#*:}"
    # 兼容旧写法：yum 已更名为 pkg (跨发行版语义更准确)
    if [ "$PICK_MODE" = yum ]; then
      PICK_MODE=pkg
      log_warn "'yum' 形式已更名为 'pkg' (跨发行版)，已自动转换"
    fi
  else
    # 未指定形式：优先用组件默认形式；若该版本不支持，则回落到它支持的第一种
    if [[ ",${modes}," == *",${defm},"* ]]; then PICK_MODE="$defm"; else PICK_MODE="${modes%%,*}"; fi
  fi
  validate_choice "$comp" "$PICK_VER" "$PICK_MODE"
}
