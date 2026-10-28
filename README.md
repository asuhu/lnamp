# LNAMP 全功能使用说明

一套**清单驱动**的 Linux Web 环境安装器：一条命令装好 Nginx / Apache / PHP / MySQL / MariaDB / Redis / Tomcat 及全套常用扩展，
并自带站点管理、装前预检、装后自检、压测调参、巡检诊断、备份还原、升级卸载。

- 所有「版本 × 安装形式」都在 `versions.conf` 里声明，加一行即新增一个版本，不用改代码
- 默认值都是保守且可解释的；破坏性动作（删站点、清残留、删数据）默认**只报告不执行**
- 源码编译组件的 OpenSSL / PCRE / zlib 一并自编，不依赖发行版的老库

---

## 目录

| 章节 | 内容 |
|---|---|
| [1](#1-一分钟上手) | 一分钟上手 |
| [2](#2-能力总览) | 能力总览 |
| [3](#3-环境要求与支持矩阵) | 环境要求与支持矩阵 |
| [4](#4-安装交互菜单) | 安装：交互菜单 |
| [5](#5-安装命令行全参数) | 安装：命令行全参数 |
| [6](#6-版本--形式清单) | 版本 × 形式清单 |
| [7](#7-常用场景配方) | 常用场景配方 |
| [8](#8-站点管理-vhost) | 站点管理 `vhost` |
| [9](#9-装前预检-precheck) | 装前预检 `precheck` |
| [10](#10-装后自检-verify) | 装后自检 `verify` |
| [11](#11-日常运维-status--doctor) | 日常运维 `status` / `doctor` |
| [12](#12-安全检查-scan) | 安全检查 `scan` |
| [13](#13-压测与调参-bench) | 压测与调参 `bench` |
| [14](#14-备份与还原-backup--restore) | 备份与还原 `backup` / `restore` |
| [15](#15-升级--卸载--回滚) | 升级 / 卸载 / 回滚 |
| [16](#16-内核调优-sysctl-与包索引镜像-mirror) | 内核调优 / 包索引镜像 |
| [17](#17-安装位置与产物) | 安装位置与产物 |
| [18](#18-环境变量与可覆盖路径) | 环境变量与可覆盖路径 |
| [19](#19-离线与内网安装) | 离线与内网安装 |
| [20](#20-故障排查手册) | 故障排查手册 |
| [21](#21-测试与验证矩阵) | 测试与验证矩阵 |
| [22](#22-附录命令速查) | 附录：命令速查 |

---

## 1. 一分钟上手

```bash
# 1) 上传安装器并进入目录（root）
cd /root/lnamp

# 2) 先看一眼这台机器适不适合装（只读，5 秒）
bash install.sh precheck --nginx 1.30.6 --php 8.5.12:fpm --mysql 8.4.13:binary

# 3) 装（一条命令，全自动）
bash install.sh -y --nginx 1.30.6 --php 8.5.12:fpm --mysql 8.4.13:binary --redis --phpredis

# 4) 装完自检 + 建站
bash install.sh verify
bash install.sh vhost demo.com 80 /home/wwwroot/demo.com nginx
```

不带任何参数就是**交互菜单**，逐项问你要什么：

```bash
bash install.sh
```

装完访问 `http://<你的IP>/` 应看到默认站点页面；`http://<你的IP>/i.php` 能看到 PHP 信息。

---

## 2. 能力总览

| 分类 | 功能 | 一句话 |
|---|---|---|
| **安装** | 清单驱动 | `versions.conf` 声明版本与形式，支持源码 / 二进制 / 包管理器三种 |
| | 交互菜单 | 不认识参数也能装，逐项选择并复述确认 |
| | 干跑 | `--dry-run` 打印完整计划（下载 URL 链、将写的配置、将启的服务），零副作用 |
| | 幂等 | 已装同版本自动跳过；重跑不会重下重编（源码编译一次 10 分钟起） |
| | 并发锁 | 同一台机器同时只允许一个安装进程；`vhost` / `bench --apply` / `sysctl` / `mirror <切换>` 同样串行化 |
| **站点** | `vhost` | 创建 / 列表 / 启停 / HTTPS / 删除 |
| | 站点隔离 | 每站点独立 php-fpm 池 + `open_basedir`，读不到别家源码 |
| | 残留治理 | `vhost prune` 识别坏配置、根目录缺失、孤儿目录、孤儿池 |
| **质量** | `precheck` | 装前 10 项只读检查，把「装到一半失败」提前拦掉 |
| | `verify` | 装后 7 类检查，包括 Web 端 PHP 端到端与 Redis 密码一致性 |
| **运维** | `status` | 一屏看现状（只读），可 `--brief` 给监控采集 |
| | `doctor` | 只读诊断，每条问题都给出可执行修复命令 |
| | `scan` | webshell / 可疑文件巡检（只读，绝不自动删） |
| | `bench` | 本机压测 + 按核数内存反推 `worker_processes` / `pm.max_children` |
| | `backup` / `restore` | 整套备份（库 + 配置 + 可选站点代码）与还原，带 sha256 校验 |
| | `upgrade` / `uninstall` | 平滑升级（配置自动备份、数据保留）、干净卸载 |
| **系统** | `sysctl` | 内核参数与句柄上限，逐项取优、绝不回退 |
| | `mirror` | Composer / npm 包索引国内镜像 |

---

## 3. 环境要求与支持矩阵

| 项 | 要求 |
|---|---|
| 系统 | RHEL / CentOS **7**、Rocky / Alma / RHEL **8 · 9**、CentOS Stream **8**、Debian **11 · 12 · 13**、Ubuntu **20 · 22 · 24** |
| 架构 | x86_64 / aarch64（Node.js 额外支持 armv7l） |
| 权限 | root（需要写 `/usr/local`、`/etc`、注册 systemd） |
| init | systemd（容器内无 systemd 不支持服务管理） |
| 磁盘 | 基础 2GB + 源码组件 6GB + 二进制数据库 2GB；**源码 Web + MySQL binary + JDK + 全套插件建议 ≥25GB** |
| 内存 | 源码编译 PHP 8 / MySQL 5.7 需 ≥2000MB（清单 `min_mem` 可调） |
| 网络 | 需能访问官方源或镜像；离线安装见 [§19](#19-离线与内网安装) |

已实测跑通完整安装 + 自检的矩阵见 [§21](#21-测试与验证矩阵)。

> **矩阵外不阻止安装**，只打印 `未在测试矩阵内，将尽力而为`。RHEL 6 及更早会被直接拒绝。

---

## 4. 安装：交互菜单

```bash
bash install.sh
```

流程：

1. 系统检测（发行版 / 版本 / 内存 / 磁盘 / 是否容器）
2. 逐项选择：**Web 服务器 → PHP → 数据库 → Redis → phpredis → Java → Tomcat → 附加组件**
3. 汇总复述一遍你要装的东西，确认后开始
4. 自动执行 `precheck`，有阻塞项会停下来问你要不要继续
5. 开始安装，每个组件一段日志，最后自动 `verify`

交互菜单里的默认值会随环境调整，例如：

| 场景 | 自动调整 |
|---|---|
| CentOS 7 / glibc < 2.28 | Node.js 自动回落到 `16.20.2`（18+ 官方二进制需 glibc 2.28）—— 交互菜单与 `--nodejs` 都生效 |
| 内存 < 2000MB | 提示源码编译 PHP 8 可能失败，建议改 `pkg` 形式 |
| 已装 nginx 系统包 | 提示会与 `/usr/local/nginx` 抢端口 |
| 只装了 Apache | 隐藏 php-fpm 相关选项，PHP 默认 `apache` 形式 |

想自动化就用命令行（下一节），两者等价。

---

## 5. 安装：命令行全参数

### 5.1 组件选择

| 参数 | 说明 |
|---|---|
| `--nginx VER[:MODE]` | Nginx 系。`MODE` = `source`(编译) / `pkg`(包管理器)。含 `tengine-3.1.0`、`freenginx-1.31.4` 等 flavor |
| `--apache VER[:MODE]` | Apache。`source` / `pkg` |
| `--apache-mpm MPM` | Apache 工作模式：`prefork` / `worker` / `event`（默认 `event`） |
| `--php VER[:MODE]` | PHP。`MODE` = `fpm`（配 Nginx，Unix socket）/ `apache`（mod_php） |
| `--mysql VER[:MODE]` | MySQL。`source`（仅 5.x）/ `binary` / `pkg`。**省略版本 = 8.4.13**（当前 LTS） |
| `--mariadb VER[:MODE]` | MariaDB。`binary` / `pkg`。**与 `--mysql` 互斥** |
| `--redis [VER[:MODE]]` | Redis。`source` / `pkg` |
| `--redis-modules` | Redis 8.x 连内置模块一起编（需 cmake + Rust，默认只编核心） |
| `--phpredis [VER]` | phpredis 扩展（需同时或已装 PHP，默认 6.3.0） |
| `--memcached [VER]` | Memcached 服务端（默认 1.6.45） |
| `--php-memcached [VER]` | PHP memcached 扩展（默认 3.4.0，PHP 5.6 自动降到 2.2.0） |
| `--no-php-memcached` | 明确不装（`-y` 下默认就不装，用于覆盖交互菜单记忆） |
| `--swoole [VER]` | Swoole 扩展（需 PHP ≥ 8.0） |
| `--composer [VER]` | Composer（默认 2.10.3；PHP < 7.2.5 自动用 2.2.30） |
| `--nodejs [VER]` | Node.js LTS（默认 24.22.1；glibc < 2.28 自动回落 16.20.2，`LNAMP_NODE_NO_FALLBACK=1` 可关） |
| `--java <11\|17>` | OpenJDK（Temurin），并设 `JAVA_HOME` / `PATH` |
| `--tomcat` | Tomcat 10.1.55（依赖 Java，未选 `--java` 时自动用 17） |
| `--fail2ban` / `--no-fail2ban` | fail2ban（sshd / nginx-http-auth / nginx-limit-req 三个 jail） |
| `--php-imagick` / `--no-php-imagick` | ImageMagick 的 PHP 扩展 imagick |
| `--imagemagick-source` | imagick 链接**源码编译**的最新 ImageMagick（含 `--php-imagick`） |
| `--phpmyadmin` / `--no-phpmyadmin` | phpMyAdmin 5.2.3 → `/home/wwwroot/web/phpMyAdmin` |
| `--adminer` / `--no-adminer` | Adminer 5.4.2 → `/home/wwwroot/web/adminer` |

### 5.2 行为开关

| 参数 | 说明 |
|---|---|
| `-y`, `--yes` | 跳过所有交互确认（CI / 批量部署必用） |
| `--dry-run` | 干跑：只打印计划，不做任何改动 |
| `--list` | 列出所有可选版本与形式后退出 |
| `--skip-precheck` | 跳过装前预检（默认会先跑一遍） |
| `--mirror cn\|official\|none` | Composer / npm 包索引（默认 `cn`） |
| `--no-mirror` | 等价 `--mirror none` |
| `--lock-wait SEC` | 并发锁最多等待 SEC 秒（默认 0 = 立即失败） |
| `-h`, `--help` | 帮助 |

> **形式可省略**：`--nginx 1.30.6` 等于 `--nginx 1.30.6:source`（该组件的默认形式）。

### 5.3 退出码

| 码 | 含义 |
|---|---|
| 0 | 成功 |
| 1 | 安装失败（会指出失败组件，日志在 `logs/`） |
| 2 | `precheck` 有阻塞项 / 参数错误 |

---

## 6. 版本 × 形式清单

**加粗为默认值**（`bash install.sh --list` 会在默认版本后标 `← 默认 (default)`）。

| 组件 | 可选版本 | 形式 |
|---|---|---|
| Nginx 系 | **nginx 1.30.6** / 1.26.2 / tengine-3.1.0 / freenginx-1.31.4 / freenginx-1.30.1 | `source`（自编 OpenSSL 3.5.9 + PCRE2-10.47 + zlib 1.3.2）、`pkg`（仅 nginx） |
| Apache | **2.4.69** | `source`（event + HTTP/2，MPM 可选）、`pkg` |
| PHP | **8.5.12** / 8.4.27 / 8.3.36 / 8.2.35 / 7.4.33 / 5.6.40 | `fpm`、`apache`（mod_php）。8.x 链 OpenSSL 3.5.9；**7.x 优先用系统的 1.1.1**（系统是 3.x 时才自编 1.1.1w 并自动关掉 LDAP/Kerberos）；5.6 用独立 1.0.2u |
| MySQL | **8.4.13**(LTS，默认) / 9.7.4(LTS) / 8.0.46 / 5.7.44 | `binary`、`pkg`、`source`(仅 5.7) |
| MariaDB | **11.8.8**(LTS) / 11.4.8(LTS) / 10.11.14(LTS) | `binary`、`pkg` |
| Redis | **8.10.2** / 8.8.3 / 7.4.9 / 6.2.24 | `source`、`pkg`(7.4/6.2) |
| phpredis | **6.3.0** / 5.3.7 / 4.3.0 | `source`（用已装 PHP 的 phpize） |
| Memcached | **1.6.45** | `source`、`pkg` |
| PHP memcached | **3.4.0** / 3.3.0 / 2.2.0 | `source`（pecl） |
| Swoole | **6.2.3** / 6.1.10 | `source`（需 PHP ≥ 8.0） |
| Composer | **2.10.3** / 2.2.30 | `phar` + SHA256 校验 |
| Node.js | **24.22.1**(Krypton) / 22.23.4(Jod) / 16.20.2(Gallium) | `binary` |
| fail2ban | **1.1.1**（实际随发行版仓库） | `pkg` |
| phpMyAdmin | **5.2.3** | 解压部署 |
| Adminer | **5.4.2** | 单文件 |
| ImageMagick / imagick | IM **7.1.2-34**；imagick **3.8.1**(≥PHP 8.4) / 3.7.0 | 发行版包或源码 |
| OpenJDK / Tomcat | OpenJDK **11 / 17**(Temurin)；Tomcat **10.1.55** | 二进制 |

**互斥关系**：MySQL ↔ MariaDB；nginx / tengine / freenginx（共用 `/usr/local/nginx`）。

**版本兼容硬约束**（`precheck` 会拦）：

| 组件 | 约束 | 不满足时 |
|---|---|---|
| MySQL 9.x / 8.4、MariaDB 11.x | glibc ≥ 2.28 | 二进制下载会自动按 2.28→2.17→2.12 回退；回退不了则失败 |
| MySQL 8.0、MariaDB 10.11 | glibc ≥ 2.17 | CentOS 7 可用 |
| Node.js 18+ | glibc ≥ 2.28 | glibc 更低时自动改用 16.20.2（菜单与 `--nodejs` 同一套判断，在下载**之前**回落） |
| Swoole 6.x | C++14 | CentOS 7 自动装 SCL devtoolset-11 并静态链 libstdc++ |
| PHP 7.4.33 | OpenSSL **1.1.1**（不支持 3.x） | 系统自带 1.1.1 就直接用；系统是 3.x 才编到 `/usr/local/openssl-1.1`，并**关闭 LDAP/Kerberos**（避免与系统 libk5crypto 混链两套 libcrypto） |
| PHP 5.6.40 | OpenSSL 1.0.2 | 安装器自动单独编译到 `/usr/local/openssl-1.0` |

`bash install.sh --list` 可随时打印当前清单。

---

## 7. 常用场景配方

以下都可直接复制，`-y` 可去掉以先看确认信息。

### LNMP（最常见）

```bash
bash install.sh -y --nginx 1.30.6 --php 8.5.12:fpm --mysql 8.4.13:binary \
  --redis --phpredis --phpmyadmin
```

### LAMP（Apache + mod_php）

```bash
bash install.sh -y --apache 2.4.69 --apache-mpm event --php 8.3.36:apache \
  --mariadb 11.8.8:binary --redis --phpredis --adminer
```

> `--apache-mpm prefork` 只在必须用非线程安全扩展时选；现代 PHP 8 用 `event` 性能更好。

### freenginx / tengine（非官方发行版）

```bash
bash install.sh -y --nginx freenginx-1.31.4 --php 8.4.27:fpm --mysql 8.4.13:binary
bash install.sh -y --nginx tengine-3.1.0    --php 8.2.35:fpm --mysql 8.0.46:binary
```

> tengine 3.x 已移除 `upstream_check` 模块，清单里不再传该参数（传了 configure 直接失败）。

### 现代 PHP 应用栈（缓存 + 协程 + 前端工具链）

```bash
bash install.sh -y --nginx 1.30.6 --php 8.4.27:fpm --mysql 8.4.13:binary \
  --redis --phpredis --memcached --php-memcached --swoole \
  --composer --nodejs --php-imagick --fail2ban
```

### Java 栈（Tomcat）

```bash
bash install.sh -y --nginx 1.30.6 --java 17 --tomcat
# Tomcat 装在最后（依赖 Java），默认 8080
```

### 遗留应用（PHP 5.6，建议 CentOS 7）

```bash
bash install.sh -y --nginx 1.26.2 --php 5.6.40:fpm --phpredis 4.3.0 --mysql 5.7.44:binary
```

> PHP 5.6 已 EOL：自动改用独立 OpenSSL 1.0.2、启用 mcrypt、跳过 sodium/argon2/intl、现代 GCC 追加 `-fcommon`。
> GD 显式启用 JPEG/PNG/FreeType，装了 `libvpx-devel` 时启用 WebP。

### 只装数据库 / 只装 Redis（已有 Web 环境）

```bash
bash install.sh -y --mysql 8.4.13:binary
bash install.sh -y --redis 7.4.9
```

### CI / 批量部署（先看计划再执行）

```bash
bash install.sh --nginx 1.30.6 --php 8.5.12:fpm --mysql 8.4.13:binary --dry-run
bash install.sh -y --nginx 1.30.6 --php 8.5.12:fpm --mysql 8.4.13:binary --lock-wait 600
```

---

## 8. 站点管理 `vhost`

### 8.1 创建站点

```bash
sudo bash install.sh vhost example.com 80 /home/wwwroot/example.com
sudo bash install.sh vhost example.com 8080 /home/wwwroot/example.com   # 自定义端口
sudo bash install.sh vhost example.com 80 /home/wwwroot/example.com apache   # 同时装了 nginx 与 apache 时指定
sudo bash install.sh vhost                                              # 无参数 = 交互输入
```

自动完成：创建根目录与日志路径 → 写 vhost 配置 → 放行防火墙端口 → `nginx -t` / `httpd -t` → reload →
检测到 php-fpm 时自动接 PHP（并建独立池）→ 检测到上传目录时加禁执行规则。

**默认首页是静态 `index.html`，不会生成 `phpinfo()` 页面**（见 8.1.1）。

### 8.1.1 验证 PHP：用临时探针，验证后删除

`phpinfo()` 会把 PHP 版本、编译参数、扩展清单、`$_SERVER` 里的绝对路径与环境变量全部公开。
建站默认放一个，等于每个新站点自带一个信息泄露页（很多站上线后忘了删，扫描器第一件事就是找 phpinfo）。
所以需要时才生成一个**一次性**探针：

```bash
sudo bash install.sh vhost probe example.com     # 打印 URL，验证 PHP/SAPI/扩展
sudo bash install.sh vhost probe --list          # 列出还没删的探针
sudo bash install.sh vhost probe --rm            # 验证完立刻删除（--rm example.com 只删一个站）
sudo bash install.sh probe example.com           # 顶层别名，同上
```

探针的自我保护：文件名带随机后缀（扫不到 `/phpinfo.php` 这种常见名）、权限 `0640 www:www`、
登记到 `/root/.lnamp_probes`，在 systemd 机器上还会安排 15 分钟后自动删除
（`LNAMP_PROBE_TTL_MIN=0` 关闭）。`doctor` 会把残留的 phpinfo / 探针当安全项报出来。

### 8.2 列表

```bash
sudo bash install.sh vhost list
```

```
  TYPE         PORTS      DOMAIN                         ROOT                           ISO   STATE     NOTE
  ------------ ---------- ------------------------------ ------------------------------ ----- --------- --------
  HTTP+HTTPS   80,443     both.example.com               /home/wwwroot/both             yes   enabled   ok
  HTTP         80         www.example.com                /home/wwwroot/www              yes   enabled   ok
  HTTPS        443        api.example.com                /home/wwwroot/api              no    enabled   ok
  HTTP         8080       test.example.com               /home/wwwroot/test             -     disabled  ok
  HTTP         80         old.example.com                /home/wwwroot/old              -     enabled   no-root  [!] 目录不存在
  UNKNOWN      80         (no-server-name)               /home/wwwroot/x                -     enabled   bad-conf

  共 6 个站点：HTTPS 1 个，已禁用 1 个，已隔离 3 个
  异常：坏配置 1 个（解析不出域名），根目录缺失 1 个；孤儿目录 2 个；归档 4 个
  → 建议执行: install.sh vhost prune    （先看清单，再加 --yes 清理）
```

| 列 | 含义 |
|---|---|
| `TYPE` | `HTTP`(仅 80/自定义端口) / `HTTPS`(含 443 或配了证书) / `HTTP+HTTPS`(双栈) / `UNKNOWN`(配置写坏) |
| `ISO` | `yes` = 独立 php-fpm 池（只能读自己根目录）；`no` = 共用全局池（**能读别的站点源码**）；`-`/`php` = 纯静态 / mod_php |
| `NOTE` | `ok` / `bad-conf`（解析不出 `server_name`）/ `no-root`（根目录不存在） |

### 8.3 启停

```bash
sudo bash install.sh vhost disable example.com    # 改名 .conf.disabled
sudo bash install.sh vhost enable  example.com    # 改回来
```

只改文件名、不动内容 → 可一字节不差还原；`include` 通配天然不匹配 `.disabled`，无需 `a2ensite`。

### 8.4 一键 HTTPS

```bash
sudo bash install.sh vhost ssl example.com                                  # 自动探测已有证书
sudo bash install.sh vhost ssl example.com --cert /path/fullchain.pem --key /path/privkey.pem
sudo bash install.sh vhost ssl example.com --self-signed                    # 内网/测试
sudo bash install.sh vhost ssl example.com --no-redirect                    # 80 仍然直接服务
sudo bash install.sh vhost ssl example.com --hsts 15552000                  # 下发 HSTS（半年）
sudo bash install.sh vhost ssl example.com --force                          # 证书续期后重建 443 段
```

**本命令不申请证书**，只负责：配好 443 → 配 80 跳转 → `-t` 校验 → 本机发 HTTPS 请求自检。

| 证书来源 | 探测位置 |
|---|---|
| 已有证书 | `--cert` / `--key`（会校验证书与私钥是否成对） |
| 自动探测 | `/etc/letsencrypt/live/<域名>/`、`~/.acme.sh/<域名>[_ecc]/` |
| 自签 | `--self-signed`（10 年、带 SAN，存 `conf/ssl/`，浏览器会告警） |

默认行为：80 **全部 301 到 https**（`--no-redirect` 关闭）；TLS 只开 `TLSv1.2/1.3`；
HSTS **默认不下发**（一旦下发，浏览器在有效期内禁止降级）。

获取证书（自行执行，工具不代劳）：

```bash
certbot certonly --webroot -w /home/wwwroot/example.com -d example.com
# 或
curl https://get.acme.sh | sh -s email=you@example.com
~/.acme.sh/acme.sh --issue -d example.com -w /home/wwwroot/example.com
```

### 8.5 站点隔离（防止一个站读走全部源码）

```bash
sudo bash install.sh vhost rebind example.com      # 给已有站点补建独立池
sudo bash install.sh vhost rebind --all            # 全部已启用站点
sudo bash install.sh vhost rebind --all --shared    # 反悔：退回全局池
```

建站时**默认就会建独立池**。池长这样：

```ini
; /usr/local/php/etc/php-fpm.d/site_example_com_398749663.conf
[site_example_com_398749663]
listen = /run/php/site_example_com_398749663.sock
php_admin_value[open_basedir] = /home/wwwroot/example.com:/tmp:/usr/local/php/var/log:/usr/local/php/var/lib/php/sessions/site_...
php_admin_value[session.save_path] = /usr/local/php/var/lib/php/sessions/site_...
security.limit_extensions = .php
```

真机验证效果：

```
PHP=8.4.27 sapi=fpm-fcgi
self_file=readable                                  ← 读自己的文件正常
other_site=blocked                                  ← 读别的站点被 open_basedir 拦住
open_basedir=/home/wwwroot/www.demo.local:/tmp:...
```

| 设计点 | 原因 |
|---|---|
| 必须拆池 | `open_basedir` 是**进程级**配置，写在 `php.ini` 里所有站点共用一个范围，等于没设 |
| `/tmp` 必须放行 | `upload_tmp_dir` / `sys_temp_dir` 在 `/tmp`，不放行则上传和临时文件直接失败 |
| 日志/会话目录放行 | 否则写 session 与 error_log 被**静默拒绝**（表现为"登录状态莫名丢失、错误日志空的"） |
| 池名带 hash | 否则 `a-b.com` 与 `a.b.com` 会撞成同一个池，两个站抢一个 socket |
| 建池失败不阻断建站 | 只告警并明确提示"该站点未隔离"，退回全局池 |
| 顺序：写池 → `-t` → reload → 等 socket → 切 vhost | 反过来会有 502 窗口 |

> 隔离目标是"读不到别的站点"，**不是多租户强隔离**（那需要每站点一个系统用户）。
> 主池默认也带 `open_basedir`（范围是整个 `/home/wwwroot`），存量站点不受影响。
> 要更严：`LNAMP_MAIN_OPEN_BASEDIR=/home/wwwroot/web`；完全关闭：`LNAMP_SKIP_MAIN_OPEN_BASEDIR=1`。

### 8.6 删除站点

```bash
sudo bash install.sh vhost del old.example.com                 # 删配置（先归档），保留目录
sudo bash install.sh vhost del old.example.com --purge         # 连站点目录一起删
sudo bash install.sh vhost del old.example.com --purge --yes   # 跳过确认
sudo bash install.sh vhost del --file /usr/local/nginx/conf/vhost/broken.conf
```

- 配置先 `mv` 到 `/var/lib/lnamp/vhost-archive`（带时间戳），误删可捞回
- `--purge` 只允许删 `${WWWROOT}` 之下的目录（防止配置写错 `/etc` 被一锅端）
- `--file` 专治"域名都写坏、`del <域名>` 够不着"的配置，且校验目标必须在 vhost 目录内
- 删完自动清对应的 php-fpm 池 → `-t` → reload；失败全回滚

### 8.7 残留清理 `prune`

配置目录越攒越乱的根源是：**解析不出 `server_name` 的配置在 `list` 里完全隐形，`del` 又按域名找 → 永远删不掉**。
`prune` 把四类残留都摊开：

| 类型 | 怎么来的 | 处理 |
|---|---|---|
| `bad-conf` | 手写/拷贝的配置没有 `server_name` | 归档 |
| `no-root` | 站点目录被手工删了，配置还在 | 归档 |
| `orphan-dir` | 配置删了，目录留着 | `--purge-dirs` 删除 |
| `pool-orphan` | 站点删了、php-fpm 池还在 | 归档（**不清会让整机 PHP 起不来**，见下） |

```bash
sudo bash install.sh vhost prune                       # 只出清单，不动任何文件
sudo bash install.sh vhost prune --yes                 # 归档残留配置（不硬删）
sudo bash install.sh vhost prune --yes --purge-dirs    # 连孤儿目录一起删
sudo bash install.sh vhost prune --yes --disabled      # 连 .conf.disabled 一起清
sudo bash install.sh vhost prune --archive-keep 30     # 归档只留最近 30 个（默认 60）
```

真实输出：

```
$ bash install.sh vhost prune
  孤儿池 pool-orphan (1) —— 站点已删或 chdir 目录不存在
    /usr/local/php/etc/php-fpm.d/site_c_demo_2764366100.conf
    ⚠ 这类池会让 php-fpm -t 失败（chdir 不存在），进而 reload/restart 全挂
```

**为什么孤儿池必须清**：池的 `chdir` 指向已删目录时，`php-fpm -t` 直接失败 →

```
ERROR: [pool site_c_demo_...] the chdir path '/home/wwwroot/c.demo' does not exist
ERROR: FPM initialization failed
```

→ reload / restart 全失败 → **所有站点的 PHP 都不可用**。删一个站点目录就能把整机 PHP 弄停。

`prune` 的执行顺序因此是：**归档配置 → 归档孤儿池 → 删孤儿目录 → 再扫一遍池 → 统一 reload + 校验**。
最后那步"再扫一遍"是必需的 —— 删目录之前，池的 `chdir` 还是有效的，扫不出来。

端到端实测：

```
$ rm -rf /home/wwwroot/c.demo && php-fpm -t     → ERROR chdir ...
$ bash install.sh vhost prune --yes             → 已归档 1 个配置 + 1 个孤儿池
$ php-fpm -t                                     → configuration file test is successful
```

---

## 9. 装前预检 `precheck`

```bash
bash install.sh precheck                                           # 只查通用项
bash install.sh precheck --nginx 1.30.6 --php 8.5.12:fpm --mysql 8.4.13:binary   # 按实际组合估算
```

**全部只读**：不改系统、不装包、不写文件，5 秒内跑完 10 项。

| # | 检查 | 拦的是什么 |
|---|---|---|
| 1 | 系统信息 | 容器环境（systemd / 内核参数不生效）、单核（编译慢） |
| 2 | 磁盘空间 | 按所选组件估算；数据目录在 `/data` 时优先看该挂载点 |
| 3 | 内存 | 与清单 `min_mem` 比对；无 swap 且 < 2GB 时提示 |
| 4 | 端口占用 | 80/443/3306/6379/11211/8080，带占用进程名 |
| 5 | 已装冲突 | 系统包 `nginx/httpd/php/mysql-server/mariadb-server/redis` + 已存在的 `/usr/local` 前缀 |
| 6 | glibc | 拿清单 `glibc=` 与 `ldd --version` 比对，直接拦掉 `GLIBC_2.28 not found` |
| 7 | 时间同步 | `timedatectl` / `timesync` / `chronyc` / `ntpq` 四路探测 |
| 8 | DNS 与外网 | 域名解析 + **IP 层连通性**（区分"真离线"与"DNS 配错"） |
| 9 | 基础命令 | `tar/gzip/xz`（缺了必然第一步失败）、`make/gcc/patch`、包管理器可用性 |
| 10 | 杂项 | `/tmp` 是否 `noexec`、SELinux、somaxconn/nofile 基线、locale 是否真实可用 |

退出码：`0` = 通过或有警告；`2` = 存在阻塞项。

真实安装前会自动跑一次；有 FAIL 会停下来询问，`-y` 下只告警继续（自动化不便交互）。

**DNS 这一项的细节**：域名全解析失败时，会再做一次绕开 DNS 的 IP 探测（ping `223.5.5.5` / `114.114.114.114`）。
能通就判定为 **DNS 配置问题**（而不是机器离线），并直接打印 `resolv.conf` 内容与修复方法：

```bash
echo "nameserver 223.5.5.5" >> /etc/resolv.conf
```

---

## 10. 装后自检 `verify`

装完自动执行，也可随时单独跑。

```bash
bash install.sh verify            # 自动探测：按已安装产物判断组件，版本比对自动跳过
```

严格模式（交付验收用，版本逐一与 `versions.conf` 比对）：

```bash
bash install.sh verify --nginx 1.30.6 --php 8.3.36:fpm --mysql 8.0.46 \
  --redis 7.4.9 --phpredis 6.3.0 --memcached 1.6.45 --php-memcached 3.4.0 \
  --swoole 6.2.3 --composer --nodejs 16.20.2 --php-imagick \
  --phpmyadmin --adminer --fail2ban
```

七类检查，每项独立计数、互不中断，最后汇总：

| # | 检查 | 判据 |
|---|---|---|
| 1 | 服务状态 | `systemctl is-active` nginx / httpd / php-fpm / mysqld / mariadb / redis / memcached / fail2ban / tomcat |
| 2 | 端口监听 | 80 / 3306 / 6379 / 11211 + php-fpm 的 Unix socket 是否存在 |
| 3 | **PHP 端到端解析** | 写探针到 `${WWWROOT}/web/`，`curl` 断言返回标记，并确认 **web 端**能看到 redis 扩展；phpMyAdmin / Adminer 页面 200 |
| 4 | 扩展生效 | `php -m` 断言 gd / mysqli / pdo_mysql / curl / mbstring / openssl / xml / zip / json（选了再加 redis / imagick） |
| 5 | 版本一致性 | `nginx -v` / `php -v` / `mysql --version` / `redis-server --version` 与清单比对 |
| 6 | 数据库连通 | 用 `/root/.mysql_root_password` 里的随机密码执行 `SELECT 1` |
| 7 | **Redis 密码一致性** | 用配置里的 `requirepass` 实际认证一次，失败即 FAIL 并给出修复命令 |

输出形如：

```
[OK] 自检通过 (verification passed): PASS=39 SKIP=6 FAIL=0
```

第 3 项抓的是「`.so` 编译出来了、`php -m` 也有，但 phpinfo 看不到」这类只在 web 端暴露的问题（必须重启 php-fpm）。
第 7 项抓的是「端口在监听 ≠ 能连上」：配置密码与运行实例不一致时，客户端全部 `WRONGPASS`，
而服务状态、端口监听、扩展检查**全都看不出来**。

---

## 11. 日常运维 `status` / `doctor`

### 11.1 `status`：现在怎么样

```bash
sudo bash install.sh status           # 一屏总览
bash install.sh status                # 普通用户也能跑（绝不写文件）
sudo bash install.sh status --brief   # 单行摘要，退出码 0=正常 1=有告警
```

内容：主机负载 / 内存 / 磁盘 / inode、各组件版本与服务状态、站点清单、证书剩余天数、
近期错误摘要、可升级组件提示。

### 11.2 `doctor`：哪里不对、怎么修

```bash
sudo bash install.sh doctor            # 每条问题都给可执行修复命令
sudo bash install.sh doctor --quiet    # 只列问题项（给巡检脚本）
```

检查的都是真机上会**静默出错**的点：

| 检查 | 典型现象 |
|---|---|
| unit 存在但二进制已删 | `systemctl start` 报 `No such file` |
| logrotate 指向不存在路径 | 日志无限增长，无人发现 |
| PHP 扩展 `.so` 缺失但 ini 还在 | php-fpm 启动即 `Unable to load dynamic library` |
| 端口被别的进程占用 | 服务 active 但访问 502 |
| 凭据权限过宽 | `/root/.mysql_root_password` 变成 644 |
| 数据库意外监听 0.0.0.0 | 公网可直连 3306（监听范围与防火墙是两道闸，这道是根本） |
| 旧模板站点缺上传防护 | 上传目录可执行 `.php` |

**`status` 与 `verify` 的分工**：`verify` 验"装对了吗"（会写探针、统计 FAIL）；`status` 看"现在怎么样"（绝不写任何文件）。

---

## 12. 安全检查 `scan`

```bash
sudo bash install.sh scan                                   # 扫 /home/wwwroot
sudo bash install.sh scan --path /home/wwwroot/a.com        # 只扫一个站
sudo bash install.sh scan --since 3                          # 只看 3 天内改过的脚本
sudo bash install.sh scan --fast                             # 跳过 vendor / dist / build / .cache
sudo bash install.sh scan --exclude cache --exclude '*/storage/logs'
sudo bash install.sh scan --quiet                            # 只输出发现项（cron/监控）
```

> `--exclude` 可重复：给**目录名**（`cache`）按任意层级匹配，给**路径片段**
> （`*/storage/logs`）按 `find -path` 匹配。默认已排除 `node_modules` / `.git` /
> `.svn` / `.hg`；启动时若发现排除表达式没被 `find` 接受会直接告警（历史上单引号
> 被当字面量，排除与 `--fast` 曾长期静默失效）。

结论分两级：**HIT**（基本可直接判死）与 **WARN**（需人看一眼）。**退出码 1 = 有发现**。

| 检查项 | 级别 | 说明 |
|---|---|---|
| 特征匹配 | HIT | `eval($_POST…)`、`assert($_GET…)`、`system/exec/passthru($_POST…)`、`call_user_func($_REQUEST…)`、`$f($_POST…)`、`eval(base64_decode…)`、`preg_replace(.../e)` |
| 上传目录里的可执行文件 | HIT | 与 vhost 的"上传目录禁执行"同一份名单 |
| 图片马 | HIT | 图片里出现 `<?php` |
| `.user.ini` / `.htaccess` 注入 | HIT | `auto_prepend_file` 会让每个请求先执行指定文件 |
| 权限 / 属主 | HIT/WARN | 全局可写文件（`o+w`）；站点根属主是 `www`（Web 进程能改自身代码 → 木马可持久化） |
| 近期改动 | WARN | 默认 7 天内改过的脚本（正常发版也命中，故只提示） |
| 可疑文件名 | WARN | `shell / cmd / backdoor / wso / b374k / c99 / r57 …` |

**设计取舍：绝不自动删除。** 误删业务代码的代价远大于漏报。报告只给隔离/取证命令：

```bash
mv suspicious.php /var/lib/lnamp/quarantine/
sha256sum suspicious.php > suspicious.php.sha256
```

---

## 13. 压测与调参 `bench`

装完之后 `worker_processes` / `pm.max_children` 该给多少，一直没人说得清 —— 48 核机器只开 1 个 worker、
2 核机器把 `pm.max_children` 开到 50，两种都见过。`bench` 的做法是：**本机打一遍静态与 PHP，
再按核数 / 内存 / 实测 worker RSS 反推**，给出"当前 vs 建议 vs 依据"。

```bash
sudo bash install.sh bench                          # 静态 + PHP，默认 -n 2000 -c 20
sudo bash install.sh bench -n 5000 -c 50            # 加压
sudo bash install.sh bench static                   # 只测静态
sudo bash install.sh bench php                      # 只测 PHP
sudo bash install.sh bench --url http://127.0.0.1/app/   # 打已有页面
sudo bash install.sh bench --apply                  # 把推荐值写回（备份 + 校验 + reload）
sudo bash install.sh bench --no-install             # 不自动装 ab，只做硬件推算
```

真机输出（16 核 / 31G / PHP 8.5）：

```
压测结果 (results)
  静态       27840.03 req/s   平均  0.718 ms   P95      1 ms   失败 0
  PHP         6636.29 req/s   平均  3.014 ms   P95      4 ms   失败 0

参数建议 (recommendations)
  项                            当前     建议     依据
  nginx worker_processes         auto       auto       当前 auto = 自动跟随核数（16 核），保持即可
  nginx worker_connections       51200      51200      当前 51200 已 ≥ 需求 1024，保持
  php-fpm pm.max_children        5          32         CPU 16 核 ×2 = 32；内存上限 592（更宽松）→ 取 CPU 上限  ← 建议调整
  php-fpm pm.start_servers       2          8          max_children / 4
  php-fpm pm.min_spare_servers   1          8          max_children / 4
  php-fpm pm.max_spare_servers   3          16         max_children / 2

  采样: php-fpm worker 平均 RSS 43 MB（压测后采样，已含扩展）
```

| 设计点 | 原因 |
|---|---|
| **默认只读** | 只在 `${WWWROOT}/web` 放两个临时探针（`__lnamp_bench.txt/.php`），测完即删 |
| `pm.max_children` 双上限 | 内存上限 = 可用内存×80% ÷ worker RSS；CPU 上限 = 核数×2；取小者 |
| RSS 在**压测后**采样 | 空闲时扩展未加载，RSS 偏低 → `max_children` 算大 → 上线 OOM |
| 小内存不硬抬下限 | 2G 内存 / 300MB per worker 只够 5 个，不会硬抬到 8 个把自己撑爆 |
| `auto` 不建议改成数字 | `worker_processes auto` 就等于核数，加核还自动跟上 |
| `worker_connections` 不降配 | 它是上限，当前值够用就不动 |
| `--apply` 区分两种语法 | nginx 要结尾分号，php-fpm 是 ini 风格**不要**分号 |
| `--apply` 用 SIGUSR2 | php-fpm 的 systemd unit 一般**没有** `ExecReload`，`systemctl reload` 返回 0 但什么都不做 |

压测工具优先 `ab`（apache2-utils / httpd-tools，缺失时自动装）→ `wrk` → 都没有则只做硬件推算并标注"未压测"。

> 压测会在本机产生真实负载，生产机请自行调小 `-n` / `-c`。

---

## 14. 备份与还原 `backup` / `restore`

### 14.1 备份

```bash
sudo bash install.sh backup                                  # 默认：MySQL 全量 + Redis RDB + 配置
sudo bash install.sh backup --with-site                      # 连站点代码（按 vhost 的 root 逐个打包）
sudo bash install.sh backup --only db,conf,site --dest /data/backups --keep 7
sudo bash install.sh backup --remote backup@10.0.0.9:/data/bk  # 异地（有 rsync 用 rsync，否则 scp）
sudo bash install.sh backup --dry-run                         # 只说要做什么
```

| 项 | 说明 |
|---|---|
| 默认范围 | `db,conf`（站点代码动辄几十 G，要带就显式 `--with-site` 或 `--only site`） |
| 输出 | `/root/lnamp-backups/lnamp-backup-<时间戳>.tar.gz` + 同名 `.sha256` |
| 凭据 | 默认**打包**（否则还原到新机连不上库），因此包等同密钥，落地即 `chmod 600` |
| 保留 | `--keep N`（默认 7），自动清理更早的包；**有分项失败时跳过轮转**，不让残缺包把最后一份好备份挤出去 |

### 14.2 还原

```bash
sudo bash install.sh restore /root/lnamp-backups/lnamp-backup-20261025_170000.tar.gz
sudo bash install.sh restore <包> --only conf        # 只还原配置（不动库、不动凭据文件）
sudo bash install.sh restore <包> --only db --with-credentials   # 库+凭据一起回（口令才一致）
sudo bash install.sh restore <包> --yes --restart    # 还原后自动重启受影响服务
```

还原前会**自动把当前状态再备份一份**（`--no-pre-backup` 跳过），并先校验 `.sha256`，不通过直接中止。
默认只提示需要重启哪些服务，不擅自动线上 —— 但**两个例外**：

- Redis 的 RDB 只能换文件，必须停服；既然是我们自己停的，还原后就**自动拉起来**
  （不等 `--restart`，否则业务侧只看到连接被拒）；
- `--only conf` **不会**覆盖 `/root/.*_password`：只改配置不动库时换掉口令文件，
  等于让"密码文件"与"库里实际口令"永久不一致。要一起还原请显式加
  `--with-credentials`（只在库也一并还原时才应该这么做）。

---

## 15. 升级 / 卸载 / 回滚

### 15.1 升级

```bash
sudo bash install.sh upgrade nginx 1.30.6            # 指定目标版本
sudo bash install.sh upgrade redis                   # 省略版本 = 升到清单默认版本
sudo bash install.sh upgrade php 8.4.27:fpm          # 可带形式
sudo bash install.sh upgrade mysql 8.4.13 --force    # 数据库必须显式 --force
```

流程：探测当前版本 → 打印 `当前 → 目标` → 配置备份成 `/root/lnamp-backup-<组件>-<时间戳>.tar.gz`
→ 升级模式安装 → 重建该组件的 PHP 扩展 ini。

> 当前版本探测对 IIS 伪装的 nginx 同样正确：`-v` 输出形如
> `nginx version: Microsoft-IIS/10.0/1.30.2`，取 `version: ` 后第一段的
> **最后一个 `/` 之后**才是真版本（1.30.2）；Tengine 的 `Tengine/3.1.0 (nginx/1.18.0)`
> 取第一段则得 3.1.0，不会误取括号里的 1.18.0。

升级模式下各组件的差异：

| 组件 | 差异 |
|---|---|
| MySQL / MariaDB | 只替换程序目录，`data/` 原样搬回；**绝不重新 `initialize`**（否则等于清库） |
| Redis | 沿用旧 `requirepass`，**不重新生成密码**（否则客户端全部连不上） |
| PHP | 升级后按 `php.d/*.ini` 自动重建已启用的扩展（phpredis / swoole / memcached / imagick）；imagick 也可用 `PHP_IMAGICK=yes` 环境变量或 `--php-imagick`（安装模式）指定 |
| 其它 | 配置照常覆盖，覆盖前留 `.bak.<时间戳>` |

> 数据库跨大版本（如 8.0 → 8.4）通常需要额外的数据字典升级步骤，安装器**不代做**，
> 只保证"程序换了、数据还在、旧程序备份了"。生产请先演练。

### 15.2 卸载

```bash
sudo bash install.sh uninstall --list                     # 列出本机已装组件（按探测，不靠记忆）
sudo bash install.sh uninstall --component redis
sudo bash install.sh uninstall --component mysql          # 默认保留 /data/mysql
sudo bash install.sh uninstall --component mysql --purge  # 连数据一起删（二次确认）
sudo bash install.sh uninstall --component phpredis       # 只摘 PHP 扩展
```

顺序（每步都做存在性判断，缺了跳过）：停服务 → 删 unit + `daemon-reload` → 删 logrotate / `profile.d`
→ 清理 `/usr/local/bin` 里的悬空软链 → 删安装前缀（数据库**默认只删程序、保 `/data`**）
→ 删额外文件 → PHP 扩展删 ini 与 `.so` 后 reload。

`--purge` 会再问一次；非交互（`-y`）时**不删数据**。

### 15.3 回滚

```bash
# 配置回滚
tar -xzf /root/lnamp-backup-nginx-20261023_094512.tar.gz -C /

# 单个配置文件
cp -a /etc/my.cnf.bak.20261023_053313 /etc/my.cnf

# 程序回滚：重装旧版本
sudo bash install.sh upgrade nginx 1.26.2
```

---

## 16. 内核调优 `sysctl` 与包索引镜像 `mirror`

### 16.1 `sysctl`

```bash
sudo bash install.sh sysctl      # 单独应用（幂等）
```

安装时由 `system_prep` 自动调用。调整项：

| 参数 | 默认 | 调到 | 不调的后果 |
|---|---|---|---|
| `net.core.somaxconn` | 128 | 65535 | accept 队列一满就**丢连接** |
| `net.ipv4.tcp_max_syn_backlog` | 1024 | 65535 | SYN 洪峰时半连接溢出 |
| `fs.file-max` / `nofile` | 1024 | 65535 | `Too many open files` |
| `net.core.netdev_max_backlog` | 1000 | 65535 | 网卡收包积压、软中断丢包 |
| `vm.swappiness` | 60 | 10 | 内存充足也换页，数据库延迟抖动 |

幂等策略：**逐项取优绝不回退**（`max` 类当前值更大就保留；`min` 类当前值更小就保留）；
整份内容未变化时连 `sysctl --system` 都不执行。

三份落地文件（路径可用同名环境变量覆盖）：

| 文件 | 作用 |
|---|---|
| `/etc/sysctl.d/99-lnamp.conf` | 内核参数 |
| `/etc/security/limits.d/99-lnamp.conf` | **登录会话**句柄上限 |
| `/etc/systemd/system.conf.d/99-lnamp.conf` | **systemd 服务**句柄上限 |

> 第三份必须有：`limits.d` 只对登录会话生效，对 systemd 拉起的 nginx / php-fpm / mysqld **完全无效**。
> 只写 limits.d 的话，服务起来还是 1024。

### 16.2 `mirror`

```bash
sudo bash install.sh mirror           # 查看当前包索引
sudo bash install.sh mirror cn        # 阿里云 Composer + npmmirror（默认）
sudo bash install.sh mirror official  # 恢复官方源
sudo bash install.sh mirror none      # 不改动
```

只改**包索引地址**（`composer config -g repo.packagist`、npm 全局 `registry`），
不碰安装器自己下载源码包的 `MIRROR_PRIMARY` / `MIRROR_FALLBACK`。幂等：值一致就跳过。

整栈安装时以 **soft 模式**运行：写入失败只告警、不中止安装；单独执行本命令仍返回非零，便于脚本判断。

---

## 17. 安装位置与产物

| 项 | 位置 |
|---|---|
| Nginx / Apache / PHP / Redis | `/usr/local/{nginx,apache,php,redis}` |
| Memcached / Node.js | `/usr/local/{memcached,node}` |
| Java / Tomcat / ImageMagick | `/usr/local/{java,tomcat,imagemagick}` |
| MySQL / MariaDB 数据 | `/data/mysql` / `/data/mariadb` |
| Composer | `/usr/local/bin/composer`（单文件 phar） |
| 网站根 | `/home/wwwroot` |
| 默认站点 | `/home/wwwroot/web`（支持 PHP，`http://IP/` 直接可访问） |
| 站点日志 | `/home/wwwlogs` |
| php-fpm socket | `/run/php/php-fpm.sock`（站点池 `/run/php/site_*.sock`） |
| PHP 错误日志 | `<php前缀>/var/log/php_errors.log`；FPM 主日志 `php-fpm.log` |
| phpMyAdmin / Adminer | `/home/wwwroot/web/{phpMyAdmin,adminer}` |
| MySQL root 密码 | `/root/.mysql_root_password`（600） |
| MariaDB root 密码 | `/root/.mariadb_root_password`（600） |
| Redis 密码 | `/root/.redis_password`（600） |
| vhost 配置 | nginx `/usr/local/nginx/conf/vhost/`；apache `/usr/local/apache/conf/extra/` |
| vhost 归档 | `/var/lib/lnamp/vhost-archive` |
| fail2ban jail | `/etc/fail2ban/jail.d/lnamp.local`（不动发行版 `jail.conf`） |
| 备份包 | `/root/lnamp-backups/` |
| 安装日志 | `logs/`（每组件一份 + `build_*.log` 总日志） |

源码/二进制安装的程序会自动写 `/etc/profile.d/lnamp-*.sh` 并软链到 `/usr/local/bin`，
装完即可直接 `nginx -V`、`php -v`、`mysql --version`、`redis-cli -v`、`node -v`、`composer -V`、`java -version`。

---

## 18. 环境变量与可覆盖路径

用于测试隔离、非标准部署、内网环境。

| 变量 | 默认 | 作用 |
|---|---|---|
| `LNAMP_CACHE` | `<安装器目录>/packages` | 本地包缓存目录，命中即不联网 |
| `MY_CNF_PATH` | `/etc/my.cnf` | 数据库主配置落地路径（systemd `--defaults-file` 跟着变） |
| `LDSO_CONF_DIR` | `/etc/ld.so.conf.d` | `ldconfig` 配置落地目录（nghttp2 / openssl / imagemagick） |
| `REDIS_CRED_FILE` | `/root/.redis_password` | Redis 密码文件路径 |
| `LNAMP_BACKUP_DIR` | `/root/lnamp-backups` | 备份输出目录 |
| `LNAMP_VHOST_ARCHIVE` | `/var/lib/lnamp/vhost-archive` | 站点配置归档目录 |
| `LNAMP_MAIN_OPEN_BASEDIR` | `${WWWROOT}` | 主池 `open_basedir` 范围（可收窄到默认站点） |
| `LNAMP_SKIP_MAIN_OPEN_BASEDIR` | 空 | 设为 `1` 完全关闭主池 `open_basedir` |
| `LNAMP_FPM_POOL_DIR` | `<php前缀>/etc/php-fpm.d` | php-fpm 池目录 |
| `MYSQL_BIND_ADDRESS` | `127.0.0.1` | 数据库监听地址；改成非回环**必须**同时 `LNAMP_DB_PUBLIC=yes` |
| `LNAMP_DB_PUBLIC` | 空 | `yes` 才允许数据库监听非回环地址 |
| `LNAMP_DB_PORTS` | `3306,3360` | 防火墙放行的数据库端口（**默认放行 3306 与 3360**；多实例再加，如 `3306,3360,33060`） |
| `LNAMP_DB_OPEN_PORTS` | `yes` | 设为 `no` 一个端口都不放通（仅靠回环监听，最严格） |
| `LNAMP_DB_CONF_DIRS` | `/etc/my.cnf.d /etc/mysql/conf.d …` | 数据库 drop-in 配置目录（测试隔离用） |
| `LNAMP_UPGRADE` | `0` | `1` = 升级模式：换程序文件、保留 datadir |
| `LNAMP_FORCE_DB_WIPE` | `no` | `yes` 才允许在非升级模式下清空已有数据目录（**会删库**） |
| `LNAMP_KEEP_MAIL` | `no` | `yes` 时 `disable_functions` 里保留 `mail()`（WordPress `wp_mail` 需要） |
| `LNAMP_DISABLE_FUNCTIONS_EXTRA` | 空 | 追加要禁用的 PHP 函数，逗号分隔 |
| `LNAMP_NODE_NO_FALLBACK` | `0` | `1` 关闭旧 glibc 上的 Node 版本自动回落 |
| `LNAMP_SCAN_EXCLUDE` | 空 | `scan` 额外排除的目录名/路径片段（等价于 `--exclude`） |
| `LNAMP_PROBE_STATE` | `/root/.lnamp_probes` | 临时探针登记文件 |
| `LNAMP_PROBE_TTL_MIN` | `15` | 探针自动删除延时（分钟，`0`=不自动删） |
| `LNAMP_LOCK_FILE` | `/var/run/lnamp.lock` | 并发锁文件 |
| `LNAMP_LOCK_WAIT` | `0` | 等锁秒数（`--lock-wait` 等价） |
| `LNAMP_LOGROTATE_DIR` | `/etc/logrotate.d` | logrotate 配置目录 |
| `SYSCTL_CONF` / `LIMITS_CONF` / `SYSTEMD_LIMITS_CONF` | 见 §16.1 | 三份调优文件路径 |

示例：

```bash
sudo MY_CNF_PATH=/data/mysql/my.cnf bash install.sh --mysql 8.4.13
sudo LNAMP_CACHE=/mnt/nas/lnamp-pkgs bash install.sh -y --nginx 1.30.6 --php 8.5.12:fpm
```

---

## 19. 离线与内网安装

`fetch` 的搜索顺序是：**本地缓存 → 官方源 → 镜像站兜底**。

```bash
# 方式 1：把包放进安装器的 packages/ 目录（文件名必须与官方一致）
ls lnamp/packages/
#   nginx-1.30.6.tar.gz  openssl-3.5.9.tar.gz  pcre2-10.47.tar.gz
#   php-8.5.12.tar.gz    zlib-1.3.2.tar.gz     mysql-8.4.13-linux-glibc2.28-x86_64.tar.xz

# 方式 2：指定任意缓存目录
sudo LNAMP_CACHE=/mnt/nas/lnamp-pkgs bash install.sh -y --nginx 1.30.6 --php 8.5.12:fpm
```

全部安装包的完整文件名与候选 URL 清单见 `packages/README.txt`（也可 `--dry-run` 打印）。

**内网实战建议**：

- 先在能上网的机器 `--dry-run`，从输出里抄下全部 URL，批量下载后按原名放进 `packages/`
- 大文件（MySQL 二进制 800MB、MariaDB 430MB、JDK 190MB）优先在本地下载再上传 ——
  真机上 GitHub / TUNA 的下载速度经常只有 30~40 KB/s
- 磁盘小的机器（< 25GB）可让 MySQL 走 **minimal 包 + 流式解压**：`curl -sL <url> | tar -xJ -C /data`，
  不落 tarball

---

## 20. 故障排查手册

### 20.1 现象速查

| 现象 | 最可能的原因 | 处理 |
|---|---|---|
| Redis 起不来，日志 `Failed to configure LOCALE for invalid locale name` | `/etc/locale.conf` 写了 `LANG=en_US.UTF-8` 但系统没真正生成 | 安装器会自动修复（`localedef` → 装语言包 → 回退 `C.utf8`）；手工：`localedef -i en_US -f UTF-8 en_US.UTF-8` |
| `node -v` 报 `GLIBC_2.28 not found` | CentOS 7（glibc 2.17）装了 Node 18+ | 用 `--nodejs 16.20.2` |
| `mysqld` 启动报 `No data dictionary version number found` | `initialize` 中途失败（多为磁盘写满） | 清盘后重跑；校验已改为检查 `data/mysql.ibd` 与 `#innodb_redo` |
| PHP 7.4 编译报 `discards 'const' qualifier` | 链了 OpenSSL 3.x（7.4 只支持 1.1.1） | 已修：7.x 自动编独立 OpenSSL 1.1.1；旧包请升级 |
| Debian 12 上 fail2ban `status=255`，日志 `Have not found any log file for sshd jail` | 无 rsyslog，`/var/log/auth.log` 不存在 | 已修：自动探测日志，缺失时 `backend = systemd` 读 journal |
| `php-fpm -t` 报 `the chdir path ... does not exist` | 站点目录被删、池还在 | `bash install.sh vhost prune --yes` |
| `systemctl reload php-fpm` 返回 0 但配置没生效 | 该 unit 没有 `ExecReload` | `kill -USR2 $(cat <prefix>/var/run/php-fpm.pid)`；`bench --apply` 已内置 |
| 站点 A 能读到站点 B 的 `config.php` | 该站点还在用全局池 | `bash install.sh vhost rebind --all` |
| 改了 `php.d/*.ini` 但 `phpinfo` 看不到 | php-fpm 未重启 | `systemctl restart php-fpm`；`verify` 第 3 项专抓这个 |
| 浏览器访问 502 | php-fpm 没起 / socket 路径不匹配 / 池 `chdir` 失效 | `systemctl status php-fpm` + `php-fpm -t` + `vhost list` 看 `NOTE` |
| apache 编译报 `./configure: No such file` | 拿到了 git 快照（无 autotools 产物） | 已修：官方 release 优先 + `autoreconf -i` 兜底；用最新安装包 |
| tengine 报 `invalid option "--with-http_upstream_check_module"` | 抄了 tengine 2.x 的参数 | 清单已移除该参数，用最新 `versions.conf` |
| `precheck` 说"官方源不可用，请预放安装包" | 实际是 DNS 配错 | 看同段输出里的 IP 探测结论；`echo "nameserver 223.5.5.5" >> /etc/resolv.conf` |
| PHP 7 编译到 bz2 探测时报 `bz2 module requires libbz2`，但 `bzip2-devel` 已装 | 同一次链接里混了两套 libcrypto（`libk5crypto.so: undefined reference to EVP_KDF_derive@OPENSSL_1_1_1b`），报错指向的 bz2 只是第一个受害者 | 已修：系统是 1.1.1 就用系统的、是 3.x 才自编并关掉 LDAP/Kerberos；旧包请升级 |
| 安装成功、`php -m` 却没有 `zip`（`verify` 报"扩展未加载: zip"） | PHP 7.4 只认 `--with-zip`，而 `--enable-zip` 被 autoconf 静默忽略 | 已修：按 `configure --help` 探测开关名；旧包手工补：重编时把 `--enable-zip` 换成 `--with-zip` |
| MySQL 5.7 装完报"数据字典未生成 / mysql.ibd 缺失" | 校验套用了 8.x 判据（5.7 没有 `mysql.ibd`，系统表是 `data/mysql/*.frm`） | 已修：按 6/8.x 与 5.x 分别校验；旧包升级后重跑即可（会跳过已存在的 datadir） |
| SSH 能建 TCP 但一直卡在握手（`kex_exchange_identification: Connection closed`），80 端口正常 | sshd 子进程起不来（privsep 目录缺失 / fork 失败），unit 仍显示 active | `mkdir -p /run/sshd && systemctl restart sshd`；`bash install.sh doctor` 的"SSH 可登录性"会真读一次 banner 判定 |
| `tar: command not found` | 最小化系统 | `dnf install -y tar` / `apt install -y tar`（`precheck` 第 9 项会提前报） |
| 数据库能从别的机器连上（3306 对外） | 包管理器装的库用的是发行版配置：MariaDB 官方 `server.cnf` 写 `bind-address=0.0.0.0`，MySQL 社区 RPM 干脆不写 | 已修：装完统一收敛到 `127.0.0.1`（`zz-lnamp-bind.cnf`）；存量机器执行 `bash install.sh doctor` 看"监听范围"，或手工改 `bind-address = 127.0.0.1` 后 `systemctl restart mysqld` |
| 确需远程连库 | 默认只听回环 | `MYSQL_BIND_ADDRESS=内网IP LNAMP_DB_PUBLIC=yes bash install.sh --mysql <版本>`，并只在防火墙放行可信来源 IP（不要 0.0.0.0 裸奔） |
| 站点首页打开就是 phpinfo | 老版本建站默认生成了 `index.php` | 已修：默认只生成静态 `index.html`；存量删掉 `index.php` 即可，`doctor` 的"phpinfo 残留"项会列出来 |
| `No space left on device` | 17G 盘装全套 | 见 §20.2 |
| `Another lnamp instance is running` | 并发锁 | 等它结束，或 `--lock-wait 600`；确认无进程后 `rm -f /var/run/lnamp.lock` |
| fail2ban 启动失败 `Have not found any log file` | jail 日志路径与实际不符（源码装的 apache 日志不在 `/var/log/apache2/`） | 已修：按实际安装探测 + 启动后校验，不活则降级为仅 sshd jail |

### 20.2 磁盘不够（小盘机器）

顺序建议：

```bash
apt-get clean; dnf clean all                     # 包缓存
journalctl --vacuum-size=50M                     # 日志
rm -rf /usr/share/doc/* /usr/share/man/*         # 文档
rm -rf /usr/share/locale/* /usr/share/i18n       # 语言包（只在确定不用时）
apt-get purge linux-image-<旧内核>               # 旧内核（保留当前运行版本！）
```

MySQL 走流式解压不落 tarball：

```bash
mkdir -p /data && curl -sL <mysql-minimal.tar.xz> | tar -xJ -C /data
```

装完立刻删源码目录与无用的 `.a` / `include`。**17G 盘装源码 Web + MySQL binary + JDK + 全套插件属极限操作**，
正式环境请 ≥25GB，或用 `pkg` 形式。

### 20.3 下载太慢

```bash
# 在快的机器上下载，再传到目标机 packages/ 目录
curl -sL -o openssl-3.5.9.tar.gz https://codeload.github.com/openssl/openssl/tar.gz/refs/tags/openssl-3.5.9
scp openssl-3.5.9.tar.gz root@target:/root/lnamp/packages/
```

命中缓存时 `fetch` 会打印 `<= 本地缓存`，完全不联网。

### 20.4 重跑安装会不会从头编译

不会。nginx / php / mysql 都有幂等判断：`nginx -v`、`php -v`、`mysqld --version` 与目标版本一致就跳过下载与编译
（flavor 前缀如 `freenginx-` / `tengine-` 会先剥掉再比）。中途失败后直接重跑即可续上。

### 20.5 拿不准就先干跑

```bash
bash install.sh --nginx 1.30.6 --php 8.5.12:fpm --mysql 8.4.13:binary --dry-run
```

干跑会打印：每个包的完整 URL 候选链、将执行的 `configure` / `make`、将安装的系统包、
将写入的配置文件、将启动的服务、将开放的端口。计划同时落盘到 `logs/dryrun_<时间戳>.log`。

### 20.6 装完不放心

```bash
bash install.sh status      # 现在怎么样（只读）
bash install.sh verify      # 装对了吗（写探针，统计 FAIL）
bash install.sh doctor      # 有什么隐患（只读，给修复命令）
```

---

## 21. 测试与验证矩阵

### 21.1 跑测试

```bash
bash tests/run_all.sh       # 全部套件 + 干跑副作用审计
bash tests/smoke.sh         # 主套件（函数级 + 静态检查）
```

| 套件 | 内容 |
|---|---|
| `smoke.sh` | 358 断言：清单解析、参数校验、路径守卫、vhost 全套、bench 算法、幂等跳过、PHP7 的 OpenSSL 约束、MySQL 5.7 校验分支 |
| `smoke2.sh` | 62 断言：边界与回归 |
| `fetch_sim.sh` | 13 项：下载链路（URL 顺序与回退） |
| `newfn_sim.sh` | 36 项：新增函数行为 |
| `dryrun_sim.sh` | 端到端干跑 + **双重副作用审计**（路径 + 内容指纹） |

干跑审计分两轮：① 42 个关键路径是否被意外创建；② 已存在配置文件的内容指纹是否被改写。
第二轮是被一个真实缺陷逼出来的：`redis_set_random_password()` 曾漏掉 `DRY_RUN` 保护，
干跑真的改写了运行中 Redis 的密码却没重启 → 客户端全部 `WRONGPASS`。

### 21.2 真机实测记录

| 主机 / 系统 | 配置 | 结果 |
|---|---|---|
| Ubuntu 24.04 | nginx 1.30.6 源码 + MySQL 8.4.13 binary + PHP 8.4.27 fpm + 全套插件 + vhost | ✅ `verify 38/0`；建站→200→删站 通过 |
| Ubuntu 22.04 | Apache 2.4.69 源码(event) + MariaDB 11.8.8 + PHP 8.3.36 **mod_php** + Tomcat + JDK17 | ✅ `verify 36/0` |
| Rocky 9.8 | nginx 1.30.6 + MySQL 8.4.13 + PHP 8.5.12 fpm + Tomcat + Node.js | ✅ `verify 39/0` |
| Rocky 9.8 | nginx + Tomcat 10.1.55 + JDK17 + MySQL 9.7.4 + PHP 8.5.12 | ✅ `verify 39/0` |
| Ubuntu 24.04（**17G 盘**） | freenginx 1.31.4 + MySQL 8.4.13 + PHP 8.4.27 + Tomcat + JDK17 | ⚠️ 装完 `verify 37/0`，随后磁盘写满导致整机宕机 |
| Rocky 8.10 | tengine 3.1.0 + MySQL 8.0.46 + PHP 8.2.35 + Tomcat + Node.js | ⚠️ 中途整机宕机（磁盘空闲 57G，非空间问题），未完成 |
| Rocky 8.10 | **Apache 2.4.69 + MariaDB 11.8.8 + PHP 8.3.36 mod_php** + Tomcat + JDK17 | ✅ `verify 37/0` |
| Ubuntu 22.04 | nginx 1.30.6 + MySQL 9.7.4 + PHP 8.5.12 + Tomcat + Node.js | ✅ `verify 39/0` |
| Ubuntu 22.04 | **tengine 3.1.0** + MySQL 8.0.46 + PHP 8.2.35 + Tomcat + Node.js | ✅ `verify 39/0` |
| Ubuntu 24.04 | **Apache 2.4.69 + PHP 8.4.27 mod_php** + MySQL 9.7.4 + Tomcat + Node.js | ✅ `verify 38/0` |
| Ubuntu 24.04 | **tengine 3.1.0** + MySQL 8.4.13 + PHP 8.4.27 + Tomcat + Node.js | ✅ `verify 39/0` |
| **Debian 12** | nginx 1.30.6 + MySQL 9.7.4 + PHP 8.5.12 + Tomcat + Node.js | ✅ `verify 39/0`（修 fail2ban 后） |
| Rocky 8.10 | **freenginx 1.31.4 + MySQL 5.7.44 + PHP 7.4.33 + Tomcat + JDK17** + 全插件 | ✅ `verify 38/0`，建站/删站通过（`SAPI=fpm-fcgi V=7.4.33 other=blocked zip=on`） |

容器矩阵（完整安装 + 自检 + 端到端）：Ubuntu 22.04 / 24.04、Rocky 8 / 9、CentOS 7、
CentOS Stream 8、Debian 11 / 12。

> 标注 ⚠️ 的两台中断都在**宿主机层面**（17G 盘写满 / 疑似 OOM），不是安装器逻辑问题。
> freenginx + MySQL 5.7 + PHP 7.4 这条老栈最终在 Rocky 8.10（10.53.222.181）上 `verify 38/0` 通过；
> 此前 224 / 184 两台装到一半 sshd 失去握手能力（端口通、无 banner），处置见 §20.1 最后一条。

### 21.3 安全默认值

| 项 | 默认 |
|---|---|
| 数据库 / Redis 密码 | 安装时随机生成，存 `/root/.{mysql_root,mariadb_root,redis}_password`（600） |
| **MySQL / MariaDB** | 只监听 `127.0.0.1`（`bind-address` + `mysqlx-bind-address`）；防火墙默认放行 `3306,3360`（`LNAMP_DB_PORTS`），`LNAMP_DB_OPEN_PORTS=no` 可全关 |
| Redis | 只监听 `127.0.0.1`，`protected-mode yes`，必带 `requirepass` |
| Memcached | 强制 `-l 127.0.0.1`，**不开防火墙端口**（无认证，历史上被用于 UDP 放大攻击） |
| **站点首页** | 静态 `index.html`；**不生成 `phpinfo()`**，验证改用 `vhost probe`（临时、用完即删） |
| PHP | `expose_php Off`、`display_errors Off`、`cgi.fix_pathinfo=0`、`disable_functions`（含 `mail` / `link`；`putenv` 不禁——Composer 等管理工具依赖，2026-10-27 决策放行） |
| Nginx | `server_tokens off`、`Server` 伪装、上传目录禁执行 |
| 站点 | 每站点独立池 + `open_basedir`（读不到别家源码）；网站根拒绝 `/`、`/etc` 等系统目录 |
| 数据库重装 | 非升级模式下检测到已有数据字典会**拒绝删除**（先 dump 或显式声明才继续） |
| fail2ban | sshd（始终）+ web 相关 jail（检测到 Web 服务器才启用） |

> `disable_functions` 刻意**保留** `chmod`、`set_time_limit` 等框架常用函数 —— 禁了 `chmod` 会让
> Twig / Composer / WordPress 报 `Call to undefined function chmod()`；禁了 `set_time_limit` 会让 Adminer / phpMyAdmin 报错。
> `mail` 已在禁用列表里（第五个参数可注入 sendmail 参数），WordPress 之类要用 `wp_mail()` 的站点
> 请用 `LNAMP_KEEP_MAIL=yes` 装，或装完手工从 `disable_functions` 里去掉；另需追加用
> `LNAMP_DISABLE_FUNCTIONS_EXTRA=函数名,函数名`。

---

## 22. 附录：命令速查

```bash
# ── 安装 ────────────────────────────────────────────────
bash install.sh                                   # 交互菜单
bash install.sh --list                            # 列出所有版本与形式
bash install.sh --help                            # 完整帮助
bash install.sh -y --nginx 1.30.6 --php 8.5.12:fpm --mysql 8.4.13:binary --redis --phpredis
bash install.sh ... --dry-run                      # 只打印计划
bash install.sh ... --lock-wait 600                # 等锁

# ── 站点 ────────────────────────────────────────────────
bash install.sh vhost example.com 80 /home/wwwroot/example.com [nginx|apache]
bash install.sh vhost list
bash install.sh vhost probe example.com            # 临时 phpinfo 探针（验证后 --rm）
bash install.sh vhost probe --list | --rm [域名]
bash install.sh vhost disable|enable example.com
bash install.sh vhost ssl example.com [--cert F --key F | --self-signed] [--no-redirect] [--hsts 秒]
bash install.sh vhost rebind example.com | --all [--shared]
bash install.sh vhost del example.com [--purge] [--yes]
bash install.sh vhost del --file /path/to/broken.conf
bash install.sh vhost prune [--yes] [--purge-dirs] [--disabled] [--archive-keep N]

# ── 质量 ────────────────────────────────────────────────
bash install.sh precheck [组件参数]
bash install.sh verify [组件参数...]
bash install.sh status [--brief]
bash install.sh doctor [--quiet]
bash install.sh scan [--path 目录] [--since N] [--fast] [--quiet]
bash install.sh bench [static|php|both] [-n N] [-c C] [--url URL] [--apply]

# ── 数据 ────────────────────────────────────────────────
bash install.sh backup [--with-site] [--only db,conf,site] [--dest DIR] [--keep N] [--remote u@h:/p]
bash install.sh restore <包> [--only ...] [--yes] [--restart] [--no-pre-backup]
bash install.sh upgrade <组件> [版本[:形式]] [--force]
bash install.sh uninstall --list
bash install.sh uninstall --component <组件> [--purge]

# ── 系统 ────────────────────────────────────────────────
bash install.sh sysctl
bash install.sh mirror [cn|official|none]

# ── 测试 ────────────────────────────────────────────────
bash tests/run_all.sh
```

---

## 目录结构（想改代码看这里）

```
install.sh        主入口：参数解析 / 交互菜单 / 编排 / 守卫
versions.conf     清单：所有版本×形式、镜像、前缀
lib/common.sh     公共库：日志/下载(fetch)/OS检测/包抽象/清单解析/my.cnf/扩展启用
modules/*.sh      各组件：nginx apache php mysql mariadb redis deps vhost
                  phpmyadmin adminer java verify fail2ban memcached swoole
                  devtools(composer/node) uninstall(upgrade) sysctl precheck
                  mirror status doctor scan backup bench
conf/             nginx.conf 优化参考 + conf/lnamp 片段
packages/         离线包缓存（README.txt 列全部文件名与 URL）
tests/            run_all.sh + smoke.sh + smoke2.sh + fetch_sim.sh
                  + newfn_sim.sh + dryrun_sim.sh
```

**新增一个版本**：只需在 `versions.conf` 对应 `*_VERSIONS` 数组加一行 `版本|形式|元数据`，无需改模块。

```bash
# 例：新增 PHP 8.6.0
"8.6.0|fpm,apache|openssl=3.5.9;min_mem=2000;ext=8;phpredis=6.3.0"
```
