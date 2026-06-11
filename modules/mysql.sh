#!/bin/bash
# ============================================================================
#  modules/mysql.sh  ——  MySQL 安装模块
#  install_mysql <version> <mode>     mode = source | binary | pkg
#  版本: 5.6.51 / 5.7.43 / 5.7.44
#  合并了原 mysql.sh(5.6源码) / mysql5.7.sh(源码) / mysql5.7_binary.sh / yum_mysql5.7.sh
# ============================================================================

install_mysql() {
  local ver="$1" mode="$2"
  local meta min_mem boost glibc
  meta=$(manifest_lookup MYSQL "$ver"); meta="${meta#*|}"
  min_mem=$(meta_get "$meta" min_mem); boost=$(meta_get "$meta" boost); glibc=$(meta_get "$meta" glibc)

  detect_mem
  if [ "${min_mem:-0}" -gt 0 ] && [ "$MEM_MB" -lt "$min_mem" ]; then
    die "MySQL ${ver} (${mode}) 需要至少 ${min_mem}MB 内存 (current ${MEM_MB}MB)"
  fi
  log "安装 MySQL ${ver}  形式(mode)=${mode}"

  # 清理可能冲突的发行版自带 DB
  if [ "$OS_FAMILY" = debian ]; then
    pkg_remove mariadb-server mariadb-common mysql-server
  else
    pkg_remove mariadb-libs
    rpm -e --nodeps "$(rpm -qa | grep -i mariadb-libs)" >/dev/null 2>&1
  fi

  case "$mode" in
    source) _mysql_source "$ver" "$boost" ;;
    binary) _mysql_binary "$ver" "$glibc" ;;
    pkg)    _mysql_pkg "$ver" ;;
    *)      die "mysql: 未知形式 ${mode}" ;;
  esac
}

_mysql_common_post() {
  ensure_mysql_user
  open_ports "3306"
  register_path mysql "${PREFIX_MYSQL}/bin" mysql mysqld mysqladmin mysqldump
  # 自动设置随机 root 密码（源码/二进制安装：root 初始为空密码）
  db_set_random_root_password "${PREFIX_MYSQL}/bin/mysql" "/root/.mysql_root_password" "MySQL"
  log_ok "MySQL 安装完成。"
}

ensure_mysql_user() { ensure_sysuser mysql; }

# ---------------------------------------------------------------------------
# 源码编译 (cmake)
# ---------------------------------------------------------------------------
_mysql_source() {
  local ver="$1" boost="$2"
  if [ "$OS_FAMILY" = debian ]; then pkg_update; pkg_install build-essential pkg-config; fi
  dep cmake gcc gcc-c++ ncurses-devel bison openssl-devel libaio-devel wget perl perl-Module-Install
  ensure_mysql_user
  cd ~ || die "cd ~"

  local pkg
  if [ "$boost" = "on" ]; then
    pkg="mysql-boost-${ver}"
    fetch "${pkg}.tar.gz" "http://cdn.mysql.com/Downloads/MySQL-${ver%.*}/${pkg}.tar.gz" \
      || die "下载失败 (download failed): ${pkg}.tar.gz"
  else
    pkg="mysql-${ver}"
    fetch "${pkg}.tar.gz" "http://cdn.mysql.com/Downloads/MySQL-${ver%.*}/${pkg}.tar.gz" \
      || die "下载失败 (download failed): ${pkg}.tar.gz"
  fi
  tar -zxf "${pkg}.tar.gz"
  cd "mysql-${ver}" || die "cd mysql src"

  local cmake_args=(-DCMAKE_INSTALL_PREFIX="${PREFIX_MYSQL}"
    -DMYSQL_DATADIR="${PREFIX_MYSQL}/data" -DSYSCONFDIR=/etc
    -DWITH_INNOBASE_STORAGE_ENGINE=1 -DWITH_PARTITION_STORAGE_ENGINE=1
    -DDEFAULT_CHARSET=utf8mb4 -DDEFAULT_COLLATION=utf8mb4_general_ci
    -DWITH_SSL=system -DENABLED_LOCAL_INFILE=1)
  [ "$boost" = "on" ] && cmake_args+=(-DWITH_BOOST="$HOME/mysql-${ver}/boost" -DDOWNLOAD_BOOST=1)

  cmake "${cmake_args[@]}"
  mkdir -p "${PREFIX_MYSQL}"   # 确保目标目录(如 /data/mysql)存在
  make -j "${THREAD}" && make install
  [ -x "${PREFIX_MYSQL}/bin/mysqld" ] || die "MySQL ${ver} 编译失败 (build failed)"

  _mysql_init_db "$ver"
  _mysql_register_service
  _mysql_common_post
  cd ~ && rm -rf "mysql-${ver}" "${pkg}.tar.gz"
}

# ---------------------------------------------------------------------------
# 官方二进制 (binary tarball)
# ---------------------------------------------------------------------------
_mysql_binary() {
  local ver="$1" glibc="$2" meta ext
  meta=$(manifest_lookup MYSQL "$ver"); meta="${meta#*|}"
  ext=$(meta_get "$meta" ext); [ -z "$ext" ] && ext=tar.gz
  if [ "$OS_FAMILY" = debian ]; then
    pkg_update
    # Ubuntu 22: libaio1 / libncurses5 ; Ubuntu 24: libaio1t64 / libtinfo6
    pkg_install libaio1 libncurses5 2>/dev/null
    pkg_install libaio1t64 libtinfo6 2>/dev/null
    pkg_install libaio1 2>/dev/null
    [ "$ext" = tar.xz ] && pkg_install xz-utils
  else
    dep libaio libaio-devel ncurses-compat-libs wget
    [ "$ext" = tar.xz ] && pkg_install xz
  fi
  ensure_mysql_user
  cd ~ || die "cd ~"
  # 依次尝试多个 glibc 变体（清单指定的优先），兼容 8.x(glibc2.17) 与 9.x(glibc2.28)
  local base="https://cdn.mysql.com/Downloads/MySQL-${ver%.*}" g cand pkg=""
  for g in "$glibc" glibc2.28 glibc2.17 glibc2.12; do
    [ -z "$g" ] && continue
    cand="mysql-${ver}-linux-${g}-x86_64"
    if fetch "${cand}.${ext}" "${base}/${cand}.${ext}"; then pkg="$cand"; break; fi
  done
  [ -n "$pkg" ] || die "下载失败 (download failed): mysql-${ver} 各 glibc 变体均不可用"
  # MySQL 8.x/9.x 为 .tar.xz，5.7 为 .tar.gz
  case "$ext" in
    tar.xz) tar -Jxf "${pkg}.${ext}" ;;
    *)      tar -zxf "${pkg}.${ext}" ;;
  esac
  # 解压目录名以实际包名为准（动态探测，避免 glibc 变体导致目录名不一致）
  local d; d=$(tar -tf "${pkg}.${ext}" 2>/dev/null | head -1 | cut -d/ -f1); [ -n "$d" ] || d="$pkg"
  mkdir -p "${PREFIX_MYSQL%/*}"   # 确保父目录(如 /data)存在，否则 mv 会失败
  rm -rf "${PREFIX_MYSQL}"; mv "$d" "${PREFIX_MYSQL}"

  _mysql_init_db "$ver"
  _mysql_register_service
  _mysql_common_post
  cd ~ && rm -rf "${pkg}.${ext}"
}

# ---------------------------------------------------------------------------
# 包管理器安装 (OS package manager)
#   rhel  -> MySQL 官方社区仓库 (el7/8/9)
#   debian-> 发行版自带 mysql-server (版本由发行版决定，可能与所选版本号不同)
# ---------------------------------------------------------------------------
_mysql_pkg() {
  local ver="$1" series
  series="${ver%.*}"; series="${series/./}"   # 5.7 -> 57
  if [ "$OS_FAMILY" = debian ]; then
    pkg_update
    pkg_install mysql-server || pkg_install default-mysql-server
    enable_service mysql
    log_warn "Debian/Ubuntu 通过 apt 安装的 MySQL 版本由发行版决定，可能并非 ${ver}"
    # Debian 的 root 默认走 auth_socket，可直接设随机密码
    db_set_random_root_password "$(command -v mysql)" "/root/.mysql_root_password" "MySQL"
  else
    pkg_install epel-release wget
    rpm -Uvh "https://repo.mysql.com/mysql${series}-community-release-el${OS_VER}.rpm" 2>/dev/null
    pkg_install mysql-community-server
    enable_service mysqld
    # MySQL 社区版会在日志里生成临时密码，这里读取后改为随机密码
    _mysql_pkg_reset_rhel_password
  fi
  open_ports "3306"
  log_ok "MySQL (${PM}) 安装完成"
}

# RHEL 社区版 yum/dnf 安装后：读取临时密码并改为随机密码
_mysql_pkg_reset_rhel_password() {
  local sock=/tmp/mysql.sock tmp pass
  _db_wait_socket "$sock" || { log_warn "mysqld 未就绪，临时密码见 /var/log/mysqld.log"; return 0; }
  tmp=$(grep 'temporary password' /var/log/mysqld.log 2>/dev/null | tail -1 | awk '{print $NF}')
  pass=$(gen_password)
  if [ -n "$tmp" ] && mysql --connect-expired-password -uroot -p"$tmp" \
        -e "ALTER USER 'root'@'localhost' IDENTIFIED BY '${pass}'; FLUSH PRIVILEGES;" 2>/dev/null; then
    ( umask 077; printf 'MySQL root 密码 (password): %s\n生成时间: %s\n' "$pass" "$(date)" > /root/.mysql_root_password )
    chmod 600 /root/.mysql_root_password
    hr; log_ok "MySQL 已自动设置随机 root 密码: ${pass}  (保存于 /root/.mysql_root_password)"; hr
  else
    log_warn "未能自动重置 root 密码，临时密码见: grep 'temporary password' /var/log/mysqld.log"
  fi
}

# 初始化数据目录 (源码/二进制共用)
_mysql_init_db() {
  local ver="$1"
  mkdir -p "${PREFIX_MYSQL}/data"
  chown -R mysql:mysql "${PREFIX_MYSQL}"
  write_my_cnf "${PREFIX_MYSQL}" "${PREFIX_MYSQL}/data" mysql "$ver"
  "${PREFIX_MYSQL}/bin/mysqld" --initialize-insecure \
    --user=mysql --basedir="${PREFIX_MYSQL}" --datadir="${PREFIX_MYSQL}/data"
}

_mysql_register_service() {
  cat > "${SYSTEMD_DIR}/mysqld.service" <<EOF
[Unit]
Description=MySQL Server
After=network.target

[Service]
User=mysql
Group=mysql
ExecStart=${PREFIX_MYSQL}/bin/mysqld --defaults-file=/etc/my.cnf
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF
  enable_service mysqld
}
