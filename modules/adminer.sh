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
  safe_mkdir "${webdir}/adminer"
  log "安装 Adminer ${ver} -> ${webdir}/adminer/index.php"

  cd_src "${webdir}/adminer" "Adminer: 无法进入 ${webdir}/adminer"
  # 下载 + 内容校验（2026-10 实测）：adminer.org 的 /static/download/<ver>/ 路径已 404
  # （官网只提供 latest.php 与 GitHub release 两个下载口），曾返回介绍页 HTML（约 2.7KB）
  # 而 wget 退出码是 0，单看退出码会把 HTML 当单文件落地。这里逐个源下载后校验
  # 「以 <?php 开头且足够大」，不合格就删掉换下一个源；GitHub release 放在首位（实测最稳）。
  # 注：多台真机 GitHub 不通（超时）时全源皆可能失败 —— 最稳兜底是把已验证的
  # adminer-${ver}.php 放进 <安装器目录>/packages/（fetch 本地缓存优先，命中即不联网）。
  local src ok=0
  if [ "${DRY_RUN:-0}" = 1 ]; then
    # 干跑只列源，不下载、不落盘 —— 否则会真的写出 index.php 污染工作目录
    for src in \
      "https://github.com/vrana/adminer/releases/download/v${ver}/adminer-${ver}.php" \
      "https://www.zhangfangzhou.cn/third/adminer-${ver}.php"; do
      log "  [dry-run] 将下载并校验单文件: adminer-${ver}.php  <-  ${src}"
    done
    log "  [dry-run] 将落地到 ${webdir}/adminer/index.php"
  else
    for src in \
      "https://github.com/vrana/adminer/releases/download/v${ver}/adminer-${ver}.php" \
      "https://www.zhangfangzhou.cn/third/adminer-${ver}.php" \
      "https://www.zhangfangzhou.cn/third/so/adminer-${ver}.php"; do
      fetch "adminer-${ver}.php" "$src" || continue
      if [ "$(head -c 5 "adminer-${ver}.php" 2>/dev/null)" = "<?php" ] \
         && [ "$(stat -c %s "adminer-${ver}.php" 2>/dev/null || echo 0)" -gt 102400 ]; then
        ok=1; break
      fi
      log_warn "该源返回的不是有效 Adminer 单文件（可能是跳转/介绍页），换下一个源: ${src}"
      rm -f "adminer-${ver}.php"
    done
    [ "$ok" = 1 ] || die_with_log "Adminer ${ver} 下载失败（所有源均未取得有效的单文件）"
    mv -f "adminer-${ver}.php" index.php
  fi

  ensure_www_user 2>/dev/null || ensure_sysuser www 2>/dev/null || true
  chown -R www:www "${webdir}/adminer" 2>/dev/null || true
  chmod 644 "${webdir}/adminer/index.php" 2>/dev/null || true

  hr
  log_ok "Adminer ${ver} 安装完成（轻量级，单文件）"
  log_ok "  访问地址 (access): http://<你的域名或IP>/adminer/"
  log_ok "  用 MySQL/MariaDB 账号密码登录（root 密码见 /root/.mysql_root_password 或 .mariadb_root_password）"
  hr
}
