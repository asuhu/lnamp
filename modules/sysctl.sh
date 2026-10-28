#!/bin/bash
# ============================================================================
#  modules/sysctl.sh  ——  内核参数 / 句柄上限调优 (kernel & fd tuning)
# ----------------------------------------------------------------------------
#  解决的问题：Linux 默认值对 LNMP 高并发是硬瓶颈
#    net.core.somaxconn        = 128      -> accept 队列一满就丢连接
#    net.ipv4.tcp_max_syn_backlog = 1024  -> SYN 洪峰时半连接溢出
#    fs.file-max / nofile      = 1024     -> php-fpm / nginx 报 "Too many open files"
#  这些默认值在压力上来时才暴露，现场常被误判成"PHP 性能问题"。
#
#  幂等策略（"之前优化过就不再增加"）：
#    1) 逐项比较当前值与目标值，只朝好的方向调整，绝不回退已有更优配置：
#         - max 类（somaxconn / file-max / backlog）当前值 >= 目标 -> 保留当前值
#         - min 类（swappiness / fin_timeout）      当前值 <= 目标 -> 保留当前值
#         - set 类（ip_local_port_range，多值）      始终用目标值
#    2) 生成内容与磁盘上已有文件完全一致时，整份跳过（不重写、不重载、不备份）
#    3) systemd 的 DefaultLimitNOFILE 已 >= 目标时，不写 drop-in
#
#  注意：/etc/security/limits.d 只对**登录会话**生效，对 systemd 拉起的服务无效。
#  所以句柄上限必须同时写 /etc/systemd/system.conf.d/99-lnamp.conf
#  （DefaultLimitNOFILE），否则 php-fpm / nginx 仍然是 1024。
#
#  用法: install_sysctl [profile]        由 system_prep / install.sh sysctl 调用
#  环境: DRY_RUN=1 只打印计划；三个落地路径见 versions.conf（可用同名变量覆盖）
# ============================================================================

# 目标参数表：key|目标值|方向(max|min|set)
#   max = 越大越好，当前更大就保留当前
#   min = 越小越好，当前更小就保留当前
#   set = 多值/枚举，不做比较，始终用目标值
_SYSCTL_TARGETS=(
  "net.core.somaxconn|65535|max"
  "net.core.netdev_max_backlog|65535|max"
  "net.ipv4.tcp_max_syn_backlog|65535|max"
  "net.ipv4.tcp_max_tw_buckets|262144|max"
  "net.ipv4.tcp_tw_reuse|1|max"
  "net.ipv4.tcp_slow_start_after_idle|0|min"
  "net.ipv4.tcp_fin_timeout|15|min"
  "net.ipv4.ip_local_port_range|10240 65000|set"
  "fs.file-max|1048576|max"
  "vm.swappiness|10|min"
  "vm.overcommit_memory|1|max"
)

# 纯数字比较：a >= b
_num_ge() {
  case "${1:-}" in ''|*[!0-9]*) return 1 ;; esac
  case "${2:-}" in ''|*[!0-9]*) return 1 ;; esac
  [ "$1" -ge "$2" ]
}

# 读当前值（取不到输出空）
_sysctl_get() {
  command -v sysctl >/dev/null 2>&1 || return 0
  sysctl -n "$1" 2>/dev/null | tr -s '[:space:]' ' ' | sed 's/ *$//'
}

# 按"只朝好的方向"决定最终值，输出 "key = value"
_sysctl_resolve() {
  local key="$1" want="$2" dir="$3" cur
  cur=$(_sysctl_get "$key")
  case "$dir" in
    max) _num_ge "$cur" "$want" && { echo "${key} = ${cur}"; return 0; } ;;
    min) if [ -n "$cur" ] && _num_ge "$want" "$cur"; then echo "${key} = ${cur}"; return 0; fi ;;
    *) : ;;
  esac
  echo "${key} = ${want}"
}

# 生成 sysctl 配置正文（按当前系统实际值"取优"后的结果）
_sysctl_build_conf() {
  local item key want dir
  echo "# 由 LNAMP 安装器生成 (managed by lnamp installer)"
  echo "# 只朝更优方向调整，不会覆盖系统上已有的更大/更小值。"
  echo "# 手工修改会在下次执行 install.sh sysctl 时被覆盖，"
  echo "# 如需长期自定义请另建 /etc/sysctl.d/98-*.conf（数字更大者后加载、优先级更高）。"
  echo
  for item in "${_SYSCTL_TARGETS[@]}"; do
    key="${item%%|*}"; item="${item#*|}"
    want="${item%%|*}"; dir="${item##*|}"
    _sysctl_resolve "$key" "$want" "$dir"
  done
}

# 生成 limits.conf 正文
_limits_build_conf() {
  cat <<EOF
# 由 LNAMP 安装器生成 (managed by lnamp installer)
# 仅对登录会话生效；systemd 服务看的是 ${SYSTEMD_LIMITS_CONF}
*    soft nofile ${SYSCTL_NOFILE}
*    hard nofile ${SYSCTL_NOFILE}
*    soft nproc  ${SYSCTL_NPROC}
*    hard nproc  ${SYSCTL_NPROC}
root soft nofile ${SYSCTL_NOFILE}
root hard nofile ${SYSCTL_NOFILE}
EOF
}

# 生成 systemd drop-in 正文
_systemd_limits_build_conf() {
  cat <<EOF
# 由 LNAMP 安装器生成 (managed by lnamp installer)
# 让所有 systemd 服务（nginx / php-fpm / mysqld / redis）默认拿到足够的 fd。
[Manager]
DefaultLimitNOFILE=${SYSCTL_NOFILE}:${SYSCTL_NOFILE}
DefaultLimitNPROC=${SYSCTL_NPROC}:${SYSCTL_NPROC}
EOF
}

# 写文件（内容相同则跳过），返回 0=已写入 1=跳过
_apply_conf() {
  local f="$1" desc="$2"; shift 2
  local body; body=$(printf '%s\n' "$*")
  if [ -f "$f" ] && [ "$body" = "$(cat "$f" 2>/dev/null)" ]; then
    log_ok "${desc} 已是期望配置，跳过 (unchanged): ${f}"
    return 1
  fi
  printf '%s\n' "$body" | save_file "$f"
  log_ok "已写入 ${desc}: ${f}"
  return 0
}

# 主入口：应用内核参数 + 句柄上限（幂等）
install_sysctl() {
  local profile="${1:-lnamp-v1}"
  log "内核/句柄调优 (sysctl & limits, profile=${profile})"

  local conf_body limits_body systemd_body
  conf_body=$(_sysctl_build_conf)
  limits_body=$(_limits_build_conf)
  systemd_body=$(_systemd_limits_build_conf)

  if [ "${DRY_RUN:-0}" = 1 ]; then
    log "  [dry-run] 将写入内核参数: ${SYSCTL_CONF}"
    printf '%s\n' "$conf_body" | sed 's/^/  [dry-run]   /'
    log "  [dry-run] 将写入登录会话限制: ${LIMITS_CONF}"
    log "  [dry-run] 将写入 systemd 服务限制: ${SYSTEMD_LIMITS_CONF}"
    log "  [dry-run] 将执行: sysctl --system  （使内核参数立即生效）"
    log "  [dry-run] 将执行: systemctl daemon-reexec  （使 DefaultLimitNOFILE 生效）"
    return 0
  fi

  local changed=0
  _apply_conf "$SYSCTL_CONF" "内核参数" "$conf_body" && changed=1
  _apply_conf "$LIMITS_CONF" "会话句柄限制" "$limits_body" && changed=1
  _apply_conf "$SYSTEMD_LIMITS_CONF" "systemd 句柄限制" "$systemd_body" && changed=1

  if [ "$changed" = 0 ]; then
    log_ok "系统已完成过同等或更优的调优，本次不做改动 (already tuned, skipped)"
    return 0
  fi

  # 立即生效：sysctl --system 会按文件名顺序加载 /etc/sysctl.d/*.conf
  log_run "应用内核参数" sysctl --system
  # DefaultLimitNOFILE 需要重新 exec PID 1 才会被新服务继承
  if command -v systemctl >/dev/null 2>&1; then
    log_run "重载 systemd 管理器配置" systemctl daemon-reexec
    # daemon-reexec 之后 systemd 会重建各服务的 RuntimeDirectory。若 sshd 的
    # privsep 目录 /run/sshd 在这一刻消失，正在运行的 sshd 主进程仍占着 22 端口，
    # 但每个新连接 fork 出来的子进程会因 "Missing privilege separation directory"
    # 直接退出 —— 表现就是"端口能连上、但永远收不到 SSH banner"，而且不会自愈。
    # 两台 Rocky 8.10 + freenginx 的机器（224 / 184）都踩到了，补一次无害的兜底。
    safe_mkdir /run/sshd 2>/dev/null || true
  fi

  # 回读校验（干跑已在上方 return）
  local somax nofile
  somax=$(_sysctl_get net.core.somaxconn)
  if [ -n "$somax" ] && _num_ge "$somax" 65535; then
    log_ok "校验通过: net.core.somaxconn = ${somax}"
  else
    log_warn "net.core.somaxconn 当前为 ${somax:-未知}，未达到 65535（可能被 /etc/sysctl.d 里序号更大的文件覆盖）"
  fi
  nofile=$(ulimit -Hn 2>/dev/null)
  if [ -n "$nofile" ] && [ "$nofile" != unlimited ] && _num_ge "$nofile" "$SYSCTL_NOFILE"; then
    log_ok "校验通过: 当前 shell hard nofile = ${nofile}"
  elif [ "$nofile" = unlimited ]; then
    log_ok "校验通过: 当前 shell hard nofile = unlimited"
  else
    log "  提示：当前 shell 的 nofile=${nofile:-未知} 需重新登录才会变成 ${SYSCTL_NOFILE}"
  fi
  return 0
}

# 供 verify.sh 使用：返回 0 表示已调优
sysctl_tuned() {
  local somax
  somax=$(_sysctl_get net.core.somaxconn)
  [ -n "$somax" ] && _num_ge "$somax" 65535
}
