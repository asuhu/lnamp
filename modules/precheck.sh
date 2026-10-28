#!/bin/bash
# ============================================================================
#  modules/precheck.sh  ——  安装前预检 (pre-install precheck)
# ----------------------------------------------------------------------------
#  目的：把"装到一半才失败"的坑提前到 5 秒内暴露。
#  全部检查都是**只读**的，不改系统、不装包、不写文件。
#
#  覆盖：
#    1) 系统信息   发行版 / 内核 / CPU / 内存 / 是否容器
#    2) 磁盘空间   按所选组件估算所需空间（源码编译比二进制吃得多）
#    3) 内存       与清单 min_mem 比对（PHP8 / MySQL5.7 源码要求 ≥2000MB）
#    4) 端口占用   80/443/3306/6379/11211/8080
#    5) 已装冲突   系统包 nginx/httpd/php/mysql/mariadb/redis（会与 /usr/local 版打架）
#    6) glibc      MySQL/MariaDB 二进制包对 glibc 有硬要求（8.0 需 2.17、8.4/9.x 需 2.28）
#    7) 时间同步   TLS 证书校验、主从复制都依赖时钟准确
#    8) DNS        解析不通时官方源全废，只能走镜像或离线包
#    9) 杂项      /tmp 是否 noexec（会让 configure 直接失败）、SELinux、已存在的安装前缀
#
#  用法:
#     install.sh precheck                          # 只查通用项
#     install.sh precheck --nginx 1.30.6 --php 8.3.36:fpm --mysql 8.0.46:binary
#  退出码: 0=全部通过或有警告  2=存在 FAIL（建议先修复再装）
# ============================================================================

_PC_PASS=0; _PC_WARN=0; _PC_FAIL=0; _PC_INFO=0
_pc_ok()   { printf '  [ OK ] %s\n' "$*"; _PC_PASS=$((_PC_PASS+1)); }
_pc_warn() { printf '  [WARN] %s\n' "$*"; _PC_WARN=$((_PC_WARN+1)); }
_pc_fail() { printf '  [FAIL] %s\n' "$*"; _PC_FAIL=$((_PC_FAIL+1)); }
_pc_info() { printf '  [INFO] %s\n' "$*"; _PC_INFO=$((_PC_INFO+1)); }

# ---- 基础探测 --------------------------------------------------------------
_pc_cpu() {
  local n
  n=$(nproc 2>/dev/null || getconf _NPROCESSORS_ONLN 2>/dev/null)
  echo "${n:-0}"
}

_pc_is_container() {
  [ -f /.dockerenv ] && return 0
  [ -f /run/.containerenv ] && return 0
  grep -qaE '(docker|lxc|kubepods|containerd)' /proc/1/cgroup 2>/dev/null && return 0
  return 1
}

_pc_glibc_ver() {
  ldd --version 2>/dev/null | head -1 | awk '{print $NF}' | grep -E '^[0-9]+\.[0-9]+' || true
}

# 端口是否在监听
_pc_port_busy() {
  local p="$1"
  if command -v ss >/dev/null 2>&1; then
    # 注意：不要用 `| grep -q`——install.sh 开了 pipefail，grep -q 提前退出会让
    # 上游 awk/ss 收到 SIGPIPE(141)，整条管道判为失败，探测结果被静默反转。
    ss -lnt 2>/dev/null | awk '{print $4}' | grep -cE "[:.]${p}\$" >/dev/null && return 0
    return 1
  fi
  if command -v netstat >/dev/null 2>&1; then
    netstat -lnt 2>/dev/null | awk '{print $4}' | grep -cE "[:.]${p}\$" >/dev/null && return 0
    return 1
  fi
  return 1   # 工具缺失时不下结论
}

_pc_port_tool() {
  command -v ss >/dev/null 2>&1 || command -v netstat >/dev/null 2>&1
}

# 端口被谁占（尽力而为，取不到就空）
_pc_port_owner() {
  local p="$1"
  if command -v ss >/dev/null 2>&1; then
    ss -lntp 2>/dev/null | awk -v p=":${p}\$" '$4 ~ p {print $NF; exit}' | sed 's/.*users:(("\([^"]*\)".*/\1/'
  elif command -v netstat >/dev/null 2>&1; then
    netstat -lntp 2>/dev/null | awk -v p=":${p}\$" '$4 ~ p {print $7; exit}' | cut -d/ -f2
  fi
}

_pc_resolve() {
  local h="$1"
  if command -v getent >/dev/null 2>&1 && getent hosts "$h" >/dev/null 2>&1; then return 0; fi
  if command -v timeout >/dev/null 2>&1; then
    timeout 3 bash -c "exec 3<>/dev/tcp/${h}/443" >/dev/null 2>&1 && return 0
  fi
  return 1
}

_pc_time_synced() {
  if command -v timedatectl >/dev/null 2>&1; then
    [ "$(timedatectl show -p NTPSynchronized --value 2>/dev/null)" = yes ] && return 0
  fi
  [ -f /run/systemd/timesync/synchronized ] && return 0
  if command -v chronyc >/dev/null 2>&1; then
    chronyc tracking 2>/dev/null | grep -q 'Leap status *: *Normal' && return 0
  fi
  if command -v ntpq >/dev/null 2>&1; then
    ntpq -p 2>/dev/null | grep -q '^\*' && return 0
  fi
  return 1
}

# 系统包里是否装了某组件（rpm / dpkg）
_pc_syspkg_installed() {
  local name="$1"
  if command -v rpm >/dev/null 2>&1; then
    rpm -q "$name" >/dev/null 2>&1 && return 0
  fi
  if command -v dpkg >/dev/null 2>&1; then
    dpkg -s "$name" >/dev/null 2>&1 && return 0
  fi
  return 1
}

# ---- 1) 系统信息 -----------------------------------------------------------
_pc_system() {
  echo "[1/10] 系统信息 (system)"
  _pc_info "系统: ${OS_PRETTY:-未知}  内核: $(uname -r 2>/dev/null || echo '?')  CPU: $(_pc_cpu) 核"
  if _pc_is_container; then
    _pc_warn "检测到容器环境：systemd 服务/内核参数可能不生效，建议在虚拟机或物理机上安装"
  else
    _pc_ok "非容器环境，systemd 与内核参数可正常生效"
  fi
  if [ "$(_pc_cpu)" -lt 2 ] 2>/dev/null; then
    _pc_warn "CPU 仅 1 核：源码编译会明显变慢（PHP/MySQL 单核可能需要 20 分钟以上）"
  fi
}

# ---- 2) 磁盘空间 -----------------------------------------------------------
# 估算规则（GB）：基础 2 + 源码组件 + 二进制组件
_pc_disk_need_gb() {
  local need=2
  local src=0
  [ -n "${SEL_NGINX:-}" ]   && [ "${SEL_NGINX##*:}"   = source ] && src=1
  [ -n "${SEL_APACHE:-}" ]  && [ "${SEL_APACHE##*:}"  = source ] && src=1
  [ -n "${SEL_PHP:-}" ]     && src=1
  [ -n "${SEL_MYSQL:-}" ]   && [ "${SEL_MYSQL##*:}"   = source ] && src=1
  [ -n "${SEL_REDIS:-}" ]   && [ "${SEL_REDIS##*:}"   = source ] && src=1
  [ -n "${SEL_MEMCACHED:-}" ] && [ "${SEL_MEMCACHED##*:}" = source ] && src=1
  [ -n "${SEL_SWOOLE:-}" ] && src=1
  [ "$src" = 1 ] && need=$((need + 6))
  [ -n "${SEL_MYSQL:-}" ]   && [ "${SEL_MYSQL##*:}"   != source ] && need=$((need + 2))
  [ -n "${SEL_MARIADB:-}" ] && need=$((need + 2))
  echo "$need"
}

_pc_disk() {
  echo "[2/10] 磁盘空间 (disk)"
  command -v df >/dev/null 2>&1 || { _pc_info "无 df 命令，跳过磁盘检查"; return 0; }
  local need; need=$(_pc_disk_need_gb)
  local target="/" avail
  # 数据目录在 /data，优先检查它的挂载点
  if [ -d /data ] || [ -n "${SEL_MYSQL:-}${SEL_MARIADB:-}" ]; then
    [ -d /data ] && target="/data"
  fi
  # df -Pk: 1024 字节块，第 4 列是可用块
  avail=$(df -Pk "$target" 2>/dev/null | awk 'NR==2{print $4}')
  if [ -z "$avail" ]; then
    _pc_info "取不到 ${target} 的磁盘信息，跳过"
    return 0
  fi
  local gb; gb=$((avail / 1024 / 1024))
  if [ "$gb" -lt 2 ]; then
    _pc_fail "${target} 仅剩 ${gb}GB，安装必然中途失败（至少需要 2GB，建议 ${need}GB）"
  elif [ "$gb" -lt "$need" ]; then
    _pc_warn "${target} 可用 ${gb}GB，低于估算需求 ${need}GB（源码编译 + 解压峰值比较吃空间）"
  else
    _pc_ok "${target} 可用 ${gb}GB（估算需求 ${need}GB）"
  fi
}

# 遍历已选组件，输出 "清单键|选择值"（清单键即 <KEY>_VERSIONS 的前缀）
_pc_each_sel() {
  [ -n "${SEL_PHP:-}" ]     && echo "PHP|${SEL_PHP}"
  [ -n "${SEL_MYSQL:-}" ]   && echo "MYSQL|${SEL_MYSQL}"
  [ -n "${SEL_MARIADB:-}" ] && echo "MARIADB|${SEL_MARIADB}"
  [ -n "${SEL_REDIS:-}" ]   && echo "REDIS|${SEL_REDIS}"
  return 0
}

# ---- 3) 内存 ---------------------------------------------------------------
_pc_mem() {
  echo "[3/10] 内存 (memory)"
  [ -n "${MEM_MB:-}" ] || { command -v detect_mem >/dev/null 2>&1 && detect_mem; }
  local mem="${MEM_MB:-0}"
  if [ "$mem" -le 0 ] 2>/dev/null; then
    _pc_info "取不到内存大小，跳过"; return 0
  fi
  # 取所选组件里最大的 min_mem
  local need=0 comp sel ver meta m
  while IFS='|' read -r comp sel; do
    [ -n "$comp" ] || continue
    ver="${sel%%:*}"
    meta=$(manifest_lookup "$comp" "$ver" 2>/dev/null) || continue
    meta="${meta#*|}"
    m=$(meta_get "$meta" min_mem)
    [ -n "$m" ] || m=0
    [ "$m" -gt "$need" ] 2>/dev/null && need="$m"
  done < <(_pc_each_sel)
  if [ "$need" -gt 0 ] && [ "$mem" -lt "$need" ]; then
    _pc_warn "内存 ${mem}MB < 所选组件建议的 ${need}MB（源码编译可能 OOM；可用 swap 兜底或改用 binary/pkg 形式）"
  else
    _pc_ok "内存 ${mem}MB${need:+（所选组件最高要求 ${need}MB）}"
  fi
  local sw; sw=$(awk '/^SwapTotal:/{print int($2/1024)}' /proc/meminfo 2>/dev/null)
  if [ -n "$sw" ] && [ "$sw" = 0 ] && [ "$mem" -lt 2048 ] 2>/dev/null; then
    _pc_warn "无 swap 且内存 < 2GB：建议先加 swap（安装器会调用 conf/swap.sh 自动处理）"
  fi
}

# ---- 4) 端口占用 -----------------------------------------------------------
_pc_ports() {
  echo "[4/10] 端口占用 (ports)"
  if ! _pc_port_tool; then
    _pc_info "ss/netstat 均不可用，跳过端口检查"; return 0
  fi
  local p label owner
  while read -r p label; do
    [ -n "$p" ] || continue
    if _pc_port_busy "$p"; then
      owner=$(_pc_port_owner "$p")
      _pc_warn "端口 ${p} (${label}) 已被占用${owner:+（进程: ${owner}）}；若与本安装器要装的服务冲突，装完会启动失败"
    else
      _pc_ok "端口 ${p} (${label}) 空闲"
    fi
  done <<EOF
80 HTTP
443 HTTPS
3306 MySQL/MariaDB
6379 Redis
11211 Memcached
8080 Tomcat
EOF
}

# ---- 5) 已装冲突 -----------------------------------------------------------
_pc_conflict() {
  echo "[5/10] 已装组件冲突 (existing packages)"
  local bad=0 n
  for n in nginx httpd php mysql-server mariadb-server redis; do
    if _pc_syspkg_installed "$n"; then
      _pc_warn "系统包 ${n} 已安装：会与本安装器的 /usr/local 版本抢端口/服务名/PATH，建议先 systemctl disable --now ${n}"
      bad=1
    fi
  done
  [ "$bad" = 0 ] && _pc_ok "未发现冲突的系统包 (nginx/httpd/php/mysql/mariadb/redis)"

  local pre
  for pre in "${PREFIX_NGINX}" "${PREFIX_PHP}" "${PREFIX_MYSQL}" "${PREFIX_MARIADB}" "${PREFIX_REDIS}" "${PREFIX_MEMCACHED}" "${PREFIX_NODE}"; do
    [ -n "$pre" ] && [ -d "$pre" ] && _pc_info "已存在 ${pre}（将按所选版本覆盖；配置会先备份为 .bak.<时间戳>）"
  done
}

# ---- 6) glibc --------------------------------------------------------------
_pc_glibc() {
  echo "[6/10] glibc 与二进制包兼容性 (glibc)"
  local have; have=$(_pc_glibc_ver)
  [ -n "$have" ] || { _pc_info "取不到 glibc 版本，跳过"; return 0; }

  local checked=0 comp sel ver mode meta need
  while IFS='|' read -r comp sel; do
    [ -n "$comp" ] || continue
    case "$comp" in MYSQL|MARIADB) ;; *) continue ;; esac
    ver="${sel%%:*}"; mode="${sel##*:}"
    [ "$mode" = binary ] || continue
    meta=$(manifest_lookup "$comp" "$ver" 2>/dev/null) || continue
    meta="${meta#*|}"
    need=$(meta_get "$meta" glibc)
    [ -n "$need" ] || continue
    need="${need#glibc}"
    checked=1
    if ver_ge "$have" "$need"; then
      _pc_ok "glibc ${have} 满足 ${comp} ${ver} 的要求 (≥ ${need})"
    else
      _pc_fail "glibc ${have} 低于 ${comp} ${ver} 二进制包要求 (≥ ${need})：会直接报 GLIBC_2.xx not found。请改用 pkg 形式，或换低版本（如 MySQL 8.0/5.7）"
    fi
  done < <(_pc_each_sel)
  [ "$checked" = 1 ] || _pc_ok "未选择二进制数据库，glibc 版本无需特别校验（当前 ${have}）"
}

# ---- 7) 时间同步 -----------------------------------------------------------
_pc_time() {
  echo "[7/10] 时间同步 (time sync)"
  if _pc_time_synced; then
    _pc_ok "系统时钟已同步"
  else
    _pc_warn "未检测到 NTP 同步：证书校验、MySQL 主从复制都可能出问题（装 chrony: pkg_install chrony && systemctl enable --now chronyd）"
  fi
}

# ---- 8) DNS ----------------------------------------------------------------
_pc_dns() {
  echo "[8/10] DNS 与外网 (dns)"
  local h ok=0 fail=0
  for h in nginx.org www.php.net codeload.github.com getcomposer.org; do
    if _pc_resolve "$h"; then
      ok=$((ok+1))
    else
      fail=$((fail+1))
    fi
  done
  if [ "$fail" = 0 ]; then
    _pc_ok "DNS 正常，官方源可达（${ok}/4）"
    return 0
  fi

  # 全部解析失败时，必须区分"真离线"和"DNS 配错"——两种处理方式完全不同：
  # 前者要预放安装包，后者只要改 /etc/resolv.conf。真机（199，Rocky 8.10）上
  # resolv.conf 只指向了一个不转发外网的内网 DNS，IP 层是通的，却被误报成离线。
  if [ "$ok" = 0 ] && _pc_ip_reachable; then
    _pc_fail "域名全部解析失败，但 IP 层可达（能 ping 通公共 DNS）—— 这是 DNS 配置问题，不是离线"
    _pc_info "修复: 往 /etc/resolv.conf 加公共 DNS，例如 nameserver 223.5.5.5"
    _pc_info "      当前: $(grep -E '^nameserver' /etc/resolv.conf 2>/dev/null | tr '\n' ' ')"
    _pc_info "      验证: getent hosts mirrors.aliyun.com"
    return 0
  fi

  if [ "$ok" = 0 ]; then
    _pc_warn "4 个域名全部解析失败、IP 层也不通：这台机器基本离线。请把安装包预放到 packages/（见 packages/README.txt）"
  else
    _pc_warn "部分域名解析失败（${ok} 通 / ${fail} 不通）：官方源可能超时，安装器会自动回落到镜像站"
  fi
}

# IP 层是否可达（绕开 DNS，直接打公共 DNS 的 IP）。有 ping 用 ping，没有就用 curl 裸 IP。
_pc_ip_reachable() {
  if command -v ping >/dev/null 2>&1; then
    ping -c 1 -W 2 223.5.5.5 >/dev/null 2>&1 && return 0
    ping -c 1 -W 2 114.114.114.114 >/dev/null 2>&1 && return 0
    return 1
  fi
  command -v curl >/dev/null 2>&1 || return 1
  curl -s -m 4 -o /dev/null "http://223.5.5.5" 2>/dev/null && return 0
  return 1
}

# ---- 9) 杂项 ---------------------------------------------------------------
# 探测包管理器：**不能**用 $OS_FAMILY 判断 —— 它只在 detect_os 之后才有值，
# 而 precheck_main 可能被单独调用（测试、或被别的脚本 source）。曾经这里写成
# `[ "$OS_FAMILY" = debian ] && apt || dnf`，在 Ubuntu 上 OS_FAMILY 为空时
# 走 else 去找 dnf，直接报 "找不到包管理器 dnf/yum" 的假失败。
_pc_pm() {
  if command -v apt-get >/dev/null 2>&1; then echo apt
  elif command -v dnf     >/dev/null 2>&1; then echo dnf
  elif command -v yum     >/dev/null 2>&1; then echo yum
  fi
}

_pc_tools() {
  echo "[9/10] 基础命令 (basic tools)"
  # 这些是"解包 + 编译"的前置。缺了必然在第一步失败，但错误往往埋在编译日志里：
  # `tar: command not found` 会和 configure 输出混在一起，很难第一眼看出根因。
  # 真机案例：Rocky Linux 9.8 最小化安装**没有 tar**（实测 10.53.123.209），
  # 安装器在下载完源码、执行 tar 解包时直接失败。
  local base="tar gzip xz" build="make gcc patch" c mb="" mbuild="" optional=""
  for c in $base;  do command -v "$c" >/dev/null 2>&1 || mb="$mb $c"; done
  for c in $build; do command -v "$c" >/dev/null 2>&1 || mbuild="$mbuild $c"; done
  for c in awk sed grep find; do command -v "$c" >/dev/null 2>&1 || optional="$optional $c"; done

  # 解包工具：下载完就要用，且部分步骤（install_nghttp2 等）早于 dep 的补装，
  # 所以缺了算阻塞项。
  local pm; pm=$(_pc_pm)
  if [ -z "$mb" ]; then
    _pc_ok "解包工具齐全 (tar/gzip/xz)"
  else
    _pc_fail "缺少解包工具:${mb} —— 源码下载完成后会在第一步解包失败"
    case "$pm" in
      apt) _pc_info "修复: apt-get update && apt-get install -y tar gzip xz-utils" ;;
      *)   _pc_info "修复: dnf install -y tar gzip xz" ;;
    esac
  fi

  # 编译工具：dep() 会自动补装，所以只是警告（但最小化镜像上务必确认能装上）
  if [ -z "$mbuild" ]; then
    _pc_ok "编译工具齐全 (make/gcc/patch)"
  else
    _pc_warn "缺少编译工具:${mbuild}（安装器会自动补装；若包源不可用则会失败）"
  fi

  [ -n "$optional" ] && _pc_warn "缺少常用命令:${optional}（安装脚本本身依赖它们）"

  # 包管理器本身不可用的话，上面自动补装也无从谈起
  if [ -n "$pm" ]; then
    _pc_ok "包管理器可用 (${pm})"
  else
    _pc_fail "找不到包管理器 (apt/dnf/yum)：无法自动安装依赖，请先修复包管理环境"
  fi
}

_pc_misc() {
  echo "[10/10] 其它 (misc)"
  # /tmp 挂 noexec 会让 configure/make 生成的临时可执行文件直接失败
  local opts; opts=$(awk '$2=="/tmp"{print $4}' /proc/mounts 2>/dev/null)
  case ",${opts}," in
    *,noexec,*) _pc_fail "/tmp 挂载了 noexec：源码编译（configure 探测）会失败，请先 remount 去掉 noexec" ;;
    *)          _pc_ok  "/tmp 可执行" ;;
  esac

  if command -v getenforce >/dev/null 2>&1; then
    case "$(getenforce 2>/dev/null)" in
      Enforcing) _pc_warn "SELinux 处于 Enforcing：可能拦截非标准路径的 nginx/php-fpm（安装器会尝试置为 disabled，需重启生效）" ;;
      *)         _pc_ok "SELinux 非 Enforcing" ;;
    esac
  else
    _pc_info "无 getenforce（非 RHEL 系或未装 SELinux 工具）"
  fi

  # PHP 7.x 与系统 OpenSSL 的搭配：7.x 的 ext/openssl 编不过 OpenSSL 3.x。
  # 这里只提示会走哪条路，避免装到一半才发现在编译 OpenSSL（耗时且占空间）。
  local _php_sel="" _phpver="" _sysossl=""
  _php_sel=$(printf '%s\n' "${SEL_PHP:-}" | head -1)
  [ -n "$_php_sel" ] && _phpver="${_php_sel%%:*}" && _phpver="${_phpver%%.*}"
  if [ "${_phpver:-0}" = "7" ] 2>/dev/null; then
    _sysossl=$(openssl version 2>/dev/null | awk '{print $2}')
    case "$_sysossl" in
      1.1.1*|1.0.2*)
        _pc_ok "PHP ${_php_sel%%:*} 使用系统 OpenSSL ${_sysossl}（7.x 不支持 3.x，系统正好是 1.1.1）"
        ;;
      *)
        _pc_info "PHP ${_php_sel%%:*} 需要 OpenSSL 1.1.1（系统为 ${_sysossl:-未知}）：安装时会额外编译一份 1.1.1 到 ${PREFIX_OPENSSL_11:-/usr/local/openssl-1.1}，并自动关闭 LDAP/Kerberos 以避开两套 libcrypto 混链"
        ;;
    esac
  fi

  # 监听队列：调优前先看一眼，方便装完对比
  local somax; somax=$(sysctl -n net.core.somaxconn 2>/dev/null)
  [ -n "$somax" ] && _pc_info "当前 net.core.somaxconn = ${somax}（安装器会调到 ≥65535）"
  local nofile; nofile=$(ulimit -Hn 2>/dev/null)
  [ -n "$nofile" ] && _pc_info "当前 hard nofile = ${nofile}（安装器会调到 ${SYSCTL_NOFILE:-65535}）"

  # locale：极简镜像/云镜像常在 /etc/locale.conf 写着 LANG=en_US.UTF-8 却没生成该 locale，
  # Redis 7.4+ 会因 setlocale 失败在启动时直接退出（服务永远起不来）。
  # 这里只读提示（不改系统），安装阶段 ensure_utf8_locale 会自动修复。
  local _loc; _loc=$(sed -n 's/^[[:space:]]*LANG[[:space:]]*=[[:space:]]*"\?\([^"]*\)"\?.*/\1/p' \
                     /etc/locale.conf 2>/dev/null | head -1)
  [ -n "$_loc" ] || _loc="${LANG:-}"
  if [ -n "$_loc" ] && ! _locale_available "$_loc"; then
    _pc_warn "系统 locale 不可用 (LANG=${_loc})：Redis 7.4+ 等服务会启动失败（安装器会自动修复）"
  fi
}

# ---- 主入口 ---------------------------------------------------------------
precheck_main() {
  _PC_PASS=0; _PC_WARN=0; _PC_FAIL=0; _PC_INFO=0
  hr
  log "安装前预检 (pre-install precheck) —— 只读检查，不改系统"
  hr

  _pc_system
  _pc_disk
  _pc_mem
  _pc_ports
  _pc_conflict
  _pc_glibc
  _pc_time
  _pc_dns
  _pc_tools
  _pc_misc

  hr
  printf '  预检结果 (result): PASS=%d  WARN=%d  FAIL=%d  INFO=%d\n' "$_PC_PASS" "$_PC_WARN" "$_PC_FAIL" "$_PC_INFO"
  if [ "$_PC_FAIL" -gt 0 ]; then
    printf '  ❌ 存在 %d 项阻塞问题，建议修复后再安装（继续安装大概率中途失败）\n' "$_PC_FAIL"
    hr
    return 2
  fi
  if [ "$_PC_WARN" -gt 0 ]; then
    printf '  ⚠️  有 %d 项警告，不阻塞安装，但请确认是否可接受\n' "$_PC_WARN"
  else
    printf '  ✅ 预检全部通过，可以开始安装\n'
  fi
  hr
  return 0
}
