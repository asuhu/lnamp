#!/bin/bash
# ============================================================================
#  install.sh  ——  LNAMP 安装器 (重构版 / refactored)
#  Nginx · Apache · PHP · MySQL  —— 支持选择不同版本与不同安装形式
#
#  两种用法 (two ways to run):
#
#  1) 交互菜单 (interactive):
#         ./install.sh
#
#  2) 命令行 (non-interactive，适合自动化/CI):
#         ./install.sh --nginx 1.26.2:source \
#                      --php   7.4.33:fpm    \
#                      --mysql 5.7.44:binary
#     # 形式可省略，使用该组件默认形式：--nginx 1.30.6
#     # 列出全部可选项：       ./install.sh --list
# ============================================================================
set -o pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export SCRIPT_DIR

# shellcheck source=/dev/null
source "${SCRIPT_DIR}/versions.conf"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/lib/common.sh"
# shellcheck source=/dev/null
for m in deps sysctl nginx apache php mysql mariadb redis memcached fail2ban swoole devtools mirror vhost phpmyadmin adminer java uninstall verify precheck status doctor scan backup bench; do source "${SCRIPT_DIR}/modules/${m}.sh"; done

# 选择结果 (空 = 不安装该组件)
SEL_NGINX="" ; SEL_APACHE="" ; SEL_PHP="" ; SEL_MYSQL="" ; SEL_MARIADB="" ; SEL_REDIS="" ; SEL_PHPREDIS=""
SEL_MEMCACHED="" ; SEL_PHPMEMCACHED="" ; SEL_SWOOLE="" ; SEL_COMPOSER="" ; SEL_NODE=""
APACHE_MPM=""   # prefork|worker|event（安装 Apache 时选择，应用到 httpd.conf 与 vhost）
# yes|no（是否为 PHP 安装 ImageMagick/imagick 扩展）。
# 保留外部环境变量：upgrade 子命令不接受 --php-imagick 参数，只能靠 env 透传；
# 原来无条件置空会把外部 export 的 PHP_IMAGICK=yes 冲掉（真机教训：190 升级
# 8.4.27 后 imagick 没有重建，ini 仍指旧模块 API 路径）。
PHP_IMAGICK="${PHP_IMAGICK:-}"
IMAGEMAGICK_SOURCE=""  # yes|no（imagick 链接的 ImageMagick 是否从源码编译最新版）
INSTALL_PMA=""  # yes|no（是否安装 phpMyAdmin 到默认站点）
INSTALL_ADMINER=""  # yes|no（是否安装 Adminer 轻量级数据库工具）
SEL_JAVA=""  # 11|17（OpenJDK 版本，空=不装）
INSTALL_TOMCAT=""  # yes|no（是否安装 Tomcat 10）
INSTALL_FAIL2BAN=""  # yes|no（是否安装 fail2ban）
ASSUME_YES=0
MIRROR_MODE="${MIRROR_MODE:-cn}"   # cn|official|none（Composer/npm 包索引镜像）
usage() {
  cat <<EOF
LNAMP 安装器 (重构版)
支持系统 (Supported): CentOS/RHEL 7、Rocky/Alma/RHEL 8 9、Ubuntu 22 24

用法 (Usage):
  $0 [选项]

选项 (Options):
  --nginx  VER[:MODE]   安装 Nginx/Tengine (mode: source|pkg; 含 tengine-3.1.0)
  --apache VER[:MODE]   安装 Apache  (mode: source|pkg)
  --apache-mpm MPM      选择 Apache MPM 工作模式 (prefork|worker|event; 默认 event/2.4)
  --php    VER[:MODE]   安装 PHP     (mode: fpm|apache)
  --mysql  VER[:MODE]   安装 MySQL   (mode: source|binary|pkg)
  --mariadb VER[:MODE]  安装 MariaDB (mode: binary|pkg; 与 --mysql 互斥)
  --redis  VER[:MODE]   安装 Redis   (mode: source|pkg)
  --phpredis [VER]      安装 phpredis 扩展 (需先/同时安装 PHP; 默认 6.3.0)
  --memcached [VER]     安装 Memcached 服务端 (mode: source|pkg; 默认 1.6.45)
  --php-memcached [VER] 安装 PHP memcached 扩展 (默认 3.4.0；PHP5.6 自动降到 2.2.0)
  --no-php-memcached    明确不装 PHP memcached 扩展
  --swoole [VER]        安装 Swoole 扩展 (Hyperf/Octane 用; 需 PHP >= 8.0)
  --composer [VER]      安装 Composer (默认 2.10.3; PHP<7.2.5 用 2.2.30)
  --nodejs [VER]        安装 Node.js LTS (默认 24.22.1 Krypton)
                        CentOS 7 (glibc 2.17) 请用 16.20.2：18+ 官方二进制需 glibc 2.28
  --fail2ban            安装 fail2ban (sshd/nginx-http-auth/nginx-limit-req 三个 jail)
  --redis-modules       Redis 8.x 连内置模块一起编译（需 cmake + Rust；默认只编核心）
  --lock-wait SEC       安装/升级/卸载的并发锁最多等待 SEC 秒（默认 0=立即失败）
  --no-fail2ban         明确不安装 fail2ban
  --mirror MODE         Composer/npm 包索引: cn(默认,阿里云+npmmirror)|official|none
  --no-mirror           不修改 Composer/npm 的包索引（等价 --mirror none）
  --skip-precheck       跳过安装前预检（默认会先跑一遍 precheck）
  --php-imagick         为 PHP 安装 ImageMagick(imagick) 扩展 (非交互时默认不装)
  --no-php-imagick      明确不安装 imagick (非交互场景)
  --imagemagick-source  imagick 链接源码编译的最新 ImageMagick (含 --php-imagick)
  --phpmyadmin          安装 phpMyAdmin 到默认站点 ${WWWROOT:-/home/wwwroot}/web/phpMyAdmin
  --no-phpmyadmin       明确不安装 phpMyAdmin (非交互场景)
  --adminer             安装 Adminer (轻量级单文件 DB 工具) 到 ${WWWROOT:-/home/wwwroot}/web/adminer
  --no-adminer          明确不安装 Adminer (非交互场景)
  --java <11|17>        安装 OpenJDK(Temurin) 并设置 JAVA_HOME/PATH
  --tomcat              安装 Tomcat 10（依赖 Java；未选 --java 时自动用 OpenJDK 17）
  --list                列出所有可选版本与形式后退出
  -y, --yes             跳过交互确认
  --dry-run             干跑：只打印将下载的包(含全部候选URL)、将安装的系统包、
                       将写的配置、将启动的服务，不做任何实际改动
  -h, --help            显示本帮助

子命令 (Subcommands):
  $0 precheck [组件参数]                             安装前预检（只读）：磁盘/内存/端口/已装冲突/
                                        glibc/时间同步/DNS//tmp 挂载。返回 2 表示有阻塞项
  $0 sysctl                                          单独应用内核参数与句柄上限（幂等，已调优则跳过）
  $0 mirror [cn|official|none]                       查看/切换 Composer 与 npm 的包索引镜像
  $0 vhost <域名> [端口] [根目录] [nginx|apache]     创建站点(自定义端口，HTTP)
                                        不带参数则交互输入；同时装了 nginx 与 apache 时可用第4参数指定
  $0 vhost list                                      列出站点：区分 HTTP(80)/HTTPS(443)/双栈、
                                        自定义端口、根目录是否存在、启用/禁用状态
  $0 vhost ssl <域名> [--self-signed | --cert F --key F]   一键启用 HTTPS（80+443）：
                                        [--no-redirect] [--hsts [秒]] [--force]
                                        用已有证书/自动探测 certbot·acme.sh/自签，不代为申请证书
  $0 vhost disable <域名> / enable <域名>             停用/启用站点（改名为 .conf.disabled，不改内容）
  $0 vhost rebind <域名>|--all [--shared]            给站点建独立 php-fpm 池（按站点 open_basedir 隔离）
  $0 vhost del <域名> [--purge] [--yes]              删除站点（配置先归档；--purge 连目录一起删）
  $0 vhost probe <域名>                              临时 phpinfo 探针（部署验证用）
  $0 vhost probe --list|--rm [域名]                  列出 / 删除探针（验证后务必 --rm）
  $0 verify                                         装完后自检：服务/端口/PHP解析/扩展/版本/数据库连通
  $0 status [--brief]                               运维总览（只读）：主机负载/内存/磁盘/inode、组件版本与服务、
                                        站点清单、证书剩余天数、近期错误摘要、可升级组件
  $0 doctor [--fix-hint]                            只读诊断：时钟/权限/ABI/配置漂移/logrotate/凭据，
                                        每条问题都给出可直接执行的修复命令
  $0 bench [static|php|both] [-n N] [-c C] [--apply]  本机压测静态与 PHP，按核数/内存反推
                                        worker_processes 与 pm.max_children（默认只读）
  $0 scan [--path 目录] [--since 天数] [--fast]      只读巡检 webshell：特征匹配、上传目录可执行文件、
                                        图片马、.user.ini 注入、权限属主、近期改动
  $0 backup [--only db,conf,site] [--keep N]        整套备份（MySQL全量+Redis RDB+配置+站点代码）
  $0 restore <备份包> [--only ...]                  从备份包还原（还原前自动再备份一份当前状态）
  $0 upgrade <组件> [版本[:形式]] [--force]          平滑升级（自动备份配置；数据库需 --force 且保留数据）
  $0 uninstall --component <组件> [--purge]          卸载（反注册 systemd/logrotate/PATH；DB 默认保留数据）
  $0 uninstall --list                                列出本机已安装的组件

示例 (Examples):
  $0 --nginx 1.26.2:source --php 8.3.36:fpm --phpredis 6.3.0 --mysql 5.7.44:binary
  $0 --apache 2.4.69:source --apache-mpm event --php 8.3.36:fpm
  $0 --apache 2.4.69:source --apache-mpm prefork --php 8.2.35:apache
  $0 --nginx 1.30.6 --php 8.3.36:fpm --mysql 8.0.46:binary --dry-run   # 只看计划不改动
  $0 --nginx 1.30.6 --php 8.3.36:fpm --memcached --php-memcached --swoole --composer --nodejs --fail2ban
  $0 vhost example.com 8080 /home/wwwroot/example.com
  $0 vhost list                                                         # 看所有站点（含 HTTPS 标记）
  $0 vhost ssl example.com --self-signed                                # 内网/测试：自签一键 HTTPS
  $0 vhost ssl example.com --cert /etc/letsencrypt/live/example.com/fullchain.pem \
                           --key  /etc/letsencrypt/live/example.com/privkey.pem   # 用已有证书
  $0 vhost disable example.com                                          # 临时下线
  $0 vhost del old.example.com --purge                                  # 连站点目录一起删
  $0 vhost probe example.com                                            # 临时探针验证 PHP（用完 --rm）
  $0 vhost probe --rm                                                   # 验证完删除全部探针
  $0 precheck --nginx 1.30.6 --php 8.3.36:fpm --mysql 8.4.13:binary   # 装前预检
  $0 sysctl                                                             # 只调内核参数/句柄上限
  $0 mirror cn                                                          # 切到国内包镜像
  $0 verify                                                             # 装完后自检
  $0 upgrade nginx 1.30.6                                               # 升级 nginx
  $0 uninstall --component redis                                        # 卸载 redis（保留数据）
  $0 status                                                             # 一屏看现状（只读）
  $0 doctor                                                             # 自动诊断并给出修复命令
  $0 scan                                                               # 巡检 webshell/可疑文件（只读）
  $0 scan --path /home/wwwroot/a.com --since 3                          # 只扫一个站点、只看近 3 天
  $0 vhost prune                                                        # 列出站点配置残留（只读）
  $0 vhost prune --yes --purge-dirs                                     # 清理残留（配置归档，不硬删）
  $0 bench                                                              # 本机压测 + 并发参数推荐（只读）
  $0 bench --apply                                                      # 把推荐的 pm.max_children 等写回
  $0 backup --with-site --keep 7                                        # 备份：库+配置+站点代码
  $0 restore /root/lnamp-backups/lnamp-backup-20261025_170000.tar.gz     # 从备份还原
  $0          # 不带参数 -> 进入交互菜单
EOF
}

print_list() {
  hr; echo "可安装组件与版本 (Available components / versions / modes):"; hr
  echo "Nginx/Tengine:" ; list_versions NGINX
  echo "Apache:"; list_versions APACHE
  echo "PHP:"   ; list_versions PHP
  echo "MySQL:" ; list_versions MYSQL
  echo "MariaDB:"; list_versions MARIADB
  echo "Redis:" ; list_versions REDIS
  echo "phpredis:"; list_versions PHPREDIS
  echo "Memcached:"; list_versions MEMCACHED
  echo "PHP memcached 扩展:"; list_versions PHPMEMCACHED
  echo "Swoole:"; list_versions SWOOLE
  echo "Composer:"; list_versions COMPOSER
  echo "Node.js:"; list_versions NODE
  echo "fail2ban:"; list_versions FAIL2BAN
  hr
  echo "默认 (defaults): nginx=${NGINX_DEFAULT}:${NGINX_DEFAULT_MODE}  apache=${APACHE_DEFAULT}:${APACHE_DEFAULT_MODE}  php=${PHP_DEFAULT}:${PHP_DEFAULT_MODE}  mysql=${MYSQL_DEFAULT}:${MYSQL_DEFAULT_MODE}  mariadb=${MARIADB_DEFAULT}:${MARIADB_DEFAULT_MODE}  redis=${REDIS_DEFAULT}:${REDIS_DEFAULT_MODE}"
  echo "                   memcached=${MEMCACHED_DEFAULT}:${MEMCACHED_DEFAULT_MODE}  php-memcached=${PHPMEMCACHED_DEFAULT}  swoole=${SWOOLE_DEFAULT}  composer=${COMPOSER_DEFAULT}  nodejs=${NODE_DEFAULT}  fail2ban=${FAIL2BAN_DEFAULT}"
  echo "注: MySQL 与 MariaDB 互斥；Nginx 列表中的 tengine-* 为 Tengine；phpredis 为独立组件(--phpredis)。"
  echo "    Swoole 需 PHP >= 8.0；Composer 2.x 需 PHP >= 7.2.5；Memcached 只监听 127.0.0.1。"
}

# ----- 参数解析 -------------------------------------------------------------
# 处理"版本可选"的参数（如 --memcached [VER]）：
#   若下一个参数看起来是版本(不以 - 开头)则吃掉它，否则只前移 1。
#   直接 shift 2 在参数末尾会因 shift 失败而陷入死循环。
_opt_ver() {
  _OPT_VER=""; _OPT_SHIFT=1
  if [ $# -ge 2 ] && [ -n "$2" ] && [ "${2#-}" = "$2" ]; then
    _OPT_VER="$2"; _OPT_SHIFT=2
  fi
}

parse_args() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --nginx)  _opt_ver "$@"; parse_pick NGINX "$_OPT_VER"; SEL_NGINX="${PICK_VER}:${PICK_MODE}"; shift "$_OPT_SHIFT" ;;
      --apache)  _opt_ver "$@"; parse_pick APACHE "$_OPT_VER"; SEL_APACHE="${PICK_VER}:${PICK_MODE}"; shift "$_OPT_SHIFT" ;;
      --apache-mpm)
        case "$2" in prefork|worker|event) APACHE_MPM="$2" ;; *) die "--apache-mpm 取值须为 prefork|worker|event" ;; esac
        shift 2 ;;
      --php)  _opt_ver "$@"; parse_pick PHP "$_OPT_VER"; SEL_PHP="${PICK_VER}:${PICK_MODE}"; shift "$_OPT_SHIFT" ;;
      --mysql)  _opt_ver "$@"; parse_pick MYSQL "$_OPT_VER"; SEL_MYSQL="${PICK_VER}:${PICK_MODE}"; shift "$_OPT_SHIFT" ;;
      --mariadb)  _opt_ver "$@"; parse_pick MARIADB "$_OPT_VER"; SEL_MARIADB="${PICK_VER}:${PICK_MODE}"; shift "$_OPT_SHIFT" ;;
      --redis)  _opt_ver "$@"; parse_pick REDIS "$_OPT_VER"; SEL_REDIS="${PICK_VER}:${PICK_MODE}"; shift "$_OPT_SHIFT" ;;
      --phpredis)
        _opt_ver "$@"; parse_pick PHPREDIS "$_OPT_VER"; SEL_PHPREDIS="${PICK_VER}:${PICK_MODE}"; shift "$_OPT_SHIFT" ;;
      --memcached)
        _opt_ver "$@"; parse_pick MEMCACHED "$_OPT_VER"; SEL_MEMCACHED="${PICK_VER}:${PICK_MODE}"; shift "$_OPT_SHIFT" ;;
      --php-memcached)
        _opt_ver "$@"; parse_pick PHPMEMCACHED "$_OPT_VER"; SEL_PHPMEMCACHED="${PICK_VER}:${PICK_MODE}"; shift "$_OPT_SHIFT" ;;
      --no-php-memcached) PHP_MEMCACHED_NO=1; SEL_PHPMEMCACHED=""; shift ;;
      --swoole)
        _opt_ver "$@"; parse_pick SWOOLE "$_OPT_VER"; SEL_SWOOLE="${PICK_VER}:${PICK_MODE}"; shift "$_OPT_SHIFT" ;;
      --composer)
        _opt_ver "$@"; parse_pick COMPOSER "$_OPT_VER"; SEL_COMPOSER="${PICK_VER}:${PICK_MODE}"; shift "$_OPT_SHIFT" ;;
      --nodejs)
        _opt_ver "$@"; parse_pick NODE "$_OPT_VER"; SEL_NODE="${PICK_VER}:${PICK_MODE}"; shift "$_OPT_SHIFT" ;;
      --fail2ban)    INSTALL_FAIL2BAN=yes; shift ;;
      --no-fail2ban) INSTALL_FAIL2BAN=no; shift ;;
      --mirror)
        case "${2:-}" in
          cn|official|none) MIRROR_MODE="$2" ;;
          *) die "--mirror 取值须为 cn|official|none" ;;
        esac
        shift 2 ;;
      --no-mirror)   MIRROR_MODE=none; shift ;;
      --skip-precheck) SKIP_PRECHECK=1; shift ;;
      --redis-modules) REDIS_MODULES=1; shift ;;
      --lock-wait)
        case "${2:-}" in ''|*[!0-9]*) die "--lock-wait 需要一个非负整数（秒）" ;; esac
        LNAMP_LOCK_WAIT="$2"; shift 2 ;;
      --php-imagick)   PHP_IMAGICK=yes; shift ;;
      --no-php-imagick) PHP_IMAGICK=no; shift ;;
      --imagemagick-source) PHP_IMAGICK=yes; IMAGEMAGICK_SOURCE=yes; shift ;;
      --phpmyadmin)    INSTALL_PMA=yes; shift ;;
      --no-phpmyadmin) INSTALL_PMA=no; shift ;;
      --adminer)       INSTALL_ADMINER=yes; shift ;;
      --no-adminer)    INSTALL_ADMINER=no; shift ;;
      --java)
        case "$2" in 11|17) SEL_JAVA="$2" ;; *) die "--java 取值须为 11 或 17" ;; esac
        shift 2 ;;
      --tomcat)        INSTALL_TOMCAT=yes; shift ;;
      --no-tomcat)     INSTALL_TOMCAT=no; shift ;;
      --list)   print_list; exit 0 ;;
      -y|--yes) ASSUME_YES=1; shift ;;
      --dry-run) DRY_RUN=1; shift ;;
      -h|--help) usage; exit 0 ;;
      *) die "未知参数 (unknown option): $1   (用 --help 查看)" ;;
    esac
  done
}

# ----- 交互菜单 (选择版本 + 形式) ------------------------------------------
# 通用菜单：列出某组件版本，让用户选版本，再选支持的形式。
menu_component() {
  local comp="$1" label="$2" defv_var="${1}_DEFAULT" defm_var="${1}_DEFAULT_MODE"
  local defv="${!defv_var}" defm="${!defm_var}"
  local arr="${comp}_VERSIONS[@]" lines=() line i

  for line in "${!arr}"; do lines+=("$line"); done

  echo; hr; echo -e "$(_c '1;36' "是否安装 ${label}? (Install ${label}?)")"
  read -rp "  [y/N]: " yn
  [[ "$yn" =~ ^[Yy]$ ]] || { echo "  跳过 ${label} (skipped)"; return 1; }

  echo "  请选择版本 (select version):"
  for i in "${!lines[@]}"; do
    local v="${lines[$i]%%|*}" modes; modes="$(echo "${lines[$i]}" | cut -d'|' -f2)"
    printf "    %d) %-10s [形式 modes: %s]%s\n" "$((i+1))" "$v" "$modes" \
      "$([ "$v" = "$defv" ] && echo '  <默认>')"
  done
  read -rp "  输入序号 (number, 回车=默认 ${defv}): " vn
  local ver
  if [ -z "$vn" ]; then
    ver="$defv"
  else
    # 输入 0 不能落到 arr[-1]（会静默选中最后一项），越界/非数字一律视为无效
    _menu_pick lines "$vn" "${#lines[@]}" ver || die "${label}: 无效序号 ${vn}（可选 1-${#lines[@]}）"
    ver="${ver%%|*}"
  fi
  [ -n "$ver" ] || die "${label}: 无效选择"

  local modes; modes="$(manifest_modes "$comp" "$ver")"
  local mode
  if [[ ",${modes}," == *","* ]] && [ "$(echo "$modes" | tr ',' '\n' | wc -l)" -gt 1 ]; then
    echo "  请选择安装形式 (select mode): ${modes}"
    local marr=(); IFS=',' read -ra marr <<< "$modes"
    for i in "${!marr[@]}"; do
      printf "    %d) %s%s\n" "$((i+1))" "${marr[$i]}" \
        "$([ "${marr[$i]}" = "$defm" ] && echo '  <默认>')"
    done
    read -rp "  输入序号 (number, 回车=默认): " mn
    if [ -z "$mn" ]; then
      [[ ",${modes}," == *",${defm},"* ]] && mode="$defm" || mode="${marr[0]}"
    else
      _menu_pick marr "$mn" "${#marr[@]}" mode || die "${label}: 无效形式序号 ${mn}（可选 1-${#marr[@]}）"
    fi
  else
    mode="$modes"
  fi

  validate_choice "$comp" "$ver" "$mode"
  printf -v "SEL_${comp}" '%s' "${ver}:${mode}"
  log_ok "${label} 选择: ${ver} (${mode})"
}

# 选择 Apache MPM 工作模式（prefork/worker/event）。
_menu_apache_mpm() {
  local ver="$1" def choice m
  m=$(manifest_lookup APACHE "$ver"); def=$(meta_get "${m#*|}" mpm); [ -n "$def" ] || def=event
  echo
  echo "请选择 Apache MPM 工作模式 (默认 ${def}):"
  echo "  1) prefork  —— 多进程，最稳，兼容 mod_php（线程不安全模块）"
  echo "  2) worker   —— 多进程+多线程，省内存"
  echo "  3) event    —— worker 增强，高并发推荐（Apache 2.4）"
  read -rp "输入序号或名称 [回车=${def}]: " choice
  case "$choice" in
    1|prefork) APACHE_MPM=prefork ;;
    2|worker)  APACHE_MPM=worker ;;
    3|event)   APACHE_MPM=event ;;
    "")        APACHE_MPM="$def" ;;
    *)         log_warn "无效输入，使用默认 ${def}"; APACHE_MPM="$def" ;;
  esac
  log_ok "Apache MPM 选择: ${APACHE_MPM}"
  if [ -n "$SEL_PHP" ] && [ "${SEL_PHP##*:}" = apache ] && [ "$APACHE_MPM" != prefork ]; then
    log_warn "注意：PHP 选了 apache(mod_php) 模式，但 MPM=${APACHE_MPM} 非 prefork；mod_php 仅在 prefork 下线程安全，建议改 prefork 或改用 PHP fpm 模式。"
  fi
}

# 数据库统一选择：把 MySQL 与 MariaDB 各版本列在同一张表里，二选一(或不装)。
menu_database() {
  echo; hr; echo -e "$(_c '1;36' '选择数据库 (Database)? MySQL 与 MariaDB 互斥，二选一')"
  local types=() vers=() i=1 line v modes
  echo "  可选版本 (select one):"
  for line in "${MYSQL_VERSIONS[@]}"; do
    v="${line%%|*}"; modes="$(echo "$line" | cut -d'|' -f2)"
    printf "    %2d) %-10s  %-8s [形式 modes: %s]%s\n" "$i" "$v" "MySQL" "$modes" \
      "$([ "$v" = "$MYSQL_DEFAULT" ] && echo '  <MySQL默认>')"
    types+=("MYSQL"); vers+=("$v"); i=$((i+1))
  done
  for line in "${MARIADB_VERSIONS[@]}"; do
    v="${line%%|*}"; modes="$(echo "$line" | cut -d'|' -f2)"
    printf "    %2d) %-10s  %-8s [形式 modes: %s]%s\n" "$i" "$v" "MariaDB" "$modes" \
      "$([ "$v" = "$MARIADB_DEFAULT" ] && echo '  <MariaDB默认>')"
    types+=("MARIADB"); vers+=("$v"); i=$((i+1))
  done
  echo "     0) 不安装数据库 (skip)"
  read -rp "  输入序号 (number, 回车=不安装): " n
  { [ -z "$n" ] || [ "$n" = 0 ]; } && { echo "  跳过数据库 (skipped)"; return 0; }
  case "$n" in ''|*[!0-9]*) die "数据库: 无效序号 ${n}" ;; esac
  local idx=$((10#$n - 1))
  { [ "$idx" -ge 0 ] && [ "$idx" -lt "${#vers[@]}" ]; } || die "数据库: 无效序号 ${n}"
  local comp="${types[$idx]}" ver="${vers[$idx]}" label
  [ "$comp" = MYSQL ] && label=MySQL || label=MariaDB

  # 选择安装形式
  modes="$(manifest_modes "$comp" "$ver")"
  local mode defm_var defm
  defm_var="${comp}_DEFAULT_MODE"; defm="${!defm_var}"
  if [ "$(echo "$modes" | tr ',' '\n' | wc -l)" -gt 1 ]; then
    echo "  请选择安装形式 (select mode): ${modes}"
    local marr=() j; IFS=',' read -ra marr <<< "$modes"
    for j in "${!marr[@]}"; do
      printf "    %d) %s%s\n" "$((j+1))" "${marr[$j]}" \
        "$([ "${marr[$j]}" = "$defm" ] && echo '  <默认>')"
    done
    read -rp "  输入序号 (number, 回车=默认 ${defm}): " mn
    if [ -z "$mn" ]; then
      [[ ",${modes}," == *",${defm},"* ]] && mode="$defm" || mode="${marr[0]}"
    else
      _menu_pick marr "$mn" "${#marr[@]}" mode || die "数据库 ${ver}: 无效形式序号 ${mn}（可选 1-${#marr[@]}）"
    fi
  else
    mode="$modes"
  fi

  validate_choice "$comp" "$ver" "$mode"
  printf -v "SEL_${comp}" '%s' "${ver}:${mode}"
  log_ok "${label} 选择: ${ver} (${mode})"
}

interactive_menu() {
  clear 2>/dev/null
  hr
  echo -e "$(_c '1;32' '  LNAMP 安装器 (重构版)  Nginx / Apache / PHP / MySQL')"
  hr
  detect_mem
  echo "  CPU 线程 (threads): ${THREAD}    内存 (mem): ${MEM_MB}MB (${MEM_LEVEL})"
  menu_component NGINX  "Nginx (Web)"
  menu_component APACHE "Apache (Web)"
  # 选了 Apache(源码安装) 时，手动选择 MPM 工作模式
  if [ -n "$SEL_APACHE" ] && [ "${SEL_APACHE##*:}" = source ]; then
    _menu_apache_mpm "${SEL_APACHE%%:*}"
  fi
  menu_component PHP    "PHP"
  # 选了 PHP 时，提示是否安装 ImageMagick(imagick) 扩展
  if [ -n "$SEL_PHP" ]; then
    local _ans
    read -rp "是否为 PHP 安装 ImageMagick(imagick) 扩展? [y/N]: " _ans
    case "$_ans" in y|Y|yes|YES) PHP_IMAGICK=yes ;; *) PHP_IMAGICK=no ;; esac
    if [ "$PHP_IMAGICK" = yes ]; then
      local _src
      read -rp "ImageMagick 来源: 1) 发行版包(默认)  2) 源码编译最新 ${IMAGEMAGICK_VERSION}  [1/2]: " _src
      case "$_src" in 2|source|src) IMAGEMAGICK_SOURCE=yes ;; *) IMAGEMAGICK_SOURCE=no ;; esac
    fi
    log_ok "ImageMagick(imagick): $([ "$PHP_IMAGICK" = yes ] && echo "安装 (来源: $([ "$IMAGEMAGICK_SOURCE" = yes ] && echo 源码${IMAGEMAGICK_VERSION} || echo 发行版包))" || echo 不安装)"
    # 是否安装 phpMyAdmin（装到默认站点 ${WWWROOT}/web/phpMyAdmin）
    local _pma
    read -rp "是否安装 phpMyAdmin? (装到 ${WWWROOT}/web/phpMyAdmin) [y/N]: " _pma
    case "$_pma" in y|Y|yes|YES) INSTALL_PMA=yes ;; *) INSTALL_PMA=no ;; esac
    log_ok "phpMyAdmin: $([ "$INSTALL_PMA" = yes ] && echo 安装 || echo 不安装)"
    # 是否安装 Adminer（轻量级单文件 DB 工具）
    local _adm
    read -rp "是否安装 Adminer? (轻量级单文件 DB 工具 -> ${WWWROOT}/web/adminer) [y/N]: " _adm
    case "$_adm" in y|Y|yes|YES) INSTALL_ADMINER=yes ;; *) INSTALL_ADMINER=no ;; esac
    log_ok "Adminer: $([ "$INSTALL_ADMINER" = yes ] && echo 安装 || echo 不安装)"
  fi
  menu_database
  menu_component REDIS  "Redis (缓存)"
  menu_component MEMCACHED "Memcached (另一种内存缓存)"
  # 选了 Memcached 且装了 PHP 时，提示是否装 PHP 扩展（扩展可选，默认不装）
  if [ -n "$SEL_MEMCACHED" ] && [ -n "$SEL_PHP" ]; then
    if ask_yes_no "是否同时安装 PHP memcached 扩展 (${PHPMEMCACHED_DEFAULT})?" n; then
      SEL_PHPMEMCACHED="${PHPMEMCACHED_DEFAULT}:source"
      log_ok "PHP memcached 扩展: 安装"
    else
      log_ok "PHP memcached 扩展: 不安装"
    fi
  fi
  # phpredis：需要 PHP（本次选了 PHP，或系统已装 PHP）才询问
  if [ -n "$SEL_PHP" ] || [ -x "${PREFIX_PHP}/bin/phpize" ]; then
    menu_component PHPREDIS "phpredis (PHP 的 Redis 扩展)"
    # Swoole / Composer / Node.js：都是 PHP 生态的附加件，按需询问
    if ask_yes_no "是否安装 Swoole 扩展 (Hyperf/Octane 运行时，需 PHP >= 8.0)?" n; then
      SEL_SWOOLE="${SWOOLE_DEFAULT}:source"
      log_ok "Swoole: 安装 ${SWOOLE_DEFAULT}"
    fi
    if ask_yes_no "是否安装 Composer (PHP 依赖管理器)?" y; then
      SEL_COMPOSER="${COMPOSER_DEFAULT}:phar"
      log_ok "Composer: 安装 ${COMPOSER_DEFAULT}"
    fi
    if ask_yes_no "是否安装 Node.js LTS (前端构建/PM2 用)?" n; then
      # 与 CLI --nodejs 共用同一个回落函数（devtools.sh），避免两处逻辑不一致。
      # 兜底版本是 16.20.x —— 最后一个支持 glibc 2.17 的系列（见 _node_fallback_ver）
      local nd
      nd=$(_node_fallback_ver "${NODE_DEFAULT}")
      SEL_NODE="${nd}:binary"
      log_ok "Node.js: 安装 ${nd}"
    fi
  fi
  # fail2ban：安全项，默认建议装
  if ask_yes_no "是否安装 fail2ban (SSH/HTTP 防暴力破解)?" y; then
    INSTALL_FAIL2BAN=yes
    log_ok "fail2ban: 安装"
  else
    INSTALL_FAIL2BAN=no
  fi
  # Java(OpenJDK) 与 Tomcat
  local _jv _tc
  read -rp "是否安装 OpenJDK? 输入版本 11 / 17，回车=不装: " _jv
  case "$_jv" in 11) SEL_JAVA=11 ;; 17) SEL_JAVA=17 ;; *) SEL_JAVA="" ;; esac
  [ -n "$SEL_JAVA" ] && log_ok "OpenJDK: 安装 ${SEL_JAVA}" || log_ok "OpenJDK: 不安装"
  if [ -n "$SEL_JAVA" ]; then
    read -rp "是否安装 Tomcat ${TOMCAT_VERSION}? [y/N]: " _tc
    case "$_tc" in y|Y|yes|YES) INSTALL_TOMCAT=yes ;; *) INSTALL_TOMCAT=no ;; esac
    log_ok "Tomcat: $([ "$INSTALL_TOMCAT" = yes ] && echo 安装 || echo 不安装)"
  fi
}

# ----- 系统准备 (跨发行版) --------------------------------------------------
system_prep() {
  if [ "${DRY_RUN:-0}" = 1 ]; then
    log "  [dry-run] 系统初始化 (system prep) 将执行：刷新包索引、安装基础编译依赖"
    log "  [dry-run]   (curl wget gcc gcc-c++ make git lsof net-tools)"
    log "  [dry-run]   设置时区 Asia/Shanghai"
    [ "$OS_FAMILY" = rhel ] && log "  [dry-run]   RHEL 系: setenforce 0 并将 /etc/selinux/config 置为 disabled"
    log "  [dry-run]   sshd UseDNS no; 视情况调用 conf/swap.sh 配置 swap"
    log "  [dry-run]   内核参数/句柄上限调优（幂等：已优化过则整份跳过）"
    install_sysctl "lnamp-v1"
    return 0
  fi
  log "系统初始化 (system prep)..."
  pkg_update
  dep curl wget gcc gcc-c++ make git lsof net-tools
  # 时区
  timedatectl set-timezone Asia/Shanghai 2>/dev/null || \
    { rm -f /etc/localtime; ln -s /usr/share/zoneinfo/Asia/Shanghai /etc/localtime; }
  # SELinux 仅 RHEL 系
  if [ "$OS_FAMILY" = rhel ]; then
    setenforce 0 2>/dev/null
    sed -i 's/^SELINUX=.*/SELINUX=disabled/' /etc/selinux/config 2>/dev/null
  fi
  sed -i 's@^#UseDNS yes@UseDNS no@' /etc/ssh/sshd_config 2>/dev/null
  # swap (若仓库带 swap.sh 则调用)
  [ -f "${SCRIPT_DIR}/conf/swap.sh" ] && source "${SCRIPT_DIR}/conf/swap.sh"
  # 内核参数 / 句柄上限：放在 swap 之后，避免 swap.sh 的 swappiness 被覆盖
  # 幂等：逐项取优；三份配置内容都没变时整份跳过（不重写、不重载、不备份）
  install_sysctl "lnamp-v1"
}

# 是否至少选了一个组件。
# SEL_* 是"空=不装"；INSTALL_* 是 yes/no 开关，只看是否等于 yes。
_has_any_selection() {
  local v
  for v in "${SEL_NGINX}" "${SEL_APACHE}" "${SEL_PHP}" "${SEL_MYSQL}" "${SEL_MARIADB}" \
           "${SEL_REDIS}" "${SEL_PHPREDIS}" "${SEL_MEMCACHED}" "${SEL_PHPMEMCACHED}" \
           "${SEL_SWOOLE}" "${SEL_COMPOSER}" "${SEL_NODE}" "${SEL_JAVA}"; do
    [ -n "$v" ] && return 0
  done
  for v in "${INSTALL_PMA}" "${INSTALL_ADMINER}" "${INSTALL_TOMCAT}" "${INSTALL_FAIL2BAN}"; do
    [ "$v" = yes ] && return 0
  done
  return 1
}

# 菜单序号 -> 数组元素。
# 直接用 arr[$((n-1))] 有两个坑：
#   1) 输入 0 时下标为 -1，bash 的负下标取**最后一个元素** —— 用户以为没选，
#      实际装了列表最后一项（版本和形式菜单都有这个问题）；
#   2) 输入字母或超范围数字同样会静默取到奇怪的值。
# 用法: _menu_pick <数组名> <用户输入> <元素个数> <输出变量名>；无效返回 1
_menu_pick() {
  # 注意：输出变量名**不能**声明成 local —— 那样赋值只发生在函数作用域里，
  # 调用方拿到的永远是自己原来的空值（实测：选了版本却得到空串）。
  # 局部变量**不能**取名为 arr：调用方的数组常常也叫 arr/marr/lines，
  # 同名 local 标量会把数组遮住，`${arr[0]}` 就退化成取这个标量自己（实测取到 "arr"）。
  local _mp_arr="$1" n="$2" total="$3" outname="$4" i val
  case "$n" in ''|*[!0-9]*) return 1 ;; esac
  i=$((10#$n - 1))
  [ "$i" -ge 0 ] && [ "$i" -lt "$total" ] || return 1
  eval "val=\${${_mp_arr}[$i]}"
  printf -v "$outname" '%s' "$val"
  return 0
}

confirm_summary() {
  # MySQL 与 MariaDB 互斥
  if [ -n "$SEL_MYSQL" ] && [ -n "$SEL_MARIADB" ]; then
    die "MySQL 与 MariaDB 不能同时安装 (choose only one database)。请只选其一。"
  fi
  # Nginx 与 Apache 都默认监听 80：同一次安装必然有一个起不来（且安装脚本
  # 会在 service start 处报错，留下半装状态）。要么装完一个改端口再装另一个。
  if [ -n "$SEL_NGINX" ] && [ -n "$SEL_APACHE" ]; then
    die "Nginx 与 Apache 不能在同一次安装中选择（二者都监听 80，必有一个起不来）。请先装其一；确需共存，装完后修改其监听端口，再单独安装另一个。"
  fi
  # PHP 的 apache 形式(mod_php) 依赖 Apache 的 apxs：缺了会在编译十几分钟后的
  # configure 阶段才炸。这里提前拦，并给出替代写法。
  if [ -n "$SEL_PHP" ] && [ "${SEL_PHP##*:}" = apache ]; then
    if [ -z "$SEL_APACHE" ] && [ ! -x "${PREFIX_APACHE}/bin/apxs" ]; then
      die "PHP 的 apache 形式需要先/同时安装 Apache（--apache 2.4.69）。配合 Nginx 请用 --php <版本>:fpm"
    fi
  fi
  # Tomcat 需要 Java：未选 Java 且系统无 java 时，自动选 OpenJDK 17
  if [ "${INSTALL_TOMCAT}" = yes ] && [ -z "$SEL_JAVA" ] \
     && [ ! -x "${PREFIX_JAVA}/bin/java" ] && ! command -v java >/dev/null 2>&1; then
    SEL_JAVA=17
    log_warn "Tomcat 需要 Java，未选择 OpenJDK，已自动选 OpenJDK 17"
  fi
  # PHP 生态附加件（memcached 扩展 / Swoole / Composer）必须有 PHP
  if [ -n "${SEL_PHPMEMCACHED}${SEL_SWOOLE}${SEL_COMPOSER}" ] && [ -z "$SEL_PHP" ] \
     && [ ! -x "${PREFIX_PHP}/bin/php" ]; then
    die "phpredis / php-memcached / Swoole / Composer 都需要 PHP。请同时加 --php <版本>，或先装好 PHP 再单独安装。"
  fi
  # 选了 Memcached 但没明确表态要不要 PHP 扩展时，按需求提示一次
  if [ -n "$SEL_MEMCACHED" ] && [ -z "$SEL_PHPMEMCACHED" ] && [ -z "${PHP_MEMCACHED_NO:-}" ]; then
    if ask_yes_no "已选择 Memcached，是否同时安装 PHP memcached 扩展 (${PHPMEMCACHED_DEFAULT})?" n; then
      SEL_PHPMEMCACHED="${PHPMEMCACHED_DEFAULT}:source"
    fi
  fi
  # Swoole 的 PHP 版本硬门槛（提前拦，别等编译到一半才报错）
  # 必须优先看**本次选择的** PHP 版本，而不是机器上已装的那个：
  # 同一台机上先装了 PHP 7.4，之后再 --php 8.3.36 --swoole 应该放行；
  # 反过来（机上装着 8.3、本次选 7.4 + swoole）才该拦。
  if [ -n "$SEL_SWOOLE" ]; then
    local _pv=""
    [ -n "$SEL_PHP" ] && _pv="${SEL_PHP%%:*}"
    [ -n "$_pv" ] || _pv=$(php_bin_version 2>/dev/null)
    if [ -n "$_pv" ]; then
      ver_ge "$_pv" "8.0" || die "Swoole 需要 PHP >= 8.0，当前选择的是 ${_pv}。请改用 --php 8.3.36 或更高。"
    fi
  fi
  hr; echo "安装计划 (Install plan):"
  echo "  Nginx : ${SEL_NGINX:-不安装(skip)}"
  echo "  Apache: ${SEL_APACHE:-不安装(skip)}${SEL_APACHE:+${APACHE_MPM:+  (MPM=${APACHE_MPM})}}"
  echo "  PHP   : ${SEL_PHP:-不安装(skip)}${SEL_PHP:+  (ImageMagick=$([ "${PHP_IMAGICK}" = yes ] && echo "是[$([ "${IMAGEMAGICK_SOURCE}" = yes ] && echo 源码${IMAGEMAGICK_VERSION} || echo 包)]" || echo 否), fileinfo=是)}"
  echo "  MySQL : ${SEL_MYSQL:-不安装(skip)}"
  echo "  MariaDB: ${SEL_MARIADB:-不安装(skip)}"
  echo "  Redis : ${SEL_REDIS:-不安装(skip)}"
  echo "  phpredis: ${SEL_PHPREDIS:-不安装(skip)}"
  echo "  Memcached: ${SEL_MEMCACHED:-不安装(skip)}"
  echo "  PHP memcached: ${SEL_PHPMEMCACHED:-不安装(skip)}"
  echo "  Swoole: ${SEL_SWOOLE:-不安装(skip)}"
  echo "  Composer: ${SEL_COMPOSER:-不安装(skip)}"
  echo "  Node.js: ${SEL_NODE:-不安装(skip)}"
  echo "  fail2ban: $([ "${INSTALL_FAIL2BAN}" = yes ] && echo "安装 (sshd / nginx-http-auth / nginx-limit-req)" || echo "不安装(skip)")"
  echo "  phpMyAdmin: $([ "${INSTALL_PMA}" = yes ] && echo "安装 -> ${WWWROOT}/web/phpMyAdmin" || echo "不安装(skip)")"
  echo "  Adminer: $([ "${INSTALL_ADMINER}" = yes ] && echo "安装 -> ${WWWROOT}/web/adminer" || echo "不安装(skip)")"
  echo "  OpenJDK: ${SEL_JAVA:-不安装(skip)}"
  echo "  Tomcat: $([ "${INSTALL_TOMCAT}" = yes ] && echo "安装 ${TOMCAT_VERSION}" || echo "不安装(skip)")"
  hr
  # 逐个判断，不能拼成一个大字符串再看 -z：
  # 拼接串里混着 INSTALL_PMA=no 这类"未安装"的标记值，它们**非空**，
  # 于是什么都没选也永远不为空 —— 这条保护形同虚设（实测：全 skip 也会开始安装）。
  if ! _has_any_selection; then
    die "未选择任何组件 (nothing selected)。用 --help 看可选项，或: $0 --nginx --php 8.3.36:fpm --mysql 8.4.13"
  fi
  if [ "$ASSUME_YES" -ne 1 ]; then
    read -rp "确认开始安装? (proceed?) [y/N]: " ok
    [[ "$ok" =~ ^[Yy]$ ]] || die "已取消 (aborted)"
  fi
}

# ----- 干跑计划报告 / dry-run plan report ----------------------------------
# 静态列出"将要发生什么"，不依赖真正执行安装函数：
#   选中的组件/版本/形式、安装前缀、将创建/覆盖的配置文件、将启动的服务。
# 下载 URL 链由 fetch() 在干跑模式下实时打印（见 run_installs -> 各 install_*）。
plan_report() {
  hr
  log_warn "干跑模式 (DRY-RUN)：以下为安装计划，不会做任何实际改动。"
  hr
  echo "将安装的组件 (components):"
  [ -n "$SEL_NGINX" ]   && echo "  Nginx   ${SEL_NGINX%%:*}  (${SEL_NGINX##*:})   -> ${PREFIX_NGINX}"
  [ -n "$SEL_APACHE" ]  && echo "  Apache  ${SEL_APACHE%%:*}  (${SEL_APACHE##*:})  -> ${PREFIX_APACHE}${APACHE_MPM:+  (MPM=${APACHE_MPM})}"
  [ -n "$SEL_PHP" ]     && echo "  PHP     ${SEL_PHP%%:*}  (${SEL_PHP##*:})     -> ${PREFIX_PHP}"
  [ -n "$SEL_MYSQL" ]   && echo "  MySQL   ${SEL_MYSQL%%:*}  (${SEL_MYSQL##*:})   -> ${PREFIX_MYSQL}"
  [ -n "$SEL_MARIADB" ] && echo "  MariaDB ${SEL_MARIADB%%:*}  (${SEL_MARIADB##*:})  -> ${PREFIX_MARIADB}"
  [ -n "$SEL_REDIS" ]   && echo "  Redis   ${SEL_REDIS%%:*}  (${SEL_REDIS##*:})   -> ${PREFIX_REDIS}"
  [ -n "$SEL_PHPREDIS" ] && echo "  phpredis ${SEL_PHPREDIS%%:*} (扩展，装入 PHP)"
  [ -n "$SEL_MEMCACHED" ] && echo "  Memcached ${SEL_MEMCACHED%%:*} (${SEL_MEMCACHED##*:}) -> ${PREFIX_MEMCACHED}"
  [ -n "$SEL_PHPMEMCACHED" ] && echo "  PHP memcached ${SEL_PHPMEMCACHED%%:*} (扩展，装入 PHP)"
  [ -n "$SEL_SWOOLE" ] && echo "  Swoole ${SEL_SWOOLE%%:*} (扩展，装入 PHP)"
  [ -n "$SEL_COMPOSER" ] && echo "  Composer ${SEL_COMPOSER%%:*} -> /usr/local/bin/composer"
  [ -n "$SEL_NODE" ] && echo "  Node.js ${SEL_NODE%%:*} (${SEL_NODE##*:}) -> ${PREFIX_NODE}"
  [ -n "$SEL_COMPOSER$SEL_NODE" ] && echo "  包索引镜像 mirror=${MIRROR_MODE:-cn}  -> Composer repo.packagist / npm registry"
  [ "${INSTALL_FAIL2BAN}" = yes ] && echo "  fail2ban -> /etc/fail2ban/jail.d/lnamp.local"
  [ -n "$SEL_JAVA" ]    && echo "  OpenJDK ${SEL_JAVA}  -> ${PREFIX_JAVA}"
  [ "${INSTALL_TOMCAT}" = yes ] && echo "  Tomcat  ${TOMCAT_VERSION}  -> ${PREFIX_TOMCAT}"
  [ "${INSTALL_PMA}" = yes ]     && echo "  phpMyAdmin ${PMA_VERSION} -> ${WWWROOT}/web/phpMyAdmin"
  [ "${INSTALL_ADMINER}" = yes ] && echo "  Adminer ${ADMINER_VERSION} -> ${WWWROOT}/web/adminer"

  echo
  echo "将创建/覆盖的配置文件 (config files):"
  echo "  ${MY_CNF_PATH}                      数据库主配置 (若已存在会先备份为 .bak.<时间戳>)"
  [ -n "$SEL_NGINX" ]   && echo "  ${PREFIX_NGINX}/conf/nginx.conf, ${PREFIX_NGINX}/conf/vhost/, ${PREFIX_NGINX}/conf/lnamp/"
  [ -n "$SEL_NGINX" ]   && echo "  /etc/logrotate.d/nginx            日志轮转"
  [ -n "$SEL_APACHE" ]  && echo "  ${PREFIX_APACHE}/conf/httpd.conf 及 conf/lnamp/*.conf"
  [ -n "$SEL_PHP" ]     && echo "  ${PREFIX_PHP}/etc/php.ini, ${PREFIX_PHP}/etc/php-fpm.conf, ${PREFIX_PHP}/etc/php-fpm.d/www.conf, ${PREFIX_PHP}/etc/php.d/*.ini"
  [ -n "$SEL_PHP" ]     && echo "  /etc/logrotate.d/php-fpm          日志轮转"
  [ -n "$SEL_MYSQL$SEL_MARIADB" ] && echo "  /etc/logrotate.d/mysqld            日志轮转"
  [ -n "$SEL_REDIS" ]   && echo "  ${PREFIX_REDIS}/etc/redis.conf"
  [ -n "$SEL_REDIS" ]   && echo "  /etc/logrotate.d/redis            日志轮转"
  [ -n "$SEL_MEMCACHED" ] && echo "  ${PREFIX_MEMCACHED}/etc/memcached.conf"
  [ "${INSTALL_FAIL2BAN}" = yes ] && echo "  /etc/fail2ban/jail.d/lnamp.local  三个 jail (sshd/nginx-http-auth/nginx-limit-req)"
  echo "  /etc/profile.d/lnamp-*.sh        PATH 注册"
  echo "  ${SYSCTL_CONF}    内核参数 (somaxconn / backlog / file-max ...)"
  echo "  ${LIMITS_CONF}    登录会话句柄上限"
  echo "  ${SYSTEMD_LIMITS_CONF}  systemd 服务句柄上限 (DefaultLimitNOFILE)"
  [ -n "$SEL_NGINX" ]   && echo "  ${SYSTEMD_DIR}/nginx.service"
  [ -n "$SEL_APACHE" ]  && echo "  ${SYSTEMD_DIR}/httpd.service"
  [ -n "$SEL_PHP" ]     && echo "  ${SYSTEMD_DIR}/php-fpm.service"
  [ -n "$SEL_MYSQL" ]   && echo "  ${SYSTEMD_DIR}/mysqld.service"
  [ -n "$SEL_MARIADB" ] && echo "  ${SYSTEMD_DIR}/mariadb.service"
  [ -n "$SEL_REDIS" ]   && echo "  ${SYSTEMD_DIR}/redis.service"
  [ -n "$SEL_JAVA" ]    && echo "  /etc/profile.d/lnamp-java.sh"
  [ "${INSTALL_TOMCAT}" = yes ] && echo "  ${SYSTEMD_DIR}/tomcat.service"

  echo
  echo "将创建/使用的目录 (directories):"
  echo "  ${WWWROOT} ${WWWROOT}/web ${WWWLOGS}   (站点与日志)"
  [ -n "$SEL_NGINX" ]   && echo "  ${PREFIX_NGINX}"
  [ -n "$SEL_APACHE" ]  && echo "  ${PREFIX_APACHE}"
  [ -n "$SEL_PHP" ]     && echo "  ${PREFIX_PHP} 及其 var/log"
  [ -n "$SEL_MYSQL" ]   && echo "  ${PREFIX_MYSQL} ${PREFIX_MYSQL}/data"
  [ -n "$SEL_MARIADB" ] && echo "  ${PREFIX_MARIADB} ${PREFIX_MARIADB}/data"
  [ -n "$SEL_REDIS" ]   && echo "  ${PREFIX_REDIS}/var"
  [ -n "$SEL_MEMCACHED" ] && echo "  ${PREFIX_MEMCACHED}/etc ${PREFIX_MEMCACHED}/var"
  [ -n "$SEL_NODE" ]    && echo "  ${PREFIX_NODE}"
  [ -n "$SEL_PHP" ]     && [ "${PHP_IMAGICK}" = yes ] && [ "${IMAGEMAGICK_SOURCE}" = yes ] && echo "  ${PREFIX_IMAGEMAGICK}"

  echo
  echo "将启动的服务 (services):"
  echo -n " "
  local svcs=()
  [ -n "$SEL_NGINX" ]   && svcs+=(nginx)
  [ -n "$SEL_APACHE" ]  && svcs+=(httpd)
  [ -n "$SEL_PHP" ]     && svcs+=(php-fpm)
  [ -n "$SEL_MYSQL" ]   && svcs+=(mysqld)
  [ -n "$SEL_MARIADB" ] && svcs+=(mariadb)
  [ -n "$SEL_REDIS" ]   && svcs+=(redis)
  [ -n "$SEL_MEMCACHED" ] && svcs+=(memcached)
  [ "${INSTALL_FAIL2BAN}" = yes ] && svcs+=(fail2ban)
  [ "${INSTALL_TOMCAT}" = yes ] && svcs+=(tomcat)
  [ ${#svcs[@]} -gt 0 ] && echo "${svcs[*]}" || echo "(无)"

  echo
  echo "将开放的端口 (firewall):"
  echo -n " "
  local ports=()
  [ -n "$SEL_NGINX" ] || [ -n "$SEL_APACHE" ] && ports+=(80)
  [ -n "$SEL_MYSQL$SEL_MARIADB" ] && ports+=(3306)
  [ ${#ports[@]} -gt 0 ] && echo "${ports[*]}" || echo "(无)"

  echo
  echo "下载 URL 链（fetch 将按顺序尝试，[dry-run] 标记的每一行都是一次真实尝试）:"
  hr
}

run_installs() {
  if [ "${DRY_RUN:-0}" = 1 ]; then
    mkdir -p logs
    local dts; dts=$(date +%Y%m%d_%H%M%S)
    local dlog="logs/dryrun_${dts}.log"
    : > "$dlog"
    log "  [dry-run] 计划详情同时写入: ${dlog}"
    {
      echo "# LNAMP dry-run  $(date '+%F %T')"
      echo "# 组件/版本/形式、下载URL链、将装的系统包、将执行的命令、将启动的服务"
    } >> "$dlog"
    # 干跑下把各 install_* 的计划输出也留档，便于事后核对。
    # 过滤掉"源码未解压"导致的必然报错（tar/mv/sed 找不到文件、rpm/make 不存在等），
    # 这些在真实安装中不会出现，留着只会让人误以为出了问题。
    # 注意 tar 的报错前缀是 "tar (child):"，正则要一并覆盖。
    _run_installs_inner 2>&1 \
      | grep -vE '^tar( \(child\))?: |^mv: cannot stat|^sed: can.t read|^rpm: command not found|^[^ ]*\.sh: line [0-9]+: .*(No such file|command not found)' \
      | tee -a "$dlog"
    return 0
  fi
  _run_installs_inner
}

# 运行单个组件安装并落组件日志。
# 关键修复：install_* 内部用 die/die_with_log 报错时执行 exit 1，但 "cmd | tee"
# 管道会让 install_* 跑在子 shell 里——exit 只终止子 shell，父进程毫无知觉，
# 后续组件继续装，最后还打印"全部任务完成"(退出码 0)，组件失败被整个吞掉。
# 这里用 PIPESTATUS[0] 取组件真实退出码：非零即中止整个安装（干跑模式除外）。
_run_mod() {
  local name="$1"; shift
  local rc
  "$@" 2>&1 | tee "logs/${name}_${ts}.log"
  rc=${PIPESTATUS[0]}
  if [ "$rc" -ne 0 ]; then
    if [ "${DRY_RUN:-0}" = 1 ]; then
      log "  [dry-run] ${name} 退出码 ${rc}（干跑模式仅记录，不中止）"
      return 0
    fi
    log_err "组件安装失败 (component failed): ${name}，退出码 ${rc} —— 安装中止。详见 logs/${name}_${ts}.log"
    exit "$rc"
  fi
}

_run_installs_inner() {
  safe_mkdir "${WWWROOT}" "${WWWLOGS}" logs
  # 站点根 / 日志目录归 www：否则上传目录、runtime、缓存都由 root 独占，
  # 应用以 www 身份运行时写不进去（历史现象：/home/wwwroot 与 web 都是 root:root）。
  if id www >/dev/null 2>&1; then
    chown www:www "${WWWROOT}" "${WWWLOGS}" 2>/dev/null || true
    [ -d "${WWWROOT}/web" ] && chown -R www:www "${WWWROOT}/web" 2>/dev/null || true
  fi
  local ts; ts=$(date +%Y%m%d_%H%M%S)
  export BUILD_LOG="$(pwd)/logs/build_${ts}.log"; : > "$BUILD_LOG"
  log "详细编译日志 (build log): ${BUILD_LOG}"
  # 先修好系统 locale：极简镜像里 /etc/locale.conf 指向的 locale 常未生成，
  # 会让 Redis 7.4+ 等服务在启动时 setlocale 失败而直接退出（服务永远起不来）。
  ensure_utf8_locale
  if [ -n "$SEL_NGINX" ];   then _run_mod nginx   install_nginx   "${SEL_NGINX%%:*}"   "${SEL_NGINX##*:}";   fi
  if [ -n "$SEL_APACHE" ];  then _run_mod apache  install_apache  "${SEL_APACHE%%:*}"  "${SEL_APACHE##*:}"  "${APACHE_MPM}"; fi
  if [ -n "$SEL_PHP" ];     then _run_mod php     install_php     "${SEL_PHP%%:*}"     "${SEL_PHP##*:}";     fi
  if [ -n "$SEL_MYSQL" ];   then _run_mod mysql   install_mysql   "${SEL_MYSQL%%:*}"   "${SEL_MYSQL##*:}";   fi
  if [ -n "$SEL_MARIADB" ]; then _run_mod mariadb install_mariadb "${SEL_MARIADB%%:*}" "${SEL_MARIADB##*:}"; fi
  if [ -n "$SEL_REDIS" ];   then _run_mod redis   install_redis   "${SEL_REDIS%%:*}"   "${SEL_REDIS##*:}";   fi
  if [ -n "$SEL_MEMCACHED" ]; then _run_mod memcached install_memcached "${SEL_MEMCACHED%%:*}" "${SEL_MEMCACHED##*:}"; fi
  if [ -n "$SEL_PHPREDIS" ]; then _run_mod phpredis install_phpredis_pick "${SEL_PHPREDIS%%:*}"; fi
  if [ -n "$SEL_PHPMEMCACHED" ]; then _run_mod php_memcached install_phpmemcached "${SEL_PHPMEMCACHED%%:*}"; fi
  if [ -n "$SEL_SWOOLE" ]; then _run_mod swoole install_swoole "${SEL_SWOOLE%%:*}" "${SEL_SWOOLE##*:}"; fi
  if [ -n "$SEL_COMPOSER" ]; then _run_mod composer install_composer "${SEL_COMPOSER%%:*}" "${SEL_COMPOSER##*:}"; fi
  if [ -n "$SEL_NODE" ]; then _run_mod nodejs install_nodejs "${SEL_NODE%%:*}" "${SEL_NODE##*:}"; fi
  # Composer/npm 包索引镜像：必须放在 composer/nodejs 之后（要先有可执行文件）
  if [ -n "$SEL_COMPOSER$SEL_NODE" ]; then _run_mod mirror install_mirrors "${MIRROR_MODE:-cn}" soft; fi
  if [ "${INSTALL_PMA}" = yes ]; then _run_mod phpmyadmin install_phpmyadmin; fi
  if [ "${INSTALL_ADMINER}" = yes ]; then _run_mod adminer install_adminer; fi
  if [ -n "$SEL_JAVA" ]; then _run_mod java install_java "$SEL_JAVA"; fi
  # Tomcat 最后安装（依赖 Java）
  if [ "${INSTALL_TOMCAT}" = yes ]; then _run_mod tomcat install_tomcat; fi
  # fail2ban 放最后：jail 里要引用 nginx 的错误日志路径，需等 Web 服务器装完
  if [ "${INSTALL_FAIL2BAN}" = yes ]; then _run_mod fail2ban install_fail2ban "$FAIL2BAN_DEFAULT" pkg; fi
  hr; log_ok "全部任务完成 (all done)。日志见 logs/ 目录。"
  log "已编译安装的程序已加入系统 PATH，可直接运行，例如: nginx -V / php -v / mysql --version / redis-cli -v"
  log "（当前终端通过 /usr/local/bin 软链立即可用；新开终端会自动加载 /etc/profile.d/lnamp-*.sh）"
  return 0
}

# ============================ main =========================================
# 并发保护：安装/升级/卸载会共用 /root 下的源码包名与安装前缀，
# 两个进程同时跑会互相删掉对方刚下载的 tarball（实测：一个进程收尾时
# `safe_rm_rf` 删掉了另一个进程正在解压的 redis-*.tar.gz，报
# "tar: Cannot open: No such file or directory"）。这里用 flock 串行化。
_lock_guard() {
  command -v flock >/dev/null 2>&1 || return 0
  local lf="${LNAMP_LOCK_FILE:-/var/run/lnamp.lock}"
  local d; d=$(dirname "$lf")
  [ -d "$d" ] || lf="/tmp/lnamp.lock"
  # 用固定 fd（200）持有锁，进程退出自动释放
  eval "exec 200>\"$lf\"" 2>/dev/null || return 0
  local wait="${LNAMP_LOCK_WAIT:-0}"
  if [ "$wait" -gt 0 ] 2>/dev/null; then
    flock -w "$wait" 200 || die "另一个 lnamp 进程正在运行（已等待 ${wait}s 仍被占用，锁: ${lf}）。"
  elif ! flock -n 200; then
    die "另一个 lnamp 进程正在运行（锁: ${lf}）。可加 --lock-wait <秒> 等待，或等它结束后重试。"
  fi
  return 0
}

# 从参数里"预扫描" --lock-wait：upgrade/uninstall 的加锁发生在它们自己解析参数之前，
# 不预扫的话 --lock-wait 永远不生效（实测表现为立即失败）。
_lock_wait_scan() {
  local a n
  while [ $# -gt 0 ]; do
    case "$1" in
      --lock-wait)
        n="${2:-}"
        case "$n" in ''|*[!0-9]*) ;; *) LNAMP_LOCK_WAIT="$n"; export LNAMP_LOCK_WAIT ;; esac
        shift 2 ;;
      *) shift ;;
    esac
  done
}

main() {
  # vhost 子命令：创建虚拟主机(自定义端口，HTTP)。需 root。
  # 会写 vhost 配置 / 站点目录 / php-fpm 池并 reload，与另一个 lnamp 进程（安装、
  # prune、bench --apply）同时跑会互相覆盖配置 —— 所以除纯读的 list/help 外都加锁。
  if [ "${1:-}" = "vhost" ] || [ "${1:-}" = "addvhost" ]; then
    shift; require_root; detect_os
    case "${1:-}" in
      list|ls|-h|--help) : ;;
      *) _lock_wait_scan "$@"; _lock_guard ;;
    esac
    vhost_main "$@"; exit 0
  fi
  # probe 顶层别名：$0 probe <域名> 等价于 $0 vhost probe <域名>
  if [ "${1:-}" = "probe" ] || [ "${1:-}" = "phpinfo" ]; then
    shift; require_root; detect_os; vhost_main probe "$@"; exit $?
  fi
  # verify 子命令：装完后自检（服务/端口/PHP解析/扩展/版本/数据库连通）
  # 可带组件参数做严格版本比对，如:
  #   $0 verify                                  # 自动探测已装组件（版本比对跳过）
  #   $0 verify --nginx 1.30.6 --php 8.3.36:fpm   # 严格比对 versions.conf
  if [ "${1:-}" = "verify" ] || [ "${1:-}" = "check" ]; then
    shift; require_root; detect_os
    [ $# -gt 0 ] && parse_args "$@"
    [ -r "${SCRIPT_DIR}/versions.conf" ] && verify_stack
    exit $?
  fi
  # status 子命令：一屏运维总览（只读）。
  # 与 verify 的分工：verify 验"装对了吗"（会写探针、会 FAIL 计数）；
  # status 看"现在怎么样"（绝不写任何文件），供日常巡检与监控采集。
  if [ "${1:-}" = "status" ] || [ "${1:-}" = "st" ]; then
    shift; status_main "$@"; exit $?
  fi
  # doctor 子命令：只读诊断 + 给出可直接执行的修复命令
  if [ "${1:-}" = "doctor" ] || [ "${1:-}" = "diag" ]; then
    shift; doctor_main "$@"; exit $?
  fi
  # scan 子命令：只读巡检 webshell / 可疑文件（不写任何文件、不改任何配置）
  # 不需要 detect_os：扫描逻辑与发行版无关，非 root 也能跑（只是看不到部分属主信息）
  if [ "${1:-}" = "scan" ] || [ "${1:-}" = "av" ]; then
    shift; scan_main "$@"; exit $?
  fi
  # bench 子命令：本地压测 + 并发参数推荐（默认只读，--apply 才写回）
  # 只有 --apply 会改 nginx.conf / php-fpm 池并 reload，才需要锁；
  # 纯压测加锁反而会挡住同机正在跑的安装任务。
  if [ "${1:-}" = "bench" ] || [ "${1:-}" = "benchmark" ]; then
    shift; require_root; detect_os
    for a in "$@"; do [ "$a" = "--apply" ] && { _lock_wait_scan "$@"; _lock_guard; break; }; done
    bench_main "$@"; exit $?
  fi
  # backup / restore：整套栈的统一备份与还原
  if [ "${1:-}" = "backup" ] || [ "${1:-}" = "bak" ]; then
    shift; require_root; detect_os; _lock_wait_scan "$@"; _lock_guard; backup_main "$@"; exit $?
  fi
  if [ "${1:-}" = "restore" ]; then
    shift; require_root; detect_os; _lock_wait_scan "$@"; _lock_guard; restore_main "$@"; exit $?
  fi
  # upgrade 子命令：平滑升级单个组件（保留配置与数据）
  if [ "${1:-}" = "upgrade" ]; then
    shift; require_root; detect_os; _lock_wait_scan "$@"; _lock_guard; upgrade_main "$@"; exit $?
  fi
  # uninstall 子命令：卸载组件（反注册 systemd/logrotate/PATH）
  if [ "${1:-}" = "uninstall" ] || [ "${1:-}" = "remove" ]; then
    shift; require_root; detect_os; _lock_wait_scan "$@"; _lock_guard; uninstall_main "$@"; exit $?
  fi
  # precheck 子命令：安装前预检（只读）。不强制 root —— 非 root 下会降级提示，
  # 因为很多"装到一半失败"的坑（磁盘/内存/端口/DNS）普通用户也能看见。
  if [ "${1:-}" = "precheck" ] || [ "${1:-}" = "check-env" ]; then
    shift; detect_os
    [ "$(id -u 2>/dev/null)" = 0 ] || \
      log_warn "非 root 运行：rpm/dpkg 查询与 systemctl 相关检查可能取不到结果（其余检查照常）"
    [ $# -gt 0 ] && parse_args "$@"
    precheck_main
    exit $?
  fi
  # sysctl 子命令：单独应用内核参数与句柄上限（幂等）。
  # 会写 /etc/sysctl.d、/etc/security/limits.d 并执行 sysctl --system /
  # daemon-reexec —— 和安装过程里的 system_prep 抢同一批文件，必须串行。
  if [ "${1:-}" = "sysctl" ] || [ "${1:-}" = "tune" ]; then
    shift; require_root; detect_os; _lock_wait_scan "$@"; _lock_guard
    install_sysctl "manual"; exit $?
  fi
  # mirror 子命令：查看/切换 Composer 与 npm 的包索引。
  # 无参数只是打印当前配置（只读，不锁）；带 cn/official/none 会改 ~/.composer 与
  # ~/.npmrc，和安装末尾的 install_mirrors 是同一批文件，需要锁。
  if [ "${1:-}" = "mirror" ] || [ "${1:-}" = "registry" ]; then
    shift
    case "${1:-}" in
      ''|-h|--help) : ;;
      *) _lock_wait_scan "$@"; _lock_guard ;;
    esac
    mirror_main "$@"; exit $?
  fi
  # --help / --list 无需 root 或 CentOS 环境，提前处理
  for a in "$@"; do
    case "$a" in
      -h|--help) usage; exit 0 ;;
      --list)    print_list; exit 0 ;;
    esac
  done
  require_root
  detect_os
  if [ $# -gt 0 ]; then parse_args "$@"; else interactive_menu; fi
  # 参数解析后再加锁：--lock-wait 的值此时才确定
  _lock_guard
  # 安装前预检（只读）：把"装到一半才失败"的坑提前暴露。
  # 有阻塞项时默认停下询问；-y 下只告警继续（自动化场景不便交互）。
  if [ "${SKIP_PRECHECK:-0}" != 1 ] && [ "${DRY_RUN:-0}" != 1 ]; then
    if ! precheck_main; then
      log_warn "预检存在阻塞项，继续安装大概率中途失败。"
      if [ "$ASSUME_YES" -ne 1 ]; then
        ask_yes_no "仍然继续安装吗? (continue anyway?)" n || die "已取消 (aborted)。修复后可重跑: $0 precheck"
      else
        log_warn "--yes 已指定，跳过确认直接继续（风险自负）"
      fi
    fi
  fi
  confirm_summary
  if [ "${DRY_RUN:-0}" = 1 ]; then
    plan_report
    system_prep        # 干跑下只打印计划（pkg_* / sed / timedatectl 均被 gate 或无害失败）
    run_installs       # 干跑下 fetch/log_run/enable_service 只打印
    hr
    log_warn "干跑结束 (dry-run finished)：未做任何实际改动。去掉 --dry-run 即为真实安装。"
    exit 0
  fi
  system_prep
  run_installs
  verify_stack || log_warn "自检未全部通过，请查看上方 [FAIL] 项；可稍后单独执行: $0 verify"
}
# LNAMP_NO_MAIN=1 时仅加载函数不执行（便于测试 / for testing）
[ -n "${LNAMP_NO_MAIN:-}" ] || main "$@"
