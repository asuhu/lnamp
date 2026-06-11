# LNAMP 安装器（重构版）

Nginx · Apache · PHP · MySQL 一键安装脚本。本次重构的核心目标：**让每个组件都能自由选择「版本」和「安装形式」**，同时消除原脚本里大量的重复代码。

> **支持系统**：CentOS / RHEL 7、Rocky / AlmaLinux / RHEL 8 9、Ubuntu 22.04 / 24.04（自动识别发行版、包管理器与 init 系统）。**已停止支持 CentOS/RHEL 6。**

---

## 1. 这次重构改了什么

### 重构前的问题
原项目是「一个组合 = 一个脚本」的结构，例如：

```
php5.sh  php7.sh  php73.sh  php74.sh  php82.sh        # PHP 各版本各一份
php5apache.sh  php7apache.sh                          # 同版本换个 SAPI 又一份
mysql.sh  mysql5.7.sh  mysql5.7_binary.sh  yum_mysql5.7.sh  # 同理
nginx.sh  yum_nginx.sh   apache.sh  apache_openssl.sh
```

带来的麻烦：
- **版本写死在脚本里**（`sqlstable=5.6.51`、`php74_ver=7.4.33`…），想换版本要改源码。
- **大量复制粘贴**：内存分级逻辑在每个 `php*.sh` 里重复 6 次；系统检测、带回落的下载、防火墙、www 用户创建等到处都是副本。
- `install.sh` 用一串 `if [ "$PHP_version" == '4' ]` 硬编码菜单与文件名映射，难以扩展。

### 重构后的结构
```
install.sh            # 唯一入口：菜单 / 命令行 / 系统准备 / 调度
versions.conf         # ★版本清单（选版本、选形式都在这里声明）
lib/
  common.sh           # 公共函数：系统检测/内存分级/下载/防火墙/清单解析…
modules/
  deps.sh             # 编译期公共依赖：nghttp2 / openssl / libsodium / argon2 / mcrypt
  nginx.sh            # install_nginx  <版本> <形式>
  apache.sh           # install_apache <版本> <形式>
  php.sh              # install_php    <版本> <形式>
  mysql.sh            # install_mysql  <版本> <形式>
conf/                 # 原仓库的配置模板与 init 脚本（沿用）
```

关键思想：**组件模块只负责「怎么装」，版本与形式由 `versions.conf` 声明、由 `install.sh` 选择并传入。**

### 本次新增：多发行版支持
`lib/common.sh` 新增了一层**操作系统抽象层**，把发行版差异收敛到一处：

- `detect_os` 通过 `/etc/os-release` 识别发行版，得出 `OS_FAMILY`(rhel/debian)、`OS_VER`、包管理器 `PM`(yum/dnf/apt-get)、是否 `HAS_SYSTEMD`。所有受支持系统均使用 systemd；RHEL 系 6 及更早版本会被明确拒绝。
- `pkg_install / pkg_remove / pkg_update` 统一封装包管理器；`dep` 函数把「以 RHEL 命名为基准的逻辑依赖名」自动翻译成各发行版实际包名（如 `zlib-devel` → Ubuntu 的 `zlib1g-dev`）。
- `open_ports` 自动选择 firewalld(rhel) / ufw(debian)；`enable_service` 统一走 systemd。
- RHEL 8/9 自动启用 CRB/PowerTools 仓库以获取 `libzip-devel` 等开发包。

模块里所有 `yum -y install ...` 已替换为 `dep ...` 或 `pkg_install ...`，因此同一套源码编译逻辑可在 CentOS、Rocky、Ubuntu 上通用。

> **形式更名**：原先的 `yum` 形式已更名为 `pkg`（含义是「用系统自带包管理器安装」，在 Ubuntu 上即 apt），语义更准确。旧写法 `:yum` 仍被接受并自动转换为 `:pkg`。

---

## 2. 「版本」与「形式」对照表

| 组件 | 可选版本 | 可选形式 (mode) |
|------|----------|------------------|
| Nginx/Tengine | nginx 1.30.2 / 1.26.2 / 1.24.0 ; tengine-3.1.0 | `source` · `pkg`（tengine 仅 `source`，并开启 `--with-http_upstream_check_module`）|
| Apache | 2.4.67 | `source`(event+HTTP2) · `pkg` |
| PHP（已取消 PHP5） | 8.5.6 / 8.4.22 / 8.3.31 / 8.2.14 / 7.4.33 | `fpm`(配合 Nginx，监听 Unix socket) · `apache`(mod_php 模块)。fileinfo 默认启用；ImageMagick(imagick) 可选 |
| MySQL  | 9.7.0(LTS) / 8.4.9(LTS) / 8.0.46 / 5.7.44 | `source`(cmake，仅 5.x) · `binary`(官方二进制) · `pkg`(仓库)。数据存放 `/data/mysql` |
| MariaDB | 11.8.6(LTS) | `binary`(官方 linux-systemd 包) · `pkg`(官方仓库/发行版)。**与 MySQL 二选一**，数据存放 `/data/mariadb` |
| Redis  | 8.8.0 / 7.4.9 / 6.2.22 | `source`(编译到 /usr/local/redis) · `pkg`。安装后自动生成随机密码 |
| phpredis（独立组件）| 6.3.0 / 5.3.7 | `source`(用已装 PHP 的 phpize 编译)。需先/同时装 PHP；`--phpredis [版本]` |
| phpMyAdmin（可选工具）| 5.2.3 | 装到 `/home/wwwroot/web/phpMyAdmin`；`--phpmyadmin` |
| Adminer（可选工具，轻量单文件）| 5.4.2 | 装到 `/home/wwwroot/web/adminer`；`--adminer` |

> 哪个版本支持哪些形式、最低内存、依赖的 openssl 版本等，全部在 `versions.conf` 里声明。
> 运行 `./install.sh --list` 可随时查看当前清单。

---

## 3. 使用方法

### 方式一：交互菜单（推荐新手）
```bash
./install.sh
```
逐个组件询问「是否安装 → 选版本 → 选形式」，最后确认安装计划。

### 方式二：命令行（适合自动化 / CI）
```bash
# 完整 LNMP：源码 Nginx + php-fpm + 二进制 MySQL + phpredis + phpMyAdmin
./install.sh --nginx 1.26.2:source --php 8.3.31:fpm --mysql 5.7.44:binary \
             --phpredis 6.3.0 --phpmyadmin -y

# LAMP：源码 Apache 2.4(选 event MPM) + PHP 作为 Apache 模块
./install.sh --apache 2.4.67:source --apache-mpm event --php 8.2.14:apache -y

# 带 ImageMagick(imagick) 与 Adminer；imagick 链接源码编译的最新 ImageMagick
./install.sh --php 8.4.22:fpm --imagemagick-source --adminer -y

# 形式可省略，使用该组件默认形式
./install.sh --nginx 1.24.0 --mysql 5.7.44
```

### 创建虚拟主机（HTTP，自定义端口）
```bash
./install.sh vhost example.com 8080 /home/wwwroot/example.com   # 可加第4参数 nginx|apache
./install.sh vhost                                              # 交互输入
```

### 常用命令
```bash
./install.sh --list     # 列出所有可选版本与形式
./install.sh --help     # 查看帮助
```

参数格式统一为 `--组件 版本[:形式]`，非法的版本或形式组合会在安装前被明确拦截。

---

## 4. 如何新增一个版本？

无需改动任何模块脚本，只要在 `versions.conf` 对应数组里加一行。例如将来新增 PHP 8.6.0：

```bash
PHP_VERSIONS=(
  "8.6.0|fpm,apache|openssl=1.1.1w;min_mem=2000;ext=8"   # ← 新增这一行
  "8.5.6|fpm,apache|openssl=1.1.1w;min_mem=2000;ext=8"
  ...
)
```

字段格式：`版本号|支持的形式(逗号分隔)|元数据(key=value;分号分隔)`。
保存后 `--list`、菜单、命令行校验都会自动识别新版本。

---

## 5. 说明与注意事项

- 运行环境：CentOS/RHEL 7、Rocky/Alma/RHEL 8 9、Ubuntu 22/24，需 root（均要求 systemd）。脚本自动区分 yum/dnf/apt 与 firewalld/ufw。Ubuntu 的 `pkg` 形式安装的 MySQL 版本由发行版决定（通常为 8.0），与所选版本号可能不同，会有提示。
- 源码编译耗时较长且占内存；PHP8 与 MySQL5.7 源码默认要求 ≥2000MB 内存（在清单里以 `min_mem` 声明，可调）。
- 安装日志输出到 `logs/` 目录，每个组件单独一份。
- 下载默认走主镜像，失败自动回落到备用镜像（见 `versions.conf` 的 `MIRROR_*`）。
- 原始脚本保留在 `sh/`（如随包附带），可作对照参考。

- MySQL 8.x（8.0/8.4）：官方二进制包为 `.tar.xz`，脚本会自动用 `xz` 解包；因 8.x 源码编译需 C++17 工具链（CentOS/RHEL 7 默认 gcc 过旧），故 8.x 仅提供 `binary` 与 `pkg` 形式，5.x 仍可 `source` 编译。
- PHP 8.3/8.4/8.5 与 8.2 走同一套 PHP8 编译流程（源码编译，约需 ≥2000MB 内存）；新增版本只是清单里多了几行，无需改动模块。
- 默认 PHP 版本为 **8.3.31**（`PHP_DEFAULT`）；MySQL 默认为 8.0.46(binary)。phpredis 已独立为单独组件（不再随 PHP 自动安装），用 `--phpredis [版本]` 或交互菜单单独选择；版本在 `versions.conf` 的 `PHPREDIS_VERSIONS` 声明（PHP8→6.3.0、PHP7.3→5.3.7）。

- Nginx 源码编译会保留原仓库的源码优化：将版本号伪装为 `Microsoft-IIS`、把 autoindex 文件名长度由 50 提到 150、复制 man 手册页。Tengine（nginx 增强发行版）与 nginx 同构，按需求开启 `--with-http_upstream_check_module`（上游健康检查）。
- Tengine 在「Web 服务器」组件下以 `tengine-3.1.0` 形式出现，与 nginx 互斥（同一 `/usr/local/nginx`）。命令行：`--nginx tengine-3.1.0`。
- MariaDB 为新增独立组件，与 MySQL 互斥（二者择一，菜单会自动跳过、命令行会拦截）。二进制包为官方 `linux-systemd` tarball，安装到 `/usr/local/mariadb`；`pkg` 形式优先用 MariaDB 官方仓库锁定 11.8 系列，失败回落发行版自带包。
- MySQL 8.4.9 为当前 8.4 LTS 线最新点版本（替换了上一版的 8.4.8）。
- 下载策略（已强化）：每个下载先试官方源，`wget --tries=3 --timeout=30` 三次失败/超时后自动转镜像站（`MIRROR_PRIMARY`→`MIRROR_FALLBACK`，按文件名）。所有组件（含 Apache/MariaDB/Tengine）现在都带镜像兜底。libsodium 升级到 1.0.19。
- 数据库 root 密码（已自动化）：MySQL / MariaDB 安装完成后会自动生成 16 位随机 root 密码并设置，密码同时打印在屏幕上并保存到 `/root/.mysql_root_password` 或 `/root/.mariadb_root_password`（权限 600），不再需要手动执行 `mysql_secure_installation`。
- 已取消 PHP 5 支持（移除 5.6 及其 mcrypt/旧 openssl 分支）。
- 编译用 OpenSSL 统一为 **3.0.20**，下载源：OpenSSL 官方 GitHub Release → 你的镜像站；nginx/apache/php 均使用该版本。
- libsodium 解压目录修正：官方发布包实际解压为 `libsodium-stable`，脚本现在自动从包内探测真实目录，不再写死版本目录。
- 新增 Redis（独立组件，`--redis`，源码或包管理器安装，systemd 管理，默认监听 127.0.0.1:6379；daemonize+systemd(forking) 管理，pidfile=/var/run/redis/redis.pid、logfile/dir 在 /usr/local/redis/var，maxmemory 自动设为物理内存的 1/8；全部 redis 命令软链到 /usr/local/bin；自动生成随机密码保存到 `/root/.redis_password`）。**phpredis** 为独立组件（见 `--phpredis`），用已装 PHP 的 phpize 编译并写入扫描目录启用。
- 系统 PATH（已优化）：源码/二进制安装的组件会自动加入系统 PATH——既写 `/etc/profile.d/lnamp-<name>.sh`（新登录 shell 生效），又把主程序软链到 `/usr/local/bin`（当前终端立即可用）。因此安装后可直接 `nginx -V`、`php -v`、`mysql --version`、`redis-cli -v`，无需重新登录或敲全路径。
- 数据库配置（已优化）：源码/二进制安装的 MySQL/MariaDB 现在生成一份完整调优的 `/etc/my.cnf`（bind 0.0.0.0、utf8mb4、binlog、慢查询日志、InnoDB 参数等），并按内存自动调优 `innodb_buffer_pool_size`/`key_buffer_size`/`tmp_table_size`/`table_open_cache` 等（1.5–2.5G/2.5–3.5G/>3.5G 三档，≤1.5G 用基础值）。配置随数据库版本自适应：MySQL 8.0/8.4 自动去掉已被移除的 `query_cache_*`、改用 `binlog_expire_logs_seconds`、去掉废弃的 `innodb_log_files_in_group`，避免 mysqld 因未知/已删指令而无法启动；MySQL 5.7 与 MariaDB 保留 query cache 等。
- PHP 编译参数（已按模板扩展）：curl/openssl/mysqli/pdo-mysql/pdo-sqlite/gd/zip/bz2/iconv/xsl/gmp/intl/soap/bcmath/opcache/sodium/argon2/kerberos/ldap+sasl/snmp 等一应俱全；并设置 `PKG_CONFIG_PATH` 让 PHP 链接到自编译的 OpenSSL 3.0.20 / libsodium / argon2。gd 与 zip 按版本自适应（PHP8/7.4 新式、7.3 旧式），SAPI 按 fpm/apache 切换。新增依赖：krb5-devel、openldap-devel、cyrus-sasl-devel、net-snmp-devel、libicu-devel（各发行版自动映射）。
- php.ini（已按模板优化）：memory_limit 按内存分级、时区 Asia/Shanghai、`cgi.fix_pathinfo=0`、`short_open_tag=On`、`expose_php=Off`、`request_order=CGP`、`post_max_size=100M`、`upload_max_filesize=50M`、`max_execution_time=60`、`realpath_cache_size=2M`、curl/openssl CA 指向 `/usr/local/openssl/cert.pem`、开启 error_log 与 opcache.error_log，并按给定清单禁用高危函数(disable_functions)。
- OpenSSL 安装判定修复：OpenSSL 3.x 在 64 位系统装到 `lib64/`，旧代码只查 `lib/libcrypto.a` 会误报“安装失败”。现在 `lib`/`lib64` 都检测，并改用 `make install_sw`（跳过冗长的 html/man 文档安装，更快），`ld.so.conf` 同时登记 lib 与 lib64。Apache 与 PHP 共用同一份 `build_openssl_prefix`。
- 构建日志（2>&1）：新增 `log_run`，把 configure/make 等重型命令的 stdout+stderr 全量写入 `logs/build_<时间>.log`；失败时自动打印日志末尾 25 行(经 tee 进入对应组件日志)，便于定位真正的报错原因。
- 数据库存放位置改到 /data：MySQL → basedir=`/data/mysql`、datadir=`/data/mysql/data`；MariaDB → `/data/mariadb`、`/data/mariadb/data`。`pid-file`、`log_error`、`slow_query_log_file` 自动落到各自 datadir 下（如 `/data/mysql/data/mysql.pid`）。安装时会自动创建并 chown 这些目录。仅改 `versions.conf` 的 `PREFIX_MYSQL`/`PREFIX_MARIADB` 即可调整。
- phpredis 改为独立组件：不再随 PHP 自动安装，需用 `--phpredis [版本]`（或交互菜单）单独选择确认。需先/同时安装 PHP；默认 6.3.0，PHP7.3 用 5.3.7。安装时自动用 PHP 的 phpize 编译并写入 `php.d/redis.ini` 启用。
- 新增 vhost 创建功能：`./install.sh vhost <域名> [端口] [网站根目录] [nginx|apache]`（不带参数则交互输入）。支持自定义监听端口、仅 HTTP（不含 HTTPS）；自动识别已装的 nginx/apache 生成对应配置、建站点目录与测试页、放行端口并 reload；若检测到 php-fpm 自动加 PHP 解析（Unix socket `/run/php/php-fpm.sock`）。
- php-fpm 改用 Unix socket 监听：默认 `listen = /run/php/php-fpm.sock`（`listen.owner/group=www`、`listen.mode=0660`），取代不安全且有性能开销的 `127.0.0.1:9000` TCP 监听；systemd 单元加 `RuntimeDirectory=php` 自动创建 `/run/php`。socket 路径可在 `versions.conf` 的 `PHP_FPM_SOCK` 修改。vhost 生成的配置同步改为 socket：nginx `fastcgi_pass unix:${PHP_FPM_SOCK}`，apache `SetHandler proxy:unix:${PHP_FPM_SOCK}|fcgi://localhost`。
- 优化默认 nginx.conf（参考 conf/nginx.conf）：worker_processes/cpu_affinity auto、events epoll+multi_accept+51200、gzip、fastcgi 缓冲/超时、open_file_cache、client_max_body_size 1024m、server_tokens off、标准 log_format；默认 server(80 default_server) 服务 `/home/wwwroot/web` 并支持 PHP(socket)；末尾 `include vhost/*.conf;`。同时生成可复用片段 conf/lnamp/security.conf(恶意UA/注入拦截) 与 conf/lnamp/static.conf(静态缓存+隐藏文件/上传目录加固)。
- 优化 nginx vhost：每站独立 access/error 日志、`try_files` 防止任意 PHP 执行(`$uri =404`)、php-fpm Unix socket、localhost-only 的 /nginx_status、按需 include 上述 security/static 片段；并修正 include 检测避免与默认 nginx.conf 的 `include vhost/*.conf` 重复。
- vhost 支持 Apache：安装 Apache 时自动启用 vhost 所需模块(proxy/proxy_fcgi/rewrite/expires/deflate/headers)并建立 `conf/vhost` 目录、在 httpd.conf 写入 `IncludeOptional conf/vhost/*.conf`。Apache vhost 模板已优化：`AllowOverride All`(.htaccess)、隐藏文件拒绝、php-fpm Unix socket 解析、mod_expires 静态缓存、mod_deflate 压缩、独立 access/error 日志、非 80 端口自动补 `Listen`。同时装了 nginx 与 apache 时，`install.sh vhost <域名> [端口] [根目录] [nginx|apache]` 可用第 4 参数指定（交互模式会询问），缺省用 nginx。
- Apache MPM 可手动选择并同步到 vhost：安装 Apache 时可选 prefork / worker / event（CLI `--apache-mpm <mpm>`，交互菜单在选了 Apache 源码安装后会提示选择；Apache 2.4 三种皆可选）。所选 MPM 用于 `--with-mpm` 编译，并写入 `conf/lnamp/mpm.conf` 调优块（prefork: StartServers/MaxRequestWorkers；worker/event: 线程参数）。vhost 生成时通过 `httpd -V` 读取当前 MPM 并据此选择 PHP 解析方式：prefork+已装 mod_php → mod_php(`SetHandler application/x-httpd-php`)；worker/event 或有 php-fpm → php-fpm Unix socket；vhost 顶部以 `# Apache MPM=X PHP=method` 标注。若 PHP 选 apache(mod_php) 模式却配非 prefork MPM，安装时会给出线程安全告警。
- PHP fileinfo 与 ImageMagick：fileinfo 对所有 PHP 版本始终启用(`--enable-fileinfo`)。ImageMagick(imagick) 为可选扩展——交互安装时会提示「是否为 PHP 安装 ImageMagick(imagick) 扩展? [y/N]」；非交互可用 `--php-imagick`/`--no-php-imagick`。选择安装后会装系统库(ImageMagick/ImageMagick-devel↔imagemagick/libmagickwand-dev)并用 phpize 编译 imagick(PHP<8.4→3.7.0，PHP≥8.4→3.8.1，版本可在 versions.conf 调整)，写入 php.d/imagick.ini 启用，适配所有 PHP 版本。可选从源码编译最新 ImageMagick(默认 7.1.2-25，versions.conf 的 IMAGEMAGICK_VERSION 可改)：交互模式选装 imagick 后会再问「ImageMagick 来源: 1)发行版包 2)源码编译最新」；非交互用 `--imagemagick-source`(自动含 --php-imagick)。源码方式编译到 /usr/local/imagemagick(带 png/jpeg/tiff/webp/freetype/xml 等 delegate)，登记 ld.so 并软链 magick 到 PATH，imagick 用 `--with-imagick` 链接到它。
- 默认站点改为 /home/wwwroot/web：nginx 默认 server(80 default_server) 与 Apache DocumentRoot 都指向该目录并支持 PHP(socket)，phpMyAdmin 等放这里即可经 http://<IP>/ 访问。
- 新增 phpMyAdmin 可选安装：交互装 PHP 后会提示「是否安装 phpMyAdmin?」；非交互用 `--phpmyadmin`/`--no-phpmyadmin`。装到 `${WWWROOT}/web/phpMyAdmin`(固定 5.2.3，需 PHP 7.2+)。流程：①动态探测解压目录并重命名为 phpMyAdmin ②复制 config.sample.inc.php 为 config.inc.php ③安全初始化——写入 32 位随机 blowfish_secret(有该行则替换/无则插入)、在 blowfish 行后插入 UploadDir/SaveDir(避免追加到文件尾落在 ?> 之后失效)、删除 setup 安装向导目录、config.inc.php 权限 640。访问 http://<域名或IP>/phpMyAdmin/。
- 新增 Adminer 可选安装（轻量级单文件 DB 工具，phpMyAdmin 的轻量替代）：交互装 PHP 后会在 phpMyAdmin 之后再问「是否安装 Adminer?」；非交互用 `--adminer`/`--no-adminer`。下载 Adminer 5.4.2 单文件(GitHub release + adminer.org 官方 + 镜像兜底)，放到 `${WWWROOT}/web/adminer/index.php`，访问 http://<域名或IP>/adminer/，用数据库账号登录。版本可在 versions.conf 的 ADMINER_VERSION 调整。
- 扩展加载修复（重要）：编译出来的共享扩展(redis/imagick/snmp 及 Zend 扩展 opcache)现在统一通过 `php.d/*.ini` 用**绝对路径**启用(`php-config --extension-dir`)，opcache 用 `zend_extension`、snmp/redis/imagick 用 `extension`；并在装好扩展后自动 `reload_php_runtime`（重启 php-fpm / 重载 apache），解决「.so 已生成但 phpinfo 看不到」的问题（根因：php-fpm 在加扩展前已启动，未重新读取 ini）。
- disable_functions 修正：从默认禁用名单移除 `set_time_limit`（Adminer/phpMyAdmin 等正常工具会调用它，禁用会导致 `Call to undefined function set_time_limit()` 致命错误）；其余高危函数(passthru/exec/system/shell_exec/proc_open/eval 等)仍保留禁用。
- 新增 OpenJDK + Tomcat：交互菜单末尾可选装 OpenJDK（输入 11 或 17，Eclipse Temurin 二进制），自动设置 `JAVA_HOME`/`JRE_HOME`/`CLASSPATH`/`PATH`(写 /etc/profile.d/lnamp-java.sh，并软链 java/javac)；随后可选装 **Tomcat 10.1.55**(systemd 管理、端口 8080、CATALINA_HOME=/usr/local/tomcat、以 tomcat 用户运行)，Tomcat 最后安装且依赖 Java（CLI `--tomcat` 未配 `--java` 时自动选 OpenJDK 17）。CLI：`--java <11|17>`、`--tomcat`；版本/前缀在 versions.conf 的 `TOMCAT_VERSION`/`PREFIX_JAVA`/`PREFIX_TOMCAT`。
- 新增 freenginx 分支：NGINX_VERSIONS 增加 `freenginx-1.30.1`(stable, flavor=freenginx)，从 https://freenginx.org/download/ 下载，源码编译且与 nginx 用相同的 OpenSSL/zlib/PCRE 依赖；同样应用 IIS 伪装。并把 IIS 伪装改为“按内容匹配 + 容忍空白”(不再依赖固定行号/空格)，对 nginx/tengine/freenginx 各版本都能可靠生效(NGINX_VER→Microsoft-IIS/10.0/、NGINX_VAR→Microsoft-IIS、错误页脚与 Server 头一并伪装)。
- 新增 Redis 8.8.0：REDIS_VERSIONS 增加 `8.8.0`(仅 source；distro 包仓库给的是旧 6/7.x，故不提供 pkg 形式)，源码从 download.redis.io + GitHub tag(github.com/redis/redis) 兜底下载，复用现有 `make && make install` 流程。注：Redis 8 源码核心编译需较新的 GCC(建议 Rocky/Alma/RHEL8+、Ubuntu22/24；CentOS7 自带 GCC 过旧可能编译失败)。
- 数据库选择改为统一列表：交互菜单把 MySQL 各版本与 MariaDB 11.8.6 列在同一张表里(标注 MySQL/MariaDB 与默认项)，输入序号二选一(或 0/回车不装)，再选安装形式；天然保证二者互斥。命令行仍用 `--mysql`/`--mariadb`。
- 新增 MySQL 9.7.0 LTS：MYSQL_VERSIONS 增加 `9.7.0`(binary,pkg；glibc2.28，.tar.xz)，从 cdn.mysql.com/Downloads/MySQL-9.7/ 下载；my.cnf 走 MySQL8+ 规则(无 query_cache)。同时把二进制下载改为多 glibc 变体回退(清单值优先→glibc2.28→2.17→2.12)并动态探测解压目录，兼容 8.x(glibc2.17) 与 9.x(glibc2.28)。注：MySQL 9.x 需 glibc≥2.28(Rocky/Alma/RHEL8+、Ubuntu22/24)，CentOS7 请用 8.4/8.0。
- 新增 tests/smoke.sh 全功能冒烟测试(64 项断言，用桩隔离网络/编译/系统调用)：覆盖静态检查、清单×形式校验、所有 CLI flag、辅助函数(meta_get/fetch镜像兜底/php_enable_ext/write_my_cnf 版本门控/IIS伪装)、每个安装器的下载 URL 与产物(nginx三flavor/apache/mysql9.7多glibc回退/mariadb/redis8.8/phpredis/phpMyAdmin安全初始化/Adminer/OpenJDK/Tomcat)、vhost、run_installs 编排顺序、互斥与 Tomcat-needs-Java 守卫、交互菜单。运行: `bash tests/run_all.sh`(共 110 项)。另含 tests/smoke2.sh 深度验证：install_X 按 mode 分发(source/binary/pkg)、生成配置内容(nginx.conf 默认站点+socket+server_tokens off+include vhost；my.cnf datadir/innodb；php.ini 无 set_time_limit/fix_pathinfo=0/expose_php Off；php-fpm www.conf socket+owner)、detect_os(CentOS7/Rocky9/Ubuntu22)、_dep_name 跨发行版映射、fetch 兜底、parse_pick、gen_password、vhost apache、redis.conf。
本重构在保持原有安装逻辑（configure 参数、init/systemd 配置、镜像源等）的前提下，把「版本 × 形式」从一堆分散脚本收敛为一份可声明、可校验、可扩展的清单。
