#!/bin/bash
# ============================================================================
#  modules/fail2ban.sh  ——  fail2ban 防暴力破解（包管理器安装）
# ----------------------------------------------------------------------------
#  三个 jail：
#    sshd              —— 防 SSH 密码爆破（最常用）
#    nginx-http-auth   —— 防 HTTP Basic Auth 爆破
#    nginx-limit-req   —— 触发 nginx limit_req 的异常来源（需 nginx 配置了限速）
#
#  仅用发行版仓库安装（RHEL 系需 EPEL），不做源码编译 —— 这个组件跟着发行版
#  走最省心，安全补丁也能随系统更新。
#
#  用法: install_fail2ban <version> <mode>      mode 目前只有 pkg
#  环境: ASSUME_YES=1 / 非交互时不会提问
# ============================================================================

# 生成 jail 配置时的公共参数（集中在一处，便于按需调整）
FAIL2BAN_BANTIME="${FAIL2BAN_BANTIME:-1h}"
FAIL2BAN_FINDTIME="${FAIL2BAN_FINDTIME:-10m}"
FAIL2BAN_MAXRETRY="${FAIL2BAN_MAXRETRY:-5}"

install_fail2ban() {
  local ver="$1" mode="$2"
  log "安装 fail2ban ${ver}  形式(mode)=${mode:-pkg}"
  case "${mode:-pkg}" in
    pkg) _fail2ban_pkg ;;
    *)   die "fail2ban: 只支持 pkg 形式 (仅支持包管理器安装)，收到: ${mode}" ;;
  esac
}

_fail2ban_pkg() {
  if [ "$OS_FAMILY" = debian ]; then
    pkg_update
    pkg_install fail2ban || die "fail2ban 安装失败（apt）"
    # backend = systemd 需要 python3-systemd 绑定；没有它 fail2ban 会报
    # "Have not installed systemd-python"。缺包不影响主流程，装不上只告警。
    if [ -z "$(_fail2ban_ssh_log)" ]; then
      pkg_install python3-systemd >/dev/null 2>&1 || log_warn "python3-systemd 未安装，fail2ban 的 journald 后端可能不可用"
    fi
  else
    # RHEL 系 fail2ban 在 EPEL
    pkg_install epel-release >/dev/null 2>&1 || true
    pkg_install fail2ban || die "fail2ban 安装失败（EPEL 是否可用？）"
  fi
  _fail2ban_write_jail
  enable_service fail2ban

  # 启动后必须真的验一次，而不是只看 enable_service 的返回：fail2ban 对
  # "logpath 匹配不到任何文件" 是硬失败（systemd 里表现为 status=255/EXCEPTION），
  # 此时 sshd 保护也一起没了 —— 比少两个 web jail 严重得多，故降级重试一次。
  if [ "${DRY_RUN:-0}" != 1 ] && command -v systemctl >/dev/null 2>&1; then
    if ! systemctl is-active --quiet fail2ban 2>/dev/null; then
      log_warn "fail2ban 未能启动（常见原因：web 错误日志不存在），降级为仅 sshd jail 再试"
      _fail2ban_write_sshd_only
      systemctl restart fail2ban >/dev/null 2>&1 || true
      if systemctl is-active --quiet fail2ban 2>/dev/null; then
        log_ok "fail2ban 已以 sshd-only 模式启动"
      else
        log_warn "fail2ban 仍无法启动，请手工检查: systemctl status fail2ban"
      fi
    fi
  fi
  _fail2ban_report
}

# SSH 日志路径：debian 系 /var/log/auth.log，RHEL 系 /var/log/secure
# ----------------------------------------------------------------------------
# 但不能只看发行版就认定文件存在：Debian 12 / Ubuntu 最小化镜像默认不装
# rsyslog，/var/log/auth.log 压根不存在（journald 独占）。此时写死路径会让
# sshd jail 报 "Have not found any log file for sshd jail"，fail2ban 整体
# status=255 起不来 —— 连 SSH 防爆破都没有，比少两个 web jail 严重得多。
# 处理：按 auth.log → secure → messages 顺序找真实存在的文件；一个都没有就
# 返回空，由调用方改用 backend = systemd（直接读 journal）。
_fail2ban_ssh_log() {
  local c
  for c in /var/log/auth.log /var/log/secure /var/log/messages; do
    [ -s "$c" ] && { echo "$c"; return 0; }
  done
  echo ""
}


# 站点错误日志：优先 nginx，其次 apache
# glob 必须同时覆盖两类文件名：主错误日志 error_nginx.log（nginx.conf 的 error_log）
# 与虚拟主机 <域名>.error.log。旧的 *error.log 匹配不到前者，零 vhost 的机器上
# fail2ban 会因 "Have not found any log file" 直接启动失败。
_fail2ban_web_log() {
  local p
  if [ -n "${SEL_NGINX:-}" ] || [ -x "${PREFIX_NGINX}/sbin/nginx" ]; then
    echo "${WWWLOGS}/*error*.log"
    return 0
  fi
  if [ -n "${SEL_APACHE:-}" ] || [ -x "${PREFIX_APACHE}/bin/httpd" ]; then
    # 源码安装的 apache 日志在 ${PREFIX_APACHE}/logs/error_log，不是发行版的
    # /var/log/apache2。真机（247，apache 2.4.69 源码装）上写死发行版路径导致
    # logpath 指向不存在的文件，fail2ban 直接
    # "Have not found any log file for nginx-http-auth jail" 启动失败。
    for p in "${PREFIX_APACHE}/logs/error_log" /var/log/apache2/error.log /var/log/httpd/error_log; do
      [ -f "$p" ] && { echo "$p"; return 0; }
    done
    # 都没有就兜底建一个（新装机器可能还没产生任何错误日志）
    if safe_mkdir "${WWWLOGS}" 2>/dev/null && touch "${WWWLOGS}/error_apache.log" 2>/dev/null; then
      echo "${WWWLOGS}/error_apache.log"; return 0
    fi
    echo ""; return 1
  fi
  echo ""
}

# 写一份"只留 sshd"的 jail。fail2ban 对 logpath 匹配不到文件是**硬失败**
# （整个服务起不来），这时候宁可少两个 web jail，也不能让 sshd 保护一起失效。
_fail2ban_write_sshd_only() {
  local jail="/etc/fail2ban/jail.d/lnamp.local" sshlog
  sshlog=$(_fail2ban_ssh_log)
  {
    cat <<EOF
# 由 LNAMP 安装器生成 (managed by lnamp installer)
# 已降级为仅 sshd：web 错误日志不可用（见下方注释），保留它会导致 fail2ban
# 因 "Have not found any log file" 而无法启动，连 sshd 保护一起失效。
[DEFAULT]
bantime  = ${FAIL2BAN_BANTIME}
findtime = ${FAIL2BAN_FINDTIME}
maxretry = ${FAIL2BAN_MAXRETRY}
backend  = auto
ignoreip = 127.0.0.1/8 ::1

[sshd]
enabled  = true
port     = ssh
$(if [ -n "$sshlog" ]; then
        echo "logpath  = ${sshlog}"
      else
        # 注释必须独立成行：fail2ban 的 ini 解析器**不剥离行内注释**，
        # 写成 "backend = systemd  # 说明" 会把整串当值，报
        # "Unknown backend systemd   # ... Must be among ['pyinotify',...]"
        # 然后整个服务 exit 255。
        printf '# 无 /var/log/auth.log（Debian 12 默认无 rsyslog），直接读 journal\n'
        echo "backend  = systemd"
      fi)
maxretry = ${FAIL2BAN_MAXRETRY}
EOF
  } | save_file "$jail"
}

_fail2ban_write_jail() {
  local jail="/etc/fail2ban/jail.d/lnamp.local"
  local sshlog web logdir
  sshlog=$(_fail2ban_ssh_log)
  web=$(_fail2ban_web_log)
  logdir="${WWWLOGS}"

  if [ "${DRY_RUN:-0}" = 1 ]; then
    log "  [dry-run] 将写入 fail2ban jail 配置: ${jail}"
    log "  [dry-run]   sshd            logpath=${sshlog}"
    if [ -n "$web" ]; then
      log "  [dry-run]   nginx-http-auth / nginx-limit-req  logpath=${web}"
    else
      log "  [dry-run]   未检测到 Web 服务器，只启用 sshd jail"
    fi
    log "  [dry-run] 将创建日志目录: ${logdir}（供 nginx jail 读取）"
    return 0
  fi

  # nginx jail 依赖错误日志存在，否则 fail2ban 启动时会报 "Have not found any log file"。
  # 目录建好之外再兜底 touch 主错误日志：新装机器可能一个 vhost 都没有、
  # nginx 也还没写过 error 日志，glob 会匹配不到任何文件。
  if [ -n "$web" ]; then
    safe_mkdir "$logdir" 2>/dev/null
    if [ -x "${PREFIX_NGINX}/sbin/nginx" ]; then
      touch "${WWWLOGS}/error_nginx.log" 2>/dev/null || true
    fi
  fi

  {
    cat <<EOF
# 由 LNAMP 安装器生成 (managed by lnamp installer)
# 手工修改会在下次安装/升级时被覆盖；如需长期自定义请放到 jail.local
[DEFAULT]
bantime  = ${FAIL2BAN_BANTIME}
findtime = ${FAIL2BAN_FINDTIME}
maxretry = ${FAIL2BAN_MAXRETRY}
backend  = auto
ignoreip = 127.0.0.1/8 ::1

[sshd]
enabled  = true
port     = ssh
$(if [ -n "$sshlog" ]; then
        echo "logpath  = ${sshlog}"
      else
        # 注释必须独立成行：fail2ban 的 ini 解析器**不剥离行内注释**，
        # 写成 "backend = systemd  # 说明" 会把整串当值，报
        # "Unknown backend systemd   # ... Must be among ['pyinotify',...]"
        # 然后整个服务 exit 255。
        printf '# 无 /var/log/auth.log（Debian 12 默认无 rsyslog），直接读 journal\n'
        echo "backend  = systemd"
      fi)
maxretry = ${FAIL2BAN_MAXRETRY}
EOF
    if [ -n "$web" ]; then
      cat <<EOF

[nginx-http-auth]
enabled  = true
port     = http,https
logpath  = ${web}
maxretry = ${FAIL2BAN_MAXRETRY}

# 只有 nginx 里配置了 limit_req 才会产生对应日志，未配置时该 jail 静默不匹配
[nginx-limit-req]
enabled  = true
port     = http,https
logpath  = ${web}
maxretry = ${FAIL2BAN_MAXRETRY}
EOF
    fi
  } | save_file "$jail"
  log_ok "已写入 fail2ban 配置: ${jail}"
}

_fail2ban_report() {
  if [ "${DRY_RUN:-0}" = 1 ]; then
    log "  [dry-run] 将启用服务 fail2ban 并打印当前 jail 状态"
    return 0
  fi
  command -v fail2ban-client >/dev/null 2>&1 || return 0
  local v; v=$(fail2ban-client --version 2>/dev/null | head -1)
  log_ok "fail2ban 实际版本 (installed): ${v:-未知}"
  # pkg 模式装的是**发行版仓库**里的包，版本必然与 versions.conf 的清单版本不同
  # （如 Ubuntu 22.04 为 0.11.2，清单写 1.1.1）。这不是安装失败，说明白免得误判。
  local vnum; vnum=$(printf '%s' "$v" | sed -n 's/.*v\([0-9][0-9.]*\).*/\1/p')
  if [ -n "$vnum" ] && [ -n "${FAIL2BAN_DEFAULT:-}" ] && [ "$vnum" != "$FAIL2BAN_DEFAULT" ]; then
    log "  说明: 本次为 pkg 模式，版本跟随发行版仓库（清单参考版本 ${FAIL2BAN_DEFAULT}）。"
    log "        功能（jail/filter/action）无差异；确需最新版请用发行版官方源或自行源码安装 python3 包。"
  fi
  if systemctl is-active --quiet fail2ban 2>/dev/null; then
    log "  已启用的 jail: $(fail2ban-client status 2>/dev/null | sed -n 's/.*Jail list:[[:space:]]*//p')"
    log "  查看封禁: fail2ban-client status sshd"
    log "  手动解封: fail2ban-client set sshd unbanip <IP>"
  else
    log_warn "fail2ban 未处于运行状态，请检查: systemctl status fail2ban"
  fi
  return 0
}
