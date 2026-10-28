#!/bin/bash
# ============================================================================
#  modules/backup.sh  ——  整套栈的统一备份与还原 (backup / restore)
# ----------------------------------------------------------------------------
#  与 upgrade 内部那个 dump 的区别：那个只为"升级失败能回滚"服务，落地在
#  /root 且只有数据库；这里面向日常运维，产物是一个自包含的包：
#
#    lnamp-backup-<ts>.tar.gz
#      ├── manifest.txt          版本、范围、数据库版本、注意事项
#      ├── db/<engine>-all.sql.gz  全量逻辑备份（mysqldump --all-databases）
#      ├── db/redis-dump.rdb       Redis 快照
#      ├── conf/…                  my.cnf / redis.conf / php 配置 / nginx 配置 /
#      │                           vhost / logrotate / systemd unit / fail2ban
#      ├── credentials/            数据库与 Redis 凭据（600，见下方说明）
#      └── site/<domain>/code.tar.gz   站点代码（需 --with-site）
#
#  用法:
#    bash install.sh backup                        # 数据库 + 配置（轻量，可每天跑）
#    bash install.sh backup --with-site            # 连站点代码一起（可能很大）
#    bash install.sh backup --only db              # 只数据库
#    bash install.sh backup --keep 7               # 保留最近 7 份（默认 7）
#    bash install.sh backup --dest /data/backups   # 换输出目录
#    bash install.sh backup --remote u@h:/path     # 完成后推一份到异地
#    bash install.sh restore <包> [--only db,conf] [--with-site] [--yes] [--restart]
#
#  两个刻意的默认值：
#    1) 默认**不含**站点代码。站点动辄几十 G，默认打包会把磁盘打爆；要带就
#       显式 --with-site。
#    2) 凭据文件**默认包含**在包里。不包含的话，还原到新机器后连不上数据库，
#       备份就失去意义。因此备份包等同密钥，产物落地即 chmod 600。
#  ============================================================================

BK_DIR="${LNAMP_BACKUP_DIR:-/root/lnamp-backups}"
BK_KEEP=7
_BK_FAIL=0

_bk_have() { command -v "$1" >/dev/null 2>&1; }

# 从凭据文件或配置里取密码（取不到返回空）
_bk_db_pass() {
  local cred="${HOME:-/root}/.$1_root_password"
  [ "$1" = "mariadb" ] && cred="${HOME:-/root}/.mariadb_root_password"
  [ -f "$cred" ] || return 0
  sed -n 's/.*password):[[:space:]]*\([^[:space:]]*\).*/\1/p' "$cred" 2>/dev/null | head -1 | tr -d '\r '
}

_bk_redis_pass() {
  local cf="${REDIS_CRED_FILE:-${HOME:-/root}/.redis_password}"
  if [ -f "$cf" ]; then
    sed -n 's/.*password):[[:space:]]*\([^[:space:]]*\).*/\1/p' "$cf" 2>/dev/null | head -1 | tr -d '\r '
    return 0
  fi
  [ -f "${PREFIX_REDIS}/etc/redis.conf" ] && \
    sed -n 's/^[[:space:]]*requirepass[[:space:]]\+//p' "${PREFIX_REDIS}/etc/redis.conf" 2>/dev/null | head -1 | tr -d '\r'
}

# 当前装的是哪个数据库引擎（都没装则空）
_bk_db_engine() {
  if [ -n "$(_up_current_version mysql 2>/dev/null)" ];   then echo mysql;   return 0; fi
  if [ -n "$(_up_current_version mariadb 2>/dev/null)" ]; then echo mariadb; return 0; fi
  return 0
}

# ---------------------------------------------------------------------------
#  各分项备份
# ---------------------------------------------------------------------------
_bk_do_db() {
  local stage="$1" eng; eng=$(_bk_db_engine)
  if [ -z "$eng" ]; then log "未检测到 MySQL/MariaDB，跳过数据库备份"; return 0; fi
  mkdir -p "$stage/db"
  log "备份数据库 (${eng}) …"
  if _up_db_dump "$eng" "$stage/db/${eng}-all.sql.gz" >/dev/null 2>&1; then
    local sz; sz=$(du -h "$stage/db/${eng}-all.sql.gz" 2>/dev/null | awk '{print $1}')
    log_ok "数据库已备份: db/${eng}-all.sql.gz (${sz:-?})"
  else
    log_err "数据库备份失败（mysqldump 出错，可手动跑一次看原因）"
    _BK_FAIL=$((_BK_FAIL + 1))
  fi
}

_bk_do_redis() {
  local stage="$1" pass addr dir out
  [ -x "${PREFIX_REDIS}/bin/redis-server" ] || { log "未安装 Redis，跳过"; return 0; }
  mkdir -p "$stage/db"
  pass=$(_bk_redis_pass)
  out="$stage/db/redis-dump.rdb"
  log "备份 Redis 快照 …"
  # 首选 --rdb：由服务端直接把 RDB 流式发过来，不依赖 dir 路径与落盘时机
  if _bk_have redis-cli && \
     redis-cli ${pass:+-a "$pass"} --no-auth-warning --rdb "$out" >/dev/null 2>&1 && [ -s "$out" ]; then
    log_ok "Redis 已备份: db/redis-dump.rdb ($(du -h "$out" 2>/dev/null | awk '{print $1}'))"
    return 0
  fi
  # 退化路径：先 BGSAVE 等落盘，再直接拷 dump.rdb
  dir=$(grep -E '^[[:space:]]*dir[[:space:]]' "${PREFIX_REDIS}/etc/redis.conf" 2>/dev/null | awk '{print $2}' | head -1)
  [ -n "$dir" ] || dir="${PREFIX_REDIS}/var"
  if [ -f "${dir}/dump.rdb" ]; then
    redis-cli ${pass:+-a "$pass"} --no-auth-warning bgsave >/dev/null 2>&1
    sleep 2
    cp -f "${dir}/dump.rdb" "$out" 2>/dev/null && { log_ok "Redis 已备份(文件拷贝): db/redis-dump.rdb"; return 0; }
  fi
  log_warn "Redis 备份失败（--rdb 与文件拷贝均不可用），包内不含 Redis 数据"
  _BK_FAIL=$((_BK_FAIL + 1))
}

# 复制一个文件/目录到 stage/conf/<name>，顺带清掉 .bak 变体（备份包里不要历史版本）
_bk_cp() {
  local src="$1" name="$2" stage="$3"
  [ -e "$src" ] || return 0
  cp -a "$src" "$stage/conf/$name" 2>/dev/null || return 0
  if [ -d "$stage/conf/$name" ]; then
    find "$stage/conf/$name" -name '*.bak.*' -type f -delete 2>/dev/null || true
  fi
}

_bk_do_conf() {
  local stage="$1" d
  mkdir -p "$stage/conf"
  log "备份配置 …"
  _bk_cp "${MY_CNF_PATH:-/etc/my.cnf}"          my.cnf            "$stage"
  _bk_cp "${PREFIX_REDIS}/etc"                  redis-etc         "$stage"
  _bk_cp "${PREFIX_PHP}/etc"                    php-etc           "$stage"
  _bk_cp "${PREFIX_NGINX}/conf"                 nginx-conf        "$stage"
  _bk_cp "${PREFIX_APACHE}/conf"                apache-conf       "$stage"
  _bk_cp "${PREFIX_MEMCACHED}/etc"              memcached-etc     "$stage"
  # 只备我们自己写的那两个文件：整个 /etc/fail2ban 里有几百个发行版自带的
  # action.d/filter.d，全打进去会让包从 30 个文件涨到 200+，还原时还会覆盖
  # 系统自带的 filter/action（那些应该由包管理器管）。
  _bk_cp /etc/fail2ban/jail.local                fail2ban-jail.local "$stage"
  _bk_cp /etc/fail2ban/jail.d                    fail2ban-jail.d     "$stage"
  # logrotate 与 systemd unit 是我们自己写的，还原时必须一起回去
  mkdir -p "$stage/conf/logrotate" "$stage/conf/systemd"
  for d in nginx php-fpm mysqld mariadb redis memcached fail2ban; do
    _bk_cp "/etc/logrotate.d/$d" "logrotate/$d" "$stage"
    _bk_cp "/etc/systemd/system/$d.service" "systemd/$d.service" "$stage"
  done
  _bk_cp /etc/sysctl.d/99-lnamp.conf            sysctl-99-lnamp.conf "$stage"
  _bk_cp /etc/security/limits.d/99-lnamp.conf   limits-99-lnamp.conf "$stage"
  # 凭据：见文件头说明，默认打包（否则还原后连不上库）；落地强制 600
  mkdir -p "$stage/credentials"
  for d in .mysql_root_password .mariadb_root_password .redis_password; do
    [ -f "${HOME:-/root}/$d" ] && cp -f "${HOME:-/root}/$d" "$stage/credentials/$d" 2>/dev/null
  done
  find "$stage/credentials" -type f -exec chmod 600 {} + 2>/dev/null || true
  log_ok "配置已备份: conf/ ($(find "$stage/conf" -type f 2>/dev/null | wc -l | tr -d ' ') 个文件)"
}

# 站点代码：按 vhost 的 root 去重后逐个打包成 site/<domain>/code.tar.gz
_bk_do_site() {
  local stage="$1" d f dom root seen="" n=0
  mkdir -p "$stage/site"
  log "备份站点代码（可能较慢）…"
  for d in "${PREFIX_NGINX}/conf/vhost" "${PREFIX_APACHE}/conf/vhost"; do
    [ -d "$d" ] || continue
    for f in "$d"/*.conf; do
      [ -f "$f" ] || continue
      case "$f" in *.bak.*) continue ;; esac
      root=$(sed -n 's/^[[:space:]]*root[[:space:]]\+\([^;]*\);.*/\1/p' "$f" 2>/dev/null | head -1)
      [ -n "$root" ] || root=$(sed -n 's/^[[:space:]]*DocumentRoot[[:space:]]\+"\{0,1\}\([^";]*\)"\{0,1\}.*/\1/p' "$f" 2>/dev/null | head -1)
      [ -n "$root" ] && [ -d "$root" ] || continue
      case " $seen " in *" $root "*) continue ;; esac     # 多个域名共用一个站点目录时只打一次
      seen="$seen $root"
      dom=$(basename "$f" .conf)
      mkdir -p "$stage/site/$dom"
      if tar -czf "$stage/site/$dom/code.tar.gz" -C "$root" . 2>/dev/null; then
        log_ok "  站点 $dom ($(du -h "$stage/site/$dom/code.tar.gz" | awk '{print $1}')) <- $root"
        n=$((n + 1))
      else
        log_warn "  站点 $dom 打包失败（权限不足或文件被独占？）"
        _BK_FAIL=$((_BK_FAIL + 1))
      fi
    done
  done
  [ "$n" -eq 0 ] && log "未发现可备份的站点目录"
}

_bk_manifest() {
  local stage="$1" inc="$2" eng; eng=$(_bk_db_engine)
  {
    echo "lnamp backup manifest"
    echo "generated : $(date '+%Y-%m-%d %H:%M:%S %Z')"
    echo "host      : $(hostname 2>/dev/null)"
    echo "includes  : ${inc}"
    echo "db_engine : ${eng:-none}"
    echo "db_version: $(_up_current_version "${eng:-mysql}" 2>/dev/null || echo -)"
    echo
    echo "# 组件版本（还原前请确认目标机不低于源机大版本）"
    for c in nginx php mysql mariadb redis memcached; do
      local v; v=$(_up_current_version "$c" 2>/dev/null)
      [ -n "$v" ] && echo "component.$c = $v"
    done
    echo
    echo "# 注意：credentials/ 内含数据库与 Redis 明文密码，本包等同密钥，请按密钥管理"
  } > "$stage/manifest.txt"
}

# 保留策略：只留最近 N 份
_bk_prune() {
  local dir="$1" keep="$2" n=0 f
  [ "$keep" -gt 0 ] 2>/dev/null || return 0
  for f in $(ls -1t "$dir"/lnamp-backup-*.tar.gz 2>/dev/null | tail -n +$((keep + 1))); do
    rm -f "$f" "${f}.sha256" && n=$((n + 1))
  done
  [ "$n" -gt 0 ] && log "已清理 ${n} 个过期备份（保留最近 ${keep} 份）"
  return 0
}

# ---------------------------------------------------------------------------
#  backup 入口
# ---------------------------------------------------------------------------
backup_main() {
  # 默认目录要在**运行时**取环境变量：BK_DIR 是 source 时求值的，
  # 若调用方在 source 之后才 export LNAMP_BACKUP_DIR，读 BK_DIR 会拿到旧值
  local only="" with_site=0 dest="${LNAMP_BACKUP_DIR:-$BK_DIR}" remote="" keep="$BK_KEEP" a
  while [ $# -gt 0 ]; do
    case "$1" in
      --only)      only="${2:-}"; shift 2 ;;
      --only=*)    only="${1#*=}"; shift ;;
      --with-site) with_site=1; shift ;;
      --dest)      dest="${2:-}"; shift 2 ;;
      --dest=*)    dest="${1#*=}"; shift ;;
      --remote)    remote="${2:-}"; shift 2 ;;
      --keep)      keep="${2:-7}"; shift 2 ;;
      --keep=*)    keep="${1#*=}"; shift ;;
      --dry-run)   DRY_RUN=1; shift ;;
      -h|--help)
        echo "用法: $0 backup [--only db,conf,site] [--with-site] [--dest DIR] [--keep N] [--remote u@h:/path]"
        echo "  默认范围: db,conf（数据库 + 配置），不含站点代码（用 --with-site）"
        return 0 ;;
      *) die "backup: 未知参数 $1" ;;
    esac
  done

  # 范围归一
  [ -n "$only" ] || { [ "$with_site" = 1 ] && only="db,conf,site" || only="db,conf"; }
  case ",$only," in *,site,*) with_site=1 ;; esac
  local _o
  for _o in $(printf '%s' "$only" | tr ',' ' '); do
    case "$_o" in
      db|conf|site) : ;;
      *) die "backup: --only 只接受 db / conf / site，收到: ${_o}（完整值: ${only}）" ;;
    esac
  done
  case "$keep" in ''|*[!0-9]*) die "backup: --keep 需要一个非负整数" ;; esac

  local inc; inc=$(printf '%s' "$only" | tr -d ' ')
  local ts stamp; ts=$(date +%Y%m%d_%H%M%S); stamp=$(date '+%Y-%m-%d %H:%M:%S')

  hr; log "lnamp 备份 ${stamp}"; log "范围: ${inc}    输出: ${dest}"; hr

  if [ "${DRY_RUN:-0}" = 1 ]; then
    log "  [dry-run] 将备份: ${inc}"
    log "  [dry-run] 输出包: ${dest}/lnamp-backup-${ts}.tar.gz"
    [ -n "$remote" ] && log "  [dry-run] 将推送到: ${remote}"
    return 0
  fi

  # 输出目录建不出来必须立刻中止：否则后面 tar 写不进去，
  # 最后却打印"备份完成"——运维以为有备份，实际什么都没有。
  safe_mkdir "$dest" || die "backup: 无法创建输出目录 ${dest}（权限不足或路径不可写）"
  local stage; stage=$(mktemp -d)
  [ -d "$stage" ] || die "backup: 无法创建临时目录"

  case ",$inc," in *,db,*)   _bk_do_db    "$stage" ;; esac
  case ",$inc," in *,db,*)   _bk_do_redis "$stage" ;; esac
  case ",$inc," in *,conf,*) _bk_do_conf  "$stage" ;; esac
  case ",$inc," in *,site,*) _bk_do_site  "$stage" ;; esac
  _bk_manifest "$stage" "$inc"

  local pkg="$dest/lnamp-backup-${ts}.tar.gz"
  log "打包 …"
  if ! tar -czf "$pkg" -C "$stage" . 2>/dev/null; then
    log_err "打包失败: $pkg"
    rm -rf "$stage"
    return 1
  fi
  chmod 600 "$pkg" 2>/dev/null || true   # 包内含凭据

  # 校验和：还原前用它确认包没被截断/篡改
  if _bk_have sha256sum; then
    ( cd "$dest" && sha256sum "$(basename "$pkg")" > "$(basename "$pkg").sha256" ) 2>/dev/null || true
  fi

  log_ok "备份完成: ${pkg}  ($(du -h "$pkg" | awk '{print $1}'))"

  # 完整性判断必须在轮转**之前**：轮转只保留最近 N 份，如果 dump 连续失败，
  # 本次产出的是"缺库"的残缺包，照旧轮转会把窗口里最后一份完好备份挤出去 ——
  # 想回滚时才发现能用的包已经被自己删了。
  if [ "$_BK_FAIL" -gt 0 ]; then
    log_err "有 ${_BK_FAIL} 个分项失败，包内可能不完整: ${pkg}"
    log_warn "已跳过本轮轮转与异地推送 —— 保留旧包，并避免用残缺包覆盖远端的好包"
    log_warn "修好失败项后重跑一次；确认这个包没用时手工删除: rm -f ${pkg} ${pkg}.sha256"
    rm -rf "$stage"
    return 1
  fi

  _bk_prune "$dest" "$keep"

  if [ -n "$remote" ]; then
    log "推送到异地: ${remote}"
    if _bk_have rsync; then
      rsync -a --partial "$pkg" "$remote" && log_ok "异地推送完成 (rsync)"
    elif _bk_have scp; then
      scp -q "$pkg" "$remote" && log_ok "异地推送完成 (scp)"
    else
      log_warn "rsync 与 scp 都不可用，异地推送跳过"
    fi
  fi

  rm -rf "$stage"
  log "还原: $0 restore ${pkg}"
  return 0
}

# ---------------------------------------------------------------------------
#  restore 入口
# ---------------------------------------------------------------------------
restore_main() {
  local pkg="" only="" with_site=0 yes=0 restart=0 no_pre=0 with_creds=0 a
  while [ $# -gt 0 ]; do
    case "$1" in
      --with-credentials) with_creds=1; shift ;;
      --only)        only="${2:-}"; shift 2 ;;
      --only=*)      only="${1#*=}"; shift ;;
      --with-site)   with_site=1; shift ;;
      -y|--yes)      yes=1; shift ;;
      --restart)     restart=1; shift ;;
      --no-pre-backup) no_pre=1; shift ;;
      --dry-run)     DRY_RUN=1; shift ;;
      -h|--help)
        echo "用法: $0 restore <备份包> [--only db,conf,site] [--with-site] [--yes] [--restart]"
        echo "  还原前会自动把当前状态再备份一份（--no-pre-backup 可跳过）"
        echo "  --restart  还原后自动重启受影响的服务（默认只提示，不动线上）"
        echo "  --with-credentials  连凭据文件(/root/.*_password)一起还原（默认只在含 db 时还原）"
        return 0 ;;
      -*) die "restore: 未知参数 $1" ;;
      *)  [ -z "$pkg" ] && pkg="$1" || die "restore: 多余的参数 $1"; shift ;;
    esac
  done
  [ -n "$pkg" ] || die "restore: 需要指定备份包，例如: $0 restore /root/lnamp-backups/lnamp-backup-20261025_170000.tar.gz"
  [ -f "$pkg" ] || die "restore: 备份包不存在: $pkg"

  # 1) 完整性校验
  if [ -f "${pkg}.sha256" ] && _bk_have sha256sum; then
    if ( cd "$(dirname "$pkg")" && sha256sum -c "$(basename "$pkg").sha256" ) >/dev/null 2>&1; then
      log_ok "校验和通过"
    else
      die "restore: sha256 校验失败，包可能损坏或被篡改，已中止"
    fi
  else
    log_warn "未找到 .sha256，跳过完整性校验"
  fi

  # 2) 解包 + 读 manifest
  local tmp; tmp=$(mktemp -d)
  tar -xzf "$pkg" -C "$tmp" 2>/dev/null || { rm -rf "$tmp"; die "restore: 解包失败"; }
  if [ -f "$tmp/manifest.txt" ]; then
    log "包信息:"; sed 's/^/    /' "$tmp/manifest.txt" | grep -vE '^    #' | head -12
  fi

  # 3) 范围推断（没指定就按包里有的来）
  if [ -z "$only" ]; then
    local parts=""
    ls "$tmp/db"/*.sql.gz >/dev/null 2>&1 && parts="$parts,db"
    ls "$tmp/db"/redis-dump.rdb >/dev/null 2>&1 && parts="$parts,redis"
    [ -d "$tmp/conf" ] && parts="$parts,conf"
    [ -n "$parts" ] || die "restore: 包里没有可还原的内容"
    only=${parts#,}
  fi
  if [ "$with_site" = 1 ]; then
    case ",$only," in *,site,*) : ;; *) only="$only,site" ;; esac
  fi

  hr; log "即将还原: ${only}"; log "包: ${pkg}"; hr
  if [ "$yes" != 1 ]; then
    log_warn "还原会覆盖当前数据库 / 配置（数据库为全量导入，同名库表将被覆盖）"
    if ! ask_yes_no "确认继续？"; then log "已取消"; rm -rf "$tmp"; return 1; fi
  fi

  # 4) 还原前给当前状态再存一份：还原错包时还有退路
  if [ "$no_pre" != 1 ] && [ "${DRY_RUN:-0}" != 1 ]; then
    local pre_only="conf"
    case ",$only," in *,db,*) pre_only="db,conf" ;; esac
    log "先备份当前状态（还原错了还能回去）…"
    if ! backup_main --only "$pre_only" --keep 0 >/dev/null 2>&1; then
      log_warn "还原前备份失败，继续还原（未被 --no-pre-backup 跳过）"
      if [ "$yes" != 1 ] && ! ask_yes_no "仍要继续？"; then rm -rf "$tmp"; return 1; fi
    fi
  fi

  local rc=0 svcs=""

  # 5) 数据库
  case ",$only," in *,db,*)
    local sqlf; sqlf=$(ls "$tmp"/db/*-all.sql.gz 2>/dev/null | head -1)
    if [ -n "$sqlf" ]; then
      local eng; eng=$(basename "$sqlf" | sed 's/-all\.sql\.gz$//')
      local bin pass sock
      bin="${PREFIX_MYSQL}/bin/mysql"; [ -x "$bin" ] || bin="${PREFIX_MARIADB}/bin/mysql"
      [ -x "$bin" ] || bin=$(command -v mysql 2>/dev/null)
      if [ -z "$bin" ]; then log_err "找不到 mysql 客户端，数据库未还原"; rc=1
      else
        pass=$(_bk_db_pass "$eng")
        sock=/tmp/mysql.sock
        [ -f "${MY_CNF_PATH:-/etc/my.cnf}" ] && sock=$(awk -F'=' '/^[[:space:]]*socket[[:space:]]*=/{gsub(/[[:space:]]/,"",$2);print $2;exit}' "${MY_CNF_PATH:-/etc/my.cnf}")
        [ -n "$sock" ] || sock=/tmp/mysql.sock
        log "还原数据库 (${eng}) …"
        # shellcheck disable=SC2086
        if gunzip -c "$sqlf" | "$bin" --socket="$sock" -uroot ${pass:+-p"$pass"} 2>/dev/null; then
          log_ok "数据库已还原（各库表为导入时刻状态；建议跑一次 mysqlcheck）"
          [ "$eng" = "mysql" ] && svcs="$svcs mysqld" || svcs="$svcs mariadb"
        else
          log_err "数据库还原失败（版本不兼容或 dump 不完整？）"; rc=1
        fi
      fi
    fi
  ;; esac

  # 6) Redis（RDB 只能换文件，需停服）
  case ",$only," in *,redis,*)
    local rdb="$tmp/db/redis-dump.rdb"
    if [ -f "$rdb" ] && [ -x "${PREFIX_REDIS}/bin/redis-server" ]; then
      local rdir pass
      rdir=$(grep -E '^[[:space:]]*dir[[:space:]]' "${PREFIX_REDIS}/etc/redis.conf" 2>/dev/null | awk '{print $2}' | head -1)
      [ -n "$rdir" ] || rdir="${PREFIX_REDIS}/var"
      pass=$(_bk_redis_pass)
      log "还原 Redis 数据（需短暂停服）…"
      systemctl stop redis 2>/dev/null || true
      safe_mkdir "$rdir"
      if cp -f "$rdb" "${rdir}/dump.rdb"; then
        chown redis:redis "${rdir}/dump.rdb" 2>/dev/null || true
        log_ok "Redis dump.rdb 已还原到 ${rdir}"
      else
        log_err "Redis 数据文件写入失败"; rc=1
      fi
      # 是我们自己停的，就得由我们拉起来。历史上只有加了 --restart 才启动，
      # 默认还原完 Redis 一直躺着 —— 业务侧只看到连接被拒，还以为是还原失败。
      # --restart 管的是"没被动过的服务要不要重启"，不适用于这里。
      if [ "${DRY_RUN:-0}" != 1 ]; then
        if systemctl start redis >/dev/null 2>&1; then
          log_ok "Redis 已启动（还原需要停服，已自动恢复）"
        else
          log_warn "Redis 启动失败，请手工: systemctl start redis"
          svcs="$svcs redis"
        fi
      fi
    fi
  ;; esac

  # 7) 配置（先备份现有，再覆盖；nginx 配置要过 -t）
  case ",$only," in *,conf,*)
    if [ -d "$tmp/conf" ]; then
      log "还原配置 …"
      local ts; ts=$(date +%Y%m%d%H%M%S)
      # 凭据文件默认**不**跟着 conf 还原：--only conf 只改配置、不动库，
      # 此时把 /root/.mysql_root_password 换成旧口令，就等于让"密码文件"和
      # "库里实际口令"永久不一致 —— 之后任何脚本拿它连库都是认证失败。
      # 只有还原了数据库（库被整体导回，口令随之变回旧值）时才同步还原凭据。
      local creds=0
      case ",$only," in *,db,*) creds=1 ;; esac
      [ "$with_creds" = 1 ] && creds=1
      _bk_restore_conf "$tmp/conf" "$ts" "$creds"
      svcs="$svcs nginx php-fpm"
    fi
  ;; esac

  # 8) 站点代码
  case ",$only," in *,site,*)
    if [ -d "$tmp/site" ]; then
      local dom root
      for dom in "$tmp/site"/*; do
        [ -d "$dom" ] || continue
        dom=$(basename "$dom")
        root=$(sed -n 's/^[[:space:]]*root[[:space:]]\+\([^;]*\);.*/\1/p' "${PREFIX_NGINX}/conf/vhost/${dom}.conf" 2>/dev/null | head -1)
        [ -n "$root" ] || { log_warn "站点 ${dom}: 当前没有对应 vhost，代码包留在包内未展开（可手动解压）"; continue; }
        safe_mkdir "$root"
        if tar -xzf "$tmp/site/${dom}/code.tar.gz" -C "$root" 2>/dev/null; then
          id www >/dev/null 2>&1 && chown -R www:www "$root" 2>/dev/null || true
          log_ok "站点 ${dom} 代码已还原到 ${root}"
        else
          log_err "站点 ${dom} 解压失败"; rc=1
        fi
      done
    fi
  ;; esac

  # 9) 重启（默认不动线上）
  if [ "$restart" = 1 ] && [ "${DRY_RUN:-0}" != 1 ]; then
    local s
    for s in $svcs; do
      systemctl restart "$s" >/dev/null 2>&1 && log_ok "已重启 ${s}" || log_warn "${s} 重启失败，请检查"
    done
  elif [ -n "$svcs" ]; then
    log "还原完成。生效需重启服务: systemctl restart $(echo "$svcs" | tr ' ' '\n' | sort -u | tr '\n' ' ')"
  fi

  rm -rf "$tmp"
  [ "$rc" = 0 ] && log_ok "还原结束（无错误）" || log_err "还原结束，但有失败项，请按上方 [ERR] 处理"
  return "$rc"
}

# 把 conf/ 下的内容覆盖回各自的生产路径（先存 .bak.<ts>）
_bk_restore_conf() {
  local src="$1" ts="$2" with_creds="${3:-0}"
  _rc_put() {   # 源 目标
    local s="$1" d="$2"
    [ -e "$s" ] || return 0
    if [ -e "$d" ]; then cp -a "$d" "${d}.bak.${ts}" 2>/dev/null || true; fi
    safe_mkdir "$(dirname "$d")"
    rm -rf "$d" 2>/dev/null || true
    cp -a "$s" "$d" 2>/dev/null && log "  恢复 $d" || log_warn "  恢复失败 $d"
  }
  _rc_put "$src/my.cnf"                  "${MY_CNF_PATH:-/etc/my.cnf}"
  _rc_put "$src/redis-etc"               "${PREFIX_REDIS}/etc"
  _rc_put "$src/php-etc"                 "${PREFIX_PHP}/etc"
  _rc_put "$src/nginx-conf"              "${PREFIX_NGINX}/conf"
  _rc_put "$src/apache-conf"             "${PREFIX_APACHE}/conf"
  _rc_put "$src/memcached-etc"           "${PREFIX_MEMCACHED}/etc"
  _rc_put "$src/fail2ban-jail.local"     /etc/fail2ban/jail.local
  if [ -d "$src/fail2ban-jail.d" ]; then
    local jf
    for jf in "$src"/fail2ban-jail.d/*; do
      [ -f "$jf" ] && _rc_put "$jf" "/etc/fail2ban/jail.d/$(basename "$jf")"
    done
  fi
  _rc_put "$src/sysctl-99-lnamp.conf"    /etc/sysctl.d/99-lnamp.conf
  _rc_put "$src/limits-99-lnamp.conf"    /etc/security/limits.d/99-lnamp.conf
  local f
  for f in "$src"/logrotate/*; do
    [ -f "$f" ] && _rc_put "$f" "/etc/logrotate.d/$(basename "$f")"
  done
  for f in "$src"/systemd/*.service; do
    [ -f "$f" ] && _rc_put "$f" "/etc/systemd/system/$(basename "$f")"
  done
  # 凭据：见 restore_main 里的说明 —— 只在明确要（含 db 或 --with-credentials）时才覆盖。
  # 不还原时也要说清楚，否则运维会以为"口令跟着配置一起回来了"。
  if [ "$with_creds" = 1 ]; then
    for f in "$src"/credentials/.*_password; do
      [ -f "$f" ] && { cp -f "$f" "${HOME:-/root}/$(basename "$f")" 2>/dev/null \
        && chmod 600 "${HOME:-/root}/$(basename "$f")" 2>/dev/null \
        && log "  恢复 $(basename "$f")"; }
    done
  elif [ -d "$src/credentials" ] && [ -n "$(ls -A "$src/credentials" 2>/dev/null)" ]; then
    log_warn "  凭据文件未还原（当前库口令保持不变）: $(ls -A "$src/credentials" 2>/dev/null | tr '\n' ' ')"
    log_warn "  确要一起还原加 --with-credentials（只有库也一并还原时才该这么做）"
  fi
  # nginx 配置必须过 -t，否则还原出一个起不来的配置（历史上踩过）
  if [ -x "${PREFIX_NGINX}/sbin/nginx" ]; then
    if "${PREFIX_NGINX}/sbin/nginx" -t >/dev/null 2>&1; then
      log_ok "  nginx 配置测试通过"
    else
      log_err "  还原后的 nginx 配置未通过 nginx -t！备份文件在 *.bak.${ts}，请检查"
      _BK_FAIL=$((_BK_FAIL + 1))
    fi
  fi
  systemctl daemon-reload 2>/dev/null || true
  return 0
}
