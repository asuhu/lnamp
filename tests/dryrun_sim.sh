#!/usr/bin/env bash
# 测试隔离：logrotate 目录必须指到临时位置。setup_logrotate 默认写
# /etc/logrotate.d，跑一次测试就会把宿主机的 nginx 日志路径覆盖成临时前缀，
# 此后 logrotate 每天 stat failed、日志永不轮转（真机上已实际发生过）。
export LNAMP_LOGROTATE_DIR="${LNAMP_LOGROTATE_DIR:-$(mktemp -d)}"
# ============================================================================
#  端到端干跑仿真 (end-to-end dry-run simulation)
# ----------------------------------------------------------------------------
#  在非 Linux/非 root 环境下跑通 install.sh 的真实干跑路径：
#    1) source install.sh（LNAMP_NO_MAIN=1，只加载函数不执行 main）
#    2) 覆盖 require_root / detect_os，伪装成 Rocky 9 + root
#    3) 设置 DRY_RUN=1，走 confirm_summary -> plan_report -> system_prep -> run_installs
#    4) 全程只打印、不改系统
#
#  用途：验证 plan_report / 干跑分支 / 各 install_* 的 fetch URL 链是否正确，
#        且确认没有任何真实副作用（尤其是 safe_rm_rf 的拦截）。
#  用法: bash tests/dryrun_sim.sh > /tmp/dry.log 2>&1   # 结尾会打印副作用审计
# ============================================================================
set -u

R="$(cd "$(dirname "$0")/.." && pwd)"

export LNAMP_NO_MAIN=1
# shellcheck source=/dev/null
source "${R}/install.sh"

# ---- 伪装运行环境（不真的动系统）------------------------------------------
require_root() { :; }
detect_os() {
  OS_ID=rocky; OS_FAMILY=rhel; OS_VER=9; OS_PRETTY="Rocky Linux 9.4 (simulated)"
  PM=dnf; HAS_SYSTEMD=1; SYSTEMD_DIR=/etc/systemd/system
  export OS_ID OS_FAMILY OS_VER PM HAS_SYSTEMD SYSTEMD_DIR OS_PRETTY
}
detect_mem() { MEM_MB=4096; MEM_LEVEL=high; MEMORY_LIMIT=512; export MEM_MB MEM_LEVEL MEMORY_LIMIT; }

# 系统写操作全部拦掉（双保险：即便漏了 gate 也不会真改本机）
_sim_noop() { return 0; }
systemctl() { :; }
timedatectl() { :; }
setenforce() { :; }
useradd() { :; }
groupadd() { :; }
chown() { :; }
ldconfig() { :; }
firewall-cmd() { :; }
ufw() { :; }
ln() { :; }

detect_os
detect_mem
DRY_RUN=1
ASSUME_YES=1

# ---- 选择一组有代表性的组件 -----------------------------------------------
SEL_NGINX="1.30.6:source"
SEL_APACHE=""
SEL_PHP="8.3.36:fpm"
SEL_MYSQL="8.0.46:binary"
SEL_MARIADB=""
SEL_REDIS="8.8.3:source"
SEL_PHPREDIS="6.3.0:source"
PHP_IMAGICK="yes"
IMAGEMAGICK_SOURCE="no"
INSTALL_PMA="yes"
INSTALL_ADMINER="yes"
SEL_JAVA=""
INSTALL_TOMCAT="no"

# 新增组件（第二批）——全部选中，验证四件套接入后的干跑路径
SEL_MEMCACHED="1.6.45:source"
SEL_PHPMEMCACHED="3.4.0:source"
SEL_SWOOLE="6.2.3:source"
SEL_COMPOSER="2.10.3:phar"
SEL_NODE="24.22.1:binary"
INSTALL_FAIL2BAN="yes"

echo "############ 干跑仿真开始 (dry-run simulation) ############"
echo "# 伪装环境: ${OS_PRETTY}  family=${OS_FAMILY} ver=${OS_VER} pm=${PM}"
echo "# 选中: nginx ${SEL_NGINX} / php ${SEL_PHP} / mysql ${SEL_MYSQL} / redis ${SEL_REDIS}"
echo "# 新增: memcached ${SEL_MEMCACHED} / php-memcached ${SEL_PHPMEMCACHED} / swoole ${SEL_SWOOLE}"
echo "# 新增: composer ${SEL_COMPOSER} / nodejs ${SEL_NODE} / fail2ban ${INSTALL_FAIL2BAN}"
echo "# 新增: 内核调优 sysctl=${SYSCTL_CONF} / mirror=${MIRROR_MODE:-cn}"
echo

confirm_summary
echo
plan_report
echo
# ---- 审计路径清单：干跑之后一项都不允许被真实创建 -------------------------
_audit_list="/data
/data/mysql
/data/mariadb
/usr/local/php
/usr/local/nginx
/usr/local/redis
/usr/local/mysql
/usr/local/mariadb
/etc/my.cnf
/etc/logrotate.d/nginx
/etc/logrotate.d/php-fpm
/etc/logrotate.d/mysqld
/etc/logrotate.d/redis
/etc/systemd/system/nginx.service
/etc/systemd/system/mysqld.service
/etc/systemd/system/php-fpm.service
/etc/systemd/system/redis.service
/etc/profile.d/lnamp-php.sh
/etc/profile.d/lnamp-nginx.sh
/etc/ld.so.conf.d/nghttp2.conf
/etc/ld.so.conf.d/imagemagick.conf
/etc/my.cnf.d/zz-lnamp-bind.cnf
/root/.lnamp_probes
/root/.mysql_root_password
/root/.mariadb_root_password
/root/.redis_password
/home/wwwroot
/home/wwwlogs
/usr/local/memcached
/usr/local/node
/usr/local/memcached/etc/memcached.conf
/etc/profile.d/lnamp-memcached.sh
/etc/profile.d/lnamp-nodejs.sh
/usr/local/bin/composer
/usr/local/bin/node
/usr/local/bin/npm
/usr/local/bin/npx
/usr/local/bin/corepack
/usr/local/bin/memcached
/etc/fail2ban
/etc/fail2ban/jail.d/lnamp.local
/etc/systemd/system/memcached.service
/etc/systemd/system/fail2ban.service
/etc/logrotate.d/memcached
/etc/sysctl.d/99-lnamp.conf
/etc/security/limits.d/99-lnamp.conf
/etc/systemd/system.conf.d/99-lnamp.conf"

echo
echo "############ 干跑执行 (dry-run execution) ############"
# 基线：干跑之前就已存在的路径属于宿主机既有状态，不是本次干跑造成的，
# 不能算缺陷（否则审计会被环境状态干扰而误报，例如机器上本来就有 /etc/fail2ban）。
_audit_pre=""
while IFS= read -r _p; do
  [ -n "$_p" ] || continue
  [ -e "$_p" ] && _audit_pre="${_audit_pre}${_p}
"
done <<< "$_audit_list"

# ---- 已存在文件的内容指纹基线（防"干跑改写已有配置"）---------------------
# 只审计"路径是否新建"是不够的：干跑若把线上已有的配置文件改写了
# （例如 Redis 的 requirepass 被换成新随机密码，而干跑不重启服务），
# 会造成"配置密码 != 运行时密码"，客户端一律 WRONGPASS —— 路径依然存在，审计查不出来。
# 因此对关键配置文件记录内容指纹，干跑后逐一比对是否被改动。
_fingerprint_files="
/usr/local/redis/etc/redis.conf
/etc/redis/redis.conf
/etc/redis.conf
/etc/my.cnf
/etc/nginx/nginx.conf
/etc/php-fpm.conf
/etc/systemd/system/redis.service
/etc/systemd/system/mysqld.service
/etc/systemd/system/nginx.service
/root/.redis_password
/root/.mysql_root_password
"
_fp_before=""
while IFS= read -r _f; do
  [ -n "$_f" ] || continue
  [ -f "$_f" ] || continue
  _fp_before="${_fp_before}${_f}|$(cksum < "$_f" 2>/dev/null | awk '{print $1"-"$2}')
"
done <<< "$_fingerprint_files"

# 捕获干跑输出，便于事后断言"调优与镜像计划确实被打印了"
# （这台机器没装 composer，桩一个路径，让 composer 的干跑命令也能被打印出来）
_mirror_composer_bin(){ echo /usr/local/bin/composer; }
_mirror_npm_bin(){ echo /usr/local/bin/npm; }
_dry_out="$( { system_prep; echo; run_installs; } 2>&1 )"
printf '%s\n' "$_dry_out"

echo
echo "############ 副作用审计 (side-effect audit) ############"
# 干跑绝不能真的落地：只报"本次干跑新建"的路径，任何一条都是缺陷。
_audit_bad=0
while IFS= read -r _p; do
  [ -n "$_p" ] || continue
  if [ -e "$_p" ]; then
    if printf '%s\n' "$_audit_pre" | grep -Fxq "$_p"; then
      echo "  [pre-existing] 宿主机已存在(非本次干跑产生，不计缺陷): $_p"
    else
      echo "  [EXISTS] $_p   <-- 干跑不应创建"
      _audit_bad=$((_audit_bad + 1))
    fi
  else
    echo "  [ok] 未创建: $_p"
  fi
done <<< "$_audit_list"
if [ "$_audit_bad" = 0 ]; then
  echo "  ✅ 副作用审计通过：干跑未创建任何文件/目录"
else
  echo "  ❌ 副作用审计失败：$_audit_bad 个路径被创建"
fi

echo
echo "############ 已有文件内容改动审计 (existing-file mutation audit) ############"
# 干跑绝不能改写已存在的配置文件内容：这类改动最危险
# （Redis 的 requirepass 被换掉 -> 运行中实例与配置不一致 -> 客户端全部 WRONGPASS）。
_mut_bad=0
while IFS= read -r _f; do
  [ -n "$_f" ] || continue
  if [ ! -f "$_f" ]; then
    echo "  [ok] 未创建: $_f"
    continue
  fi
  _fp_now="$(cksum < "$_f" 2>/dev/null | awk '{print $1"-"$2}')"
  _fp_old="$(printf '%s\n' "$_fp_before" | grep -F "$_f|" | head -1 | cut -d'|' -f2)"
  if [ "$_fp_now" = "$_fp_old" ]; then
    echo "  [ok] 内容未被改写: $_f"
  else
    echo "  [MUTATED] $_f   <-- 干跑不应改写已有文件的内容"
    _mut_bad=$((_mut_bad + 1))
  fi
done <<< "$_fingerprint_files"
if [ "$_mut_bad" = 0 ]; then
  echo "  ✅ 内容审计通过：干跑未改写任何已有配置文件"
else
  echo "  ❌ 内容审计失败：${_mut_bad} 个已有文件被改写"
fi

echo
echo "############ 干跑内容断言 (content assertions) ############"
_assert_bad=0
_as() {
  if printf '%s' "$_dry_out" | grep -qF "$1"; then
    echo "  [ok] 干跑输出包含: $1"
  else
    echo "  [MISS] 干跑输出缺少: $1"
    _assert_bad=$((_assert_bad + 1))
  fi
}
_as "将写入内核参数"
_as "net.core.somaxconn = 65535"
_as "将写入 systemd 服务限制"
_as "将执行: sysctl --system"
_as "Composer/npm 包索引镜像 (package index mirrors, mode=cn)"
_as "config -g repo.packagist composer"
_as "config set registry"
if [ "$_assert_bad" = 0 ]; then
  echo "  ✅ 内容断言通过：调优与镜像计划均已进入干跑输出"
else
  echo "  ❌ 内容断言失败：$_assert_bad 项缺失"
fi

echo
echo "############ 干跑仿真结束 ############"
