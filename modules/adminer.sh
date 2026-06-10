#!/bin/bash
# ============================================================================
#  modules/adminer.sh —— 安装 Adminer（轻量级单文件数据库管理工具）
#  https://github.com/vrana/adminer  默认 5.4.2（单个 PHP 文件，~470KB，需 PHP 7.4+）
#  装到默认站点 ${WWWROOT}/web/adminer/index.php，访问 http://<域名或IP>/adminer/
#  是 phpMyAdmin 的轻量替代品。
# ============================================================================

install_adminer() {
  local webdir="${WWWROOT}/web" ver="${ADMINER_VERSION:-5.4.2}"
  if [ ! -x "${PREFIX_PHP}/bin/php" ] && ! command -v php >/dev/null 2>&1; then
    log_warn "未检测到 PHP；Adminer 需要 PHP 才能运行，将继续安装文件，请确保已/将安装 PHP。"
  fi
  mkdir -p "${webdir}/adminer"
  log "安装 Adminer ${ver} -> ${webdir}/adminer/index.php"

  cd "${webdir}/adminer" || die "Adminer: 无法进入 ${webdir}/adminer"
  # GitHub release 资产 + adminer.org 官方下载 + 镜像兜底
  fetch "adminer-${ver}.php" \
    "https://github.com/vrana/adminer/releases/download/v${ver}/adminer-${ver}.php" \
    "https://www.adminer.org/static/download/${ver}/adminer-${ver}.php" \
    || die_with_log "Adminer ${ver} 下载失败"
  mv -f "adminer-${ver}.php" index.php

  ensure_www_user 2>/dev/null || ensure_sysuser www 2>/dev/null || true
  chown -R www:www "${webdir}/adminer" 2>/dev/null || true
  chmod 644 "${webdir}/adminer/index.php" 2>/dev/null || true

  hr
  log_ok "Adminer ${ver} 安装完成（轻量级，单文件）"
  log_ok "  访问地址 (access): http://<你的域名或IP>/adminer/"
  log_ok "  用 MySQL/MariaDB 账号密码登录（root 密码见 /root/.mysql_root_password 或 .mariadb_root_password）"
  hr
}
