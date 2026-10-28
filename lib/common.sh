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
# 干跑下不该出现"[ERR] 编译失败"这类吓人的输出：源码根本没解压，必然编译不过。
# 此时把 die 转成一条中性的"校验点(干跑跳过)"提示，并以 0 退出当前子 shell
# （install_* 都在 pipeline 子 shell 里跑，exit 只影响该组件，不影响整体预览）。
die() {
  if [ "${DRY_RUN:-0}" = 1 ]; then
    log "  [dry-run] 校验点(干跑跳过，真实安装不满足则中止): $*"
    exit 0
  fi
  log_err "$*"; exit 1
}

# 70 字符分隔线
hr() { printf '%.0s-' {1..70}; echo; }

# 统一的编译日志：重型命令(configure/make 等)的 stdout+stderr 全部写入该文件
BUILD_LOG="${BUILD_LOG:-/tmp/lnamp_build.log}"
export BUILD_LOG

# 数据库主配置路径。默认 /etc/my.cnf，可用 MY_CNF_PATH 覆盖：
#   - 测试环境把它指到临时目录，避免跑测试时污染宿主机的 /etc/my.cnf
#   - 特殊部署(容器、非标准路径)也可复用
MY_CNF_PATH="${MY_CNF_PATH:-/etc/my.cnf}"
export MY_CNF_PATH

# ld.so 配置目录。默认 /etc/ld.so.conf.d，可用 LDSO_CONF_DIR 覆盖（测试用它隔离宿主）。
LDSO_CONF_DIR="${LDSO_CONF_DIR:-/etc/ld.so.conf.d}"
export LDSO_CONF_DIR

# 运行一条命令并把 stdout+stderr(2>&1) 追加到 BUILD_LOG；返回该命令的退出码。
# 用法: log_run <说明> <命令...>
# 干跑模式下只把命令写进计划，不实际执行。
log_run() {
  local desc="$1"; shift
  if [ "${DRY_RUN:-0}" = 1 ]; then
    log "  [dry-run] 将执行: ${desc}  ->  $*"
    return 0
  fi
  { echo; echo "==== [$(date '+%F %T')] ${desc}"; echo "+ $*"; } >> "$BUILD_LOG"
  "$@" >> "$BUILD_LOG" 2>&1
}

# 编译失败时，把日志末尾打印出来(会被上层 tee 记入组件日志)，再退出。
# 干跑下源码未解压、必然编译不过，此时不打印构建日志、按中性提示处理。
die_with_log() {
  local msg="$1"
  if [ "${DRY_RUN:-0}" = 1 ]; then
    log "  [dry-run] 真实安装会在此中止: ${msg}"
    exit 0
  fi
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
  # 按 OS_ID 精确匹配：Ubuntu 与 Debian 同属 debian 家族但版本号体系不同
  # （Ubuntu 20/22/24 vs Debian 11/12/13），混用会让真正的 Debian 11/12
  # 被误报成"未在测试矩阵内"。
  case "${OS_ID}:${OS_VER}" in
    rhel:7|rhel:8|rhel:9|rocky:7|rocky:8|rocky:9|centos:7|centos:8|almalinux:8|almalinux:9|debian:11|debian:12|debian:13|ubuntu:20|ubuntu:22|ubuntu:24) : ;;
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
  [ "${DRY_RUN:-0}" = 1 ] && { log "  [dry-run] 将刷新包索引 (pkg_update)"; return 0; }
  case "$PM" in
    apt-get) DEBIAN_FRONTEND=noninteractive apt-get update -y >/dev/null 2>&1 || true ;;
    dnf|yum) $PM -y makecache >/dev/null 2>&1 || true ;;
  esac
}

# 等待 dpkg 前端锁释放。Debian/Ubuntu 上并发的 apt（unattended-upgrades、镜像
# 初始化脚本、人工 apt-get）会让 apt-get install 立刻失败：
#   "Could not get lock /var/lib/dpkg/lock-frontend ... is another process using it?"
# 此时依赖一个都装不上，后续编译必然因缺 pkg-config 等而失败，且失败点离根因很远。
# fuser 缺失(无 psmisc)时直接放行，由 pkg_install 的重试兜底。
_apt_wait_lock() {
  command -v fuser >/dev/null 2>&1 || return 0
  local i
  for i in $(seq 1 60); do
    fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1 || return 0
    sleep 5
  done
  return 1
}

pkg_install() {
  [ $# -gt 0 ] || return 0
  [ "${DRY_RUN:-0}" = 1 ] && { log "  [dry-run] 将安装系统包: $*"; return 0; }
  case "$PM" in
    apt-get)
      _apt_wait_lock || log_warn "dpkg 锁仍被占用，继续尝试（可能失败）"
      local _i
      for _i in 1 2 3; do
        DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "$@" && return 0
        sleep 5; _apt_wait_lock
      done
      return 1 ;;
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

# 判断某个 locale 名在当前系统是否可用。
# 注意：不能用 "LC_ALL=x locale" 的退出码判断 —— locale(1) 在 locale 不可用时
# 仍返回 0（只在 stderr 打印 "Cannot set LC_ALL ..."）。改为与 locale -a 列表
# 归一化比对（大小写/别名：en_US.UTF-8 -> en_us.utf8，C.UTF-8 -> c.utf8）。
_locale_available() {
  local want="${1:-}" l nw
  [ -n "$want" ] || return 1
  nw=$(printf '%s' "$want" | tr 'A-Z' 'a-z' | sed 's/utf-8/utf8/g')
  # 一次归一化整张表再精确比对。
  # 原实现对每一行 locale 都 fork 两次（tr + sed）：`locale -a` 有 700+ 条时，
  # 单次调用就是上千个进程，在慢环境（Windows/Git Bash、低配容器）里表现为
  # "卡死"——实测 install 卡在这里 60s 以上，被误判成死锁。
  # 归一化后的整表缓存一次：locale -a 本身在慢环境就要 2s（枚举几百条），
  # 而 ensure_locale 会对多个候选依次调用本函数
  if [ -z "${_LN_LOCALE_LIST:-}" ]; then
    _LN_LOCALE_LIST=$(locale -a 2>/dev/null | tr 'A-Z' 'a-z' | sed 's/utf-8/utf8/g')
  fi
  l="$_LN_LOCALE_LIST"
  [ -n "$l" ] || return 1
  # 用 grep -c 而不是 -q：pipefail 下 -q 提前退出会让上游收到 SIGPIPE
  printf '%s\n' "$l" | grep -Fxc "$nw" >/dev/null 2>&1
}

# 确保系统有一个"可用"的 UTF-8 locale，否则服务可能起不来。
# 背景：极简镜像 / 云镜像常在 /etc/locale.conf 写着 LANG="en_US.UTF-8"，
# 但并没有真正生成该 locale（locale -a 里只有 C / C.utf8 / POSIX）。
# 此时 setlocale(LC_COLLATE,"") 返回 NULL，Redis 7.4+ 会在启动时直接退出：
#   # Failed to configure LOCALE for invalid locale name.
# 表现为 systemd 反复重启（Restart=always）、服务永远不 active、端口不监听。
# 策略：locale 不可用 -> ① localedef 就地生成；② 不行就装语言包(glibc-langpack-en/locales)再生成；
# ③ 仍不行 -> 回退到 glibc 内建的 C.utf8；并同步 /etc/locale.conf 与 systemd 管理器环境。
ensure_utf8_locale() {
  [ "${DRY_RUN:-0}" = 1 ] && { log "  [dry-run] 将确保系统存在可用的 UTF-8 locale"; return 0; }
  local cur name lang charmap
  cur=$(sed -n 's/^[[:space:]]*LANG[[:space:]]*=[[:space:]]*"\?\([^"]*\)"\?.*/\1/p' \
        /etc/locale.conf 2>/dev/null | head -1)
  [ -n "$cur" ] || cur="${LANG:-}"
  [ -n "$cur" ] || cur="en_US.UTF-8"
  _locale_available "$cur" && return 0

  name="$cur"; lang="${cur%%.*}"
  case "$cur" in
    *UTF-8|*utf8|*UTF8) charmap=UTF-8 ;;
    *) charmap= ;;
  esac
  # ① 直接 localedef（locale 源文件/charset 已就位时可用）
  if [ -n "$charmap" ] && command -v localedef >/dev/null 2>&1; then
    localedef -i "$lang" -f "$charmap" "$name" >/dev/null 2>&1 || true
  fi
  # ② minimal 镜像缺 charmap/源文件 -> 装对应语言包再生成
  if ! _locale_available "$name" && [ -n "$charmap" ] && command -v localedef >/dev/null 2>&1; then
    case "${OS_FAMILY:-}" in
      rhel)   pkg_install glibc-langpack-en >/dev/null 2>&1 || true ;;
      debian) pkg_install locales >/dev/null 2>&1 || true ;;
    esac
    localedef -i "$lang" -f "$charmap" "$name" >/dev/null 2>&1 || true
  fi
  if _locale_available "$name"; then
    log_ok "已生成缺失的 locale: ${name}"
  elif _locale_available "C.utf8"; then
    name="C.utf8"
    log_warn "locale ${cur} 不可用（且无法生成），已回退为 C.utf8"
  else
    log_warn "系统无可用 UTF-8 locale，服务启动可能受影响"
    return 0
  fi
  case "${OS_FAMILY:-}" in
    rhel)   save_file /etc/locale.conf <<EOF
LANG="${name}"
EOF
      ;;
    debian) save_file /etc/default/locale <<EOF
LANG=${name}
EOF
      ;;
  esac
  export LANG="$name" LC_ALL="$name"
  if command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]; then
    systemctl set-environment LANG="$name" LC_ALL="$name" >/dev/null 2>&1 || true
  fi
  log_ok "系统 locale 已就绪: ${name}"
}

# RHEL 系：确保 EPEL 仓库可用。
# 背景：epel-release 包放在 Extras 仓里，而 CentOS Stream 8 没有 Extras 仓，
# 直接 `dnf install epel-release` 会报 "No match for argument" 并返回非零 ——
# 若调用点不容错，整套安装会被打断。但 EPEL 只提供 memcached/fail2ban 等可选组件，
# 不该因此中断主流程。
# 策略：先装 epel-release 包（RHEL/CentOS 7/8/9 常规路径）；装不到就直接写仓库文件
# （按主版本选镜像），仍失败只告警。
ensure_epel() {
  [ "${OS_FAMILY:-}" = rhel ] || return 0
  [ "${DRY_RUN:-0}" = 1 ] && { log "  [dry-run] 将确保 EPEL 仓库可用"; return 0; }
  # 已有 EPEL 仓库文件就不重复配置
  ls /etc/yum.repos.d/epel*.repo >/dev/null 2>&1 && return 0
  if pkg_install epel-release >/dev/null 2>&1; then
    log_ok "EPEL 仓库已就绪 (epel-release)"
    return 0
  fi
  local m="${OS_VER:-8}" url=""
  case "$m" in
    7) url="https://mirrors.aliyun.com/epel-archive/7/Everything/x86_64" ;;
    8) url="https://mirrors.aliyun.com/epel/8/Everything/x86_64" ;;
    9) url="https://mirrors.aliyun.com/epel/9/Everything/x86_64" ;;
    *) url="https://mirrors.aliyun.com/epel/${m}/Everything/x86_64" ;;
  esac
  if save_file /etc/yum.repos.d/epel-installer.repo <<EOF
[epel]
name=Extra Packages for Enterprise Linux ${m} - \$basearch
baseurl=${url}
gpgcheck=0
enabled=1
EOF
  then
    log_ok "EPEL 仓库已配置: ${url}（epel-release 包不可用，已直接写入仓库文件）"
  else
    log_warn "EPEL 仓库配置失败，可选组件（memcached/fail2ban 等）可能装不上"
  fi
  return 0
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
      libtool-ltdl-devel)        echo libltdl-dev ;;   # ImageMagick --with-modules 必需
      libvpx-devel)              echo libvpx-dev ;;
      libtiff-devel)             echo libtiff-dev ;;
      expat-devel)               echo libexpat1-dev ;;
      ncurses-devel)             echo libncurses-dev ;;
      libaio-devel)              echo libaio-dev ;;
      numactl-libs)              echo libnuma1 ;;      # debian/ubuntu: mysqld/mariadbd 链接 libnuma.so.1
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
      xz)                        echo xz-utils ;;
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
  # 解包三件套是所有源码安装的前置，却**不在**任何模块的依赖列表里：
  # RHEL/Rocky 最小化镜像可以没有 tar（实测 Rocky 9.8 连 tar 都没有），
  # Ubuntu minimal 也可能缺 xz。缺了的表现是下载完成后 `tar: command not found`，
  # 错误埋在编译日志里很难定位。这里保证"任何一次 dep 调用都先把它们装上"，
  # 只做一次；装不上只告警，不改变调用方对后续包安装结果的判断。
  local out=() n m b bt=()
  if [ "${_LNAMP_BASE_TOOLS:-0}" != 1 ]; then
    for b in tar gzip xz; do
      m=$(_dep_name "$b"); [ -n "$m" ] && bt+=("$m")
    done
    if pkg_install "${bt[@]}" >/dev/null 2>&1; then
      export _LNAMP_BASE_TOOLS=1
    else
      log_warn "基础工具 (${bt[*]}) 安装失败，后续解包可能报 command not found"
      # 同理不用 $OS_FAMILY 判断（它可能还没被 detect_os 赋值）
      if command -v apt-get >/dev/null 2>&1; then
        log_warn "  手动修复: apt-get install -y tar gzip xz-utils"
      else
        log_warn "  手动修复: dnf install -y tar gzip xz"
      fi
    fi
  fi
  for n in "$@"; do m=$(_dep_name "$n"); [ -n "$m" ] && out+=("$m"); done
  [ "${#out[@]}" -eq 0 ] && return 0
  pkg_install "${out[@]}"
}

# ----- 现代 C++ 工具链 (C++14+) / modern C++ toolchain -----------------------
# 背景：RHEL/CentOS 7 自带的 gcc 4.8.5 只支持到 C++11，且其 libstdc++ 没有
# C++14 的库特性（std::exchange / std::make_unique 等）。Swoole 6.x 起需要
# C++14，在该系统上直接编译必失败 —— 注意换 -std=c++1y 也救不了：缺的是
# **库**特性而不是语言特性。RHEL 7 上唯一的官方升级路径是 SCL devtoolset
# （gcc 7~11），RHEL 8+/Debian 11+ 自带 gcc 8+ 无需处理。
#
#   cxx14_ok [编译器]       该 g++ 能否编译**并运行** C++14 代码（编译+运行双测）
#   ensure_cxx14_toolchain  确保系统有可用 C++14 编译器。成功时在 stdout 打印
#                           devtoolset 的 enable 脚本路径（系统 g++ 够用时打印空行），
#                           失败返回 1。调用方 `source` 该脚本即可用上新编译器。
_cxx14_ok() {
  local cxx="${1:-g++}" tmpd
  command -v "$cxx" >/dev/null 2>&1 || return 1
  tmpd=$(mktemp -d 2>/dev/null) || return 1
  cat > "$tmpd/t.cc" <<'EOF'
#include <utility>
int main() { int a = 1; return (std::exchange(a, 2) == 1 && a == 2) ? 0 : 1; }
EOF
  if "$cxx" -std=c++14 "$tmpd/t.cc" -o "$tmpd/t" >/dev/null 2>&1 \
     && "$tmpd/t" >/dev/null 2>&1; then
    rm -rf "$tmpd"; return 0
  fi
  rm -rf "$tmpd"; return 1
}

ensure_cxx14_toolchain() {
  if [ "${DRY_RUN:-0}" = 1 ]; then
    log "  [dry-run] 将确保系统具备 C++14 编译器（必要时安装 SCL devtoolset）"
    echo ""; return 0
  fi
  # ① 系统 g++ 已经够用（RHEL 8+/Debian 11+ 默认 gcc 8+；CentOS 7 是 4.8.5）
  if _cxx14_ok g++; then echo ""; return 0; fi
  # ② 以前装过 devtoolset：按版本从新到旧找一个能用的
  local d v
  for v in 15 14 13 12 11 10 9 8 7; do
    d="/opt/rh/devtoolset-${v}"
    if [ -x "$d/root/usr/bin/g++" ] && _cxx14_ok "$d/root/usr/bin/g++"; then
      echo "$d/enable"; return 0
    fi
  done
  # ③ RHEL 7 系：安装 SCL devtoolset（SCLO 仓库）
  if [ "${OS_FAMILY:-}" = rhel ] && [ "${OS_VER:-0}" -le 7 ]; then
    log "系统 g++ 不支持 C++14，自动安装 SCL devtoolset (RHEL ${OS_VER} 官方工具链升级路径)"
    if ! ls /etc/yum.repos.d/*[Ss][Cc][Ll]*.repo >/dev/null 2>&1; then
      pkg_install centos-release-scl >/dev/null 2>&1 || true
    fi
    if ! yum -q --showduplicates list devtoolset-11-gcc-c++ >/dev/null 2>&1; then
      save_file /etc/yum.repos.d/CentOS-SCLo-rh.repo <<'EOF'
[centos-sclo-rh]
name=CentOS-7 - SCLo rh
baseurl=https://mirrors.aliyun.com/centos/7/sclo/x86_64/rh/
gpgcheck=0
enabled=1

[centos-sclo-sclo]
name=CentOS-7 - SCLo sclo
baseurl=https://mirrors.aliyun.com/centos/7/sclo/x86_64/sclo/
gpgcheck=0
enabled=1
EOF
      pkg_update
    fi
    for v in 11 10 9 8 7; do
      if pkg_install "devtoolset-${v}-gcc-c++" >/dev/null 2>&1; then
        d="/opt/rh/devtoolset-${v}"
        if [ -x "$d/root/usr/bin/g++" ] && _cxx14_ok "$d/root/usr/bin/g++"; then
          log_ok "已安装 devtoolset-${v} (gcc $($d/root/usr/bin/g++ -dumpversion 2>/dev/null))"
          echo "$d/enable"; return 0
        fi
        log_warn "devtoolset-${v} 装完仍不可用，尝试更低版本"
      fi
    done
  else
    log_warn "系统 g++ 不支持 C++14，且不是 RHEL 7 系（无 SCL devtoolset 可自动安装）"
    log_warn "请先升级 gcc（RHEL 8+ / Debian 11+ 默认即可），或改用不需要 C++14 的组件版本"
  fi
  return 1
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

# ----- 下载 (本地缓存 → 官方源 → 自己的镜像) / robust download ------------
# 优先级 (priority order)：
#   1) 本地缓存 packages/ 或 $LNAMP_CACHE（命中即用，完全不联网）
#   2) 调用方给出的官方源（$@）—— 官方优先，保证包的真实性与新鲜度
#   3) 自己的镜像 MIRROR_PRIMARY / MIRROR_FALLBACK（按文件名，兼顾根目录与 so/ 子目录）
#      —— 官方源不可达(超时/被墙/404)时才回落，作为国内加速兜底
#
# fetch <输出文件名> [官方url1] [官方url2 ...]
#   调用方只需给官方候选源；本地缓存与镜像由 fetch 统一按上面的优先级补齐。
fetch() {
  local out="$1"; shift
  [ -n "$out" ] || { log_err "fetch: 缺少输出文件名"; return 1; }
  local base; base=$(basename "$out")

  # 1) 本地离线缓存优先 (local cache first)：
  #    把预先下载好的安装包放进缓存目录，命中即直接复用，完全不联网。
  #    搜索顺序：$LNAMP_CACHE(环境变量) -> <安装器目录>/packages
  #    文件名必须与官方一致，例如 php-8.3.36.tar.gz、openssl-1.0.2u.tar.gz。
  local cdir
  for cdir in "${LNAMP_CACHE:-}" "${SCRIPT_DIR:-.}/packages"; do
    [ -n "$cdir" ] || continue
    if [ -s "${cdir}/${base}" ]; then
      if [ "$(readlink -f "${cdir}/${base}" 2>/dev/null)" = "$(readlink -f "$out" 2>/dev/null)" ]; then
        log_ok "使用本地缓存 (local cache): ${cdir}/${base}"; return 0
      fi
      # 干跑只报告"会命中缓存"，不复制 —— 复制会让后续步骤（如 adminer 的
      # mv index.php）在干跑里真的落盘，破坏"干跑零副作用"的承诺。
      if [ "${DRY_RUN:-0}" = 1 ]; then
        log "  [dry-run] 将使用本地缓存: ${cdir}/${base}  ->  ${out}"; return 0
      fi
      if cp -f "${cdir}/${base}" "$out" 2>/dev/null; then
        log_ok "使用本地缓存 (local cache): ${cdir}/${base}"; return 0
      fi
    fi
  done

  # 2) 官方源($@)优先 → 3) 自己的镜像(root 与 so/ 子目录)兜底
  local urls=(
    "$@"
    "${MIRROR_PRIMARY}/${base}"     "${MIRROR_PRIMARY}/so/${base}"
    "${MIRROR_FALLBACK}/${base}"    "${MIRROR_FALLBACK}/so/${base}"
  )
  local u
  for u in "${urls[@]}"; do
    [ -n "$u" ] || continue
    if [ "${DRY_RUN:-0}" = 1 ]; then
      log "  [dry-run] 将下载: ${base}  <-  ${u}"
      continue
    fi
    log "下载尝试 (try, 最多3次/读超时180s): ${u}"
    # --read-timeout=180：大包（MySQL 二进制 600MB+）在慢链路上是"慢而不断"，
    # 30s 读超时会把正常下载误杀（真机实测：cdn.mysql.com 694MB 被 30s 放弃）；
    # -c 断点续传：重试/换源时接着下，别把几百 MB 从头再来。
    # 注：续传假定各源是同一产物（官方/镜像同文件名即同包），本项目无校验和场景成立。
    if wget -4 --no-check-certificate \
            --tries=3 --timeout=30 --read-timeout=180 --waitretry=5 --no-dns-cache \
            -c -q -O "$out" "$u"; then
      log_ok "下载成功 (downloaded): ${base}  <= ${u}"
      return 0
    fi
    log_warn "失败/超时，换下一个源 (failed/timeout, next source)"
  done
  [ "${DRY_RUN:-0}" = 1 ] && return 0     # 干跑：URL 链已全部列出，视为"计划完成"
  rm -f "$out" 2>/dev/null
  return 1
}

# dl <镜像相对路径> [输出名]   —— 镜像上的文件(root/so 均可)，由 fetch 统一按优先级取，失败退出
dl() {
  local path="$1" out="${2:-$(basename "$1")}"
  fetch "$out" "${MIRROR_PRIMARY}/${path}" "${MIRROR_FALLBACK}/${path}" \
    || die "下载失败 (download failed): ${path}"
}

# dl_url <官方URL> [输出名]   —— 本地缓存/镜像优先(fetch 内置) → 官方源兜底，全部失败退出
dl_url() {
  local url="$1" out="${2:-$(basename "$1")}"
  fetch "$out" "$url" || die "下载失败 (download failed): ${url}"
}

# dl_openssl <版本> [输出名]
#   缓存/镜像/官方查找统一用真实文件名 openssl-<ver>.tar.gz（与官方一致，
#   这样预放到 packages/ 或镜像上的 openssl-<ver>.tar.gz 才能被命中）；
#   下载完成后，若调用方要求别名(如 openssl-src.tar.gz)再重命名。
dl_openssl() {
  local ov="$1"
  # 注意：必须分两条 local —— 同一条里 ${ov} 尚未生效，会拼出 "openssl-.tar.gz"。
  local out="${2:-openssl-${ov}.tar.gz}"
  local real="openssl-${ov}.tar.gz"
  # codeload.github.com 与 github.com 同源但独立主机：部分网络只墙 github.com 主机，
  # codeload 仍可直连（openssl.org/source 的下载也 302 回 github release）。
  fetch "$real" \
    "https://codeload.github.com/openssl/openssl/tar.gz/refs/tags/openssl-${ov}" \
    "https://github.com/openssl/openssl/releases/download/openssl-${ov}/openssl-${ov}.tar.gz" \
    || die "下载失败 (download failed): ${real}"
  [ "$out" != "$real" ] && mv -f "$real" "$out"
  return 0
}

# untar_as <归档> <期望顶层目录名>
#   解压并把顶层目录规范为期望名。GitHub codeload 归档的顶层目录是 "<repo>-<tag>"：
#     - tag 以仓库名开头  -> pcre2 + pcre2-10.47  -> "pcre2-pcre2-10.47"（双前缀）
#     - tag 带 v 前缀     -> nghttp2 + v1.70.0    -> "nghttp2-v1.70.0"
#   二者都与官方 release 包目录名不同，下游按固定名 cd/configure 会失败，故统一重命名。
untar_as() {
  local tf="$1" want="$2" top
  tar -zxf "$tf" || return 1
  top=$(tar -tzf "$tf" 2>/dev/null | head -1 | cut -d/ -f1)
  [ -z "$top" ] && return 0
  if [ "$top" != "$want" ]; then
    safe_rm_rf "$want"
    mv -f "$top" "$want" || return 1
  fi
  return 0
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

# OpenSSL 3.x 的 Configure 依赖 perl 的 IPC::Cmd 与 Time::Piece 模块
# （缺失时报 "Can't locate IPC/Cmd.pm" / "Can't locate Time/Piece.pm"）。
# Debian 的 perl-modules 与 Rocky8+ 镜像通常自带，CentOS 7 基础镜像不含，需显式安装。
ensure_perl_ipc_cmd() {
  perl -MIPC::Cmd -e 1 >/dev/null 2>&1 && perl -MTime::Piece -e 1 >/dev/null 2>&1 && return 0
  log "  [deps] perl IPC::Cmd/Time::Piece 缺失，尝试安装（OpenSSL 3.x 编译需要）"
  if [ "$OS_FAMILY" = debian ]; then
    pkg_install libipc-run-perl >/dev/null 2>&1 || true
  else
    pkg_install perl-IPC-Cmd perl-Time-Piece >/dev/null 2>&1 || true
  fi
  perl -MIPC::Cmd -e 1 >/dev/null 2>&1 && perl -MTime::Piece -e 1 >/dev/null 2>&1
}

# 等待数据库 socket 就绪(最多 ~40s)
# 干跑下服务并未真正启动，socket 永远不会出现；若照常轮询会白等 40s，
# 所以直接返回 0 并由调用方用 DRY_RUN 判断是否跳过后续客户端操作。
_db_wait_socket() {
  local sock="$1" i
  if [ "${DRY_RUN:-0}" = 1 ]; then
    log "  [dry-run] 跳过等待数据库 socket: ${sock}"
    return 0
  fi
  for i in $(seq 1 40); do [ -S "$sock" ] && return 0; sleep 1; done
  return 1
}

# ----- 数据库二进制运行时库兼容 (runtime lib compat) ------------------------
# 官方 MySQL/MariaDB 二进制按较老发行版链接，新发行版会缺库，缺库时
# mysqld/mysql 直接 "error while loading shared libraries" 退出 127：
#   Ubuntu 24.04: libaio1t64 只提供 libaio.so.1t64(无 libaio.so.1 兼容链)，
#                 且仓库已删除 libncurses5/libtinfo5(ncurses5 ABI)。
# 处理：ldd 全量体检 bin/ 下每个可执行文件；系统包能补的已在前面装好，
#       仍缺失的建立兼容软链(如 libaio.so.1 -> libaio.so.1t64)并明确告警。
# 用法: db_ensure_runtime_libs <解压出的数据库目录>
db_ensure_runtime_libs() {
  local bindir="$1/bin"
  [ -d "$bindir" ] || return 0
  [ "${DRY_RUN:-0}" = 1 ] && return 0
  local f lib missing=()
  for f in "$bindir"/*; do
    [ -f "$f" ] && [ -x "$f" ] || continue
    while read -r lib _; do
      case "$lib" in *.so|*.so.*) missing+=("$lib") ;; esac
    done < <(ldd "$f" 2>/dev/null | awk '/not found/ {print $1}')
  done
  [ ${#missing[@]} -gt 0 ] || return 0
  # 去重
  local uniq=() l
  for l in "${missing[@]}"; do
    case " ${uniq[*]-} " in *" $l "*) ;; *) uniq+=("$l") ;; esac
  done
  local target ok=0
  for l in "${uniq[@]}"; do
    target=$(_db_find_compat_lib "$l")
    if [ -n "$target" ]; then
      if ln -sf "$target" "/usr/lib/x86_64-linux-gnu/$l" 2>/dev/null \
         || ln -sf "$target" "/usr/lib64/$l" 2>/dev/null; then
        log_warn "运行时库兼容 (runtime lib compat): $l 缺失，已建软链 -> $target（发行版未提供该 ABI 的原生包；若运行异常请改用源码编译或其他版本）"
        ok=1
      else
        log_warn "运行时库缺失且无法建软链 (missing lib): $l"
      fi
    else
      log_warn "运行时库缺失 (missing lib): $l（未找到可兼容的替代库，请手动安装）"
    fi
  done
  [ "$ok" = 1 ] && log_run "ldconfig" ldconfig
  return 0
}

# 在系统库里为缺失的 soname 找可兼容的实机库（同库不同 ABI 版本，取最高版本）。
# 例: libaio.so.1 -> /usr/lib/x86_64-linux-gnu/libaio.so.1t64
#     libncurses.so.5 -> /usr/lib/x86_64-linux-gnu/libncurses.so.6
_db_find_compat_lib() {
  local want="$1" base cand
  base="${want%.so*}"   # libncurses.so.5 -> libncurses ; libaio.so.1 -> libaio
  for cand in $(ls /usr/lib/x86_64-linux-gnu/${base}.so.* /lib/x86_64-linux-gnu/${base}.so.* \
                   /usr/lib64/${base}.so.* /lib64/${base}.so.* 2>/dev/null \
               | grep -E "${base}\.so\.[0-9]+(t64)?$" | sort -V); do
    echo "$cand"; return 0
  done
  return 1
}

# 为 MySQL/MariaDB 自动设置随机 root 密码并保存。
# 用法: db_set_random_root_password <client二进制> <凭据文件> <标签>
#   依赖：服务已启动、root 初始为空密码(由 *-install-db / --initialize-insecure 产生)。
db_set_random_root_password() {
  local client="$1" credfile="$2" label="$3" sock=/tmp/mysql.sock
  if [ "${DRY_RUN:-0}" = 1 ]; then
    log "  [dry-run] 将设置 ${label} root 随机密码并写入 ${credfile} (chmod 600)"
    return 0
  fi
  # 客户端不存在时直接跳过：否则会为等一个永远等不到的 socket 白耗 40s。
  if [ -z "$client" ] || ! command -v "$client" >/dev/null 2>&1; then
    log_warn "${label} 客户端不可用 (client not found: ${client:-空})，跳过自动设置 root 密码"
    return 0
  fi
  if ! _db_wait_socket "$sock"; then
    log_warn "${label} 未就绪，自动设密码已跳过；可稍后手动执行 mysql_secure_installation"
    return 0
  fi
  # 重装/修复场景：凭据文件还在且能登录 -> 保留原密码。
  # 否则重装会重新随机生成密码，而数据目录里的账号仍是旧密码（无凭据登录不上，
  # ALTER USER 必然失败），最终凭据文件与数据库对不上 —— 用户直接被锁在门外。
  if [ -f "$credfile" ]; then
    local _old; _old=$(sed -n 's/.*password):[[:space:]]*\([^[:space:]]*\).*/\1/p; s/.*password:[[:space:]]*\([^[:space:]]*\).*/\1/p' "$credfile" 2>/dev/null | head -1 | tr -d '\r ')
    if [ -n "$_old" ] && "$client" --socket="$sock" -uroot -p"$_old" -e "SELECT 1" >/dev/null 2>&1; then
      log_ok "${label} 已存在可用 root 凭据，保留原密码（不重置）"
      DB_ROOT_PASS="$_old"; export DB_ROOT_PASS
      return 0
    fi
  fi
  local pass; pass=$(gen_password)
  # MySQL 5.7/8 与 MariaDB 11 通用：root 初始为空/socket 认证，下面两种写法二选一成功即可
  if "$client" --socket="$sock" -uroot --connect-expired-password \
        -e "ALTER USER 'root'@'localhost' IDENTIFIED BY '${pass}'; FLUSH PRIVILEGES;" 2>/dev/null \
   || "$client" --socket="$sock" -uroot \
        -e "SET PASSWORD FOR 'root'@'localhost' = PASSWORD('${pass}'); FLUSH PRIVILEGES;" 2>/dev/null; then
    # 放行本机 TCP 回环（127.0.0.1 / ::1），与 root@localhost 同密码同权限：
    # 默认只有 root@localhost（经 unix socket 登录）可用，Web 应用配 127.0.0.1:3306
    # 连接会报 SQLSTATE[HY000] [1130] Host ... not allowed。两者均限本机回环，
    # 不开放远程 root，安全边界不变。幂等：已存在则更新密码并重新授权。
    "$client" --socket="$sock" -uroot -p"$pass" -e "
      CREATE USER IF NOT EXISTS 'root'@'127.0.0.1' IDENTIFIED BY '${pass}';
      ALTER USER 'root'@'127.0.0.1' IDENTIFIED BY '${pass}';
      GRANT ALL PRIVILEGES ON *.* TO 'root'@'127.0.0.1' WITH GRANT OPTION;
      CREATE USER IF NOT EXISTS 'root'@'::1' IDENTIFIED BY '${pass}';
      ALTER USER 'root'@'::1' IDENTIFIED BY '${pass}';
      GRANT ALL PRIVILEGES ON *.* TO 'root'@'::1' WITH GRANT OPTION;
      FLUSH PRIVILEGES;" 2>/dev/null \
      || log_warn "${label} 未放行 root@127.0.0.1（TCP 回环）；Web 应用请用 localhost 走 socket，或参考安装日志手动授权"
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
  # redo log 容量：MySQL 8.0.30 起 innodb_log_file_size 废弃，9.x 已彻底移除 ——
  # 9.x 上写它 mysqld 直接报 "unknown variable 'innodb_log_file_size=32M'" 并 Aborting。
  # 新版改用 innodb_redo_log_capacity（96M ≈ 旧配置的 3×32M），MariaDB/旧版维持原写法。
  local redolog
  if [ "$flavor" = mysql ] && ver_ge "$ver" "8.0.30"; then
    redolog="innodb_redo_log_capacity = 96M"
  else
    redolog="innodb_log_file_size = 32M"
  fi
  # 监听地址：默认只绑回环。历史默认 0.0.0.0 会把 3306 直接暴露到网络
  # （安全基线不通过）；确需远程管理时用 MYSQL_BIND_ADDRESS 覆盖（见下）。
  # mysqlx（33060，X Protocol）在 MySQL 8.x 上单独有一个绑定项，同样收回本地。
  local mysqlx_bind="" bind_addr="${MYSQL_BIND_ADDRESS:-127.0.0.1}"
  if [ "$flavor" = mysql ] && [ "$major" -ge 8 ]; then
    mysqlx_bind="mysqlx-bind-address = ${bind_addr}"
  fi

  save_file "${MY_CNF_PATH}" <<EOF
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
# 仅监听本机（远程访问请改 MYSQL_BIND_ADDRESS=0.0.0.0 + LNAMP_DB_PUBLIC=yes，并配防火墙白名单）
bind-address = ${bind_addr}
${mysqlx_bind}
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
${redolog}
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

  tune_my_cnf "${MY_CNF_PATH}"
}

# 按内存大小调优 my.cnf 关键缓冲参数（沿用常见 LNMP 分级；<=1.5G 用基础值）
tune_my_cnf() {
  local cnf="$1"
  [ -n "$MEM_MB" ] || detect_mem
  if [ "${DRY_RUN:-0}" = 1 ]; then
    log "  [dry-run] 将按内存(${MEM_MB}MB)调优 ${cnf} 的缓冲参数"
    return 0
  fi
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

# ---------------------------------------------------------------------------
# 数据库监听范围：默认只监听 127.0.0.1
#
# 为什么还要单独收敛一次：
#   · 源码/二进制安装：my.cnf 由 write_my_cnf 生成，已经是 127.0.0.1；
#   · 包管理器安装：用的是发行版/官方仓库配置 —— MariaDB 官方 server.cnf
#     写的就是 `bind-address=0.0.0.0`，MySQL 社区 RPM 干脆不写（默认监听
#     全部网卡）。只靠 write_my_cnf 管不到这两种，云主机上等于把 3306 送出去。
#
# 做法：写一份排在最末的 drop-in（mysqld 后读的配置覆盖先读的），并把主配置里
# 显式的 0.0.0.0 注释掉（有些运维脚本/面板只 grep 主配置）。幂等，可重复执行。
#
# 用法: db_enforce_bind_local [unit...]     （给了 unit 才会重启服务）
# 环境变量:
#   MYSQL_BIND_ADDRESS=127.0.0.1   监听地址（默认回环）
#   LNAMP_DB_PUBLIC=yes            允许监听非回环地址
#   LNAMP_DB_PORTS=3306,3360       防火墙放行的数据库端口（默认 3306,3360）
#   LNAMP_DB_OPEN_PORTS=no         完全不放通数据库端口
# ---------------------------------------------------------------------------
DB_BIND_DROPIN_NAME="zz-lnamp-bind.cnf"

db_enforce_bind_local() {
  local units="$*" want="${MYSQL_BIND_ADDRESS:-127.0.0.1}" public=no
  case "$want" in
    127.0.0.1|localhost|::1) : ;;
    *)
      if [ "${LNAMP_DB_PUBLIC:-no}" = yes ]; then
        public=yes
      else
        log_warn "MYSQL_BIND_ADDRESS=${want} 会把 3306 暴露到网络 —— 本次仍按 127.0.0.1 收敛"
        log_warn "确需远程管理请显式声明：MYSQL_BIND_ADDRESS=${want} LNAMP_DB_PUBLIC=yes $0 ...（并自行配置防火墙白名单）"
        want=127.0.0.1
      fi
      ;;
  esac

  if [ "${DRY_RUN:-0}" = 1 ]; then
    log "  [dry-run] 将把数据库监听收敛到 ${want}（写 ${DB_BIND_DROPIN_NAME} + 重启 ${units:-数据库服务}）"
    return 0
  fi

  local cfg="${MY_CNF_PATH:-/etc/my.cnf}" d wrote=0
  # 1) 安装器自己的 my.cnf：有就改成目标值（binlog 之类配置保持不动）
  [ -f "$cfg" ] && _db_set_bind_in_file "$cfg" "$want" && wrote=1
  # 2) 发行版配置目录：drop-in 名字以 zz- 开头，排在同目录最后被读取，
  #    因此能覆盖 server.cnf / mysqld.cnf 里的旧值，又不必改别人的文件。
  #    （LNAMP_DB_CONF_DIRS 供测试把落点指到沙箱，避免污染宿主机 /etc）
  for d in ${LNAMP_DB_CONF_DIRS:-/etc/my.cnf.d /etc/mysql/conf.d /etc/mysql/mysql.conf.d /etc/mysql/mariadb.conf.d}; do
    [ -d "$d" ] || continue
    _db_neutralize_public_bind "$d"
    if _db_write_bind_dropin "${d}/${DB_BIND_DROPIN_NAME}" "$want"; then wrote=1; fi
  done
  # 3) 非回环时才放通防火墙（回环场景由各模块 db_open_ports 决定是否放通）
  if [ "$public" = yes ]; then
    db_open_ports
  fi

  local u restarted=""
  for u in $units; do
    systemctl restart "$u" >/dev/null 2>&1 && restarted="${restarted} $u"
  done
  if [ "$wrote" = 1 ]; then
    if [ "$public" = yes ]; then
      log_warn "数据库监听已设为 ${want}（非回环，端口已放通）—— 请自行限制来源 IP"
    else
      log_ok "数据库监听已收敛到 ${want}（${DB_BIND_DROPIN_NAME}）"
    fi
  else
    log "数据库监听收敛：未找到可写的数据库配置（可能尚未安装），跳过"
  fi
  [ -n "$restarted" ] && log "已重启服务:${restarted}"
  return 0
}

# ---------------------------------------------------------------------------
# 数据库防火墙端口放行
#
# 监听地址（bind-address）和防火墙是两件事，别混为一谈：
#   · 第一道闸是 bind-address=127.0.0.1 —— 没进程在网卡上监听，防火墙全开也连不进来；
#   · 第二道才是防火墙/安全组。装完库往往还要从内网连，所以这里按清单放通端口。
#
# 默认放行 3306 与 3360（3360 多为第二个实例 / 自定义端口部署）。
# 覆盖方式（二选一或都用）：
#   LNAMP_DB_PORTS="3306,33060"    自定义放行清单（只留数字和逗号）
#   LNAMP_DB_OPEN_PORTS=no         完全不放通（最严格，仅靠回环监听）
# ---------------------------------------------------------------------------
DB_PORTS_DEFAULT="${LNAMP_DB_PORTS_DEFAULT:-3306,3360}"

# 输出规范化后的端口清单（去空字符、只留数字/逗号、去掉首尾与重复逗号）
db_ports_list() {
  printf '%s' "${LNAMP_DB_PORTS:-${DB_PORTS_DEFAULT}}" \
    | tr -cd '0-9,' | sed 's/,,*/,/g; s/^,//; s/,$//'
}

db_open_ports() {
  local ports want_local="${MYSQL_BIND_ADDRESS:-127.0.0.1}"
  case "${LNAMP_DB_OPEN_PORTS:-yes}" in
    yes|YES|Yes|1|on|true) : ;;
    *) log "已按 LNAMP_DB_OPEN_PORTS=${LNAMP_DB_OPEN_PORTS} 跳过数据库端口放行"; return 0 ;;
  esac
  ports=$(db_ports_list)
  [ -n "$ports" ] || { log_warn "数据库端口清单为空（检查 LNAMP_DB_PORTS），跳过放行"; return 0; }
  if [ "${DRY_RUN:-0}" = 1 ]; then
    log "  [dry-run] 将放通防火墙数据库端口: ${ports}"
    return 0
  fi
  open_ports "$ports"
  log_ok "数据库端口已放通防火墙: ${ports}"
  case "$want_local" in
    127.0.0.1|localhost|::1)
      log "监听仍是 ${want_local} —— 端口虽已放通，外部仍连不上；确实要远程访问请改 MYSQL_BIND_ADDRESS 并限制来源 IP" ;;
    *)
      log_warn "数据库监听 ${want_local} 且端口已放通 —— 请务必在安全组/防火墙只授权可信来源 IP" ;;
  esac
  return 0
}

# 把单个配置文件里的 bind-address 改写成目标值（没有就插到 [mysqld] 段首）
_db_set_bind_in_file() {
  local f="$1" want="$2"
  [ -f "$f" ] || return 1
  if grep -qE '^[[:space:]]*bind-address[[:space:]]*=' "$f"; then
    sed -i "s@^[[:space:]]*bind-address[[:space:]]*=.*@bind-address = ${want}@" "$f"
  elif grep -qE '^[[:space:]]*\[mysqld\][[:space:]]*$' "$f"; then
    # 没有 bind-address 但有 [mysqld]：插到该段第一行（用 awk 重建，避免 sed 转义歧义）
    local tmp="${f}.lnamp.tmp"
    awk -v want="$want" '
      !d && /^[[:space:]]*\[mysqld\][[:space:]]*$/ { print; print "bind-address = " want; d=1; next }
      { print }
    ' "$f" > "$tmp" && mv "$tmp" "$f"
  else
    printf '\n[mysqld]\nbind-address = %s\n' "$want" >> "$f"
    return 0
  fi
  # mysqlx（33060）只有 MySQL 8.x 认；5.7/MariaDB 写上会 "unknown variable" 起不来
  if grep -qE '^[[:space:]]*mysqlx-bind-address[[:space:]]*=' "$f"; then
    sed -i "s@^[[:space:]]*mysqlx-bind-address[[:space:]]*=.*@mysqlx-bind-address = ${want}@" "$f"
  fi
  return 0
}

# 注释掉目录里把数据库暴露到公网的 bind-address（保留原文，方便回滚）
_db_neutralize_public_bind() {
  local d="$1" f
  [ -d "$d" ] || return 0
  for f in "$d"/*.cnf; do
    [ -f "$f" ] || continue
    case "$f" in */"${DB_BIND_DROPIN_NAME}") continue ;; esac
    sed -i "s@^[[:space:]]*\(bind-address[[:space:]]*=[[:space:]]*\(0\.0\.0\.0\|\*\|::\|\[::\]\)\).*@# LNAMP: 已收敛到回环，原值 \1@" "$f"
  done
  return 0
}

# 写 drop-in。mysqlx 只在确认是 MySQL 8.x 时才写
_db_write_bind_dropin() {
  local f="$1" want="$2" x=""
  _db_mysqlx_supported && x="mysqlx-bind-address = ${want}"
  save_file "$f" <<EOF
# LNAMP: 数据库默认只监听回环，3306 不对外网开放（安装器自动生成，勿手改）
# 确需远程管理：改这里的地址 + 防火墙只放行可信来源 IP，不要直接 0.0.0.0
[mysqld]
bind-address = ${want}
${x}
EOF
}

# 是否支持 mysqlx（仅 MySQL 8.0+；MariaDB / MySQL 5.x 都不认这个选项）
_db_mysqlx_supported() {
  local b v out
  for b in "${PREFIX_MYSQL:-/usr/local/mysql}/bin/mysqld" /usr/sbin/mysqld /usr/libexec/mysqld \
           "$(command -v mysqld 2>/dev/null)" "$(command -v mariadbd 2>/dev/null)"; do
    [ -n "$b" ] && [ -x "$b" ] || continue
    out=$("$b" --version 2>/dev/null) || continue
    case "$out" in *MariaDB*|*mariadb*) return 1 ;; esac
    v=$(printf '%s' "$out" | sed -n 's/.*[^0-9]\([0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*\).*/\1/p' | head -1)
    [ -n "$v" ] || continue
    [ "${v%%.*}" -ge 8 ] 2>/dev/null && return 0
    return 1
  done
  return 1
}

# 数据库实际监听地址（ss/netstat 实测，空=没在听）
db_listen_addr() {
  local port="${1:-3306}"
  (ss -lnt 2>/dev/null || netstat -lnt 2>/dev/null) | \
    awk -v P="${port}" '{ for (i=1;i<=NF;i++) { if ($i ~ (":"P"$")) { print $i; exit } } }' | head -1
}

# 是否只监听回环：0=只听回环  1=对外监听  2=没在听/取不到
db_listen_is_local() {
  local addr
  addr=$(db_listen_addr "${1:-3306}")
  [ -n "$addr" ] || return 2
  case "$addr" in
    127.0.0.1:*|::1:*|localhost:*) return 0 ;;
    *) return 1 ;;
  esac
}

# ----- www 用户 / service / firewall ----------------------------------------
# 创建系统用户 (无登录 shell)，自动选取 nologin 路径 (debian 在 /usr/sbin)。
ensure_sysuser() {
  local u="$1" nologin
  nologin=$(command -v nologin || echo /sbin/nologin)
  if id -u "$u" >/dev/null 2>&1; then
    return 0
  fi
  log_run "创建系统用户 ${u}" useradd -M -s "$nologin" "$u"
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
# 干跑模式下只打印计划，不动 systemctl。
enable_service() {
  local name="$1"
  if [ "${DRY_RUN:-0}" = 1 ]; then
    log "  [dry-run] 将注册并启动服务: ${name}.service"
    return 0
  fi
  chmod 644 "${SYSTEMD_DIR}/${name}.service" 2>/dev/null
  systemctl daemon-reload
  systemctl enable "${name}.service" 2>/dev/null
  systemctl restart "${name}.service" 2>/dev/null || systemctl start "${name}.service" 2>/dev/null
}

# 在扫描目录写入扩展启用 ini（用 php-config 的绝对扩展目录，避免 extension_dir 不一致）
# 用法: php_enable_ext <ini名> <so文件> [zend]   zend=用 zend_extension(如 opcache)
php_enable_ext() {
  local name="$1" so="$2" zend="${3:-}" extdir ini key line
  extdir=$("${PREFIX_PHP}/bin/php-config" --extension-dir 2>/dev/null)
  safe_mkdir "${PREFIX_PHP}/etc/php.d"
  ini="${PREFIX_PHP}/etc/php.d/${name}.ini"
  key=extension; [ "$zend" = zend ] && key=zend_extension
  if [ -n "$extdir" ] && [ -f "${extdir}/${so}" ]; then
    line="${key}=${extdir}/${so}"
  else
    line="${key}=${so}"   # 回退：裸文件名(依赖 extension_dir)
  fi
  save_file "$ini" <<< "$line"
}

# 重新加载 PHP 运行时（php-fpm / mod_php），使后续新增的扩展在 web 端(phpinfo)生效。
# 安装顺序上，php-fpm 可能在装扩展前已启动，必须重启才会重新读取 php.d/*.ini。
reload_php_runtime() {
  # 干跑绝不能真的重启服务（会打断线上 php-fpm），只提示
  if [ "${DRY_RUN:-0}" = 1 ]; then
    log "  [dry-run] 将重启 php-fpm / 重载 httpd 以加载新扩展"
    return 0
  fi
  command -v systemctl >/dev/null 2>&1 || return 0
  if systemctl is-active --quiet php-fpm 2>/dev/null; then
    systemctl restart php-fpm 2>/dev/null && log "php-fpm 已重启以加载新扩展"
  fi
  systemctl is-active --quiet httpd   2>/dev/null && systemctl reload httpd   2>/dev/null && log "httpd 已重载以加载新扩展"
  systemctl is-active --quiet apache2 2>/dev/null && systemctl reload apache2 2>/dev/null && log "apache2 已重载以加载新扩展"
  return 0
}

# ----- 交互确认 / 版本比较 / 升级模式 --------------------------------------
# 升级模式：upgrade 子命令会置 1。各模块据此"保留数据目录 / 复用旧密码"，
# 而不是像全新安装那样重建。
LNAMP_UPGRADE="${LNAMP_UPGRADE:-0}"
export LNAMP_UPGRADE
# Redis 8.x 是否连内置模块（bloom/search/json/timeseries）一起编译：默认关。
# 打开需要 cmake + rust(cargo) 工具链，见 modules/redis.sh 的预检。
REDIS_MODULES="${REDIS_MODULES:-0}"
export REDIS_MODULES
# 并发锁等待秒数：0=不等待（立即失败），N=最多等 N 秒。由 --lock-wait 设置。
LNAMP_LOCK_WAIT="${LNAMP_LOCK_WAIT:-0}"
export LNAMP_LOCK_WAIT

# 询问是否执行某动作。ASSUME_YES=1 或非交互(stdin 非 tty)时直接取默认值，
# 避免在 CI / 管道里卡住。
# 用法: ask_yes_no "是否安装 Memcached?" [y|n]   -> 返回 0 表示 yes
ask_yes_no() {
  local prompt="$1" def="${2:-n}" ans hint
  if [ "${ASSUME_YES:-0}" = 1 ] || [ ! -t 0 ]; then
    log "  ${prompt} -> 非交互，取默认 (${def})"
    [ "$def" = y ]
    return $?
  fi
  if [ "$def" = y ]; then hint="[Y/n]"; else hint="[y/N]"; fi
  read -rp "  ${prompt} ${hint}: " ans
  [ -z "$ans" ] && ans="$def"
  case "$ans" in [Yy]*) return 0 ;; *) return 1 ;; esac
}

# 版本号比较：ver_ge 8.3.0 8.0 -> 真（8.3.0 >= 8.0）
ver_ge() {
  local a="$1" b="$2" i x y
  local -a A B
  IFS=. read -ra A <<< "$a"; IFS=. read -ra B <<< "$b"
  for i in 0 1 2; do
    x="${A[$i]:-0}"; y="${B[$i]:-0}"
    x="${x//[^0-9]/}"; y="${y//[^0-9]/}"
    [ -z "$x" ] && x=0; [ -z "$y" ] && y=0
    [ "$x" -gt "$y" ] && return 0
    [ "$x" -lt "$y" ] && return 1
  done
  return 0
}

# 已安装 PHP 的版本号（如 8.3.36）；未安装则输出空。
php_bin_version() {
  local php="${PREFIX_PHP}/bin/php"
  [ -x "$php" ] || php=$(command -v php 2>/dev/null)
  [ -n "$php" ] || return 1
  "$php" -r 'echo PHP_VERSION;' 2>/dev/null
}

# 已安装 PHP 的主版本号（8 / 7 / 5）；未安装输出空。
php_major_version() {
  local v; v=$(php_bin_version) || return 1
  echo "${v%%.*}"
}

# ----- 干跑模式 / dry-run ---------------------------------------------------
# DRY_RUN=1 时，所有"会改动系统"的动作只打印计划、不实际执行：
#   fetch()        只打印将尝试的 URL 链，不下载
#   log_run()      只打印将执行的命令，不执行（覆盖全部 configure/make）
#   pkg_*          只打印将安装/移除的包，不动包管理器
#   enable_service 只打印将注册的服务，不动 systemctl
#   save_file()    只打印将写入的文件，不落盘
# 其它 sed -i / cp 等原位操作的目标文件在干跑下不会存在，会打出无害的报错，
# 不影响"预览"这一用途。
DRY_RUN="${DRY_RUN:-0}"

# 创建目录。干跑时只打印、不在真实文件系统上创建。
# 用法: safe_mkdir <目录...>
safe_mkdir() {
  [ $# -gt 0 ] || return 0
  if [ "${DRY_RUN:-0}" = 1 ]; then
    log "  [dry-run] 将创建目录: $*"
    return 0
  fi
  mkdir -p "$@"
}

# 进入目录。干跑时目标目录通常不存在（因为没真的解压），此时不中断、只提示，
# 这样各组件在干跑下仍能继续打印后续计划，不会被 die 截断。
# 用法: cd_src <目录> [错误信息]
cd_src() {
  local d="$1" msg="${2:-cd ${1}}"
  if cd "$d" 2>/dev/null; then return 0; fi
  if [ "${DRY_RUN:-0}" = 1 ]; then
    log "  [dry-run] 跳过进入目录(尚未解压): ${d}"
    return 0
  fi
  die "$msg"
}

# 递归删除。干跑时只打印、绝不删除。
# 用法: safe_rm_rf <路径...>
# 安装器里所有 rm -rf 都必须走这里 —— 直接 rm -rf "${PREFIX_MYSQL}" 之类的调用
# 在干跑模式下会真的删掉已装目录，必须被拦截。
safe_rm_rf() {
  [ $# -gt 0 ] || return 0
  if [ "${DRY_RUN:-0}" = 1 ]; then
    log "  [dry-run] 将删除: $*"
    return 0
  fi
  rm -rf "$@"
}

# 升级专用：替换安装前缀，但把数据目录原地保住。
# 数据库的 basedir 与 datadir 共用同一前缀（/data/mysql 与 /data/mysql/data），
# 直接 rm -rf 前缀等于删库，所以升级时必须先把 data 挪出去、换完程序再挪回来。
# 用法: swap_prefix_keep_data <prefix> <新解压目录> [数据子目录名，默认 data]
# 返回: 0 = 走了"保留数据"分支（调用方不要再初始化数据目录）
#       1 = 全新安装分支（调用方应照常初始化）
# 全新安装前的"删库"保护。
#
# 前缀下的 data/mysql 存在 = 这里有已经初始化过的数据库。此时如果调用方选的是
# **另一个版本**且没走升级模式，swap_prefix_keep_data 的"全新安装"分支会
# `safe_rm_rf "$prefix"` —— data 就在 prefix 里面，等于删库。历史上这一步在 -y
# 下静默发生：precheck 只打印一行 info（"已存在 /usr/local/mysql（将按所选版本覆盖）"），
# 没人会把它读成"你的数据会被删掉"。
#
# 处理顺序：能导出就先导出（留一条退路）→ 导不出就明确拒绝，并给出三选一的命令。
# 用法: _db_guard_wipe <prefix> <数据子目录名>
_db_guard_wipe() {
  local prefix="$1" sub="${2:-data}" datadir="${1}/${2:-data}" dumpbin="" b
  [ -d "${datadir}/mysql" ] || return 0              # 没有系统库目录，不算装过数据库
  [ "${LNAMP_UPGRADE:-0}" = 1 ] && return 0           # 升级模式走保数据分支，不删
  if [ "${DRY_RUN:-0}" = 1 ]; then
    log_warn "  [dry-run] 警告：${datadir} 已存在数据库，本次全新安装会删除它（实机需 LNAMP_UPGRADE=1 或 LNAMP_FORCE_DB_WIPE=yes）"
    return 0
  fi
  if [ "${LNAMP_FORCE_DB_WIPE:-no}" = yes ]; then
    log_warn "LNAMP_FORCE_DB_WIPE=yes：即将删除已有数据目录 ${datadir}（数据不可恢复！）"
    return 0
  fi
  for b in "${prefix}/bin/mysqldump" "${prefix}/bin/mariadb-dump" \
           "$(command -v mysqldump 2>/dev/null)" "$(command -v mariadb-dump 2>/dev/null)"; do
    [ -n "$b" ] && [ -x "$b" ] && { dumpbin="$b"; break; }
  done
  if [ -n "$dumpbin" ]; then
    local dumpdir="${LNAMP_BACKUP_DIR:-/root/lnamp-backups}" dfile
    safe_mkdir "$dumpdir" 2>/dev/null
    dfile="${dumpdir}/db-pre-wipe-$(date +%Y%m%d_%H%M%S).sql.gz"
    log "检测到已有数据目录 ${datadir}，先全量导出留退路 …"
    if "$dumpbin" --all-databases --single-transaction --routines --triggers 2>/dev/null \
        | gzip > "$dfile" && [ -s "$dfile" ]; then
      log_ok "已导出到 ${dfile}（$(du -h "$dfile" 2>/dev/null | awk '{print $1}')），继续全新安装"
      return 0
    fi
    rm -f "$dfile" 2>/dev/null
    log_warn "自动导出失败（服务没起来 / 口令不匹配？），不会删除已有数据"
  fi
  die "拒绝删除已有数据库：${datadir} 里有已初始化的数据字典，而本次不是升级模式。请选择其一：
   1) 平滑升级（保留数据，只换程序文件）:  LNAMP_UPGRADE=1 $0 ${SEL_MYSQL:+--mysql ${SEL_MYSQL%%:*}}${SEL_MARIADB:+ --mariadb ${SEL_MARIADB%%:*}}
   2) 先手工确认/备份后再清空重装      :  LNAMP_FORCE_DB_WIPE=yes $0 ...
   3) 放弃本次安装，先跑               :  $0 backup --only db"
}

swap_prefix_keep_data() {
  local prefix="$1" newdir="$2" sub="${3:-data}" tmpdata
  if [ "${LNAMP_UPGRADE:-0}" = 1 ] && [ -d "${prefix}/${sub}/mysql" ]; then
    tmpdata="${prefix%/*}/.lnamp-data-$$"
    log "升级模式：保留数据目录 ${prefix}/${sub}"
    if [ "${DRY_RUN:-0}" = 1 ]; then
      log "  [dry-run] 将暂存 ${prefix}/${sub} 并只替换程序文件"
      return 0
    fi
    safe_mkdir "${prefix%/*}"
    mv "${prefix}/${sub}" "$tmpdata" || die "无法暂存数据目录 ${prefix}/${sub}"
    safe_rm_rf "$prefix"
    # rm 失败（目录被占用/权限/挂载点）时不能硬来：`mv new prefix` 在 prefix 仍存在
    # 的情况下会变成 `mv new prefix/new`（嵌套一层），程序文件位置就错了，服务起不来
    # 且很难看出原因。宁可明确中止。
    if [ -e "$prefix" ]; then
      mv "$tmpdata" "${prefix}/${sub}" 2>/dev/null
      die "无法清除旧安装目录 ${prefix}（可能被占用）。数据已回迁，请手动处理后重试"
    fi
    if ! mv "$newdir" "$prefix"; then
      mv "$tmpdata" "${prefix}/${sub}" 2>/dev/null
      die "替换程序目录失败，数据已回迁"
    fi
    # 新程序目录里若自带空的 data/，先清掉，否则 mv 会把旧数据塞进它里面
    safe_rm_rf "${prefix}/${sub}"
    mv "$tmpdata" "${prefix}/${sub}" || die "数据目录回迁失败！请手工把 ${tmpdata} 移回 ${prefix}/${sub}"
    log_ok "数据目录已保留 (datadir preserved): ${prefix}/${sub}"
    return 0
  fi
  # 走到这里就是"全新安装"分支：prefix 会被整体删除，data 也在里面。
  # 已有数据字典时先过删库保护（导出/拒绝），别让一次版本选错变成删库。
  _db_guard_wipe "$prefix" "$sub"
  safe_mkdir "${prefix%/*}"
  safe_rm_rf "$prefix"
  # 同上：prefix 没删掉就 mv 会嵌套，必须显式中止
  [ -e "$prefix" ] && die "无法清除旧安装目录 ${prefix}（可能被占用），请手动处理后重试"
  mv "$newdir" "$prefix"
  return 1
}

# 写文件并自动备份旧文件。用法与 `cat > file <<EOF` 等价：
#     save_file "${MY_CNF_PATH}" <<EOF
#     ...内容...
#     EOF
# 干跑模式下只打印目标路径，不落盘、不备份。
save_file() {
  local f="$1"
  if [ "${DRY_RUN:-0}" = 1 ]; then
    log "  [dry-run] 将写入配置文件: ${f}"
    cat > /dev/null          # 吞掉 heredoc 内容，保持调用点写法不变
    return 0
  fi
  # 目标目录可能还不存在（例如 fail2ban 包没建 jail.d），先补齐再写
  safe_mkdir "$(dirname "$f")"
  backup_file "$f"
  cat > "$f"
}

# 覆盖前备份。已存在则 cp 成 <file>.bak.<时间戳>，只保留最近 keep 份(默认5)。
# 用法: backup_file <路径> [保留份数]
backup_file() {
  local f="$1" keep="${2:-5}" ts b n=0
  [ -f "$f" ] || return 0
  if [ "${DRY_RUN:-0}" = 1 ]; then
    log "  [dry-run] 将备份: ${f} -> ${f}.bak.<时间戳>"
    return 0
  fi
  ts=$(date +%Y%m%d_%H%M%S)
  b="${f}.bak.${ts}"
  # 同一秒内多次备份会重名并互相覆盖，追加序号保证唯一
  while [ -e "$b" ]; do
    n=$((n + 1)); b="${f}.bak.${ts}.${n}"
  done
  cp -a "$f" "$b" 2>/dev/null || return 0
  log_ok "已备份 (backed up): ${f} -> ${b}"
  # 清理最旧的备份，最多保留 keep 份。
  # 按文件名排序（bak.<时间戳>[.N] 命名保证字典序 = 创建序）而非 ls -1t 的
  # mtime 排序：同一秒内多个备份 mtime 相同，ls -t 的同刻次序无 POSIX 保证，
  # 真机连跑偶发轮转不生效（keep=2 留下 3 份）。
  local old
  while IFS= read -r old; do
    [ -n "$old" ] || continue
    rm -f "$old" 2>/dev/null || true
  done < <(ls -1 "${f}".bak.* 2>/dev/null | sort | head -n -"$keep")
  return 0
}

# ----- 日志轮转 / logrotate -------------------------------------------------
# 生成 /etc/logrotate.d/<name>，并确保 logrotate 与 cron 已安装。
# 用法: setup_logrotate <name> <日志glob> [postrotate命令] [额外指令...]
#   name        配置文件名，如 nginx / php-fpm / mysqld / redis
#   glob        日志路径通配符，如 /home/wwwlogs/*log
#   postrotate  重载命令(可省略)；如需在 postrotate 里用 $ 需写成 \$
#   额外指令    追加的 logrotate 指令，如 su www www
setup_logrotate() {
  local name="$1" glob="$2" post="${3:-}"; shift 3 2>/dev/null || shift $#
  local extra=("$@")
  if [ "$OS_FAMILY" = debian ]; then
    pkg_install logrotate cron >/dev/null 2>&1
  else
    pkg_install logrotate cronie >/dev/null 2>&1
  fi
  # 目录可注入：测试/仿真必须能把它指到沙箱，否则跑一次测试就会把宿主机的
  # /etc/logrotate.d/php-fpm 覆盖成带临时前缀的路径（实测发生过：logrotate 从此
  # 每天报 stat failed，日志再也不轮转）。生产环境仍用 /etc/logrotate.d。
  local dir="${LNAMP_LOGROTATE_DIR:-/etc/logrotate.d}"
  local f="${dir}/${name}"
  if [ "${DRY_RUN:-0}" = 1 ]; then
    log "  [dry-run] 将写入日志轮转配置: ${f}  (glob=${glob})"
    return 0
  fi
  safe_mkdir "$dir"
  # 备份后缀必须用 logrotate 会**忽略**的扩展名。
  # logrotate 会读取 /etc/logrotate.d/ 下所有文件（不看扩展名），只忽略
  # .rpmsave/.dpkg-old/.disabled 这类后缀；用 ".bak.<时间戳>" 留在原地，
  # 下一次 logrotate 就会把备份当成重复配置：
  #   error: nginx.bak.20261025_171009:1 duplicate log entry for .../default.log
  #   error: found error in file ..., skipping
  # 既产生告警噪音，备份文件也永远不会被清理。
  if [ -f "$f" ]; then
    cp -f "$f" "${f}.bak.$(date +%Y%m%d_%H%M%S).disabled" 2>/dev/null || true
  fi
  {
    printf '%s {\n' "$glob"
    printf '    daily\n'
    printf '    rotate 30\n'
    printf '    missingok\n'
    printf '    notifempty\n'
    printf '    dateext\n'
    printf '    compress\n'
    printf '    delaycompress\n'
    printf '    sharedscripts\n'
    # 调用点传入的额外指令(如 su www www)，保持原有灵活性
    local e
    for e in ${extra+"${extra[@]}"}; do
      [ -n "$e" ] && printf '    %s\n' "$e"
    done
    if [ -n "$post" ]; then
      printf '    postrotate\n        %s\n    endscript\n' "$post"
    fi
    printf '}\n'
  } > "$f"
  chmod 644 "$f" 2>/dev/null
  log_ok "已配置日志轮转 (logrotate): ${f}  <- ${glob}"
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
  if [ ! -d "$bindir" ]; then
    if [ "${DRY_RUN:-0}" = 1 ]; then
      log "  [dry-run] 将注册 PATH: ${bindir} -> /etc/profile.d/lnamp-${name}.sh  (链接: $*)"
      return 0
    fi
    log_warn "register_path: 目录不存在 ${bindir}"; return 0
  fi
  save_file "/etc/profile.d/lnamp-${name}.sh" <<EOF
export PATH=${bindir}:\$PATH
EOF
  chmod 644 "/etc/profile.d/lnamp-${name}.sh" 2>/dev/null || true
  safe_mkdir /usr/local/bin
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
  local comp="$1" arr line ver modes meta dv def mark
  arr="${comp}_VERSIONS[@]"
  dv="${comp}_DEFAULT"
  def="${!dv}"
  for line in "${!arr}"; do
    ver="${line%%|*}"; modes="$(echo "$line" | cut -d'|' -f2)"; meta="$(echo "$line" | cut -d'|' -f3)"
    # 标出默认版本：不带 --<组件> 版本时装的到底是哪一个，光看列表看不出来
    mark=""
    [ "$ver" = "$def" ] && mark="  ← 默认 (default)"
    printf '    %-10s 形式(modes): %-18s %s%s\n' "$ver" "$modes" "$meta" "$mark"
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
