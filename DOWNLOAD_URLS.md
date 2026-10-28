# LNAMP 安装器 — 完整下载地址清单（官方源 + 镜像站）

> 生成时间：2026-10-23　对应版本：versions.conf
> （nginx 1.30.6/1.26.2、Apache 2.4.69、PHP 8.5.12/8.4.27/8.3.36/8.2.35/7.4.33/5.6.40、
> MySQL 9.7.4/8.4.13/8.0.46/5.7.44、MariaDB 11.8.8/11.4.8/10.11.14、Redis 8.8.3/7.4.9/6.2.24、
> **Memcached 1.6.45、PHP memcached 3.4.0/3.3.0/2.2.0、Swoole 6.2.3/6.1.10、
> Composer 2.10.3/2.2.30、Node.js 24.22.1/22.23.4、fail2ban 1.1.1**）

## 一、下载优先级（fetch 统一调度）

```
1) 本地缓存：packages/ 目录 或 $LNAMP_CACHE 指定目录（命中即用，不联网）
2) 官方源：下表各包的第一个地址（保证真实、最新）
3) 镜像站兜底（仅官方源超时/不可达/404 时回落）：
     主镜像  https://www.zhangfangzhou.cn/third/<文件名>      与  .../third/so/<文件名>
     备镜像  http://arv.asuhu.com/ftp/<文件名>               与  .../ftp/so/<文件名>
```

镜像地址规则：镜像根目录与 `so/` 子目录各试一次，`so/` 用于编译辅助库（openssl/pcre2/zlib/nghttp2/libsodium/argon2 等）。本地缓存文件名必须与官方完全一致才能命中。

---

## 二、官方下载地址（按顺序尝试）

### 1. Nginx 系（source 形式）
| 文件 | 官方地址 |
|---|---|
| nginx-1.30.6.tar.gz | http://nginx.org/download/nginx-1.30.6.tar.gz |
| nginx-1.26.2.tar.gz | http://nginx.org/download/nginx-1.26.2.tar.gz |
| tengine-3.1.0.tar.gz | http://tengine.taobao.org/download/tengine-3.1.0.tar.gz ｜ https://github.com/alibaba/tengine/archive/refs/tags/3.1.0.tar.gz |
| freenginx-1.30.1.tar.gz | https://freenginx.org/download/freenginx-1.30.1.tar.gz |

### 2. Nginx/PHP/Apache 公共编译依赖
| 文件 | 官方地址 |
|---|---|
| zlib-1.3.2.tar.gz | https://zlib.net/zlib-1.3.2.tar.gz ｜ https://zlib.net/fossils/zlib-1.3.2.tar.gz |
| pcre2-10.42.tar.gz | https://github.com/PCRE2Project/pcre2/releases/download/pcre2-10.42/pcre2-10.42.tar.gz |
| openssl-3.0.20.tar.gz（PHP7/8、nginx、Apache 共用） | https://github.com/openssl/openssl/releases/download/openssl-3.0.20/openssl-3.0.20.tar.gz |
| openssl-1.0.2u.tar.gz（仅 PHP5.6 专用） | https://www.openssl.org/source/old/1.0.2/openssl-1.0.2u.tar.gz ｜ https://github.com/openssl/openssl/releases/download/OpenSSL_1_0_2u/openssl-1.0.2u.tar.gz |
| nghttp2-1.70.0.tar.gz（Apache HTTP2） | https://github.com/nghttp2/nghttp2/releases/download/v1.70.0/nghttp2-1.70.0.tar.gz |
| libsodium-1.0.22.tar.gz（PHP7.2+） | https://download.libsodium.org/libsodium/releases/libsodium-1.0.22.tar.gz |
| argon2-20190702.tar.gz（PHP7.2+） | https://github.com/P-H-C/phc-winner-argon2/archive/refs/tags/20190702.tar.gz |

### 3. Apache httpd（source 形式）
| 文件 | 官方地址（按序） |
|---|---|
| httpd-2.4.69.tar.gz | ① https://dlcdn.apache.org/httpd/httpd-2.4.69.tar.gz ② https://downloads.apache.org/httpd/httpd-2.4.69.tar.gz ③ https://archive.apache.org/dist/httpd/httpd-2.4.69.tar.gz |
| apr-1.7.4.tar.gz | https://archive.apache.org/dist/apr/apr-1.7.4.tar.gz |
| apr-util-1.6.3.tar.gz | https://archive.apache.org/dist/apr/apr-util-1.6.3.tar.gz |

### 4. PHP
| 文件 | 官方地址 |
|---|---|
| php-8.5.12.tar.gz | https://www.php.net/distributions/php-8.5.12.tar.gz |
| php-8.4.27.tar.gz | https://www.php.net/distributions/php-8.4.27.tar.gz |
| php-8.3.36.tar.gz | https://www.php.net/distributions/php-8.3.36.tar.gz |
| php-8.2.35.tar.gz | https://www.php.net/distributions/php-8.2.35.tar.gz |
| php-7.4.33.tar.gz | https://www.php.net/distributions/php-7.4.33.tar.gz |
| php-5.6.40.tar.gz | https://www.php.net/distributions/php-5.6.40.tar.gz |

### 5. MySQL（binary 形式，均为官方 cdn.mysql.com）
| 版本 | 官方地址 |
|---|---|
| 9.7.4（glibc2.28） | https://cdn.mysql.com/Downloads/MySQL-9.7/mysql-9.7.4-linux-glibc2.28-x86_64.tar.xz |
| 8.4.13（glibc2.28） | https://cdn.mysql.com/Downloads/MySQL-8.4/mysql-8.4.13-linux-glibc2.28-x86_64.tar.xz |
| 8.0.46（glibc2.17） | https://cdn.mysql.com/Downloads/MySQL-8.0/mysql-8.0.46-linux-glibc2.17-x86_64.tar.xz |
| 5.7.44（binary, glibc2.12） | https://cdn.mysql.com/Downloads/MySQL-5.7/mysql-5.7.44-linux-glibc2.12-x86_64.tar.gz |
| 5.7.44（source, boost） | https://cdn.mysql.com/Downloads/MySQL-5.7/mysql-boost-5.7.44.tar.gz |
| pkg 形式仓库 RPM（RHEL） | https://repo.mysql.com/mysql<系列>-community-release-el<主版本>.rpm |

注：binary 形式会按 glibc 变体自动回退尝试（2.28→2.17→2.12）；8.4.13 官方仅提供 glibc2.28 包。

### 6. MariaDB（binary 形式，官方永久归档）
| 版本 | 官方地址 |
|---|---|
| 11.8.8 | https://archive.mariadb.org/mariadb-11.8.8/bintar-linux-systemd-x86_64/mariadb-11.8.8-linux-systemd-x86_64.tar.gz |
| 11.4.8 | https://archive.mariadb.org/mariadb-11.4.8/bintar-linux-systemd-x86_64/mariadb-11.4.8-linux-systemd-x86_64.tar.gz |
| 10.11.14 | https://archive.mariadb.org/mariadb-10.11.14/bintar-linux-systemd-x86_64/mariadb-10.11.14-linux-systemd-x86_64.tar.gz |
| pkg 形式仓库脚本 | https://r.mariadb.com/downloads/mariadb_repo_setup |

### 7. Redis
| 文件 | 官方地址（按序） |
|---|---|
| redis-8.8.3.tar.gz | ① https://download.redis.io/releases/redis-8.8.3.tar.gz ② https://github.com/redis/redis/archive/refs/tags/8.8.3.tar.gz |
| redis-7.4.9.tar.gz | ① https://download.redis.io/releases/redis-7.4.9.tar.gz ② https://github.com/redis/redis/archive/refs/tags/7.4.9.tar.gz |
| redis-6.2.24.tar.gz | ① https://download.redis.io/releases/redis-6.2.24.tar.gz ② https://github.com/redis/redis/archive/refs/tags/6.2.24.tar.gz |

### 8. phpredis（PHP 的 Redis 扩展）
| 文件 | 官方地址 |
|---|---|
| phpredis-6.3.0.tar.gz（PHP8） | https://github.com/phpredis/phpredis/archive/refs/tags/6.3.0.tar.gz |
| phpredis-5.3.7.tar.gz（PHP7） | https://github.com/phpredis/phpredis/archive/refs/tags/5.3.7.tar.gz |
| phpredis-4.3.0.tar.gz（PHP5.6） | https://github.com/phpredis/phpredis/archive/refs/tags/4.3.0.tar.gz |

### 9. ImageMagick / imagick（可选）
| 文件 | 官方地址（按序） |
|---|---|
| imagick-3.8.1.tgz（PHP≥8.4） | ① https://pecl.php.net/get/imagick-3.8.1.tgz |
| imagick-3.7.0.tgz（PHP7–8.3） | ① https://pecl.php.net/get/imagick-3.7.0.tgz |
| imagick-3.4.4.tgz（PHP5.6） | ① https://pecl.php.net/get/imagick-3.4.4.tgz |
| ImageMagick-7.1.2-25.tar.gz（--imagemagick-source） | ① https://imagemagick.org/archive/releases/ImageMagick-7.1.2-25.tar.gz ② https://imagemagick.org/archive/ImageMagick-7.1.2-25.tar.gz ③ https://github.com/ImageMagick/ImageMagick/archive/refs/tags/7.1.2-25.tar.gz |

### 10. phpMyAdmin / Adminer（可选）
| 文件 | 官方地址（按序） |
|---|---|
| phpMyAdmin-5.2.3-all-languages.tar.gz | ① https://files.phpmyadmin.net/phpMyAdmin/5.2.3/phpMyAdmin-5.2.3-all-languages.tar.gz |
| adminer-5.4.2.php | ① https://github.com/vrana/adminer/releases/download/v5.4.2/adminer-5.4.2.php ② https://www.adminer.org/static/download/5.4.2/adminer-5.4.2.php |

### 11. Java / Tomcat（可选）
| 文件 | 官方地址（按序） |
|---|---|
| OpenJDK11（Temurin） | ① https://api.adoptium.net/v3/binary/latest/11/ga/linux/x64/jdk/hotspot/normal/eclipse?project=jdk ② https://mirrors.tuna.tsinghua.edu.cn/Adoptium/11/jdk/x64/linux/ |
| OpenJDK17（Temurin） | ① https://api.adoptium.net/v3/binary/latest/17/ga/linux/x64/jdk/hotspot/normal/eclipse?project=jdk ② https://mirrors.tuna.tsinghua.edu.cn/Adoptium/17/jdk/x64/linux/ |
| apache-tomcat-10.1.55.tar.gz | ① https://dlcdn.apache.org/tomcat/tomcat-10/v10.1.55/bin/apache-tomcat-10.1.55.tar.gz ② https://archive.apache.org/dist/tomcat/tomcat-10/v10.1.55/bin/apache-tomcat-10.1.55.tar.gz |

（arm64 把上面 Adoptium 地址中的 `x64` 换成 `aarch64`。）

### 12. 新增组件（Memcached / PHP memcached / Swoole / Composer / Node.js / fail2ban）
| 文件 | 官方地址（按序） |
|---|---|
| memcached-1.6.45.tar.gz | ① https://www.memcached.org/files/memcached-1.6.45.tar.gz ② https://github.com/memcached/memcached/archive/refs/tags/1.6.45.tar.gz |
| memcached-3.4.0.tgz（PHP 扩展，PHP7+） | ① https://pecl.php.net/get/memcached-3.4.0.tgz |
| memcached-3.3.0.tgz（PHP 扩展，PHP7+） | ① https://pecl.php.net/get/memcached-3.3.0.tgz |
| memcached-2.2.0.tgz（PHP 扩展，PHP5.6） | ① https://pecl.php.net/get/memcached-2.2.0.tgz |
| swoole-6.2.3.tar.gz | ① https://github.com/swoole/swoole-src/archive/refs/tags/v6.2.3.tar.gz |
| swoole-6.1.10.tar.gz | ① https://github.com/swoole/swoole-src/archive/refs/tags/v6.1.10.tar.gz |
| composer-2.10.3.phar | ① https://getcomposer.org/download/2.10.3/composer.phar |
| composer-2.10.3.sha256sum（校验用） | ① https://getcomposer.org/download/2.10.3/composer.phar.sha256sum |
| composer-2.2.30.phar（PHP 5.3~7.1 LTS） | ① https://getcomposer.org/download/2.2.30/composer.phar |
| node-v24.22.1-linux-x64.tar.xz | ① https://nodejs.org/dist/v24.22.1/node-v24.22.1-linux-x64.tar.xz ② https://npmmirror.com/mirrors/node/v24.22.1/node-v24.22.1-linux-x64.tar.xz |
| node-v22.23.4-linux-x64.tar.xz | ① https://nodejs.org/dist/v22.23.4/node-v22.23.4-linux-x64.tar.xz ② https://npmmirror.com/mirrors/node/v22.23.4/node-v22.23.4-linux-x64.tar.xz |
| fail2ban（无 tarball） | 仅包管理器：RHEL 系 `dnf install epel-release && dnf install fail2ban`；Debian 系 `apt-get install fail2ban` |

**EPEL 兜底（RHEL 系）**：CentOS Stream 8 没有 Extras 仓，`dnf install epel-release` 会报 `No match for argument` 并返回非零。安装器已容错——`epel-release` 装不到时直接写 `/etc/yum.repos.d/epel-installer.repo`，按主版本选镜像：

| 主机版本 | 仓库地址 |
|---|---|
| RHEL / CentOS 7 | `https://mirrors.aliyun.com/epel-archive/7/Everything/x86_64` |
| RHEL / Rocky / Alma 8、CentOS Stream 8 | `https://mirrors.aliyun.com/epel/8/Everything/x86_64` |
| RHEL / Rocky / Alma 9 | `https://mirrors.aliyun.com/epel/9/Everything/x86_64` |

仓库配置失败只告警、不中断——EPEL 只提供 memcached / fail2ban 等可选组件，不该因此打断主流程。

Node.js 的 `linux-x64` 会按 `uname -m` 自动替换为 `linux-arm64` / `linux-armv7l`。

**Composer SHA256 实测**（2026-10-23 下载校验）：

```
文件内  7a2d379d5b8ffdaa028580ef26494c36d2feef4b178d3dd1473a4dbc5e17c8d6  composer.phar
实算    7a2d379d5b8ffdaa028580ef26494c36d2feef4b178d3dd1473a4dbc5e17c8d6   （3,642,137 字节）
```

安装器会在安装前比对，不一致直接中止（防镜像投毒）。

### 13. 其它
| 文件 | 官方地址 |
|---|---|
| cacert.pem（CA 根证书，PHP curl/openssl 用） | https://curl.se/ca/cacert.pem |
| Nginx pkg 形式 yum 仓库 | http://nginx.org/packages/centos/<主版本>/$basearch/ |

---

## 三、镜像站下载地址（兜底，按文件名拼接）

| 镜像 | 根目录 | so/ 子目录（编译辅助库） |
|---|---|---|
| 主镜像 | https://www.zhangfangzhou.cn/third/&lt;文件名&gt; | https://www.zhangfangzhou.cn/third/so/&lt;文件名&gt; |
| 备镜像 | http://arv.asuhu.com/ftp/&lt;文件名&gt; | http://arv.asuhu.com/ftp/so/&lt;文件名&gt; |

镜像布局约定：普通源码包放镜像「根目录」；openssl / pcre2 / zlib / nghttp2 / libsodium / argon2 等编译辅助库放镜像「so/」子目录。镜像上的文件名必须与官方完全一致（如 `php-8.3.36.tar.gz`、`nginx-1.30.6.tar.gz`）。

示例（以 nginx-1.30.6 为例，官方失败后依次尝试）：
```
http://nginx.org/download/nginx-1.30.6.tar.gz                              ← 官方（优先）
https://www.zhangfangzhou.cn/third/nginx-1.30.6.tar.gz                     ← 主镜像根目录
https://www.zhangfangzhou.cn/third/so/nginx-1.30.6.tar.gz                  ← 主镜像 so/
http://arv.asuhu.com/ftp/nginx-1.30.6.tar.gz                               ← 备镜像根目录
http://arv.asuhu.com/ftp/so/nginx-1.30.6.tar.gz                            ← 备镜像 so/
```

---

## 四、实测校验结果

### 4.1 第二批新增组件（12 个地址，2026-10-23 Range 联网探测）

| 文件 | 结果 |
|---|---|
| memcached-1.6.45.tar.gz（memcached.org） | ✅ 206 |
| memcached-1.6.45.tar.gz（GitHub tag 兜底） | ✅ 200 |
| memcached-3.4.0.tgz（pecl） | ✅ 200 · 93,288 B |
| memcached-2.2.0.tgz（pecl，PHP5） | ✅ 200 · 70,449 B |
| swoole v6.2.3（GitHub） | ✅ 200 · 2,195,688 B |
| swoole v6.1.10（GitHub） | ✅ 200 |
| composer-2.10.3.phar | ✅ 206 |
| composer-2.10.3.sha256sum | ✅ 206（内容与实际 phar 完全一致） |
| composer-2.2.30.phar | ✅ 206 |
| node-v24.22.1-linux-x64.tar.xz（nodejs.org） | ✅ 206 |
| node-v22.23.4-linux-x64.tar.xz（nodejs.org） | ✅ 206 |
| npmmirror 备用源 | ⚠️ 从测试机连接超时（国内网络正常，仅作兜底，不影响安装） |
| fail2ban | —（包管理器安装，无 tarball） |

### 4.2 第一批组件（38 个组件 / 版本，Range 联网探测）

| 项目 | 结果 |
|---|---|
| 官方源直接命中 | **38 / 38** |
| 首选官方 URL 命中 | 37 / 38（ImageMagick 7.1.2-25 走第 2 个源 GitHub） |
| 全部源失败 | **0** |
| 镜像站已同步 | 25 / 38 |
| 镜像站尚未同步 | 13 / 38 |

### 镜像站已同步（25）
nginx 1.30.6 / 1.26.2 / tengine-3.1.0 / freenginx-1.30.1；apache 2.4.69 / apr-1.7.4 / apr-util-1.6.3；
phpredis 6.3.0 / 5.3.7 / 4.3.0；imagick 3.7.0 / 3.8.1；
redis 8.8.3 / 7.4.9 / 6.2.24；
openssl 3.0.20 / 1.0.2u；pcre2-10.42；zlib-1.3.2；nghttp2-1.70.0；libsodium-1.0.22；argon2-20190702；
ImageMagick-7.1.2-25；phpMyAdmin-5.2.3；tomcat-10.1.55

### 镜像站尚未同步（13，不影响安装，官方源均可用）
| 组件 | 缺失文件 |
|---|---|
| php | php-8.5.12 / 8.4.27 / 8.3.36 / 8.2.35 / 7.4.33 / 5.6.40 `.tar.gz`（6 个） |
| mysql | mysql-9.7.4-linux-glibc2.28 / 8.4.13-linux-glibc2.28 / 8.0.46-linux-glibc2.17-minimal / 5.7.44-linux-glibc2.12（4 个） |
| mariadb | mariadb-11.8.8 / 11.4.8 / 10.11.14-linux-systemd-x86_64（3 个） |

> 备镜像 `arv.asuhu.com/ftp` 目录里目前仍是**升级前**的旧包（`php-8.5.6.tar.gz`、`php-8.4.22.tar.gz`）。
> 主镜像 `zhangfangzhou.cn` 无目录列表页，但文件直取可用。
> 两站证书链在严格校验下报错，安装器已用 `wget --no-check-certificate` 兼容。
> **建议**：把上表 13 个新包补传到两个镜像站，之后离线环境也能装新版。

### 第二批新增包在镜像站的状态

以下 11 个文件是本次新增的，镜像站上**尚未确认存在**（不影响安装：官方源实测全部可用，镜像仅在官方源不可达时才回落）。如需完整离线安装，请一并补传：

```
memcached-1.6.45.tar.gz
memcached-3.4.0.tgz
memcached-3.3.0.tgz
memcached-2.2.0.tgz
swoole-6.2.3.tar.gz
swoole-6.1.10.tar.gz
composer-2.10.3.phar          composer-2.10.3.sha256sum
composer-2.2.30.phar
node-v24.22.1-linux-x64.tar.xz
node-v22.23.4-linux-x64.tar.xz
```

注意：`fetch` 按**文件名**匹配本地缓存与镜像，因此镜像/`packages/` 里的文件名必须与上表完全一致（`composer-2.10.3.phar` 不能写成 `composer.phar`，`node-v24.22.1-linux-x64.tar.xz` 不能省掉 `-linux-x64`）。
