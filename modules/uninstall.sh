#!/bin/bash
# ============================================================================
#  modules/uninstall.sh  ——  组件卸载 / 版本升级
# ----------------------------------------------------------------------------
#  两个子命令的实现：
#    install.sh uninstall --component <组件> [--purge]   卸载（反注册 systemd/
#        logrotate/PATH 软链，再删安装目录）
#    install.sh upgrade <组件> [版本[:形式]]              平滑升级（保留配置与数据）
#
#  设计要点：
#    1) 组件元数据集中在一张表里（_un_fields），卸载和升级共用，避免两处漂移。
#    2) 数据库默认"只删程序、保留 datadir"，必须显式 --purge 才删数据。
#    3) 升级前自动把配置打包到 /root/lnamp-backup-<组件>-<时间戳>.tar.gz。
#    4) 升级通过 LNAMP_UPGRADE=1 通知各模块：DB 不初始化数据目录、Redis 不换密码。
#    5) 全部动作走 log_run / safe_rm_rf，因此 --dry-run 下同样安全。
# ============================================================================

# ---------------------------------------------------------------------------
#  组件元数据：设置 _U_SVC / _U_UNIT / _U_PREFIX / _U_LOGROTATE / _U_PROFILE / _U_EXTRA
# ---------------------------------------------------------------------------
_UN_COMPONENTS="nginx apache php mysql mariadb redis memcached fail2ban java tomcat phpmyadmin adminer composer nodejs phpredis phpmemcached swoole"

_un_fields() {
  local c="$1"
  _U_SVC=""; _U_UNIT=""; _U_PREFIX=""; _U_LOGROTATE=""; _U_PROFILE=""; _U_EXTRA=""
  case "$c" in
    nginx)        _U_SVC=nginx;     _U_UNIT=nginx.service;     _U_PREFIX="$PREFIX_NGINX";     _U_LOGROTATE=nginx;   _U_PROFILE=lnamp-nginx ;;
    apache)       _U_SVC=httpd;     _U_UNIT=httpd.service;     _U_PREFIX="$PREFIX_APACHE";    _U_LOGROTATE=httpd;   _U_PROFILE=lnamp-apache ;;
    php)          _U_SVC=php-fpm;   _U_UNIT=php-fpm.service;   _U_PREFIX="$PREFIX_PHP";       _U_LOGROTATE=php-fpm; _U_PROFILE=lnamp-php ;;
    mysql)        _U_SVC=mysqld;    _U_UNIT=mysqld.service;    _U_PREFIX="$PREFIX_MYSQL";     _U_LOGROTATE=mysqld;  _U_PROFILE=lnamp-mysql;   _U_EXTRA="$MY_CNF_PATH ${HOME:-/root}/.mysql_root_password" ;;
    mariadb)      _U_SVC=mariadb;   _U_UNIT=mariadb.service;   _U_PREFIX="$PREFIX_MARIADB";   _U_LOGROTATE=mysqld;  _U_PROFILE=lnamp-mariadb; _U_EXTRA="${HOME:-/root}/.mariadb_root_password" ;;
    redis)        _U_SVC=redis;     _U_UNIT=redis.service;     _U_PREFIX="$PREFIX_REDIS";     _U_LOGROTATE=redis;   _U_PROFILE=lnamp-redis;   _U_EXTRA="${HOME:-/root}/.redis_password" ;;
    memcached)    _U_SVC=memcached; _U_UNIT=memcached.service; _U_PREFIX="$PREFIX_MEMCACHED"; _U_LOGROTATE="";      _U_PROFILE=lnamp-memcached ;;
    fail2ban)     _U_SVC=fail2ban;  _U_UNIT=fail2ban.service;  _U_PREFIX="";                  _U_LOGROTATE="";      _U_PROFILE="";            _U_EXTRA="/etc/fail2ban/jail.d/lnamp.local" ;;
    java)         _U_SVC="";        _U_UNIT="";                _U_PREFIX="$PREFIX_JAVA";      _U_LOGROTATE="";      _U_PROFILE=lnamp-java ;;
    tomcat)       _U_SVC=tomcat;    _U_UNIT=tomcat.service;    _U_PREFIX="$PREFIX_TOMCAT";    _U_LOGROTATE=tomcat;  _U_PROFILE=lnamp-tomcat ;;
    phpmyadmin)   _U_SVC="";        _U_UNIT="";                _U_PREFIX="${WWWROOT}/web/phpMyAdmin"; _U_LOGROTATE=""; _U_PROFILE="" ;;
    adminer)      _U_SVC="";        _U_UNIT="";                _U_PREFIX="${WWWROOT}/web/adminer";    _U_LOGROTATE=""; _U_PROFILE="" ;;
    composer)     _U_SVC="";        _U_UNIT="";                _U_PREFIX="";                  _U_LOGROTATE="";      _U_PROFILE="";            _U_EXTRA="/usr/local/bin/composer" ;;
    nodejs)       _U_SVC="";        _U_UNIT="";                _U_PREFIX="$PREFIX_NODE";      _U_LOGROTATE="";      _U_PROFILE=lnamp-nodejs ;;
    phpredis)     _U_SVC="";        _U_UNIT="";                _U_PREFIX="";                  _U_LOGROTATE="";      _U_PROFILE="";            _U_EXTRA="${PREFIX_PHP}/etc/php.d/redis.ini" ;;
    phpmemcached) _U_SVC="";        _U_UNIT="";                _U_PREFIX="";                  _U_LOGROTATE="";      _U_PROFILE="";            _U_EXTRA="${PREFIX_PHP}/etc/php.d/memcached.ini" ;;
    swoole)       _U_SVC="";        _U_UNIT="";                _U_PREFIX="";                  _U_LOGROTATE="";      _U_PROFILE="";            _U_EXTRA="${PREFIX_PHP}/etc/php.d/swoole.ini" ;;
    *) return 1 ;;
  esac
  return 0
}

# 组件是否装过（用于 uninstall 不带参数时列出清单）
_comp_installed() {
  local c="$1" f
  _un_fields "$c" || return 1
  [ -n "$_U_PREFIX" ] && [ -e "$_U_PREFIX" ] && return 0
  [ -n "$_U_UNIT" ] && [ -e "${SYSTEMD_DIR}/${_U_UNIT}" ] && return 0
  [ -n "$_U_PROFILE" ] && [ -e "/etc/profile.d/${_U_PROFILE}.sh" ] && return 0
  for f in $_U_EXTRA; do [ -e "$f" ] && return 0; done
  return 1
}

# ---------------------------------------------------------------------------
#  卸载
# ---------------------------------------------------------------------------
uninstall_usage() {
  cat <<EOF
用法 (Usage):
  $0 uninstall --component <组件> [--purge] [-y]
  $0 uninstall <组件> [--purge]                 # 位置参数写法同上
  $0 uninstall --list                           # 列出本机已安装的组件

组件 (components):
  ${_UN_COMPONENTS}

选项:
  --purge        连同数据/配置一起删除（数据库默认只删程序、保留 datadir）
  -y, --yes      跳过确认

示例:
  $0 uninstall --component redis
  $0 uninstall phpmyadmin
  $0 uninstall --component mysql --purge        # 危险：会删除 /data/mysql/data
EOF
}

_un_list_installed() {
  local c found=0
  hr; echo "已安装的组件 (installed components):"; hr
  for c in $_UN_COMPONENTS; do
    if _comp_installed "$c"; then
      _un_fields "$c"
      printf "  %-12s %s\n" "$c" "${_U_PREFIX:-${_U_EXTRA}}"
      found=1
    fi
  done
  [ "$found" = 0 ] && echo "  (未检测到由本安装器安装的组件)"
  hr
}

uninstall_component() {
  local comp="$1" purge="${2:-no}"
  _un_fields "$comp" || die "uninstall: 未知组件 '${comp}'。可用: ${_UN_COMPONENTS}"

  local is_db=0 is_ext=0 keep_dir=""
  # Redis 的持久化数据(dump.rdb/AOF)在 <prefix>/var 下，与 MySQL 的 data 同属
  # "用户数据"，不带 --purge 时必须保留（install.sh 的用法说明也写着"保留数据"）。
  case "$comp" in
    mysql|mariadb) is_db=1; keep_dir="data" ;;
    redis)         is_db=1; keep_dir="var"  ;;
  esac
  case "$comp" in phpredis|phpmemcached|swoole) is_ext=1 ;; esac

  if ! _comp_installed "$comp"; then
    log_warn "未检测到 ${comp} 的安装痕迹，仍将清理残留的注册项（unit/logrotate/profile.d）"
  fi

  hr; log "卸载 ${comp}  (purge=${purge})"
  # 列出将被删除的东西，便于事后核对
  [ -n "$_U_UNIT" ]      && echo "  服务单元 (unit)      : ${SYSTEMD_DIR}/${_U_UNIT}"
  [ -n "$_U_LOGROTATE" ] && echo "  日志轮转 (logrotate) : /etc/logrotate.d/${_U_LOGROTATE}"
  [ -n "$_U_PROFILE" ]   && echo "  PATH 注册            : /etc/profile.d/${_U_PROFILE}.sh"
  [ -n "$_U_PREFIX" ]    && echo "  安装目录 (prefix)    : ${_U_PREFIX}$([ "$is_db" = 1 ] && [ "$purge" != yes ] && echo "  (保留 ${keep_dir})")"
  local f; for f in $_U_EXTRA; do echo "  附加文件 (extra)     : ${f}"; done

  # 1) 停服务 + 取消开机自启
  # 历史缺陷（P0，本轮真机实测）：原先用
  #     systemctl list-unit-files | grep -q "^${_U_SVC}.service"
  # 做"服务是否存在"的前置判断，而 install.sh 顶部开了 `set -o pipefail`：
  # grep -q 命中即退出 → systemctl 还在写输出 → 收到 SIGPIPE(141) →
  # 整条管道状态非 0 → 判断恒为假 → **stop 从来没执行过**。
  # 后果：unit 与安装目录都删了，进程还占着端口跑在已删除的二进制上，
  # 重装时 bind 失败、只能手工 kill。这里改为：无条件 stop/disable，
  # 再显式校验进程是否真的退出，没退出就升级为强制结束，仍失败则中止卸载。
  if [ -n "$_U_SVC" ] && command -v systemctl >/dev/null 2>&1; then
    log_run "停止 ${_U_SVC}"   systemctl stop    "${_U_SVC}"
    log_run "取消自启 ${_U_SVC}" systemctl disable "${_U_SVC}"
    if systemctl is-active --quiet "${_U_SVC}" 2>/dev/null; then
      log_warn "${_U_SVC} 仍在运行，尝试强制结束"
      log_run "强制结束 ${_U_SVC}" systemctl kill -s KILL "${_U_SVC}"
      sleep 2
      if systemctl is-active --quiet "${_U_SVC}" 2>/dev/null; then
        local _mpid
        _mpid=$(systemctl show -p MainPID --value "${_U_SVC}" 2>/dev/null)
        if [ -n "$_mpid" ] && [ "$_mpid" != 0 ]; then
          log_warn "systemd 无法结束 ${_U_SVC}(pid=${_mpid})，直接 kill -9"
          log_run "kill -9 ${_mpid}" kill -9 "$_mpid"
          sleep 1
        fi
      fi
      if systemctl is-active --quiet "${_U_SVC}" 2>/dev/null; then
        die "uninstall: ${_U_SVC} 无法停止，已中止卸载（否则会留下'程序已删、进程仍占端口'的僵尸状态）"
      fi
    fi
    systemctl reset-failed "${_U_SVC}" >/dev/null 2>&1 || true
  fi
  # 2) 删除 unit 并重载 systemd
  if [ -n "$_U_UNIT" ]; then
    safe_rm_rf "${SYSTEMD_DIR}/${_U_UNIT}"
    log_run "systemd daemon-reload" systemctl daemon-reload
  fi
  # 3) logrotate / profile.d
  [ -n "$_U_LOGROTATE" ] && safe_rm_rf "/etc/logrotate.d/${_U_LOGROTATE}"
  [ -n "$_U_PROFILE" ]   && safe_rm_rf "/etc/profile.d/${_U_PROFILE}.sh"
  # 4) /usr/local/bin 里指向该前缀的软链（否则会留下悬空链接）
  [ -n "$_U_PREFIX" ] && _un_remove_symlinks "$_U_PREFIX"
  # 5) 安装目录
  if [ -n "$_U_PREFIX" ]; then
    if [ "$is_db" = 1 ] && [ "$purge" != yes ]; then
      _un_prefix_keep_data "$_U_PREFIX" "$keep_dir"
    else
      safe_rm_rf "$_U_PREFIX"
    fi
  fi
  # 6) 附加文件（密码文件、composer.phar、jail 配置、扩展 ini 等）
  #    凭据文件在"保留数据"场景下必须留下：重装会沿用它对齐密码，
  #    删掉会让已保留的数据与新生成的随机密码对不上（MySQL 会直接锁死）。
  local f
  for f in $_U_EXTRA; do
    case "$f" in
      */.mysql_root_password|*/.mariadb_root_password|*/.redis_password)
        if [ "$purge" = yes ]; then
          safe_rm_rf "$f"
        else
          log "  保留凭据文件 (keep credentials): $f   （确认不再需要时用 --purge 清理）"
        fi
        ;;
      *) safe_rm_rf "$f" ;;
    esac
  done
  # 7) PHP 扩展还要删 .so 并重载 php-fpm
  if [ "$is_ext" = 1 ]; then
    case "$comp" in
      phpredis)     _un_php_ext redis redis.so ;;
      phpmemcached) _un_php_ext memcached memcached.so ;;
      swoole)       _un_php_ext swoole swoole.so ;;
    esac
  fi

  hr; log_ok "${comp} 卸载完成"
  [ "$is_db" = 1 ] && [ "$purge" != yes ] && \
    log_warn "数据目录已保留：${_U_PREFIX}/${keep_dir} 。确认不再需要时执行: $0 uninstall --component ${comp} --purge"
  return 0
}

# 删除 /usr/local/bin 下所有指向指定前缀的软链
_un_remove_symlinks() {
  local prefix="$1" l tgt
  for l in /usr/local/bin/*; do
    [ -L "$l" ] || continue
    tgt=$(readlink "$l" 2>/dev/null) || continue
    case "$tgt" in
      "${prefix}"/*)
        if [ "${DRY_RUN:-0}" = 1 ]; then
          log "  [dry-run] 将删除软链: ${l} -> ${tgt}"
        else
          rm -f "$l" 2>/dev/null || true
        fi
        ;;
    esac
  done
  return 0
}

# 数据库卸载：只删程序文件，保留数据目录
#   keep_dir: mysql/mariadb -> data（数据目录）；redis -> var（dump.rdb/AOF）
_un_prefix_keep_data() {
  local prefix="$1" keep="${2:-data}"
  if [ "${DRY_RUN:-0}" = 1 ]; then
    log "  [dry-run] 将删除 ${prefix} 下除 ${keep} 外的全部内容"
    return 0
  fi
  [ -d "$prefix" ] || return 0
  find "$prefix" -mindepth 1 -maxdepth 1 ! -name "$keep" -exec rm -rf {} + 2>/dev/null || true
  log_ok "已保留数据目录: ${prefix}/${keep}"
  return 0
}

# 删除 PHP 扩展的 ini 与 .so
_un_php_ext() {
  local name="$1" so="$2" extdir
  safe_rm_rf "${PREFIX_PHP}/etc/php.d/${name}.ini"
  extdir=$("${PREFIX_PHP}/bin/php-config" --extension-dir 2>/dev/null)
  [ -n "$extdir" ] && safe_rm_rf "${extdir}/${so}"
  reload_php_runtime
  return 0
}

uninstall_main() {
  local comp="" purge=no
  while [ $# -gt 0 ]; do
    case "$1" in
      --component|-c) comp="${2:-}"; shift 2 ;;
      --purge)        purge=yes; shift ;;
      --list|-l)      _un_list_installed; return 0 ;;
      -y|--yes)       ASSUME_YES=1; shift ;;
      --dry-run)      DRY_RUN=1; shift ;;
      -h|--help)      uninstall_usage; return 0 ;;
      -*)             die "uninstall: 未知选项 $1" ;;
      *)              comp="$1"; shift ;;
    esac
  done
  if [ -z "$comp" ]; then
    # 没指定组件 = 什么都没做，按命令行约定返回非 0（脚本里据此判断失败）
    _un_list_installed
    uninstall_usage
    return 1
  fi

  _un_fields "$comp" || die "uninstall: 未知组件 '${comp}'。可用: ${_UN_COMPONENTS}"

  # 危险操作二次确认
  if [ "$purge" = yes ] && [ "${ASSUME_YES:-0}" != 1 ]; then
    log_warn "⚠️ --purge 会删除数据目录与配置文件，不可恢复！"
    ask_yes_no "确认彻底删除 ${comp}（含数据）?" n || { log "已取消"; return 1; }
  fi
  uninstall_component "$comp" "$purge"
}

# ---------------------------------------------------------------------------
#  升级
# ---------------------------------------------------------------------------
upgrade_usage() {
  cat <<EOF
用法 (Usage):
  $0 upgrade <组件> [版本[:形式]] [--force] [-y]

组件 (components):
  nginx apache php redis memcached fail2ban composer nodejs
  swoole phpredis phpmemcached
  mysql mariadb                    # 需 --force，会保留 datadir

说明:
  · 不给版本时升到 versions.conf 里的默认版本
  · 升级前自动备份配置到 /root/lnamp-backup-<组件>-<时间戳>.tar.gz
  · 升级会保留配置与数据：数据库不初始化 datadir，Redis 不更换密码
  · 升级 PHP 后会自动重建已启用的扩展（redis / swoole / memcached）
  · 数据库升级（mysql/mariadb）强制先做全量 dump 到 /root/lnamp-predump-*.sql.gz

示例:
  $0 upgrade nginx                  # 升到默认版本
  $0 upgrade nginx 1.30.6           # 指定版本（形式用默认）
  $0 upgrade php 8.4.27:fpm
  $0 upgrade mysql 8.4.13 --force   # 数据库升级，保留数据（会先做全量 dump）
  $0 upgrade mysql --backup-only    # 只做配置备份 + 全量 dump，不动程序
  $0 upgrade mysql 8.4.13 --force --skip-db-backup   # 跳过升级前 dump（不建议）
EOF
}

# 组件名 -> 清单里的键名（输出到 stdout）
# 历史缺陷（P1）：case 分支里直接写 `NGINX` 是想"返回"这个字符串，但它其实是
# 一条命令——执行报 "REDIS: command not found" 并返回 127，于是
# `key=$(_up_manifest_key redis)` 走到失败分支，**所有组件的 upgrade 全部报
# "未知组件"**。必须显式赋值再 printf 输出。
_up_manifest_key() {
  local key
  case "$1" in
    nginx)       key=NGINX ;;
    apache)      key=APACHE ;;
    php)         key=PHP ;;
    redis)       key=REDIS ;;
    memcached)   key=MEMCACHED ;;
    mysql)       key=MYSQL ;;
    mariadb)     key=MARIADB ;;
    fail2ban)    key=FAIL2BAN ;;
    composer)    key=COMPOSER ;;
    nodejs)      key=NODE ;;
    swoole)      key=SWOOLE ;;
    phpredis)    key=PHPREDIS ;;
    phpmemcached) key=PHPMEMCACHED ;;
    *) return 1 ;;
  esac
  printf '%s\n' "$key"
  return 0
}

# 探测当前已安装版本（取不到就输出空）
_up_current_version() {
  local c="$1" bin
  case "$c" in
    nginx)
      bin="${PREFIX_NGINX}/sbin/nginx"; [ -x "$bin" ] || bin=$(command -v nginx 2>/dev/null)
      # 不能只认 "nginx/"：三种 flavor 的 -v 输出分别是
      #   nginx version: nginx/1.30.6
      #   nginx version: freenginx/1.31.4
      #   Tengine version: Tengine/3.1.0 (nginx/1.18.0)
      # 原来写死 "nginx/" 会让 freenginx / tengine **一律探测为空**，
      # 表现为"没装"：status 不显示、upgrade 报未知、verify 版本比对跳过。
      # 统一取 "version: " 后第一个空白段，再取其最后一个 "/" 之后：
      # 伪装输出 "nginx version: Microsoft-IIS/10.0/1.30.2" 按第一个 "/" 取段
      # 会拿到伪装的 10.0（真机教训：190 上 upgrade 显示 "10.0 -> 1.30.6"）；
      # Tengine 的 "(nginx/1.18.0)" 在空白之后，不会被误取（仍得 3.1.0）。
      [ -n "$bin" ] && "$bin" -v 2>&1 | sed -n 's#.*version: \([^ ]*\).*#\1#p' | sed 's#^.*/##' ;;
    apache)
      bin="${PREFIX_APACHE}/bin/httpd"; [ -x "$bin" ] || bin=$(command -v httpd 2>/dev/null)
      [ -n "$bin" ] && "$bin" -v 2>&1 | awk '{print $3}' | cut -d/ -f2 ;;
    php) php_bin_version ;;
    redis)
      bin="${PREFIX_REDIS}/bin/redis-server"; [ -x "$bin" ] || bin=$(command -v redis-server 2>/dev/null)
      # redis-server --version 输出第 3 段是 "v=8.10.2"（带 v= 前缀）。
      # 直接当版本号用会和清单里的 8.10.2 永不相等 -> 同版本也判"需要升级"，
      # 于是白白重编一遍。这里剥掉前缀只留数字。
      [ -n "$bin" ] && "$bin" --version 2>/dev/null | sed -n 's/.*v=\([0-9][0-9.]*\).*/\1/p' ;;
    memcached)
      bin="${PREFIX_MEMCACHED}/bin/memcached"; [ -x "$bin" ] || bin=$(command -v memcached 2>/dev/null)
      [ -n "$bin" ] && "$bin" --version 2>/dev/null | awk '{print $2}' ;;
    mysql)
      bin="${PREFIX_MYSQL}/bin/mysql"; [ -x "$bin" ] || bin=$(command -v mysql 2>/dev/null)
      [ -n "$bin" ] && "$bin" --version 2>/dev/null | sed -n 's/.*Ver[[:space:]]\+\([0-9][0-9.]*\).*/\1/p' ;;
    mariadb)
      bin="${PREFIX_MARIADB}/bin/mariadb"; [ -x "$bin" ] || bin="${PREFIX_MARIADB}/bin/mysql"
      [ -x "$bin" ] || bin=$(command -v mariadb 2>/dev/null)
      [ -n "$bin" ] && "$bin" --version 2>/dev/null | sed -n 's/.*Distrib[[:space:]]\+\([0-9][0-9.]*\).*/\1/p' ;;
    nodejs)
      bin="${PREFIX_NODE}/bin/node"; [ -n "$bin" ] && "$bin" -v 2>/dev/null | tr -d 'v' ;;
    composer)
      [ -x /usr/local/bin/composer ] && /usr/local/bin/composer --version 2>/dev/null | awk '{print $3}' ;;
    fail2ban)
      command -v fail2ban-client >/dev/null 2>&1 && fail2ban-client --version 2>/dev/null | head -1 | awk '{print $NF}' | tr -d 'v' ;;
    swoole)       "${PREFIX_PHP}/bin/php" -r 'echo phpversion("swoole");' 2>/dev/null ;;
    phpredis)     "${PREFIX_PHP}/bin/php" -r 'echo phpversion("redis");' 2>/dev/null ;;
    phpmemcached) "${PREFIX_PHP}/bin/php" -r 'echo phpversion("memcached");' 2>/dev/null ;;
  esac
}

# 升级前把配置打包（只收配置文件，不收整个安装目录）
_up_config_paths() {
  local c="$1"
  case "$c" in
    nginx)        [ -d "${PREFIX_NGINX}/conf" ]   && echo "${PREFIX_NGINX}/conf" ;;
    apache)       [ -d "${PREFIX_APACHE}/conf" ]  && echo "${PREFIX_APACHE}/conf" ;;
    php)          [ -d "${PREFIX_PHP}/etc" ]      && echo "${PREFIX_PHP}/etc" ;;
    redis)        [ -d "${PREFIX_REDIS}/etc" ]    && echo "${PREFIX_REDIS}/etc" ;;
    memcached)    [ -d "${PREFIX_MEMCACHED}/etc" ] && echo "${PREFIX_MEMCACHED}/etc" ;;
    mysql|mariadb) [ -f "$MY_CNF_PATH" ] && echo "$MY_CNF_PATH" ;;
    fail2ban)     [ -d /etc/fail2ban/jail.d ] && echo /etc/fail2ban/jail.d ;;
  esac
  return 0
}

_up_backup() {
  local c="$1" paths dest ts
  paths=$(_up_config_paths "$c")
  [ -n "$paths" ] || { log "  (该组件无可备份的配置)"; return 0; }
  ts=$(date +%Y%m%d_%H%M%S)
  dest="/root/lnamp-backup-${c}-${ts}.tar.gz"
  if [ "${DRY_RUN:-0}" = 1 ]; then
    log "  [dry-run] 将备份配置: ${dest} <- ${paths//$'\n'/ }"
    return 0
  fi
  # shellcheck disable=SC2086
  if tar -czf "$dest" $paths 2>/dev/null; then
    log_ok "已备份配置 (config backup): ${dest}"
  else
    log_warn "配置备份失败（继续升级，但请自行确认配置已留存）"
  fi
  return 0
}

# 数据库升级前的**全量逻辑备份**。
# 配置 tar 备份救不了数据：数据库升级真正能回滚的只有 mysqldump。
# 用法: _up_db_dump <mysql|mariadb>   -> 成功返回 0，并把路径写入全局 DB_DUMP_FILE
_up_db_dump() {
  # $1 组件 (mysql|mariadb)   $2 可选输出文件路径（不传则落到 LNAMP_PREDUMP_DIR，默认 /root）
  local comp="$1" out="${2:-}" prefix bin cred sock pass dest ts errf
  case "$comp" in
    mysql)   prefix="$PREFIX_MYSQL";   cred="${HOME:-/root}/.mysql_root_password" ;;
    mariadb) prefix="$PREFIX_MARIADB"; cred="${HOME:-/root}/.mariadb_root_password" ;;
    *) return 0 ;;
  esac
  bin="${prefix}/bin/mysqldump"
  [ -x "$bin" ] || bin=$(command -v mysqldump 2>/dev/null)
  if [ -z "$bin" ]; then
    log_err "找不到 mysqldump（${prefix}/bin 与 PATH 均无），无法做升级前备份"
    return 1
  fi
  sock=/tmp/mysql.sock
  if [ -f "${MY_CNF_PATH:-/etc/my.cnf}" ]; then
    sock=$(awk -F'=' '/^[[:space:]]*socket[[:space:]]*=/{gsub(/[[:space:]]/,"",$2);print $2;exit}' "${MY_CNF_PATH:-/etc/my.cnf}")
    [ -n "$sock" ] || sock=/tmp/mysql.sock
  fi
  pass=""
  if [ -f "$cred" ]; then
    pass=$(sed -n 's/.*password):[[:space:]]*\([^[:space:]]*\).*/\1/p' "$cred" 2>/dev/null | head -1 | tr -d '\r ')
  fi
  ts=$(date +%Y%m%d_%H%M%S)
  # 输出目录可注入：测试与 backup 模块都有自己的落盘点，不能一律写 /root
  dest="${out:-${LNAMP_PREDUMP_DIR:-/root}/lnamp-predump-${comp}-${ts}.sql.gz}"
  if [ "${DRY_RUN:-0}" = 1 ]; then
    log "  [dry-run] 将全量逻辑备份数据库: ${dest}"
    return 0
  fi
  errf=$(mktemp)
  log "全量逻辑备份中（--single-transaction --all-databases）: ${dest}"
  # shellcheck disable=SC2086
  if "$bin" --socket="$sock" -uroot ${pass:+"-p$pass"} \
        --single-transaction --quick --routines --events --triggers --all-databases \
        2>"$errf" | gzip -c > "$dest" && [ -s "$dest" ]; then
    chmod 600 "$dest" 2>/dev/null || true
    log_ok "数据库已备份: ${dest}  ($(du -h "$dest" 2>/dev/null | awk '{print $1}'))"
    rm -f "$errf"
    DB_DUMP_FILE="$dest"
    return 0
  fi
  log_err "数据库备份失败: $(tail -2 "$errf" 2>/dev/null | tr '\n' ' ')"
  rm -f "$dest" "$errf"
  return 1
}

# 升级后：PHP 换了，扩展的 .so 与旧 ABI 不匹配，需要按需重建
_up_rebuild_php_exts() {
  [ -d "${PREFIX_PHP}/etc/php.d" ] || return 0
  local major; major=$(php_major_version); [ -n "$major" ] || return 0
  if [ -f "${PREFIX_PHP}/etc/php.d/redis.ini" ]; then
    log "重建扩展: phpredis"; install_phpredis "$major" ""
  fi
  if [ -f "${PREFIX_PHP}/etc/php.d/swoole.ini" ]; then
    log "重建扩展: swoole"; install_swoole "$SWOOLE_DEFAULT" source
  fi
  if [ -f "${PREFIX_PHP}/etc/php.d/memcached.ini" ]; then
    log "重建扩展: memcached"; install_phpmemcached "$PHPMEMCACHED_DEFAULT" source
  fi
  # imagick 走独立编译（phpize），PHP 换模块 API 后旧 .so 必然失配。
  # 以"原 php.d 里已启用"为准重建（与上面三个扩展同一判定），升级前装过
  # imagick 的 PHP 不会因升级丢扩展（真机教训：190 升 8.4 后 imagick 没重建，
  # ini 仍指 20230831 旧路径，php -v 全程喷 "Unable to initialize module"）。
  if [ -f "${PREFIX_PHP}/etc/php.d/imagick.ini" ]; then
    log "重建扩展: imagick"; _php_install_imagick "$(php_bin_version)" "$major"
  fi
  return 0
}

# 实际调用对应的安装函数
_up_run_installer() {
  local c="$1" ver="$2" mode="$3"
  case "$c" in
    nginx)        install_nginx "$ver" "$mode" ;;
    apache)       install_apache "$ver" "$mode" "${APACHE_MPM:-event}" ;;
    php)          install_php "$ver" "$mode" ;;
    redis)        install_redis "$ver" "$mode" ;;
    memcached)    install_memcached "$ver" "$mode" ;;
    mysql)        install_mysql "$ver" "$mode" ;;
    mariadb)      install_mariadb "$ver" "$mode" ;;
    fail2ban)     install_fail2ban "$ver" "$mode" ;;
    composer)     install_composer "$ver" "$mode" ;;
    nodejs)       install_nodejs "$ver" "$mode" ;;
    swoole)       install_swoole "$ver" "$mode" ;;
    phpredis)     install_phpredis_pick "$ver" ;;
    phpmemcached) install_phpmemcached "$ver" "$mode" ;;
    *)            die "upgrade: 不支持升级 ${c}" ;;
  esac
}

upgrade_main() {
  local comp="" target="" force=0 backup_only=0 skip_db_dump=0
  while [ $# -gt 0 ]; do
    case "$1" in
      -h|--help) upgrade_usage; return 0 ;;
      --force)   force=1; shift ;;
      --backup-only)    backup_only=1; shift ;;
      --skip-db-backup) skip_db_dump=1; shift ;;
      -y|--yes)  ASSUME_YES=1; shift ;;
      --dry-run) DRY_RUN=1; shift ;;
      -*)        die "upgrade: 未知选项 $1" ;;
      *)         if [ -z "$comp" ]; then comp="$1"; else target="$1"; fi; shift ;;
    esac
  done
  [ -n "$comp" ] || { upgrade_usage; return 1; }

  local key; key=$(_up_manifest_key "$comp") || die "upgrade: 未知组件 '${comp}'。可用: nginx apache php redis memcached fail2ban composer nodejs swoole phpredis phpmemcached mysql mariadb"

  # 目标版本：显式给的就校验，没给就用清单默认
  local dver dmod
  local dv="${key}_DEFAULT" dm="${key}_DEFAULT_MODE"
  dver="${!dv}"; dmod="${!dm}"
  if [ -n "$target" ]; then
    parse_pick "$key" "$target"
    dver="$PICK_VER"; dmod="$PICK_MODE"
  fi

  local cur; cur=$(_up_current_version "$comp")

  # --backup-only：只备份（配置 tar + 数据库全量 dump），不做任何升级动作。
  if [ "$backup_only" = 1 ]; then
    hr; log "仅备份 ${comp}（不做任何改动）"; hr
    _up_backup "$comp"
    case "$comp" in
      mysql|mariadb)
        _up_db_dump "$comp" || return 1
        log_ok "数据备份文件: ${DB_DUMP_FILE:-（见上）}（还原: gunzip -c <文件> | mysql -uroot -p）"
        ;;
    esac
    log_ok "${comp} 备份完成"
    return 0
  fi

  hr
  log "升级 ${comp}: ${cur:-未安装} -> ${dver} (${dmod})"
  hr
  if [ -z "$cur" ]; then
    log_warn "未检测到已安装的 ${comp}，将按全新安装处理"
  elif [ "$cur" = "$dver" ] && [ "$force" != 1 ]; then
    log_ok "${comp} 已经是 ${dver}，无需升级（如需强制重装加 --force）"
    return 0
  fi

  # 数据库升级风险最高：默认拒绝，必须 --force
  case "$comp" in
    mysql|mariadb)
      if [ "$force" != 1 ]; then
        log_err "数据库升级涉及数据目录兼容性，安装器不会默认执行。"
        echo "  建议流程："
        echo "    1) 全量备份: mysqldump --all-databases > /root/all-$(date +%F).sql"
        echo "    2) 确认目标版本支持从 ${cur:-当前版本} 原地升级（跨大版本通常不支持）"
        echo "    3) 确认无误后加 --force 重跑本命令（会保留 datadir，只替换程序文件）"
        return 1
      fi
      local _dbp="$PREFIX_MYSQL"; [ "$comp" = mariadb ] && _dbp="$PREFIX_MARIADB"
      log_warn "--force 已指定：将替换程序文件并保留 ${_dbp}/data"
      # 强制要求先做数据备份：配置备份 ≠ 数据备份，没有 dump 就没有回滚路径。
      if [ "$skip_db_dump" = 1 ]; then
        log_warn "--skip-db-backup 已指定：跳过升级前全量备份（数据风险自负）"
      else
        _up_db_dump "$comp" || die "数据库升级前备份失败，已中止。修好备份（或确认可跳过）后重试；确实要跳过时加 --skip-db-backup"
        log_ok "数据备份文件: ${DB_DUMP_FILE:-（见上）}（还原: gunzip -c <文件> | mysql -uroot -p）"
      fi
      ;;
  esac

  if [ "${ASSUME_YES:-0}" != 1 ] && [ -t 0 ]; then
    ask_yes_no "确认升级 ${comp} 到 ${dver}?" y || { log "已取消"; return 1; }
  fi

  _up_backup "$comp"

  # 通知各模块进入升级模式（DB 不初始化数据目录 / Redis 不换密码）
  LNAMP_UPGRADE=1; export LNAMP_UPGRADE
  local rc=0
  _up_run_installer "$comp" "$dver" "$dmod" || rc=$?
  LNAMP_UPGRADE=0; export LNAMP_UPGRADE
  if [ "$rc" != 0 ]; then
    log_err "${comp} 升级失败（退出码 ${rc}）；配置备份在 /root/lnamp-backup-${comp}-*.tar.gz"
    return "$rc"
  fi

  [ "$comp" = php ] && _up_rebuild_php_exts

  # 复用 verify 的检查逻辑：把本次组件塞进 SEL_*，只校验它自己
  case "$comp" in
    nginx) SEL_NGINX="${dver}:${dmod}" ;; apache) SEL_APACHE="${dver}:${dmod}" ;;
    php)   SEL_PHP="${dver}:${dmod}" ;;   redis)  SEL_REDIS="${dver}:${dmod}" ;;
    mysql) SEL_MYSQL="${dver}:${dmod}" ;; mariadb) SEL_MARIADB="${dver}:${dmod}" ;;
    memcached) SEL_MEMCACHED="${dver}:${dmod}" ;;
    phpredis) SEL_PHPREDIS="${dver}:${dmod}" ;;
    phpmemcached) SEL_PHPMEMCACHED="${dver}:${dmod}" ;;
    swoole) SEL_SWOOLE="${dver}:${dmod}" ;;
    composer) SEL_COMPOSER="${dver}:${dmod}" ;;
    nodejs) SEL_NODE="${dver}:${dmod}" ;;
    fail2ban) INSTALL_FAIL2BAN=yes ;;
  esac
  export SEL_NGINX SEL_APACHE SEL_PHP SEL_REDIS SEL_MYSQL SEL_MARIADB SEL_MEMCACHED \
         SEL_PHPREDIS SEL_PHPMEMCACHED SEL_SWOOLE SEL_COMPOSER SEL_NODE INSTALL_FAIL2BAN
  # 装完立刻验一遍（失败不影响 upgrade 本身的结论，只作为提示）
  verify_stack || log_warn "升级后自检未全部通过，请查看上方 [FAIL] 项"
  hr; log_ok "${comp} 升级完成: ${cur:-未安装} -> ${dver}"
  log "  配置备份: /root/lnamp-backup-${comp}-*.tar.gz"
  log "  如需回滚：装回旧版本 $0 upgrade ${comp} ${cur:-<旧版本>}"
  return 0
}
