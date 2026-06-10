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
#     # 形式可省略，使用该组件默认形式：--nginx 1.24.0
#     # 列出全部可选项：       ./install.sh --list
# ============================================================================
set -o pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export SCRIPT_DIR

# shellcheck source=/dev/null
source "${SCRIPT_DIR}/versions.conf"
source "${SCRIPT_DIR}/lib/common.sh"
for m in deps nginx apache php mysql mariadb redis vhost phpmyadmin adminer; do source "${SCRIPT_DIR}/modules/${m}.sh"; done

# 选择结果 (空 = 不安装该组件)
SEL_NGINX="" ; SEL_APACHE="" ; SEL_PHP="" ; SEL_MYSQL="" ; SEL_MARIADB="" ; SEL_REDIS="" ; SEL_PHPREDIS=""
APACHE_MPM=""   # prefork|worker|event（安装 Apache 时选择，应用到 httpd.conf 与 vhost）
PHP_IMAGICK=""  # yes|no（是否为 PHP 安装 ImageMagick/imagick 扩展）
IMAGEMAGICK_SOURCE=""  # yes|no（imagick 链接的 ImageMagick 是否从源码编译最新版）
INSTALL_PMA=""  # yes|no（是否安装 phpMyAdmin 到默认站点）
INSTALL_ADMINER=""  # yes|no（是否安装 Adminer 轻量级数据库工具）
ASSUME_YES=0

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
  --php-imagick         为 PHP 安装 ImageMagick(imagick) 扩展 (非交互时默认不装)
  --no-php-imagick      明确不安装 imagick (非交互场景)
  --imagemagick-source  imagick 链接源码编译的最新 ImageMagick (含 --php-imagick)
  --phpmyadmin          安装 phpMyAdmin 到默认站点 ${WWWROOT:-/home/wwwroot}/web/phpMyAdmin
  --no-phpmyadmin       明确不安装 phpMyAdmin (非交互场景)
  --adminer             安装 Adminer (轻量级单文件 DB 工具) 到 ${WWWROOT:-/home/wwwroot}/web/adminer
  --no-adminer          明确不安装 Adminer (非交互场景)
  --list                列出所有可选版本与形式后退出
  -y, --yes             跳过交互确认
  -h, --help            显示本帮助

子命令 (Subcommands):
  $0 vhost <域名> [端口] [网站根目录] [nginx|apache]   创建虚拟主机(自定义端口，仅 HTTP，不含 HTTPS)
                                        不带参数则交互输入；同时装了 nginx 与 apache 时可用第4参数指定

示例 (Examples):
  $0 --nginx 1.26.2:source --php 8.3.31:fpm --phpredis 6.3.0 --mysql 5.7.44:binary
  $0 --apache 2.4.67:source --apache-mpm event --php 8.3.31:fpm
  $0 --apache 2.4.67:source --apache-mpm prefork --php 8.2.14:apache
  $0 vhost example.com 8080 /home/wwwroot/example.com
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
  hr
  echo "默认 (defaults): nginx=${NGINX_DEFAULT}:${NGINX_DEFAULT_MODE}  apache=${APACHE_DEFAULT}:${APACHE_DEFAULT_MODE}  php=${PHP_DEFAULT}:${PHP_DEFAULT_MODE}  mysql=${MYSQL_DEFAULT}:${MYSQL_DEFAULT_MODE}  mariadb=${MARIADB_DEFAULT}:${MARIADB_DEFAULT_MODE}  redis=${REDIS_DEFAULT}:${REDIS_DEFAULT_MODE}"
  echo "注: MySQL 与 MariaDB 互斥；Nginx 列表中的 tengine-* 为 Tengine；安装 PHP 会自动带 phpredis 扩展。"
}

# ----- 参数解析 -------------------------------------------------------------
parse_args() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --nginx)  parse_pick NGINX  "$2"; SEL_NGINX="${PICK_VER}:${PICK_MODE}";  shift 2 ;;
      --apache) parse_pick APACHE "$2"; SEL_APACHE="${PICK_VER}:${PICK_MODE}"; shift 2 ;;
      --apache-mpm)
        case "$2" in prefork|worker|event) APACHE_MPM="$2" ;; *) die "--apache-mpm 取值须为 prefork|worker|event" ;; esac
        shift 2 ;;
      --php)    parse_pick PHP    "$2"; SEL_PHP="${PICK_VER}:${PICK_MODE}";    shift 2 ;;
      --mysql)   parse_pick MYSQL   "$2"; SEL_MYSQL="${PICK_VER}:${PICK_MODE}";   shift 2 ;;
      --mariadb) parse_pick MARIADB "$2"; SEL_MARIADB="${PICK_VER}:${PICK_MODE}"; shift 2 ;;
      --redis)   parse_pick REDIS   "$2"; SEL_REDIS="${PICK_VER}:${PICK_MODE}";   shift 2 ;;
      --phpredis) parse_pick PHPREDIS "$2"; SEL_PHPREDIS="${PICK_VER}:${PICK_MODE}"; shift 2 ;;
      --php-imagick)   PHP_IMAGICK=yes; shift ;;
      --no-php-imagick) PHP_IMAGICK=no; shift ;;
      --imagemagick-source) PHP_IMAGICK=yes; IMAGEMAGICK_SOURCE=yes; shift ;;
      --phpmyadmin)    INSTALL_PMA=yes; shift ;;
      --no-phpmyadmin) INSTALL_PMA=no; shift ;;
      --adminer)       INSTALL_ADMINER=yes; shift ;;
      --no-adminer)    INSTALL_ADMINER=no; shift ;;
      --list)   print_list; exit 0 ;;
      -y|--yes) ASSUME_YES=1; shift ;;
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
  if [ -z "$vn" ]; then ver="$defv"; else ver="${lines[$((vn-1))]%%|*}"; fi
  [ -z "$ver" ] && die "${label}: 无效选择"

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
      mode="${marr[$((mn-1))]}"
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
  menu_component MYSQL  "MySQL (DB)"
  # MariaDB 与 MySQL 互斥：仅当未选 MySQL 时才询问 MariaDB
  if [ -z "$SEL_MYSQL" ]; then
    menu_component MARIADB "MariaDB (DB, 与 MySQL 二选一)"
  fi
  menu_component REDIS  "Redis (缓存)"
  # phpredis：需要 PHP（本次选了 PHP，或系统已装 PHP）才询问
  if [ -n "$SEL_PHP" ] || [ -x "${PREFIX_PHP}/bin/phpize" ]; then
    menu_component PHPREDIS "phpredis (PHP 的 Redis 扩展)"
  fi
}

# ----- 系统准备 (跨发行版) --------------------------------------------------
system_prep() {
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
}

confirm_summary() {
  # MySQL 与 MariaDB 互斥
  if [ -n "$SEL_MYSQL" ] && [ -n "$SEL_MARIADB" ]; then
    die "MySQL 与 MariaDB 不能同时安装 (choose only one database)。请只选其一。"
  fi
  hr; echo "安装计划 (Install plan):"
  echo "  Nginx : ${SEL_NGINX:-不安装(skip)}"
  echo "  Apache: ${SEL_APACHE:-不安装(skip)}${SEL_APACHE:+${APACHE_MPM:+  (MPM=${APACHE_MPM})}}"
  echo "  PHP   : ${SEL_PHP:-不安装(skip)}${SEL_PHP:+  (ImageMagick=$([ "${PHP_IMAGICK}" = yes ] && echo "是[$([ "${IMAGEMAGICK_SOURCE}" = yes ] && echo 源码${IMAGEMAGICK_VERSION} || echo 包)]" || echo 否), fileinfo=是)}"
  echo "  MySQL : ${SEL_MYSQL:-不安装(skip)}"
  echo "  MariaDB: ${SEL_MARIADB:-不安装(skip)}"
  echo "  Redis : ${SEL_REDIS:-不安装(skip)}"
  echo "  phpredis: ${SEL_PHPREDIS:-不安装(skip)}"
  echo "  phpMyAdmin: $([ "${INSTALL_PMA}" = yes ] && echo "安装 -> ${WWWROOT}/web/phpMyAdmin" || echo "不安装(skip)")"
  echo "  Adminer: $([ "${INSTALL_ADMINER}" = yes ] && echo "安装 -> ${WWWROOT}/web/adminer" || echo "不安装(skip)")"
  hr
  if [ -z "${SEL_NGINX}${SEL_APACHE}${SEL_PHP}${SEL_MYSQL}${SEL_MARIADB}${SEL_REDIS}${SEL_PHPREDIS}" ]; then
    die "未选择任何组件 (nothing selected)"
  fi
  if [ "$ASSUME_YES" -ne 1 ]; then
    read -rp "确认开始安装? (proceed?) [y/N]: " ok
    [[ "$ok" =~ ^[Yy]$ ]] || die "已取消 (aborted)"
  fi
}

run_installs() {
  mkdir -p "${WWWROOT}" "${WWWLOGS}" logs
  local ts; ts=$(date +%Y%m%d_%H%M%S)
  export BUILD_LOG="$(pwd)/logs/build_${ts}.log"; : > "$BUILD_LOG"
  log "详细编译日志 (build log): ${BUILD_LOG}"
  if [ -n "$SEL_NGINX" ];   then install_nginx   "${SEL_NGINX%%:*}"   "${SEL_NGINX##*:}"   2>&1 | tee "logs/nginx_${ts}.log";   fi
  if [ -n "$SEL_APACHE" ];  then install_apache  "${SEL_APACHE%%:*}"  "${SEL_APACHE##*:}"  "${APACHE_MPM}" 2>&1 | tee "logs/apache_${ts}.log";  fi
  if [ -n "$SEL_PHP" ];     then install_php     "${SEL_PHP%%:*}"     "${SEL_PHP##*:}"     2>&1 | tee "logs/php_${ts}.log";     fi
  if [ -n "$SEL_MYSQL" ];   then install_mysql   "${SEL_MYSQL%%:*}"   "${SEL_MYSQL##*:}"   2>&1 | tee "logs/mysql_${ts}.log";   fi
  if [ -n "$SEL_MARIADB" ]; then install_mariadb "${SEL_MARIADB%%:*}" "${SEL_MARIADB##*:}" 2>&1 | tee "logs/mariadb_${ts}.log"; fi
  if [ -n "$SEL_REDIS" ];   then install_redis   "${SEL_REDIS%%:*}"   "${SEL_REDIS##*:}"   2>&1 | tee "logs/redis_${ts}.log";   fi
  if [ -n "$SEL_PHPREDIS" ]; then install_phpredis_pick "${SEL_PHPREDIS%%:*}" 2>&1 | tee "logs/phpredis_${ts}.log"; fi
  if [ "${INSTALL_PMA}" = yes ]; then install_phpmyadmin 2>&1 | tee "logs/phpmyadmin_${ts}.log"; fi
  if [ "${INSTALL_ADMINER}" = yes ]; then install_adminer 2>&1 | tee "logs/adminer_${ts}.log"; fi
  hr; log_ok "全部任务完成 (all done)。日志见 logs/ 目录。"
  log "已编译安装的程序已加入系统 PATH，可直接运行，例如: nginx -V / php -v / mysql --version / redis-cli -v"
  log "（当前终端通过 /usr/local/bin 软链立即可用；新开终端会自动加载 /etc/profile.d/lnamp-*.sh）"
}

# ============================ main =========================================
main() {
  # vhost 子命令：创建虚拟主机(自定义端口，HTTP)。需 root。
  if [ "${1:-}" = "vhost" ] || [ "${1:-}" = "addvhost" ]; then
    shift; require_root; detect_os; vhost_main "$@"; exit 0
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
  confirm_summary
  system_prep
  run_installs
}
# LNAMP_NO_MAIN=1 时仅加载函数不执行（便于测试 / for testing）
[ -n "${LNAMP_NO_MAIN:-}" ] || main "$@"
