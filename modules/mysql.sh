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
    log_run "mysql: 强制卸载 mariadb-libs" \
      sh -c 'rpm -e --nodeps "$(rpm -qa | grep -i mariadb-libs)"' </dev/null
  fi

  case "$mode" in
    source) _mysql_source "$ver" "$boost" ;;
    binary) _mysql_binary "$ver" "$glibc" ;;
    pkg)    _mysql_pkg "$ver" ;;
    *)      die "mysql: 未知形式 ${mode}" ;;
  esac
}

_mysql_common_post() {
  local ver="${1:-}"
  ensure_mysql_user
  # 监听地址由 db_enforce_bind_local 统一收敛到 127.0.0.1；防火墙端口单独由
  # db_open_ports 按清单放行（默认 3306,3360，可用 LNAMP_DB_PORTS 覆盖 /
  # LNAMP_DB_OPEN_PORTS=no 关闭）。两者分开：改监听不等于要开防火墙，反之亦然。
  # 升级走 swap_prefix_keep_data 时会跳过 _mysql_init_db，my.cnf 可能缺失，
  # 这里补写一份，否则 mysqld --defaults-file 指向空路径直接起不来。
  if [ -n "$ver" ] && [ ! -f "${MY_CNF_PATH}" ]; then
    write_my_cnf "${PREFIX_MYSQL}" "${PREFIX_MYSQL}/data" mysql "$ver"
  fi
  db_enforce_bind_local mysqld mysql
  db_open_ports
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
  dep cmake gcc gcc-c++ ncurses-devel bison openssl-devel libaio-devel numactl-libs wget perl perl-Module-Install
  ensure_mysql_user
  cd_src ~ "cd ~"

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
  cd_src "mysql-${ver}" "cd mysql src"

  local cmake_args=(-DCMAKE_INSTALL_PREFIX="${PREFIX_MYSQL}"
    -DMYSQL_DATADIR="${PREFIX_MYSQL}/data" -DSYSCONFDIR=/etc
    -DWITH_INNOBASE_STORAGE_ENGINE=1 -DWITH_PARTITION_STORAGE_ENGINE=1
    -DDEFAULT_CHARSET=utf8mb4 -DDEFAULT_COLLATION=utf8mb4_general_ci
    -DWITH_SSL=system -DENABLED_LOCAL_INFILE=1)
  [ "$boost" = "on" ] && cmake_args+=(-DWITH_BOOST="$HOME/mysql-${ver}/boost" -DDOWNLOAD_BOOST=1)

  log_run "cmake" cmake "${cmake_args[@]}"
  safe_mkdir "${PREFIX_MYSQL}"   # 确保目标目录(如 /data/mysql)存在
  log_run "make" make -j "${THREAD}" && log_run "make install" make install
  [ -x "${PREFIX_MYSQL}/bin/mysqld" ] || die "MySQL ${ver} 编译失败 (build failed)"

  _mysql_init_db "$ver"
  _mysql_register_service
  _mysql_common_post "$ver"
  cd ~ && safe_rm_rf "mysql-${ver}" "${pkg}.tar.gz"
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
    # Ubuntu 22: libaio1/libncurses5 ; Ubuntu 24: libaio1t64/libtinfo6
    # libnuma1 为两者共同必需（mysqld 链接 libnuma.so.1，缺失时 initialize 退出 127）
    # apt 整组安装任一包不存在即整体失败，故按 22.04 包名组 -> 24.04 t64 组 -> 仅 libnuma1 依次回退
    pkg_install libaio1 libncurses5 libnuma1 2>/dev/null \
      || pkg_install libaio1t64 libtinfo6 libnuma1 2>/dev/null \
      || pkg_install libnuma1 2>/dev/null
    [ "$ext" = tar.xz ] && pkg_install xz-utils
  else
    dep libaio libaio-devel numactl-libs ncurses-compat-libs wget
    [ "$ext" = tar.xz ] && pkg_install xz
  fi
  ensure_mysql_user
  # 重跑/重试时不必再下 800MB 并解压 1.5G：同版本已在位就跳过这两步。
  # 真机（221）上根分区只剩 1G，下载+解压必然失败；没有这个判断，重跑永远
  # 卡在同一步，而且没人知道其实程序文件早就齐了。
  if [ -x "${PREFIX_MYSQL}/bin/mysqld" ]; then
    local cur; cur=$("${PREFIX_MYSQL}/bin/mysqld" --version 2>/dev/null \
      | sed -n 's/.*[^0-9]\([0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*\).*/\1/p' | head -1)
    if [ "$cur" = "$ver" ]; then
      log "MySQL ${ver} 已在 ${PREFIX_MYSQL} (already installed) —— 跳过下载与解压"
      db_ensure_runtime_libs "${PREFIX_MYSQL}"
      if [ -d "${PREFIX_MYSQL}/data/mysql" ]; then
        log "数据目录已存在，跳过初始化 (datadir exists)"
      else
        _mysql_init_db "$ver"
      fi
      _mysql_register_service
      _mysql_common_post "$ver"
      return 0
    fi
  fi
  cd_src ~ "cd ~"
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
  # 新发行版(如 Ubuntu 24.04)缺 ncurses5 ABI / libaio.so.1 命名：先做运行时库兼容，否则 initialize 退出 127
  db_ensure_runtime_libs "$d"
  safe_mkdir "${PREFIX_MYSQL%/*}"   # 确保父目录(如 /data)存在，否则 mv 会失败
  # 升级时保留 datadir，只替换程序文件；全新安装则照常初始化
  if swap_prefix_keep_data "${PREFIX_MYSQL}" "$d" data; then
    log_warn "升级模式：跳过数据目录初始化（沿用原 datadir，不会动数据）"
  else
    _mysql_init_db "$ver"
  fi
  _mysql_register_service
  _mysql_common_post "$ver"
  cd ~ && safe_rm_rf "${pkg}.${ext}"
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
    ensure_epel
    pkg_install wget
    log_run "mysql: 安装官方 yum 源" \
      rpm -Uvh "https://repo.mysql.com/mysql${series}-community-release-el${OS_VER}.rpm" </dev/null
    pkg_install mysql-community-server
    enable_service mysqld
    # MySQL 社区版会在日志里生成临时密码，这里读取后改为随机密码
    _mysql_pkg_reset_rhel_password
  fi
  # 包管理器装的是发行版/官方仓库配置：MySQL 社区 RPM 不写 bind-address（默认
  # 监听全部网卡），必须收敛到回环。端口放行统一走 db_open_ports。
  db_enforce_bind_local mysqld mysql
  db_open_ports
  log_ok "MySQL (${PM}) 安装完成"
}

# RHEL 社区版 yum/dnf 安装后：读取临时密码并改为随机密码
_mysql_pkg_reset_rhel_password() {
  local sock=/tmp/mysql.sock tmp pass
  if [ "${DRY_RUN:-0}" = 1 ]; then
    log "  [dry-run] 将读取 /var/log/mysqld.log 临时密码并改为随机密码，保存到 /root/.mysql_root_password"
    return 0
  fi
  command -v mysql >/dev/null 2>&1 || { log_warn "mysql 客户端不可用，跳过自动重置 root 密码"; return 0; }
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
  safe_mkdir "${PREFIX_MYSQL}/data"
  log_run "mysql: 目录属主" chown -R mysql:mysql "${PREFIX_MYSQL}"
  write_my_cnf "${PREFIX_MYSQL}" "${PREFIX_MYSQL}/data" mysql "$ver"
  # 幂等：数据目录已经有系统表就跳过 initialize。
  # 重跑安装（比如上次在后面的步骤失败）时，对非空 datadir 再跑一次
  # --initialize-insecure 必然报错，容易让人误以为"库坏了"。
  if [ "${DRY_RUN:-0}" != "1" ] && [ -s "${PREFIX_MYSQL}/data/ibdata1" ] \
     && [ -n "$(ls -A "${PREFIX_MYSQL}/data/mysql" 2>/dev/null)" ]; then
    log "MySQL 数据目录已初始化 (already initialized)：${PREFIX_MYSQL}/data —— 跳过 initialize"
  else
    log_run "mysql: 初始化数据目录" \
      "${PREFIX_MYSQL}/bin/mysqld" --initialize-insecure \
      --user=mysql --basedir="${PREFIX_MYSQL}" --datadir="${PREFIX_MYSQL}/data"
  fi
  [ "${DRY_RUN:-0}" = 1 ] && return 0
  # initialize 失败（典型：缺 libnuma.so.1 退出 127）时 log_run 不阻断，
  # 这里以"系统表 + 共享表空间是否生成"为准校验，未生成即中止安装，避免带着坏 datadir 继续。
  local dd="${PREFIX_MYSQL}/data"
  if [ ! -d "${dd}/mysql" ] || [ ! -f "${dd}/ibdata1" ]; then
    die_with_log "MySQL 数据目录初始化失败或数据字典不完整 (initialize failed)：${dd} 缺少系统表，请检查上方构建日志；Debian/Ubuntu 确认已装 libaio1(或 libaio1t64)/libnuma1/libtinfo6，RHEL 确认 libaio/numactl-libs/ncurses-compat-libs"
  fi
  # 上面那两条**不足以**证明初始化真的成功了：磁盘在 initialize 中途写满时，
  # data/mysql 目录和 ibdata1 都已经存在，但数据字典没写完 —— mysqld 启动时才报
  #   [ERROR] [MY-011096] No data dictionary version number found.
  #   [ERROR] [MY-010020] Data Dictionary initialization failed.
  # 真机（229，17G 盘）就是这么留下一个"看起来装好了、其实起不来"的 MySQL。
  # 但判定依据**必须按版本区分**：
  #   · MySQL 8.0+：数据字典是独立的 InnoDB 表空间 mysql.ibd，redo 在 #innodb_redo/
  #   · MySQL 5.7 及以前：没有 mysql.ibd（数据字典就是 data/mysql/*.frm），
  #     redo 是 ib_logfile*
  # 最初只按 8.x 判，结果 5.7 明明初始化成功（ibdata1 12MB + mysql/*.frm 齐全）
  # 也被判成"数据字典未生成"（真机 181 因此装完 PHP 后卡在 MySQL）。
  local _mymajor="${ver%%.*}"
  if [ "${_mymajor:-0}" -ge 8 ] 2>/dev/null; then
    if [ ! -f "${dd}/mysql.ibd" ]; then
      die_with_log "MySQL 数据字典未生成 (${dd}/mysql.ibd 缺失)：initialize 多半因磁盘空间不足中断，请清理后重跑（建议 ≥2GB 可用空间）"
    fi
    if [ -d "${dd}/#innodb_redo" ] && [ -z "$(ls -A "${dd}/#innodb_redo" 2>/dev/null)" ]; then
      die_with_log "MySQL redo log 未生成（${dd}/#innodb_redo 为空）：initialize 被中断，请清理磁盘后重跑"
    fi
  else
    # 5.x：系统表 .frm 必须存在（initialize 会写 mysql/user.frm 等），redo 为 ib_logfile*
    if [ ! -f "${dd}/ibdata1" ] || ! ls "${dd}"/mysql/*.frm >/dev/null 2>&1; then
      die_with_log "MySQL 5.x 初始化不完整（缺少 ${dd}/ibdata1 或 ${dd}/mysql/*.frm）：请检查上方 initialize 输出；Debian/Ubuntu 确认已装 libaio1/libtinfo5，RHEL 确认 libaio/ncurses-compat-libs"
    fi
  fi
}

_mysql_register_service() {
  save_file "${SYSTEMD_DIR}/mysqld.service" <<EOF
[Unit]
Description=MySQL Server
After=network.target

[Service]
User=mysql
Group=mysql
ExecStart=${PREFIX_MYSQL}/bin/mysqld --defaults-file=${MY_CNF_PATH}
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF
  enable_service mysqld
  # 日志轮转：错误日志 + 慢查询日志（my.cnf 里 log_error / slow_query_log_file 指向 datadir）
  setup_logrotate mysqld "${PREFIX_MYSQL}/data/*.log" "" "su mysql mysql"
}
