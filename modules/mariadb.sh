#!/bin/bash
# ============================================================================
#  modules/mariadb.sh  ——  MariaDB 安装模块
#  install_mariadb <version> <mode>     mode = binary | pkg
#  版本: 11.8.x (LTS)
#  binary -> 官方 linux-systemd 二进制包，安装到 /data/mariadb (basedir)
#  pkg    -> MariaDB 官方仓库(指定 11.8 系列) 或发行版自带包
#  与 MySQL 互斥（二者择一），互斥校验在 install.sh 中完成。
# ============================================================================

install_mariadb() {
  local ver="$1" mode="$2"
  local meta min_mem
  meta=$(manifest_lookup MARIADB "$ver"); meta="${meta#*|}"
  min_mem=$(meta_get "$meta" min_mem)

  detect_mem
  if [ "${min_mem:-0}" -gt 0 ] && [ "$MEM_MB" -lt "$min_mem" ]; then
    die "MariaDB ${ver} (${mode}) 需要至少 ${min_mem}MB 内存 (current ${MEM_MB}MB)"
  fi
  log "安装 MariaDB ${ver}  形式(mode)=${mode}"

  # 清理可能冲突的发行版自带 DB
  if [ "$OS_FAMILY" = debian ]; then
    pkg_remove mysql-server mariadb-server
  else
    pkg_remove mariadb-libs
  fi

  case "$mode" in
    binary) _mariadb_binary "$ver" ;;
    pkg)    _mariadb_pkg "$ver" ;;
    *)      die "mariadb: 未知形式 ${mode}" ;;
  esac
}

ensure_mysql_user() { ensure_sysuser mysql; }

# ---------------------------------------------------------------------------
# 官方二进制 (linux-systemd tarball)
# ---------------------------------------------------------------------------
_mariadb_binary() {
  local ver="$1"
  if [ "$OS_FAMILY" = debian ]; then
    pkg_update
    pkg_install libaio1 libncurses5 libnuma1 2>/dev/null
    pkg_install libaio1t64 libtinfo6 2>/dev/null
  else
    dep libaio libaio-devel ncurses-compat-libs numactl-libs wget
  fi
  ensure_mysql_user
  cd_src ~ "cd ~"

  # 下载地址分类（generic 二进制 tarball，安装到 /data/mariadb）：
  #   archive.mariadb.org —— 官方永久归档，保留全部历史版本，路径稳定，作首选
  #   (downloads.mariadb.com / legacy-downloads.mariadb.com 现 302 跳转到下载页，
  #    直链已失效，wget 会抓到 HTML，故不再使用；
  #    dlm.mariadb.com 的 *-debs.tar / *-rpms.tar 是带动态 ID 的仓库包，不适合脚本直链)
  local pkg="mariadb-${ver}-linux-systemd-x86_64"
  fetch "${pkg}.tar.gz" \
    "https://archive.mariadb.org/mariadb-${ver}/bintar-linux-systemd-x86_64/${pkg}.tar.gz" \
    || die "下载失败 (download failed): ${pkg}.tar.gz"
  tar -zxf "${pkg}.tar.gz"
  # 新发行版(如 Ubuntu 24.04)缺 libaio.so.1 等运行时库：先兼容处理，否则 install-db 退出 127
  db_ensure_runtime_libs "$pkg"
  safe_mkdir "${PREFIX_MARIADB%/*}"   # 确保父目录(如 /data)存在，否则 mv 会失败
  local _keep_data=0
  if swap_prefix_keep_data "${PREFIX_MARIADB}" "${pkg}" data; then
    _keep_data=1
    log_warn "升级模式：跳过数据目录初始化（沿用原 datadir，不会动数据）"
  fi

  safe_mkdir "${PREFIX_MARIADB}/data"
  log_run "mariadb: 目录属主" chown -R mysql:mysql "${PREFIX_MARIADB}"
  write_my_cnf "${PREFIX_MARIADB}" "${PREFIX_MARIADB}/data" mariadb "$ver"

  # 初始化数据目录（MariaDB 使用 mariadb-install-db / mysql_install_db）
  if [ "$_keep_data" = 0 ]; then
    local initdb="${PREFIX_MARIADB}/scripts/mariadb-install-db"
    [ -x "$initdb" ] || initdb="${PREFIX_MARIADB}/scripts/mysql_install_db"
    "$initdb" --user=mysql --basedir="${PREFIX_MARIADB}" --datadir="${PREFIX_MARIADB}/data"
  fi

  _mariadb_register_service
  # 监听收敛到 127.0.0.1；防火墙端口按清单放行（默认 3306,3360）
  db_enforce_bind_local mariadb mysql
  db_open_ports
  register_path mariadb "${PREFIX_MARIADB}/bin" mariadb mariadbd mariadb-admin mariadb-dump mysql
  cd ~ && safe_rm_rf "${pkg}.tar.gz"
  # 自动设置随机 root 密码（MariaDB 初始为 socket 认证，可直接改）
  db_set_random_root_password "${PREFIX_MARIADB}/bin/mariadb" "/root/.mariadb_root_password" "MariaDB"
  log_ok "MariaDB ${ver} (binary) 安装完成。"
}

# ---------------------------------------------------------------------------
# 包管理器 (MariaDB 官方仓库，按 11.8 系列；失败回落发行版自带包)
# ---------------------------------------------------------------------------
_mariadb_pkg() {
  local ver="$1" series="${ver%.*}"   # 11.8.6 -> 11.8
  command -v curl >/dev/null 2>&1 || pkg_install curl
  # MariaDB 官方仓库配置脚本（跨发行版）
  if [ "${DRY_RUN:-0}" = 1 ]; then
    log "  [dry-run] 将执行 MariaDB 官方仓库配置脚本 (mariadb_repo_setup, series=${series})"
  else
    curl -LsS https://r.mariadb.com/downloads/mariadb_repo_setup 2>/dev/null | \
      bash -s -- --mariadb-server-version="mariadb-${series}" >/dev/null 2>&1 || \
      log_warn "MariaDB 官方仓库脚本不可用，改用发行版自带版本"
  fi

  if [ "$OS_FAMILY" = debian ]; then
    pkg_update
    pkg_install mariadb-server
    enable_service mariadb
  else
    pkg_install MariaDB-server || pkg_install mariadb-server
    enable_service mariadb || enable_service mariadb
  fi
  # 官方仓库的 server.cnf 写的是 bind-address=0.0.0.0，安装后必须收敛到回环
  db_enforce_bind_local mariadb mysql
  db_open_ports
  # 自动设置随机 root 密码
  local client; client=$(command -v mariadb || command -v mysql)
  db_set_random_root_password "$client" "/root/.mariadb_root_password" "MariaDB"
  log_ok "MariaDB (${PM}) 安装完成。"
}

_mariadb_register_service() {
  save_file "${SYSTEMD_DIR}/mariadb.service" <<EOF
[Unit]
Description=MariaDB Server
After=network.target

[Service]
User=mysql
Group=mysql
ExecStart=${PREFIX_MARIADB}/bin/mariadbd --defaults-file=${MY_CNF_PATH} --user=mysql
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF
  enable_service mariadb
  # 日志轮转：错误日志 + 慢查询日志（my.cnf 里 log_error / slow_query_log_file 指向 datadir）
  setup_logrotate mysqld "${PREFIX_MARIADB}/data/*.log" "" "su mysql mysql"
}
