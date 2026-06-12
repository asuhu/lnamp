# LNAMP 安装器（重构版）

把原本「CentOS 专用、版本写死、逻辑分散」的 LNAMP 一键脚本，重构为一套**清单驱动、可声明、可校验、可扩展、跨发行版**的安装框架。一份 `versions.conf` 管理所有「版本 × 形式」，模块化的 `modules/*.sh` 负责各组件安装。

支持 Nginx/Tengine/freenginx、Apache、PHP、MySQL/MariaDB、Redis，及 phpredis、ImageMagick、phpMyAdmin、Adminer、OpenJDK、Tomcat 等可选组件。

---

## 1. 版本 × 形式对照表

| 组件 | 可选版本（默认加粗） | 形式 (mode) / 说明 |
|------|----------------------|--------------------|
| Nginx 系 | nginx 1.30.2 / **1.26.2** / 1.24.0 · tengine-3.1.0 · freenginx-1.30.1 | `source`(编译，含自编 OpenSSL/zlib/PCRE) · `pkg`(仅 nginx flavor)。tengine/freenginx 仅 `source` |
| Apache | **2.4.67** | `source`(event+HTTP2，MPM 可选 prefork/worker/event) · `pkg` |
| PHP | 8.5.6 / 8.4.22 / **8.3.31** / 8.2.14 / 7.4.33 | `fpm`(Nginx，Unix socket) · `apache`(mod_php)。fileinfo 默认启用；imagick 可选 |
| MySQL | 9.7.0(LTS) / 8.4.9(LTS) / **8.0.46** / 5.7.44 | `source`(仅 5.x) · `binary` · `pkg`。数据在 `/data/mysql` |
| MariaDB | **11.8.8**(LTS·2025) / 11.4.8(LTS·2024) / 10.11.14(LTS) | `binary`(archive.mariadb.org) · `pkg`(官方仓库)。**与 MySQL 二选一**，数据在 `/data/mariadb` |
| Redis | 8.8.0 / **7.4.9** / 6.2.22 | `source` · `pkg`。自动随机密码，systemd 管理 |
| phpredis（独立组件）| **6.3.0** / 5.3.7 | `source`(用已装 PHP 的 phpize)。`--phpredis [版本]` |
| ImageMagick / imagick | IM 7.1.2-25 ; imagick 3.7.0(PHP<8.4) / 3.8.1(≥8.4) | 可选扩展，发行版包或源码编译 IM |
| phpMyAdmin | 5.2.3 | 可选，装到 `/home/wwwroot/web/phpMyAdmin`；`--phpmyadmin` |
| Adminer | 5.4.2 | 可选，轻量单文件，装到 `/home/wwwroot/web/adminer`；`--adminer` |
| OpenJDK / Tomcat | OpenJDK 11 或 17(Temurin) ; Tomcat 10.1.55 | 可选；`--java <11\|17>`、`--tomcat` |

数据库 MySQL 与 MariaDB 互斥；Nginx 三 flavor 共用 `/usr/local/nginx`，互斥。

---

## 2. 使用方法

### 交互菜单（推荐）
```bash
sudo bash install.sh          # 逐项询问：Web / PHP / 数据库(统一列表) / Redis / phpredis / Java / Tomcat ...
```

### 命令行（自动化 / CI）
```bash
# 完整 LNMP：源码 Nginx + php-fpm + 二进制 MySQL + phpredis + phpMyAdmin
sudo bash install.sh --nginx 1.26.2:source --php 8.3.31:fpm --mysql 8.0.46:binary \
                     --phpredis 6.3.0 --phpmyadmin -y

# LAMP：源码 Apache(event MPM) + PHP 作为 Apache 模块
sudo bash install.sh --apache 2.4.67:source --apache-mpm event --php 8.2.14:apache -y

# freenginx + 源码 ImageMagick + Adminer
sudo bash install.sh --nginx freenginx-1.30.1 --php 8.4.22:fpm --imagemagick-source --adminer -y

# OpenJDK 17 + Tomcat（Tomcat 最后装，依赖 Java）
sudo bash install.sh --java 17 --tomcat -y

# 形式可省略，使用该组件默认形式
sudo bash install.sh --nginx 1.24.0 --mysql 9.7.0
```

### 创建虚拟主机（HTTP，自定义端口）
```bash
sudo bash install.sh vhost example.com 8080 /home/wwwroot/example.com [nginx|apache]
sudo bash install.sh vhost           # 交互输入
```

### 常用
```bash
bash install.sh --list      # 列出所有可选版本/形式
bash install.sh --help      # 帮助
bash tests/run_all.sh       # 跑全部冒烟测试（110 项）
```

---

## 3. 安装位置与产物

| 项 | 位置 |
|----|------|
| Nginx / Apache / PHP / Redis | `/usr/local/{nginx,apache,php,redis}` |
| MySQL / MariaDB 数据 | `/data/{mysql,mariadb}` |
| Java / Tomcat / ImageMagick | `/usr/local/{java,tomcat,imagemagick}` |
| 网站根 / 默认站点 / 日志 | `/home/wwwroot` ; `/home/wwwroot/web`(默认站点，支持 PHP) ; `/home/wwwlogs` |
| php-fpm socket | `/run/php/php-fpm.sock` |
| 数据库 root 随机密码 | `/root/.mysql_root_password` / `.mariadb_root_password`（600） |
| Redis 随机密码 | `/root/.redis_password` |
| 安装日志 | `logs/`（每组件一份 + build 总日志） |

源码/二进制安装的程序会自动写 `/etc/profile.d/lnamp-*.sh` 并软链到 `/usr/local/bin`，装完即可直接 `nginx -V`、`php -v`、`mysql --version`、`redis-cli -v`、`java -version`。

---

## 4. 目录结构与扩展

```
install.sh        主入口：参数解析 / 交互菜单 / 编排 / 守卫
versions.conf     清单：所有版本×形式、镜像、前缀、各组件版本号
lib/common.sh     公共库：日志/下载(fetch)/OS检测/包抽象/清单解析/my.cnf/扩展启用 等
modules/*.sh      各组件安装：nginx apache php mysql mariadb redis deps vhost
                  phpmyadmin adminer java
conf/             nginx.conf 优化参考 + conf/lnamp 片段
tests/            run_all.sh + smoke.sh(64) + smoke2.sh(46)
```

**新增一个版本**：通常只需在 `versions.conf` 对应 `*_VERSIONS` 数组加一行 `版本|形式|元数据`，无需改模块。例如新增 PHP：`"8.x.y|fpm,apache|openssl=3.0.20;min_mem=2000;ext=8;phpredis=6.3.0"`。

---

## 5. 注意事项

- **运行环境**：CentOS/RHEL 7、Rocky/Alma/RHEL 8·9、Ubuntu 22/24，需 root 且有 systemd。自动区分 yum/dnf/apt 与 firewalld/ufw。
- **内存**：源码编译耗时且吃内存，PHP8 / MySQL5.7 源码默认要求 ≥2000MB（清单 `min_mem` 可调）。
- **下载**：先官方源（`wget --tries=3 --timeout=30`），失败自动转镜像（`versions.conf` 的 `MIRROR_PRIMARY`→`MIRROR_FALLBACK`，按文件名兜底）。
- **MySQL 9.x**：需 glibc ≥ 2.28（Rocky/Alma/RHEL 8+、Ubuntu 22/24）；CentOS 7 请用 8.4 / 8.0。二进制下载会按 glibc 变体（2.28→2.17→2.12）自动回退。
- **Redis 8.x**：源码核心编译需较新 GCC（同上）；CentOS 7 建议用 7.4.9。
- **MySQL/MariaDB 互斥**：交互的统一数据库菜单里二选一；命令行同时给会被拦截。`pkg` 形式的版本由发行版仓库决定，可能与所选版本号不同（会提示）。
- **密码**：MySQL/MariaDB/Redis 安装后自动生成随机密码并保存到 `/root/.*`（600），无需手动 `mysql_secure_installation`。
- **php-fpm** 走 Unix socket（非 9000 端口）；网站需通过 `http://IP/xxx.php`（经 php-fpm）才能看到扩展，改 php.d 后需 `systemctl restart php-fpm`。

---

## 6. 主要特性与变更（按主题）

**Web / Nginx**
- 三 flavor：nginx（官方）、tengine（开 `--with-http_upstream_check_module`）、freenginx-1.30.1，均源码编译，自编 OpenSSL 3.0.20 / zlib 1.3.1 / PCRE2-10.42。
- 源码优化：伪装 `Server` 为 `Microsoft-IIS`（按内容匹配、容忍空白，对三 flavor 都可靠生效）、autoindex 文件名长度 50→150。
- 优化 nginx.conf：worker/epoll/gzip/fastcgi/open_file_cache/server_tokens off；默认站点服务 `/home/wwwroot/web` 且支持 PHP；`include vhost/*.conf`；附 conf/lnamp 的 security/static 片段。

**Apache**
- 2.4.67 源码（event+HTTP2），MPM 可选 prefork/worker/event（`--apache-mpm`），写入 mpm.conf 调优；DocumentRoot 指向 `/home/wwwroot/web`。

**PHP**
- 完整 configure（curl/openssl/mysqli/pdo/gd/zip/intl/soap/bcmath/opcache/sodium/argon2/ldap/snmp 等），链接自编 OpenSSL 3.0.20 / libsodium / argon2。
- php.ini 调优（内存分级、时区、`cgi.fix_pathinfo=0`、`expose_php Off` 等）；`disable_functions` 禁高危函数但**保留 `set_time_limit`**（否则 Adminer/phpMyAdmin 报错）。
- php-fpm 用 Unix socket（`listen.owner/group=www`、systemd `RuntimeDirectory=php`）。
- **扩展加载**：opcache(zend_extension)/snmp/redis/imagick 统一用绝对路径写 `php.d/*.ini`，装后自动重启 php-fpm，避免「.so 已生成但 phpinfo 看不到」。

**数据库**
- 数据统一在 `/data`；my.cnf 完整调优并随版本自适应（MySQL 8/9 去 query_cache、用 `binlog_expire_logs_seconds`；5.7/MariaDB 保留 query cache）。
- MySQL 9.7.0 LTS / 8.4.9 LTS / 8.0.46(默认) / 5.7.44；MariaDB 按 LTS 分支分类：11.8.8(当前LTS) / 11.4.8(上一LTS) / 10.11.14，二进制改用永久归档 archive.mariadb.org（downloads.mariadb.com 已失效跳转）；交互为统一二选一列表。

**Redis / phpredis**
- Redis 独立组件（8.8.0/7.4.9/6.2.22），systemd、随机密码、maxmemory=内存/8。
- phpredis 独立组件（不随 PHP 自动装），phpize 编译并启用。

**可选工具**
- ImageMagick：imagick 扩展（3.7.0/3.8.1）+ 可选源码编译 IM 7.1.2-25（`--imagemagick-source`）。
- phpMyAdmin 5.2.3：解压→重命名→复制配置→安全初始化（32 位 blowfish_secret、UploadDir/SaveDir、删 setup、权限 640）。
- Adminer 5.4.2：单文件，`/home/wwwroot/web/adminer/`。
- OpenJDK 11/17（Temurin，设 JAVA_HOME 等）+ Tomcat 10.1.55（systemd、8080），Tomcat 最后装、依赖 Java。

**vhost**
- `install.sh vhost <域名> [端口] [根目录] [nginx|apache]`，HTTP、自定义端口；自动识别 nginx/apache，建站点+日志、放行端口、reload；检测到 php-fpm 自动加 socket 解析。

**基础设施**
- 跨发行版包名映射、firewalld/ufw 抽象、systemd 服务、`log_run` 全量构建日志、OpenSSL 3.x lib64 适配、自动 PATH 注册。
