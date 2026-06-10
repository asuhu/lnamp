#!/bin/bash
# ============================================================================
#  modules/phpmyadmin.sh —— 安装 phpMyAdmin 到默认站点 (${WWWROOT}/web/phpMyAdmin)
#  固定版本 5.2.3（需 PHP 7.2+）。优化自用户脚本：镜像兜底下载、32 位随机
#  blowfish_secret、upload/save 目录、权限收紧、setup 目录锁定。
#  访问: http://<域名或IP>/phpMyAdmin/
# ============================================================================

# 生成 32 位 blowfish_secret（phpMyAdmin 要求至少 32 字节）
_pma_secret() {
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -hex 16
  else
    head -c 64 /dev/urandom | md5sum | head -c 32
  fi
}

install_phpmyadmin() {
  local webdir="${WWWROOT}/web"
  local ver="${PMA_VERSION:-5.2.3}"
  if [ ! -x "${PREFIX_PHP}/bin/php" ] && ! command -v php >/dev/null 2>&1; then
    log_warn "未检测到 PHP；phpMyAdmin 需 PHP 才能运行，将继续安装文件，请确保已/将安装 PHP。"
  fi
  mkdir -p "$webdir"
  log "安装 phpMyAdmin ${ver} -> ${webdir}/phpMyAdmin"

  cd "$webdir" || die "phpMyAdmin: 无法进入 ${webdir}"
  local pkg="phpMyAdmin-${ver}-all-languages"
  fetch "${pkg}.tar.gz" "https://files.phpmyadmin.net/phpMyAdmin/${ver}/${pkg}.tar.gz" \
    || die_with_log "phpMyAdmin ${ver} 下载失败"

  # 1) 解压并重命名为 phpMyAdmin（动态探测解压目录名，不假设固定命名）
  local d; d=$(tar -tzf "${pkg}.tar.gz" 2>/dev/null | head -1 | cut -d/ -f1)
  [ -n "$d" ] || d="$pkg"
  rm -rf phpMyAdmin "$d"
  tar -zxf "${pkg}.tar.gz" || die "phpMyAdmin 解包失败"
  rm -f "${pkg}.tar.gz"
  [ -d "$d" ] || die "phpMyAdmin: 解压目录 ${d} 未找到"
  mv "$d" phpMyAdmin
  cd phpMyAdmin || die "cd phpMyAdmin"

  # 2) 复制配置样例 config.sample.inc.php -> config.inc.php
  [ -f config.sample.inc.php ] || die "phpMyAdmin: 未找到 config.sample.inc.php"
  cp -f config.sample.inc.php config.inc.php

  # 3) 安全初始化 config.inc.php
  mkdir -p upload save
  local secret; secret=$(_pma_secret)
  # 3a) blowfish_secret（cookie 认证必需，需 ≥32 字节）：有该行则替换，无则在文件头部插入
  if grep -q "blowfish_secret" config.inc.php; then
    sed -i "s@\$cfg\['blowfish_secret'\] = '[^']*';@\$cfg['blowfish_secret'] = '${secret}';@" config.inc.php
    # 3b) 紧随 blowfish 行后插入 UploadDir/SaveDir（全局项，避免追加到文件尾可能落在 ?> 之后失效）
    grep -q "\$cfg\['UploadDir'\]" config.inc.php || \
      sed -i "/blowfish_secret'\] = /a \$cfg['UploadDir'] = 'upload';\n\$cfg['SaveDir'] = 'save';" config.inc.php
  else
    sed -i "1a \$cfg['blowfish_secret'] = '${secret}';\n\$cfg['UploadDir'] = 'upload';\n\$cfg['SaveDir'] = 'save';" config.inc.php
  fi
  # 3c) 移除 web 安装向导 setup 目录（安全建议）
  rm -rf setup
  # 3d) 属主与权限：config.inc.php 仅属主可读写
  ensure_www_user 2>/dev/null || ensure_sysuser www 2>/dev/null || true
  chown -R www:www "${webdir}/phpMyAdmin" 2>/dev/null || true
  chmod 640 "${webdir}/phpMyAdmin/config.inc.php" 2>/dev/null || true
  # 3e) 校验 blowfish_secret 已写入（非空且 ≥32）
  local bf; bf=$(grep -oE "blowfish_secret'\] = '[^']*'" config.inc.php | head -1 | sed -E "s/.*'([^']*)'\$/\1/")
  if [ "${#bf}" -ge 32 ]; then
    log_ok "config.inc.php 安全初始化完成 (blowfish_secret ${#bf} 字符, setup 已移除)"
  else
    log_warn "blowfish_secret 可能未正确写入，请检查 ${webdir}/phpMyAdmin/config.inc.php"
  fi

  hr
  log_ok "phpMyAdmin ${ver} 安装完成"
  log_ok "  访问地址 (access): http://<你的域名或IP>/phpMyAdmin/"
  log_ok "  用 MySQL/MariaDB 的 root 及密码登录（密码见 /root/.mysql_root_password 或 .mariadb_root_password）"
  hr
}
