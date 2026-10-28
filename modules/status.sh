#!/bin/bash
# ============================================================================
#  modules/status.sh  ——  运维总览 (one-screen status)
# ----------------------------------------------------------------------------
#  verify 回答"装对了吗"，status 回答"现在怎么样"。三段信息：
#    1) 主机      负载 / 内存 / Swap / 根分区 / inode / 运行时长
#    2) 组件      已装版本 / 服务状态 / 监听地址 / PHP 扩展
#    3) 站点      vhost 清单（域名 / 端口 / 根目录是否存在 / 是否有 TLS）
#  外加：证书剩余天数、近期错误日志摘要、可升级组件。
#
#  用法:
#    bash install.sh status            # 一屏总览
#    bash install.sh status --brief    # 单行摘要（给 zabbix / 自建监控采集，
#                                      #   退出码 0=正常 1=有告警）
#
#  设计原则：**纯只读**。不改配置、不重启服务、不往站点目录写探针文件
#  （verify 会写 __lnamp_probe.php，status 绝不写任何东西）。
# ============================================================================

_ST_WARN=0
_st_sec()  { echo; printf '%s\n' "$(_c '1;36' "== $* ==")"; }
_st_warn() { log_warn "$*"; _ST_WARN=$((_ST_WARN + 1)); }

# KB -> 人类可读
_st_kb() {
  awk -v k="${1:-0}" 'BEGIN{
    split("KB MB GB TB PB", u, " "); i = 1
    while (k >= 1024 && i < 5) { k /= 1024; i++ }
    printf "%.1f%s", k, u[i]
  }'
}

# 秒 -> "3天4小时"
_st_dur() {
  local s="${1:-0}"
  if   [ "$s" -ge 86400 ]; then printf '%d天%d小时' $((s / 86400)) $((s % 86400 / 3600))
  elif [ "$s" -ge 3600 ];  then printf '%d小时%d分' $((s / 3600)) $((s % 3600 / 60))
  else                          printf '%d分钟' $((s / 60))
  fi
}

# ---------------------------------------------------------------------------
#  一次性采集（避免对 systemctl / ss 反复调用，7 个组件各调一次要 2 秒）
# ---------------------------------------------------------------------------
_ST_UNITS=""; _ST_SS=""
_st_collect() {
  if command -v systemctl >/dev/null 2>&1; then
    _ST_UNITS=$(systemctl list-unit-files 2>/dev/null)
  fi
  if command -v ss >/dev/null 2>&1; then
    _ST_SS=$(ss -lnt 2>/dev/null | awk 'NR>1{print $4}')
  elif command -v netstat >/dev/null 2>&1; then
    _ST_SS=$(netstat -lnt 2>/dev/null | awk 'NR>2{print $4}')
  fi
}

_st_unit_exists() { [ -n "$_ST_UNITS" ] && printf '%s\n' "$_ST_UNITS" | grep -c "^$1\.service" >/dev/null 2>&1; }

_st_svc_state() {
  local name="$1"
  command -v systemctl >/dev/null 2>&1 || { echo "n/a"; return 0; }
  _st_unit_exists "$name" || { echo "-"; return 0; }
  if systemctl is-active --quiet "$name" 2>/dev/null; then echo "active"; else echo "STOPPED"; fi
}

# 某端口是否在听；是则回显"addr:port"，否则空
_st_listen_addr() {
  [ -n "$_ST_SS" ] || return 0
  printf '%s\n' "$_ST_SS" | grep -E "[:.]$1\$" 2>/dev/null | head -1
}

# ---------------------------------------------------------------------------
#  主机段
# ---------------------------------------------------------------------------
_st_host() {
  _st_sec "主机 (host)"
  local os kern up load mem_total mem_avail swap_total swap_free
  os=$( . /etc/os-release 2>/dev/null && printf '%s' "${PRETTY_NAME:-unknown}" ) || os="unknown"
  kern=$(uname -r 2>/dev/null)
  up=$(awk '{print int($1)}' /proc/uptime 2>/dev/null || echo 0)
  load=$(awk '{printf "%s %s %s", $1, $2, $3}' /proc/loadavg 2>/dev/null || echo "-")
  printf '  %-8s %s  (kernel %s)\n' "OS" "$os" "$kern"
  printf '  %-8s %s   运行 %s\n' "负载" "$load" "$(_st_dur "$up")"

  if [ -r /proc/meminfo ]; then
    mem_total=$(awk '/^MemTotal:/{print $2}' /proc/meminfo)
    mem_avail=$(awk '/^MemAvailable:/{print $2}' /proc/meminfo)
    # MemAvailable 是 3.14+ 才有的；缺失时按 Free+Buffers+Cached 估算，
    # 否则 avail 为空 -> used = total -> 永远是"100%"
    [ -n "$mem_avail" ] || mem_avail=$(awk '
      /^MemFree:/{f=$2} /^Buffers:/{b=$2} /^Cached:/{c=$2}
      END{ if (f=="" && b=="" && c=="") print ""; else printf "%d", f+b+c }' /proc/meminfo)
    case "$mem_avail" in ''|*[!0-9]*) mem_avail="" ;; esac
    swap_total=$(awk '/^SwapTotal:/{print $2}' /proc/meminfo)
    swap_free=$(awk '/^SwapFree:/{print $2}' /proc/meminfo)
    # mem_total 缺失或 mem_avail 取不到时，只显示总量，不编造百分比
    case "$mem_total" in ''|*[!0-9]*) mem_total=0 ;; esac
    local used=0 pct=0
    if [ -n "$mem_avail" ] && [ "$mem_total" -gt 0 ]; then
      used=$((mem_total - mem_avail))
      pct=$((used * 100 / mem_total))
    else
      mem_avail=$mem_total; used=0; pct=0
    fi
    printf '  %-8s %s / %s (%d%%)    Swap %s / %s\n' "内存" \
      "$(_st_kb "$used")" "$(_st_kb "$mem_total")" "$pct" \
      "$(_st_kb $((swap_total - swap_free)) )" "$(_st_kb "$swap_total")"
    [ "$pct" -ge 90 ] && _st_warn "内存使用率 ${pct}%，建议检查是否有进程泄漏或调小 MySQL buffer pool"
  else
    printf '  %-8s %s\n' "内存" "n/a"
  fi

  # 根分区容量 + inode（inode 满表现为"磁盘还有空间但写不进去"，最难排查）
  local dline iline
  dline=$(df -kP / 2>/dev/null | awk 'NR==2 && NF>=6{print $(NF-4), $(NF-3), $(NF-1)}')
  if [ -n "$dline" ]; then
    local t u p
    t=$(echo "$dline" | awk '{print $1}'); u=$(echo "$dline" | awk '{print $2}'); p=$(echo "$dline" | awk '{print $3}')
    local ipct="-"
    iline=$(df -iP / 2>/dev/null | awk 'NR==2 && NF>=6{print $(NF-1)}')
    [ -n "$iline" ] && ipct="$iline"
    printf '  %-8s %s / %s (%s)    inode %s\n' "磁盘 /" "$(_st_kb "$u")" "$(_st_kb "$t")" "$p" "$ipct"
    local pn=${p%\%}; local in=${ipct%\%}
    case "$pn" in ''|*[!0-9]*) pn=0 ;; esac
    case "$in" in ''|*[!0-9]*) in=0 ;; esac
    [ "${pn:-0}" -ge 90 ] 2>/dev/null && _st_warn "根分区使用率 ${p}，清理日志（logs/ 与 /root/lnamp-predump-*）"
    [ "${in:-0}" -ge 90 ] 2>/dev/null && _st_warn "inode 使用率 ${ipct}，大量小文件占满（常见于 session/缓存目录）"
  fi

  # 时间不同步会让 TLS/签名/日志时间线全部失准
  if command -v timedatectl >/dev/null 2>&1; then
    local sync; sync=$(timedatectl show -p NTPSynchronized --value 2>/dev/null)
    [ "$sync" = "no" ] && _st_warn "系统时钟未同步 (NTPSynchronized=no)，建议 systemctl enable --now systemd-timesyncd"
  fi
}

# ---------------------------------------------------------------------------
#  组件段
# ---------------------------------------------------------------------------
_st_components() {
  _st_sec "组件 (components)"
  printf '  %-12s %-16s %-9s %s\n' "组件" "版本" "服务" "监听"
  printf '  %-12s %-16s %-9s %s\n' "------------" "----------------" "---------" "----------------------"

  local installed=0
  # 组件名 服务名 端口
  local spec="nginx:nginx:80 apache:httpd:80 php:php-fpm:- mysql:mysqld:3306 mariadb:mariadb:3306 redis:redis:6379 memcached:memcached:11211 fail2ban:fail2ban:-"
  local item comp svc port ver state addr label
  for item in $spec; do
    comp=${item%%:*}; item=${item#*:}
    svc=${item%%:*};  port=${item#*:}
    ver=$(_up_current_version "$comp" 2>/dev/null)
    [ -n "$ver" ] || continue          # 没装就不列
    installed=$((installed + 1))
    case "$comp" in
      nginx)  label=$("${PREFIX_NGINX}/sbin/nginx" -v 2>&1 | grep -ci freenginx >/dev/null && echo freenginx || echo nginx) ;;
      apache) label=apache ;;
      php)    label=php ;;
      *)      label=$comp ;;
    esac
    state=$(_st_svc_state "$svc")
    [ "$state" = "STOPPED" ] && _st_warn "${comp} 已安装但服务未运行 (systemctl start ${svc})"
    if [ "$port" = "-" ]; then
      addr="-"
      [ "$comp" = "php" ] && addr="unix:${PHP_FPM_SOCK}"
    else
      addr=$(_st_listen_addr "$port")
      [ -z "$addr" ] && addr="未监听:${port}" && _st_warn "${comp} 端口 ${port} 未监听"
    fi
    printf '  %-12s %-16s %-9s %s\n' "$label" "$ver" "$state" "$addr"
  done
  # 一个组件都没探测到 = 没装，或 PREFIX 与 versions.conf 不一致（装了却看不见），
  # 两种都该算告警，不能让总览底下一句"未发现异常"盖过去
  [ "$installed" -eq 0 ] && _st_warn "本机未探测到任何本栈组件（未安装？或 PREFIX 与 versions.conf 不一致）"

  # PHP 扩展一行带过（逐个列会占满一屏）
  local phpbin="${PREFIX_PHP}/bin/php" exts="" e m
  if [ -x "$phpbin" ]; then
    local mods; mods=$("$phpbin" -m 2>/dev/null | tr 'A-Z' 'a-z')
    # opcache 的模块名是 "Zend OPcache"（带空格），不能按 "opcache" 整行匹配
    for e in redis memcached swoole imagick 'zend opcache'; do
      printf '%s\n' "$mods" | grep -cx "$e" >/dev/null 2>&1 || continue
      case "$e" in
        'zend opcache') exts="$exts opcache" ;;
        *) m=$("$phpbin" -r "echo phpversion('$e');" 2>/dev/null); exts="$exts ${e}${m:+($m)}" ;;
      esac
    done
    [ -n "$exts" ] && printf '  %-12s %s\n' "PHP 扩展" "$exts"
  fi
}

# ---------------------------------------------------------------------------
#  站点段（vhost 清单）
# ---------------------------------------------------------------------------
_st_sites() {
  _st_sec "站点 (sites)"
  local dirs="" d
  for d in "${PREFIX_NGINX}/conf/vhost" "${PREFIX_APACHE}/conf/vhost" /etc/nginx/conf.d /etc/apache2/sites-enabled; do
    [ -d "$d" ] && dirs="$dirs $d"
  done
  if [ -z "$dirs" ]; then
    log "未发现 vhost 目录（还没有创建过站点）"
    return 0
  fi

  local n=0 f dom port root ssl
  for d in $dirs; do
    for f in "$d"/*.conf; do
      [ -f "$f" ] || continue
      case "$f" in *.bak.*) continue ;; esac
      dom=$(sed -n 's/^[[:space:]]*server_name[[:space:]]\+\([^;]*\);.*/\1/p' "$f" 2>/dev/null | head -1)
      [ -n "$dom" ] || continue
      [ "$dom" = "_" ] && dom="(默认站点)"
      port=$(sed -n 's/^[[:space:]]*listen[[:space:]]\+\([0-9]\+\).*/\1/p' "$f" 2>/dev/null | head -1)
      root=$(sed -n 's/^[[:space:]]*root[[:space:]]\+\([^;]*\);.*/\1/p' "$f" 2>/dev/null | head -1)
      [ -n "$root" ] || root=$(sed -n 's/^[[:space:]]*DocumentRoot[[:space:]]\+"\{0,1\}\([^";]*\)"\{0,1\}.*/\1/p' "$f" 2>/dev/null | head -1)
      ssl="-"
      grep -c 'ssl_certificate' "$f" >/dev/null 2>&1 && ssl="TLS"
      n=$((n + 1))
      local flag=""
      if [ -n "$root" ] && [ ! -d "$root" ]; then
        flag="  [!] 根目录不存在"
        _ST_WARN=$((_ST_WARN + 1))
      fi
      printf '  %-32s :%-5s %-34s %s%s\n' "$dom" "${port:-?}" "${root:-?}" "$ssl" "$flag"
    done
  done
  [ "$n" -eq 0 ] && log "未发现已配置的站点"
}

# ---------------------------------------------------------------------------
#  TLS 证书剩余天数
# ---------------------------------------------------------------------------
_st_certs() {
  local files="" d f
  for d in "${PREFIX_NGINX}/conf" "${PREFIX_APACHE}/conf"; do
    [ -d "$d" ] || continue
    files="$files $(grep -rhs '^[[:space:]]*ssl_certificate[[:space:]]' "$d" 2>/dev/null | sed 's/.*[[:space:]]\([^;]*\);.*/\1/')"
  done
  files=$(printf '%s\n' $files | sort -u)
  [ -n "$files" ] || return 0
  command -v openssl >/dev/null 2>&1 || return 0

  _st_sec "证书 (certificates)"
  local exp end days
  for f in $files; do
    [ -r "$f" ] || { _st_warn "证书文件不可读: $f"; continue; }
    end=$(openssl x509 -in "$f" -noout -enddate 2>/dev/null | sed 's/notAfter=//')
    [ -n "$end" ] || { _st_warn "证书无法解析: $f"; continue; }
    days=$(( ( $(date -d "$end" +%s 2>/dev/null || echo 0) - $(date +%s) ) / 86400 ))
    if [ "$days" -le 0 ]; then
      _st_warn "证书已过期: $f"
    elif [ "$days" -le 15 ]; then
      _st_warn "证书 ${days} 天后过期: $f"
    else
      printf '  %-4s 剩余 %s 天   %s\n' "OK" "$days" "$f"
    fi
  done
}

# ---------------------------------------------------------------------------
#  近期错误日志摘要（只看尾部，避免大日志拖慢）
# ---------------------------------------------------------------------------
_st_errors() {
  _st_sec "近期错误 (recent errors)"
  local found=0 f n last

  _st_err_scan() {   # 文件 标签 关键字
    local file="$1" label="$2" kw="$3"
    [ -r "$file" ] || return 0
    n=$(tail -400 "$file" 2>/dev/null | grep -cE "$kw")
    if [ "${n:-0}" -gt 0 ]; then
      last=$(tail -400 "$file" 2>/dev/null | grep -E "$kw" | tail -1 | cut -c1-110)
      printf '  %-10s %s 条 (尾部 400 行)  最后: %s\n' "$label" "$n" "$last"
      found=1
      [ "$n" -ge 20 ] && _st_warn "${label} 尾部 400 行内有 ${n} 条错误，值得看日志"
    fi
  }

  _st_err_scan "${PREFIX_NGINX}/logs/error.log" "nginx" '\[(error|crit|alert|emerg)\]'
  _st_err_scan "${PREFIX_PHP}/var/log/php-fpm.log" "php-fpm" '\[(error|alert|emerg)\]|ERROR'
  local errf
  for errf in /data/mysql/data/*.err /data/mariadb/data/*.err; do
    [ -f "$errf" ] && _st_err_scan "$errf" "mysql" '\[ERROR\]'
  done

  [ "$found" = 0 ] && log_ok "未发现近期错误日志条目"
}

# ---------------------------------------------------------------------------
#  可升级组件（已装版本 vs versions.conf 参考版本）
# ---------------------------------------------------------------------------
_st_updates() {
  local comp cur want any=0 seen=0 cross=0
  for comp in nginx php mysql mariadb redis memcached; do
    cur=$(_up_current_version "$comp" 2>/dev/null)
    [ -n "$cur" ] || continue
    seen=$((seen + 1))
    case "$comp" in
      nginx)     want="${NGINX_DEFAULT}" ;;
      php)       want="${PHP_DEFAULT}" ;;
      mysql)     want="${MYSQL_DEFAULT}" ;;
      mariadb)   want="${MARIADB_DEFAULT}" ;;
      redis)     want="${REDIS_DEFAULT}" ;;
      memcached) want="${MEMCACHED_DEFAULT}" ;;
    esac
    [ -n "$want" ] || continue
    # 只在"已装版本确实低于默认版本"时才提；已装更高（如 mainline 1.31 > 默认 1.30）
    # 不该被说成"有更新"。另外跨大版本（8.4 LTS vs 9.x 创新版）不逐条列，
    # 那是两条发布线，直接按默认版本升级会出事。
    if ver_ge "$cur" "$want" 2>/dev/null; then continue; fi
    if [ "${cur%%.*}" != "${want%%.*}" ]; then cross=1; continue; fi
    if [ "$cur" != "$want" ]; then
      [ "$any" = 0 ] && { _st_sec "版本参考 (version reference)"; any=1; }
      printf '  %-10s 已装 %-12s versions.conf 默认 %s\n' "$comp" "$cur" "$want"
    fi
  done
  if [ "$seen" = 0 ]; then
    log "未探测到组件，跳过版本比对"
  elif [ "$any" = 1 ]; then
    # 这一栏只做"参考版本"提示，不是升级建议：8.4(LTS) 与 9.x(创新版) 是两条线，
    # 直接按默认版本升级会跨大版本。要升请显式: upgrade <组件> <版本>
    log "注: 仅为 versions.conf 的默认版本，不代表必须升级（跨大版本如 MySQL 8.4 LTS -> 9.x 需自行评估）"
  elif [ "$any" = 0 ]; then
    log "组件版本与 versions.conf 参考版本一致（无同系列更新提示）"
    [ "$cross" = 1 ] && log "另有跨大版本的默认版本差异（如 MySQL 8.4 LTS 与 9.x 创新版属两条发布线），不做升级提示"
  fi
}

# ---------------------------------------------------------------------------
#  入口
# ---------------------------------------------------------------------------
status_main() {
  local brief=0 a
  for a in "$@"; do
    case "$a" in
      --brief|-b) brief=1 ;;
      -h|--help)
        echo "用法: $0 status [--brief]"
        echo "  --brief   只输出一行摘要（退出码 0=正常 1=有告警）"
        return 0 ;;
      *) die "status: 未知参数 $a" ;;
    esac
  done

  _st_collect

  if [ "$brief" = 1 ]; then
    local svc_total=0 svc_ok=0 s
    # 统计所有本栈 unit（含 fail2ban），否则简报里的 5/5 会漏掉被停掉的 fail2ban
    for s in nginx php-fpm mysqld mariadb redis memcached fail2ban; do
      _st_unit_exists "$s" || continue
      svc_total=$((svc_total + 1))
      systemctl is-active --quiet "$s" 2>/dev/null && svc_ok=$((svc_ok + 1))
    done
    local dusage mempct errn=0
    dusage=$(df -kP / 2>/dev/null | awk 'NR==2 && NF>=6{print $(NF-1)}')
    mempct=$(awk '
      /^MemTotal:/{t=$2} /^MemAvailable:/{a=$2}
      /^MemFree:/{f=$2} /^Buffers:/{b=$2} /^Cached:/{c=$2}
      END{ if (a=="") a=f+b+c; if (t>0 && a!="") printf "%d", (t-a)*100/t; else print 0 }' /proc/meminfo 2>/dev/null || echo 0)
    [ -r "${PREFIX_NGINX}/logs/error.log" ] && errn=$(tail -400 "${PREFIX_NGINX}/logs/error.log" 2>/dev/null | grep -cE '\[(error|crit|alert|emerg)\]')
    # 告警判定与详细模式保持一致：服务掉线 / 磁盘 90%+ / 内存 90%+
    local flag="ok"
    [ "$svc_total" -gt 0 ] && [ "$svc_ok" -lt "$svc_total" ] && { flag="degraded"; _ST_WARN=$((_ST_WARN + 1)); }
    [ "${dusage%\%}" -ge 90 ] 2>/dev/null && { flag="degraded"; _ST_WARN=$((_ST_WARN + 1)); }
    [ "${mempct:-0}" -ge 90 ] 2>/dev/null && { flag="degraded"; _ST_WARN=$((_ST_WARN + 1)); }
    printf 'lnamp_status=%s services=%s/%s disk=%s mem=%s%% nginx_err=%s warns=%s\n' \
      "$flag" "$svc_ok" "$svc_total" "${dusage:-?}" "${mempct:-0}" "${errn:-0}" "$_ST_WARN"
    [ "$_ST_WARN" -gt 0 ] && return 1
    return 0
  fi

  echo
  printf '%s\n' "$(_c '1;37' "lnamp status  $(date '+%Y-%m-%d %H:%M:%S')")"
  _st_host
  _st_components
  _st_sites
  _st_certs
  _st_errors
  _st_updates

  echo
  if [ "$_ST_WARN" -gt 0 ]; then
    log_warn "共 ${_ST_WARN} 项告警，详见上方 [!] 行。深入排查: $0 doctor"
    return 1
  fi
  log_ok "未发现异常。深入排查（权限/ABI/配置漂移）: $0 doctor"
  return 0
}
