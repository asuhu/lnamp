================================================================================
 LNAMP 安装包缓存目录 (packages/) —— 所有下载地址清单
================================================================================

【解析优先级】fetch 对每个安装包按如下顺序取用：
  1) 本地缓存：本目录 packages/  或  环境变量 LNAMP_CACHE=/自定义目录
  2) 你自己的镜像：
       主  MIRROR_PRIMARY  = https://www.zhangfangzhou.cn/third
       备  MIRROR_FALLBACK = http://arv.asuhu.com/ftp
     （每个文件都会尝试镜像根目录与 so/ 子目录两处）
  3) 官方源（仅作最终兜底）

【离线/预下载用法】
  · 把下面列出的文件（文件名必须与官方完全一致）放进本 packages/ 目录，
    或放到 LNAMP_CACHE 指定目录，安装时即优先复用、完全跳过网络。
  · 只需下载你本次实际会安装的组件对应的包即可，不必全下。
  · 镜像布局约定：普通源码包放镜像“根目录”，*.so / 编译辅助库放镜像“so/”子目录。

--------------------------------------------------------------------------------
 各组件下载地址（含当前 versions.conf 里的全部版本）
--------------------------------------------------------------------------------

### Nginx / Tengine / freenginx (源码) #########################################
  nginx-1.30.2.tar.gz
    http://nginx.org/download/nginx-1.30.2.tar.gz
  nginx-1.26.2.tar.gz
    http://nginx.org/download/nginx-1.26.2.tar.gz
  nginx-1.24.0.tar.gz
    http://nginx.org/download/nginx-1.24.0.tar.gz
  tengine-3.1.0.tar.gz
    http://tengine.taobao.org/download/tengine-3.1.0.tar.gz
    https://github.com/alibaba/tengine/archive/refs/tags/3.1.0.tar.gz
  freenginx-1.30.1.tar.gz
    https://freenginx.org/download/freenginx-1.30.1.tar.gz

  # Nginx/Apache 源码编译公共依赖（镜像文件；官方上游见括注）
  zlib-1.3.2.tar.gz        [镜像根目录]  上游: https://zlib.net/zlib-1.3.2.tar.gz
  pcre2-10.42.tar.gz       [镜像根目录]  上游: https://github.com/PCRE2Project/pcre2/releases/download/pcre2-10.42/pcre2-10.42.tar.gz
  openssl-3.0.20.tar.gz    [镜像根目录]  上游: https://github.com/openssl/openssl/releases/download/openssl-3.0.20/openssl-3.0.20.tar.gz
  nghttp2-1.41.0.tar.gz    [镜像 so/ ]   上游: https://github.com/nghttp2/nghttp2/releases/download/v1.41.0/nghttp2-1.41.0.tar.gz

### Apache httpd (源码) ########################################################
  httpd-2.4.67.tar.gz
    http://archive.apache.org/dist/httpd/httpd-2.4.67.tar.gz
  apr-1.7.4.tar.gz        http://archive.apache.org/dist/apr/apr-1.7.4.tar.gz
  apr-util-1.6.3.tar.gz     http://archive.apache.org/dist/apr/apr-util-1.6.3.tar.gz

### PHP ########################################################################
  php-8.5.6.tar.gz
    https://www.php.net/distributions/php-8.5.6.tar.gz
  php-8.4.22.tar.gz
    https://www.php.net/distributions/php-8.4.22.tar.gz
  php-8.3.31.tar.gz
    https://www.php.net/distributions/php-8.3.31.tar.gz
  php-8.2.14.tar.gz
    https://www.php.net/distributions/php-8.2.14.tar.gz
  php-7.4.33.tar.gz
    https://www.php.net/distributions/php-7.4.33.tar.gz
  php-5.6.40.tar.gz
    https://www.php.net/distributions/php-5.6.40.tar.gz

  # PHP 依赖：
  openssl-3.0.20.tar.gz    (PHP7/8 共享 OpenSSL3，同上，镜像根目录)
  openssl-1.0.2u.tar.gz    (仅 PHP5.6 专用 OpenSSL1.0.2)
    https://www.openssl.org/source/old/1.0.2/openssl-1.0.2u.tar.gz
    https://github.com/openssl/openssl/releases/download/OpenSSL_1_0_2u/openssl-1.0.2u.tar.gz
  libsodium-1.0.19.tar.gz  (PHP7.2+ 密码哈希；镜像 so/)
    https://download.libsodium.org/libsodium/releases/libsodium-1.0.19.tar.gz
  argon2-20190702.tar.gz   (PHP7.2+ 密码哈希；镜像 so/)
    上游: https://github.com/P-H-C/phc-winner-argon2/archive/refs/tags/20190702.tar.gz

### phpredis (可选扩展；按 PHP 主版本选其一) ###################################
  phpredis-6.3.0.tar.gz     https://github.com/phpredis/phpredis/archive/refs/tags/6.3.0.tar.gz
  phpredis-5.3.7.tar.gz     https://github.com/phpredis/phpredis/archive/refs/tags/5.3.7.tar.gz
  phpredis-4.3.0.tar.gz    https://github.com/phpredis/phpredis/archive/refs/tags/4.3.0.tar.gz   (PHP5.6 用)

### ImageMagick / imagick (可选扩展) ##########################################
  imagick-3.4.4.tgz        https://pecl.php.net/get/imagick-3.4.4.tgz   (PHP5.6)
  imagick-3.7.0.tgz        https://pecl.php.net/get/imagick-3.7.0.tgz   (PHP7–8.3)
  imagick-3.8.1.tgz        https://pecl.php.net/get/imagick-3.8.1.tgz   (PHP>=8.4)
  ImageMagick-7.1.2-25.tar.gz  (仅 --imagemagick-source 源码编译时)
    https://imagemagick.org/archive/releases/ImageMagick-7.1.2-25.tar.gz
    https://imagemagick.org/archive/ImageMagick-7.1.2-25.tar.gz
    https://github.com/ImageMagick/ImageMagick/archive/refs/tags/7.1.2-25.tar.gz

### MySQL (source 仅5.7 / binary / pkg) ########################################
  # MySQL 9.7.0
    binary: https://cdn.mysql.com/Downloads/MySQL-9.7/mysql-9.7.0-linux-glibc2.28-x86_64.tar.xz
  # MySQL 8.4.9
    binary: https://cdn.mysql.com/Downloads/MySQL-8.4/mysql-8.4.9-linux-glibc2.17-x86_64.tar.xz
  # MySQL 8.0.46
    binary: https://cdn.mysql.com/Downloads/MySQL-8.0/mysql-8.0.46-linux-glibc2.17-x86_64.tar.xz
  # MySQL 5.7.44
    binary: https://cdn.mysql.com/Downloads/MySQL-5.7/mysql-5.7.44-linux-glibc2.12-x86_64.tar.gz
    source: http://cdn.mysql.com/Downloads/MySQL-5.7/mysql-boost-5.7.44.tar.gz

### MariaDB (binary / pkg；与 MySQL 二选一) ####################################
  mariadb-11.8.8-linux-systemd-x86_64.tar.gz
    https://archive.mariadb.org/mariadb-11.8.8/bintar-linux-systemd-x86_64/mariadb-11.8.8-linux-systemd-x86_64.tar.gz
  mariadb-11.4.8-linux-systemd-x86_64.tar.gz
    https://archive.mariadb.org/mariadb-11.4.8/bintar-linux-systemd-x86_64/mariadb-11.4.8-linux-systemd-x86_64.tar.gz
  mariadb-10.11.14-linux-systemd-x86_64.tar.gz
    https://archive.mariadb.org/mariadb-10.11.14/bintar-linux-systemd-x86_64/mariadb-10.11.14-linux-systemd-x86_64.tar.gz

### Redis ######################################################################
  redis-8.8.0.tar.gz
    https://download.redis.io/releases/redis-8.8.0.tar.gz
    https://github.com/redis/redis/archive/refs/tags/8.8.0.tar.gz
  redis-7.4.9.tar.gz
    https://download.redis.io/releases/redis-7.4.9.tar.gz
    https://github.com/redis/redis/archive/refs/tags/7.4.9.tar.gz
  redis-6.2.22.tar.gz
    https://download.redis.io/releases/redis-6.2.22.tar.gz
    https://github.com/redis/redis/archive/refs/tags/6.2.22.tar.gz

### Java (OpenJDK/Temurin) + Tomcat (可选) #####################################
  OpenJDK11.tar.gz  https://api.adoptium.net/v3/binary/latest/11/ga/linux/x64/jdk/hotspot/normal/eclipse?project=jdk
  OpenJDK17.tar.gz  https://api.adoptium.net/v3/binary/latest/17/ga/linux/x64/jdk/hotspot/normal/eclipse?project=jdk
    (arm64 把 x64 换成 aarch64；清华镜像: https://mirrors.tuna.tsinghua.edu.cn/Adoptium/)
  apache-tomcat-10.1.55.tar.gz
    https://dlcdn.apache.org/tomcat/tomcat-10/v10.1.55/bin/apache-tomcat-10.1.55.tar.gz
    https://archive.apache.org/dist/tomcat/tomcat-10/v10.1.55/bin/apache-tomcat-10.1.55.tar.gz

### phpMyAdmin / Adminer (可选) ################################################
  phpMyAdmin-5.2.3-all-languages.tar.gz
    https://files.phpmyadmin.net/phpMyAdmin/5.2.3/phpMyAdmin-5.2.3-all-languages.tar.gz
  adminer-5.4.2.php
    https://github.com/vrana/adminer/releases/download/v5.4.2/adminer-5.4.2.php
    https://www.adminer.org/static/download/5.4.2/adminer-5.4.2.php

### 其它 #######################################################################
  cacert.pem (CA 根证书，PHP curl/openssl 用)  https://curl.se/ca/cacert.pem

--------------------------------------------------------------------------------
 示例：离线安装 PHP 5.6（把这两个包放进本目录后执行）
--------------------------------------------------------------------------------
  php-5.6.40.tar.gz
  openssl-1.0.2u.tar.gz

  sudo bash install.sh --php 5.6.40:fpm -y

 或指定任意缓存目录：
  LNAMP_CACHE=/data/pkgs sudo bash install.sh --php 5.6.40:fpm -y
================================================================================
