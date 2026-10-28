#!/bin/bash
# ============================================================================
#  modules/doctor.sh  ——  只读诊断 (doctor)
# ----------------------------------------------------------------------------
#  status 告诉你"哪里不对"，doctor 告诉你"为什么不对、怎么修"。
#  检查的都是**真机上真的会静默出错**的地方，其中好几条来自本项目自身踩过的坑：
#
#    · unit 存在但二进制已被删  -> 卸载后残留，systemctl restart 永久失败
#    · logrotate 指向不存在的路径 -> 每天 stat failed，日志再也不轮转
#    · 扩展 .so 不存在于 extension_dir -> php -m 里看着有，FPM 里没有
#    · 端口被别的进程占着      -> 服务 active 但用户访问的是别人
#    · 凭据文件权限过宽        -> 同机任何用户可读数据库 root 密码
#    · 数据库/Redis 意外监听 0.0.0.0 -> 云主机上等于把端口送出去
#
#  用法:
#    bash install.sh doctor            # 全部检查 + 修复建议
#    bash install.sh doctor --quiet    # 只列问题项
#  退出码: 0=无问题  1=有 WARN/FAIL
#
#  设计原则：**只读**。任何检查都不改配置、不重启服务，修复命令只打印不执行。
#  ============================================================================

_D_OK=0; _D_WARN=0; _D_FAIL=0; _D_SKIP=0
_D_QUIET=0
_doc_sec()  { [ "$_D_QUIET" = 1 ] && return 0; echo; printf '%s\n' "$(_c '1;36' "== $* ==")"; }
_doc_ok()   { [ "$_D_QUIET" = 1 ] && { _D_OK=$((_D_OK + 1)); return 0; }
              printf '  [OK]  %s\n' "$*"; _D_OK=$((_D_OK + 1)); }
_doc_warn() { printf '  [!]   %s\n' "$*"; _D_WARN=$((_D_WARN + 1)); }
_doc_fail() { printf '  [X]   %s\n' "$*"; _D_FAIL=$((_D_FAIL + 1)); }
_doc_skip() { _D_SKIP=$((_D_SKIP + 1)); [ "$_D_QUIET" = 1 ] && return 0
              printf '  [-]   %s\n' "$*"; }
_doc_hint() { printf '        修复: %s\n' "$*"; }

_doc_is_root() { [ "$(id -u 2>/dev/null)" = "0" ]; }

# ---------------------------------------------------------------------------
#  1. 时钟同步
# ---------------------------------------------------------------------------
_doc_clock() {
  _doc_sec "时钟 (clock)"
  if ! command -v timedatectl >/dev/null 2>&1; then
    _doc_skip "无 timedatectl，无法判断 NTP 同步状态"
    _doc_hint "安装 chrony 或 systemd-timesyncd 并用 chronyc tracking 查看"
    return 0
  fi
  local sync now
  sync=$(timedatectl show -p NTPSynchronized --value 2>/dev/null)
  now=$(date '+%Y-%m-%d %H:%M:%S %Z')
  if [ "$sync" = "yes" ]; then
    _doc_ok "时钟已同步 (${now})"
  else
    _doc_warn "时钟未同步 (NTPSynchronized=${sync:-unknown}, 当前 ${now})"
    _doc_hint "systemctl enable --now systemd-timesyncd && timedatectl set-ntp true"
    _doc_hint "时钟偏移会让 TLS 校验、日志时间线、fail2ban 封禁时长全部失准"
  fi
}

# ---------------------------------------------------------------------------
#  2. 磁盘与 inode
# ---------------------------------------------------------------------------
_doc_disk() {
  _doc_sec "磁盘 (disk)"
  local pct ipct pn in
  # 用倒数第 2 列：Filesystem 名里可能有空格（如 Git Bash 的 C:/Program Files/Git），
  # 按 $5 取会把总量当百分比，出现"已用 325915372"这种荒谬输出
  pct=$(df -kP / 2>/dev/null | awk 'NR==2 && NF>=6{print $(NF-1)}')
  ipct=$(df -iP / 2>/dev/null | awk 'NR==2 && NF>=6{print $(NF-1)}')
  pn=${pct%\%}; in=${ipct%\%}
  if [ "${pn:-0}" -ge 90 ] 2>/dev/null; then
    _doc_fail "根分区已用 ${pct}"
    _doc_hint "du -xh --max-depth=2 / 2>/dev/null | sort -h | tail -20"
    _doc_hint "常见大户: 站点日志、/root/lnamp-predump-*.sql.gz、MySQL binlog"
  else
    _doc_ok "根分区使用 ${pct:-?}"
  fi
  if [ "${in:-0}" -ge 90 ] 2>/dev/null; then
    _doc_fail "inode 已用 ${ipct}（磁盘还有空间但写不进去，最难排查）"
    _doc_hint "df -i 找出满的分区；小文件大户通常是 PHP session、站点缓存目录"
  else
    _doc_ok "inode 使用 ${ipct:-?}"
  fi
}

# ---------------------------------------------------------------------------
#  3. systemd unit 存在但二进制缺失（本项目 P0 缺陷的原型）
# ---------------------------------------------------------------------------
_doc_units() {
  _doc_sec "服务单元 (units)"
  command -v systemctl >/dev/null 2>&1 || { _doc_skip "无 systemctl，跳过"; return 0; }
  local u ex n=0
  for u in nginx php-fpm mysqld mariadb redis memcached fail2ban; do
    systemctl list-unit-files 2>/dev/null | grep -c "^$u\.service" >/dev/null 2>&1 || continue
    n=$((n + 1))
    ex=$(systemctl show -p ExecStart --value "$u" 2>/dev/null | \
         tr ';' '\n' | sed -n 's/.*path=\([^ ]*\).*/\1/p' | head -1)
    if [ -z "$ex" ]; then
      _doc_warn "${u}.service 存在但解析不到 ExecStart（unit 被改坏了？）"
      _doc_hint "systemctl cat $u"
    elif [ ! -x "$ex" ]; then
      _doc_fail "${u}.service 指向的二进制不存在: $ex"
      local oc="$u"
      case "$u" in mysqld) oc=mysql ;; php-fpm) oc=php ;; esac
      _doc_hint "重装该组件: $0 --${oc}"
      _doc_hint "或者彻底卸载: $0 uninstall --component $u"
    else
      local st; st=$(systemctl is-active "$u" 2>/dev/null)
      if [ "$st" = "active" ]; then _doc_ok "${u}: 运行中 (${ex})"
      else _doc_warn "${u}: 未运行 ($st)"
        _doc_hint "systemctl start $u; journalctl -u $u -n 50 --no-pager"
      fi
    fi
  done
  [ "$n" -eq 0 ] && _doc_skip "本机没有任何本栈 unit（未安装）"
}

# ---------------------------------------------------------------------------
#  4. 端口归属（服务 active 但端口被别人占，用户访问的其实是别的程序）
# ---------------------------------------------------------------------------
_doc_ports() {
  _doc_sec "端口归属 (ports)"
  local items="80:nginx 3306:mysql 6379:redis 11211:memcached"
  local item port owner line
  for item in $items; do
    port=${item%%:*}
    line=$( (ss -lntp 2>/dev/null || netstat -lntp 2>/dev/null) | awk -v p="$port" '$4 ~ "[:.]"p"$"{print; exit}' )
    if [ -z "$line" ]; then
      # 没在听不一定是错（比如没装），只在对应 unit 存在时提示
      local svc=${item#*:}; [ "$svc" = "mysql" ] && svc=mysqld
      if command -v systemctl >/dev/null 2>&1 && systemctl list-unit-files 2>/dev/null | grep -c "^${svc}\.service" >/dev/null 2>&1; then
        _doc_warn "端口 ${port} 无监听，但 ${svc} 已安装"
        _doc_hint "systemctl status ${svc}; ss -lntp | grep ${port}"
      else
        _doc_ok "端口 ${port} 未使用（组件未安装）"
      fi
      continue
    fi
    owner=$(printf '%s' "$line" | sed -n 's/.*users:((\"\([^\"]*\)\".*/\1/p')
    [ -n "$owner" ] || owner=$(printf '%s' "$line" | awk '{print $NF}' | tr -d '(')
    case "$owner" in
      nginx*|mysqld*|mariadbd*|redis*|memcached*|httpd*|php-fpm*)
        _doc_ok "端口 ${port} 由 ${owner} 监听" ;;
      "")
        _doc_warn "端口 ${port} 有监听但看不到进程名（非 root 运行，重新用 root 跑可看到）" ;;
      *)
        _doc_warn "端口 ${port} 被非本栈进程占用: ${owner}"
        _doc_hint "ss -lntp | grep ${port}   # 确认是否可以停掉它，或改本栈端口" ;;
    esac
  done
}

# ---------------------------------------------------------------------------
#  SSH 可登录性：端口在听 != 能连上
#  224 / 184（Rocky 8.10）装到一半后出现"22 端口能建 TCP、但永远收不到 banner"：
#  主进程还占着端口，子进程却因 privsep 目录缺失直接退出。这种故障 verify 看不出来
#  （它只查 unit active + 端口监听），运维也只会觉得"网络抽风"，所以单列一项。
# ---------------------------------------------------------------------------
_doc_sshd() {
  _doc_sec "SSH 可登录性 (sshd)"
  command -v systemctl >/dev/null 2>&1 || { _doc_skip "无 systemd，跳过"; return 0; }
  # 不用 `list-unit-files | grep -q`：pipefail 下 grep -q 提前退出会让上游 SIGPIPE
  # 返回非零，判断结果被反转（项目里有专门的反模式护栏）。
  systemctl cat sshd.service >/dev/null 2>&1 || { _doc_skip "未安装 sshd"; return 0; }
  if ! systemctl is-active --quiet sshd 2>/dev/null; then
    _doc_fail "sshd 未运行（远程登录会全部失败）"
    _doc_hint "systemctl start sshd; systemctl enable sshd"
    return 0
  fi
  if [ ! -d /run/sshd ]; then
    _doc_fail "/run/sshd 缺失：22 端口能连上，但不会返回 SSH banner（所有新连接失败）"
    _doc_hint "mkdir -p /run/sshd && systemctl restart sshd"
    return 0
  fi
  # 端口在听 != 能握手。真机上出现过「22 可建 TCP、但永远收不到 banner」：
  # 主进程仍占着端口，fork 出来的子进程在认证前就退出。这时 unit 是 active、
  # 目录也可能存在，只看状态会误判健康。所以真读一次 banner。
  local _line="" _addr="" _host="" _port=22 _ban=""
  command -v ss >/dev/null 2>&1 && _line=$(ss -lntp 2>/dev/null | grep -w sshd | head -1)
  if [ -z "$_line" ]; then
    _doc_ok "sshd 运行中，privsep 目录 /run/sshd 存在（无监听信息，跳过 banner 探测）"
    return 0
  fi
  _addr=$(printf '%s\n' "$_line" | awk '{print $4}')
  _port=${_addr##*:}
  _host=${_addr%:*}
  case "$_host" in ""|"*"|"0.0.0.0"|"[::]"|"::") _host=127.0.0.1 ;; esac
  _host=${_host#[}; _host=${_host%]}
  if command -v timeout >/dev/null 2>&1; then
    _ban=$( { exec 3<>"/dev/tcp/${_host}/${_port}"; } 2>/dev/null && timeout 3 head -c 4 <&3 2>/dev/null )
  else
    _ban=$( { exec 3<>"/dev/tcp/${_host}/${_port}"; } 2>/dev/null && head -c 4 <&3 2>/dev/null )
  fi
  case "$_ban" in
    SSH-*)
      _doc_ok "sshd 运行中，banner 正常（${_host}:${_port} 返回 SSH-）"
      ;;
    *)
      _doc_fail "sshd 在 ${_host}:${_port} 监听但读不到 banner（新连接会全部失败）"
      _doc_hint "mkdir -p /run/sshd && chmod 755 /run/sshd && systemctl restart sshd"
      _doc_hint "若重启无效，看 journalctl -u sshd -n 20 与 /var/log/secure（有无 fork/privsep 报错）"
      ;;
  esac
}

# ---------------------------------------------------------------------------
#  5. PHP 扩展：.so 是否存在、ini 是否被扫描、CLI 与 FPM 是否一致
# ---------------------------------------------------------------------------
_doc_php_ext() {
  _doc_sec "PHP 扩展 (php extensions)"
  local php="${PREFIX_PHP}/bin/php"
  if [ ! -x "$php" ]; then _doc_skip "未安装 PHP，跳过"; return 0; fi

  local extdir scan mods ini f name miss=0
  extdir=$("$php" -i 2>/dev/null | sed -n 's/^extension_dir => \([^ ]*\).*/\1/p' | head -1)
  scan=$("$php" --ini 2>/dev/null | sed -n 's/^Scan for additional .ini files in: //p' | head -1)
  # scan 为空时下面的 "$scan"/*.ini 会退化成 /*.ini（遍历根目录），必须先兜底
  [ -n "$scan" ] || scan="${PREFIX_PHP}/etc/php.d"
  mods=$("$php" -m 2>/dev/null | tr 'A-Z' 'a-z')

  if [ -z "$extdir" ] || [ ! -d "$extdir" ]; then
    _doc_fail "extension_dir 无效: ${extdir:-空}"
    _doc_hint "$php -i | grep extension_dir"
    return 0
  fi

  # 每个 ini 里声明的 extension 都要能在 extension_dir 里找到实体文件
  for f in "$scan"/*.ini; do
    [ -f "$f" ] || continue
    name=$(sed -n 's/^[[:space:]]*extension[[:space:]]*=[[:space:]]*"\{0,1\}\([^"]*\)"\{0,1\}.*/\1/p' "$f" 2>/dev/null | head -1)
    [ -n "$name" ] || continue
    case "$name" in /*) ini="$name" ;; *) ini="${extdir}/${name}" ;; esac
    if [ ! -f "$ini" ]; then
      _doc_fail "$(basename "$f") 引用的扩展文件不存在: ${ini}"
      _doc_hint "重装该扩展（PHP 升级后未重建的最常见表现）: $0 --php $("$php" -r 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION;' 2>/dev/null):fpm --swoole --phpredis"
      miss=$((miss + 1))
    fi
  done

  # CLI 已加载的核心扩展（FPM 与 CLI 共用同一 php.ini 与扫描目录时结论一致）
  for name in redis memcached swoole imagick; do
    printf '%s\n' "$mods" | grep -cx "$name" >/dev/null 2>&1 || continue
    _doc_ok "扩展 ${name} 已加载 ($("$php" -r "echo phpversion('$name');" 2>/dev/null))"
  done
  # 模块名是 "Zend OPcache"（带空格），用 "opcache" 整行匹配永远不中 -> 恒定误报
  printf '%s\n' "$mods" | grep -cx 'zend opcache' >/dev/null 2>&1 || \
    { _doc_warn "opcache 未加载（性能损失明显）"; _doc_hint "在 php.ini 里加 zend_extension=opcache.so"; }
  [ "$miss" -eq 0 ] && _doc_ok "所有 ini 声明的扩展文件均存在"
}

# ---------------------------------------------------------------------------
#  6. logrotate 配置指向不存在的路径（本项目踩过的坑）
# ---------------------------------------------------------------------------
_doc_logrotate() {
  _doc_sec "日志轮转 (logrotate)"
  local bad=0 f path
  for f in /etc/logrotate.d/nginx /etc/logrotate.d/php-fpm /etc/logrotate.d/mysqld \
           /etc/logrotate.d/mariadb /etc/logrotate.d/redis /etc/logrotate.d/memcached; do
    [ -f "$f" ] || continue
    path=$(grep -vE '^[[:space:]]*(#|$)' "$f" 2>/dev/null | head -1 | awk '{print $1}')
    [ -n "$path" ] || continue
    case "$path" in
      *'*'*|*'?'*) ls $path >/dev/null 2>&1 || { _doc_fail "$(basename "$f") 的通配路径无匹配: $path"; _doc_hint "修正 $f 里的日志路径，或删掉这段配置"; bad=1; } ;;
      *) [ -e "$path" ] || { _doc_fail "$(basename "$f") 指向不存在的路径: $path"; _doc_hint "修正 $f；lg 不轮转会撑满磁盘"; bad=1; } ;;
    esac
  done
  [ "$bad" = 0 ] && _doc_ok "logrotate 配置的路径均存在"

  # logrotate 会读取该目录下的**所有**文件（不看扩展名），只忽略 .rpmsave/
  # .dpkg-old/.disabled 这类后缀。历史 .bak.<ts> 备份留在原地会被当配置解析，
  # 报 "duplicate log entry" 并 skip，备份也永远不清理。
  local junk
  junk=$(find /etc/logrotate.d -maxdepth 1 -type f -name '*.bak.*' 2>/dev/null | wc -l | tr -d ' ')
  if [ "${junk:-0}" -gt 0 ]; then
    _doc_warn "/etc/logrotate.d 下有 ${junk} 个 .bak.* 备份（logrotate 会当配置读取并报 duplicate entry）"
    _doc_hint "改名加 .disabled 后缀让 logrotate 忽略: cd /etc/logrotate.d && for f in *.bak.*; do mv \"\$f\" \"\$f.disabled\"; done"
  else
    _doc_ok "logrotate.d 无残留备份文件"
  fi
  # 系统级 logrotate 是否真的能解析（-d 只演练不执行）
  if command -v logrotate >/dev/null 2>&1; then
    if logrotate -d /etc/logrotate.conf >/tmp/.lnamp_lr_check 2>&1; then
      _doc_ok "logrotate -d 全局解析通过"
    else
      _doc_warn "logrotate -d /etc/logrotate.conf 有报错"
      _doc_hint "logrotate -d /etc/logrotate.conf 2>&1 | grep -i error"
    fi
    rm -f /tmp/.lnamp_lr_check
  fi
}

# ---------------------------------------------------------------------------
#  7. 目录属主与凭据权限
# ---------------------------------------------------------------------------
_doc_perm() {
  _doc_sec "权限 (permissions)"
  local d own
  for d in "${WWWROOT}" "${WWWROOT}/web" "${WWWLOGS}"; do
    [ -e "$d" ] || continue
    own=$(stat -c '%U:%G' "$d" 2>/dev/null)
    case "$own" in
      www:www|nobody:nobody) _doc_ok "属主正常 ${d} (${own})" ;;
      *) _doc_warn "属主 ${own}（应为 www:www）: $d"
         _doc_hint "chown -R www:www ${d}" ;;
    esac
  done

  local cred f mode
  for cred in "${HOME:-/root}/.mysql_root_password" "${HOME:-/root}/.mariadb_root_password" \
              "${HOME:-/root}/.redis_password"; do
    [ -f "$cred" ] || continue
    mode=$(stat -c '%a' "$cred" 2>/dev/null)
    case "$mode" in
      600|400) _doc_ok "凭据权限正常 $(basename "$cred") (${mode})" ;;
      *) _doc_fail "凭据权限过宽 $(basename "$cred") (${mode}) —— 同机任意用户可读数据库/Redis 密码"
         _doc_hint "chmod 600 ${cred} && chown root:root ${cred}" ;;
    esac
  done

  # /tmp 需要 sticky bit，否则任意用户可删他人文件
  mode=$(stat -c '%a' /tmp 2>/dev/null)
  if [ "$mode" = "1777" ]; then
    _doc_ok "/tmp 权限正常 (1777, 带 sticky 位)"
  else
    _doc_warn "/tmp 权限 ${mode}（应为 1777）"; _doc_hint "chmod 1777 /tmp"
  fi
}

# ---------------------------------------------------------------------------
#  8. 数据库 / Redis 是否意外对外监听
# ---------------------------------------------------------------------------
_doc_bind() {
  _doc_sec "监听范围 (bind)"
  local cfg bind seen=0 f
  cfg="${MY_CNF_PATH:-/etc/my.cnf}"
  if [ -f "$cfg" ]; then
    seen=1
    bind=$(awk -F'=' '/^[[:space:]]*bind-address[[:space:]]*=/{gsub(/[[:space:]]/,"",$2);print $2;exit}' "$cfg")
    # 包管理器装的库常把配置拆在 conf.d 里（我们收敛后写的 zz-lnamp-bind.cnf
    # 也在那儿），主配置里没有不代表没设置 —— 先去那儿找一遍再下结论。
    if [ -z "$bind" ]; then
      for f in /etc/my.cnf.d/*.cnf /etc/mysql/conf.d/*.cnf \
               /etc/mysql/mysql.conf.d/*.cnf /etc/mysql/mariadb.conf.d/*.cnf; do
        [ -f "$f" ] || continue
        bind=$(awk -F'=' '/^[[:space:]]*bind-address[[:space:]]*=/{gsub(/[[:space:]]/,"",$2);print $2;exit}' "$f")
        [ -n "$bind" ] && break
      done
    fi
    case "$bind" in
      127.0.0.1|localhost) _doc_ok "MySQL 仅监听回环 (${bind})" ;;
      "") _doc_warn "MySQL 未显式设置 bind-address（默认可能监听全部网卡）"
          _doc_hint "在 ${cfg} 的 [mysqld] 下加 bind-address = 127.0.0.1" ;;
      *) _doc_fail "MySQL 监听 ${bind}（对外暴露，云主机上等于把 3306 送出去）"
         _doc_hint "改为 bind-address = 127.0.0.1 后 systemctl restart mysqld；确需远程请用防火墙白名单" ;;
    esac
    # 配置写了不等于真的生效：改完没重启、或 mysqld 实际读的是另一份配置，
    # 都会出现"配置是 127.0.0.1、实际还在 0.0.0.0"——实测一次才作数。
    local addr
    addr=$(db_listen_addr 3306)
    if [ -n "$addr" ]; then
      case "$addr" in
        127.0.0.1:*|::1:*|localhost:*) _doc_ok "MySQL 实际只监听回环 (${addr})" ;;
        *) _doc_fail "MySQL 实际监听在 ${addr}（3306 对外暴露）"
           _doc_hint "确认 mysqld 读的是 ${cfg}（systemctl restart mysqld），远程管理请用 SSH 隧道或防火墙白名单" ;;
      esac
    fi
  fi

  local rc="${PREFIX_REDIS}/etc/redis.conf"
  if [ -f "$rc" ]; then
    seen=1
    bind=$(sed -n 's/^[[:space:]]*bind[[:space:]]\+\([^ ]*\).*/\1/p' "$rc" | head -1)
    case "$bind" in
      127.0.0.1|-::1|"") 
        if [ -z "$bind" ]; then
          _doc_warn "Redis 未显式 bind（8.x 默认只允许本机，但建议写明）"
          _doc_hint "在 ${rc} 里写 bind 127.0.0.1 -::1"
        else _doc_ok "Redis 仅监听回环 (${bind})"; fi ;;
      *) _doc_fail "Redis 监听 ${bind}（对外暴露）"
         _doc_hint "改为 bind 127.0.0.1 -::1 并确认 requirepass 已设置" ;;
    esac
    local rp
    rp=$(sed -n 's/^[[:space:]]*requirepass[[:space:]]\+//p' "$rc" 2>/dev/null | head -1 | tr -d '\r')
    case "$rp" in
      ""|foobared)
        _doc_warn "Redis 未设置 requirepass（等于无认证）"
        _doc_hint "在 ${rc} 里设置 requirepass，或重装: $0 --redis 8.10.2" ;;
      *) _doc_ok "Redis 已设置 requirepass" ;;
    esac
  fi

  [ "$seen" = 0 ] && _doc_skip "未安装 MySQL / MariaDB / Redis，跳过监听范围检查"
  local mc="${PREFIX_MEMCACHED}/bin/memcached"
  if [ -x "$mc" ] && (ss -lnt 2>/dev/null || netstat -lnt 2>/dev/null) | awk '$4 ~ "[:.]11211$"' | grep -c . >/dev/null 2>&1; then
    case "$( (ss -lnt 2>/dev/null || netstat -lnt 2>/dev/null) | awk '$4 ~ "[:.]11211$"{print $4;exit}' )" in
      127.0.0.1:11211|::1:11211) _doc_ok "Memcached 仅监听回环" ;;
      *) _doc_warn "Memcached 监听在非回环地址（无认证，暴露即被当放大器）"
         _doc_hint "unit 里加 -l 127.0.0.1 后 systemctl restart memcached" ;;
    esac
  fi
}

# ---------------------------------------------------------------------------
#  8b. 站点里残留的 phpinfo / 临时探针
#     建站已不再生成 phpinfo 首页，但历史上生成过的、以及手工放的老探针
#     还可能挂在站点里 —— 那是个对外公开的信息页，必须扫出来。
# ---------------------------------------------------------------------------
_doc_probe() {
  _doc_sec "phpinfo / 临时探针残留"
  if [ ! -d "${WWWROOT}" ]; then
    _doc_skip "站点根目录不存在 (${WWWROOT})，跳过探针检查"; return 0
  fi
  local hit=0 n f found=""
  n=$(find "${WWWROOT}" -maxdepth 3 -type f -name '__lnamp_probe_*.php' 2>/dev/null | wc -l)
  if [ "${n:-0}" -gt 0 ]; then
    hit=1
    _doc_fail "站点里有 ${n} 个未清理的临时探针（phpinfo：泄露 PHP 版本/扩展/路径）"
    _doc_hint "$0 vhost probe --rm"
  fi
  # 常见的 phpinfo 文件名（adminer / phpmyadmin 自身代码里也含 phpinfo 字样，跳过）
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    case "$f" in */adminer/*|*/phpmyadmin/*|*/pma/*) continue ;; esac
    grep -q 'phpinfo' "$f" 2>/dev/null || continue
    found="${found} ${f}"
  done < <(find "${WWWROOT}" -maxdepth 3 -type f \
             \( -name 'index.php' -o -name 'phpinfo*.php' -o -name 'info.php' \
                -o -name 'i.php' -o -name 'p.php' -o -name 'test.php' -o -name 'tz.php' \) 2>/dev/null)
  if [ -n "$found" ]; then
    hit=1
    _doc_fail "站点里有 phpinfo 页面（对外暴露 PHP 版本/扩展/绝对路径）"
    for f in $found; do log "    - ${f}"; done
    _doc_hint "验证完立即删除: rm -f <上面这些文件>；以后改用 $0 vhost probe <域名>（用完 --rm）"
  fi
  [ "$hit" = 0 ] && _doc_ok "站点目录无 phpinfo / 临时探针残留"
  return 0
}

# ---------------------------------------------------------------------------
#  9. Web 配置健康：nginx -t + vhost 合法性
# ---------------------------------------------------------------------------
_doc_web() {
  _doc_sec "Web 配置 (web config)"
  local nb="${PREFIX_NGINX}/sbin/nginx"
  if [ -x "$nb" ]; then
    local out
    if out=$("$nb" -t 2>&1); then
      _doc_ok "nginx -t 通过"
    else
      _doc_fail "nginx -t 失败（此后所有 reload / 重启都会失败）"
      _doc_hint "$nb -t   # 输出: $(printf '%s' "$out" | tail -1 | cut -c1-90)"
    fi
    # vhost 目录里是否有不含 server_name 的残留文件
    local d f n=0
    for d in "${PREFIX_NGINX}/conf/vhost"; do
      [ -d "$d" ] || continue
      for f in "$d"/*.conf; do
        [ -f "$f" ] || continue
        case "$f" in *.bak.*) continue ;; esac
        grep -cE '^[[:space:]]*server_name[[:space:]]' "$f" >/dev/null 2>&1 || n=$((n + 1))
      done
    done
    [ "$n" -gt 0 ] && { _doc_warn "vhost 目录里有 ${n} 个配置没有 server_name（可能是残留）"; _doc_hint "ls ${PREFIX_NGINX}/conf/vhost/ 逐个确认后删除"; }
  fi

  local ac="${PREFIX_APACHE}/bin/apachectl"
  if [ -x "$ac" ]; then
    "$ac" -t >/dev/null 2>&1 && _doc_ok "apache 配置测试通过" || { _doc_fail "apache -t 失败"; _doc_hint "$ac -t"; }
  fi
  [ ! -x "$nb" ] && [ ! -x "$ac" ] && _doc_skip "未安装 nginx / apache，跳过"
}

# ---------------------------------------------------------------------------
#  10. fail2ban jail
# ---------------------------------------------------------------------------
_doc_fail2ban() {
  _doc_sec "fail2ban"
  command -v fail2ban-client >/dev/null 2>&1 || { _doc_skip "未安装 fail2ban（未启用）"; return 0; }
  local st
  st=$(fail2ban-client status 2>/dev/null | sed -n 's/.*Jail list:[[:space:]]*//p')
  case "$st" in
    "") _doc_warn "fail2ban-client 取不到 jail 列表（服务未运行？）"
        _doc_hint "systemctl status fail2ban; fail2ban-client status" ;;
    *)  _doc_ok "启用 jail: $(printf '%s' "$st" | tr -d ' ')" ;;
  esac
}

# ---------------------------------------------------------------------------
#  11. 时区 / 站点目录可写（应用跑 www 时最容易踩）
# ---------------------------------------------------------------------------
_doc_runtime() {
  _doc_sec "运行环境 (runtime)"
  local tz; tz=$(date '+%Z %z')
  _doc_ok "时区 ${tz}（PHP: $("${PREFIX_PHP}/bin/php" -r 'echo date_default_timezone_get();' 2>/dev/null || echo -)）"

  # 站点目录必须 www 可写，否则 runtime/cache 落不了盘
  if id www >/dev/null 2>&1 && [ -d "${WWWROOT}" ] && _doc_is_root; then
    if su -s /bin/sh www -c "test -w '${WWWROOT}'" 2>/dev/null; then
      _doc_ok "www 对 ${WWWROOT} 可写"
    else
      _doc_warn "www 对 ${WWWROOT} 不可写（应用缓存/上传会失败）"
      _doc_hint "chown -R www:www ${WWWROOT}"
    fi
  fi

  # 上传目录禁执行 PHP 的规则是否真的写进了现有 vhost（模板修复前建的站没有）
  local d f n=0 m=0
  # 只看 vhost 目录：conf/lnamp 下的 security.conf / static.conf 是通用片段，
  # 本来就不该有站点级的上传规则，算进来会得出"4/4 全部缺失"的错误结论
  for d in "${PREFIX_NGINX}/conf/vhost"; do
    [ -d "$d" ] || continue
    for f in "$d"/*.conf; do
      [ -f "$f" ] || continue
      n=$((n + 1))
      # 注意用 ERE 的 |：之前的 \\| 在 ERE 里是字面竖线，导致所有站点都被误判为"缺规则"
      grep -cE 'uploads?|data|runtime' "$f" >/dev/null 2>&1 || m=$((m + 1))
    done
  done
  if [ "$n" -gt 0 ] && [ "$m" -gt 0 ]; then
    _doc_warn "${m}/${n} 个 Web 配置缺少「上传目录禁执行 PHP」规则（旧模板创建的站点）"
    _doc_hint "重新生成该站点: $0 vhost <域名> <端口> <根目录>   # 会备份旧配置"
  elif [ "$n" -gt 0 ]; then
    _doc_ok "所有 Web 配置都含上传目录禁执行规则"
  fi
}

# ---------------------------------------------------------------------------
#  PHP 站点隔离 (open_basedir)
# ---------------------------------------------------------------------------
#  没设 open_basedir 时 PHP 进程能 open() 整个文件系统：/etc/shadow、~/.ssh、
#  同机其他站点的 config.php 全可读。一个站点被传 webshell = 全部站点泄露。
#  disable_functions 完全挡不住这种"纯 PHP"的读取（不需要任何系统命令）。
_doc_php_iso() {
  _doc_sec "站点隔离 (open_basedir)"
  local www="${PREFIX_PHP}/etc/php-fpm.d/www.conf" bd
  if [ -f "$www" ]; then
    bd=$(awk -F'=[[:space:]]*' '/php_admin_value\[open_basedir\]/{print $2; exit}' "$www" 2>/dev/null)
    if [ -n "$bd" ]; then
      _doc_ok "主池已设置 open_basedir: ${bd}"
    else
      _doc_warn "主池未设置 open_basedir —— PHP 可读 /etc/shadow 与所有站点源码"
      _doc_hint "在 ${www} 加: php_admin_value[open_basedir] = ${WWWROOT}:/tmp:${PREFIX_PHP}/var/log"
      _doc_hint "或重跑安装（新版会自动写入），记得 systemctl reload php-fpm"
    fi
  else
    _doc_skip "未找到 ${www}（PHP-FPM 未安装或非源码安装）"
  fi

  # 逐站点：仍在用全局 socket 的站点等于没有隔离
  if ! declare -F _vh_scan_all >/dev/null 2>&1; then
    _doc_skip "vhost 模块未加载，跳过逐站点检查"
    return 0
  fi
  local n=0 m=0 dom typ ports root state ws path
  _vh_cache_clear 2>/dev/null || true
  while IFS='|' read -r dom typ ports root state ws path; do
    [ -n "$dom" ] || continue
    [ "$state" = "enabled" ] || continue
    grep -q 'unix:' "$path" 2>/dev/null || continue
    n=$((n + 1))
    grep -qF "unix:${PHP_FPM_SOCK}" "$path" 2>/dev/null && m=$((m + 1))
  done <<< "$(_vh_scan_all 2>/dev/null)"

  if [ "$n" = 0 ]; then
    _doc_skip "没有使用 php-fpm 的站点"
  elif [ "$m" = 0 ]; then
    _doc_ok "全部 ${n} 个 php-fpm 站点都已使用独立池（open_basedir 按站点隔离）"
  else
    _doc_warn "${m}/${n} 个站点仍共用全局池 —— 彼此能读对方的 config.php"
    _doc_hint "$0 vhost rebind --all      # 建独立池并切换（逐个 nginx -t，失败自动回滚）"
  fi
}

# ---------------------------------------------------------------------------
#  入口
# ---------------------------------------------------------------------------
doctor_main() {
  local a
  for a in "$@"; do
    case "$a" in
      --quiet|-q) _D_QUIET=1 ;;
      -h|--help)
        echo "用法: $0 doctor [--quiet]"
        echo "  只读诊断；每条问题都会给出可直接执行的修复命令"
        echo "  --quiet  只输出问题项（给脚本/巡检用）"
        return 0 ;;
      *) die "doctor: 未知参数 $a" ;;
    esac
  done

  echo
  printf '%s\n' "$(_c '1;37' "lnamp doctor  $(date '+%Y-%m-%d %H:%M:%S')")"
  _doc_is_root || log_warn "非 root 运行：端口进程名、部分权限检查会看不到，建议 sudo"

  _doc_clock
  _doc_disk
  _doc_units
  _doc_ports
  _doc_sshd
  _doc_php_ext
  _doc_logrotate
  _doc_perm
  _doc_bind
  _doc_probe
  _doc_web
  _doc_php_iso
  _doc_fail2ban
  _doc_runtime

  echo
  printf '汇总: OK=%d  WARN=%d  FAIL=%d  SKIP=%d\n' "$_D_OK" "$_D_WARN" "$_D_FAIL" "$_D_SKIP"
  if [ "$_D_FAIL" -gt 0 ]; then
    log_err "有 ${_D_FAIL} 项失败，建议按上方修复命令逐条处理"
    return 1
  elif [ "$_D_WARN" -gt 0 ]; then
    log_warn "有 ${_D_WARN} 项告警（不一定影响运行，但值得看）"
    return 1
  fi
  log_ok "未发现问题"
  return 0
}
