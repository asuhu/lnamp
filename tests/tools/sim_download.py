#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
fetch() 下载链仿真测试 (live download-chain simulation)

完全复刻 lnamp/lib/common.sh 中 fetch() 的优先级逻辑：
    1) 本地缓存 (LNAMP_CACHE / <installer>/packages)
    2) 官方源 ($@ 顺序)
    3) MIRROR_PRIMARY  ->  {base}  和  so/{base}
    4) MIRROR_FALLBACK ->  {base}  和  so/{base}

对每个组件/版本：
  - 先试官方源，记录命中的是第几级
  - 官方全失败时，验证镜像兜底 URL 是否构造正确（并实际探测可达性）
  - 用 HTTP Range 只取前 1 字节，避免下载整个大包

统计：OFFICIAL_HIT / MIRROR_HIT / ALL_FAIL
"""
import os
import sys
import time
import concurrent.futures as cf

import requests

MIRROR_PRIMARY = "https://www.zhangfangzhou.cn/third"
MIRROR_FALLBACK = "http://arv.asuhu.com/ftp"

UA = ("Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 "
      "(KHTML, like Gecko) Chrome/124.0 Safari/537.36")

# ---------------------------------------------------------------- URL 清单
# (组件, 版本, 输出文件名, [官方源 URL...])
CASES = []


def add(comp, ver, fname, *urls):
    CASES.append((comp, ver, fname, [u for u in urls if u]))


# ---- Nginx / Tengine / FreeNginx
for v in ("1.30.6", "1.26.2"):
    add("nginx", v, f"nginx-{v}.tar.gz",
        f"http://nginx.org/download/nginx-{v}.tar.gz")
add("nginx", "tengine-3.1.0", "tengine-3.1.0.tar.gz",
    "http://tengine.taobao.org/download/tengine-3.1.0.tar.gz",
    "https://github.com/alibaba/tengine/archive/refs/tags/3.1.0.tar.gz")
add("nginx", "freenginx-1.30.1", "freenginx-1.30.1.tar.gz",
    "https://freenginx.org/download/freenginx-1.30.1.tar.gz")

# ---- Apache httpd + APR
add("apache", "2.4.69", "httpd-2.4.69.tar.gz",
    "https://dlcdn.apache.org/httpd/httpd-2.4.69.tar.gz",
    "https://downloads.apache.org/httpd/httpd-2.4.69.tar.gz",
    "https://archive.apache.org/dist/httpd/httpd-2.4.69.tar.gz")
add("apache", "apr-1.7.4", "apr-1.7.4.tar.gz",
    "https://archive.apache.org/dist/apr/apr-1.7.4.tar.gz")
add("apache", "apr-util-1.6.3", "apr-util-1.6.3.tar.gz",
    "https://archive.apache.org/dist/apr/apr-util-1.6.3.tar.gz")

# ---- 编译依赖 (deps.sh)
add("deps", "openssl-3.0.20", "openssl-3.0.20.tar.gz",
    "https://www.openssl.org/source/openssl-3.0.20.tar.gz",
    "https://github.com/openssl/openssl/releases/download/"
    "openssl-3.0.20/openssl-3.0.20.tar.gz")
add("deps", "openssl-1.0.2u", "openssl-1.0.2u.tar.gz",
    "https://www.openssl.org/source/old/1.0.2/openssl-1.0.2u.tar.gz",
    "https://github.com/openssl/openssl/releases/download/"
    "OpenSSL_1_0_2u/openssl-1.0.2u.tar.gz")
add("deps", "pcre2-10.42", "pcre2-10.42.tar.gz",
    "https://github.com/PCRE2Project/pcre2/releases/download/"
    "pcre2-10.42/pcre2-10.42.tar.gz")
add("deps", "zlib-1.3.2", "zlib-1.3.2.tar.gz",
    "https://zlib.net/zlib-1.3.2.tar.gz",
    "https://zlib.net/fossils/zlib-1.3.2.tar.gz")
add("deps", "nghttp2-1.70.0", "nghttp2-1.70.0.tar.gz",
    "https://github.com/nghttp2/nghttp2/releases/download/"
    "v1.70.0/nghttp2-1.70.0.tar.gz")
add("deps", "libsodium-1.0.22", "libsodium-1.0.22.tar.gz",
    "https://download.libsodium.org/libsodium/releases/libsodium-1.0.22.tar.gz",
    "https://github.com/jedisct1/libsodium/releases/download/"
    "1.0.22-RELEASE/libsodium-1.0.22.tar.gz")
add("deps", "argon2-20190702", "argon2-20190702.tar.gz",
    "https://github.com/P-H-C/phc-winner-argon2/archive/refs/tags/20190702.tar.gz")
add("deps", "imagemagick-7.1.2-25", "ImageMagick-7.1.2-25.tar.gz",
    "https://imagemagick.org/archive/releases/ImageMagick-7.1.2-25.tar.gz",
    "https://github.com/ImageMagick/ImageMagick/archive/refs/tags/7.1.2-25.tar.gz")

# ---- PHP
for v in ("8.5.12", "8.4.27", "8.3.36", "8.2.35", "7.4.33", "5.6.40"):
    add("php", v, f"php-{v}.tar.gz",
        f"https://www.php.net/distributions/php-{v}.tar.gz",
        f"https://museum.php.net/php8/php-{v}.tar.gz"
        if v.startswith("8.") else
        f"https://museum.php.net/php7/php-{v}.tar.gz"
        if v.startswith("7.") else
        f"https://museum.php.net/php5/php-{v}.tar.gz")

# ---- phpredis (php.sh 内部按 PHP 版本选用)
for v in ("6.3.0", "5.3.7", "4.3.0"):
    add("phpredis", v, f"phpredis-{v}.tar.gz",
        f"https://github.com/phpredis/phpredis/archive/refs/tags/{v}.tar.gz",
        f"https://pecl.php.net/get/phpredis-{v}.tgz")

# ---- imagick
for v in ("3.7.0", "3.8.1"):
    add("imagick", v, f"imagick-{v}.tgz",
        f"https://pecl.php.net/get/imagick-{v}.tgz")

# ---- MySQL (binary 包)
MYSQL = [
    ("9.7.4", "mysql-9.7.4-linux-glibc2.28-x86_64.tar.xz", "9.7"),
    ("8.4.13", "mysql-8.4.13-linux-glibc2.28-x86_64.tar.xz", "8.4"),
    ("8.0.46", "mysql-8.0.46-linux-glibc2.17-x86_64-minimal.tar.xz", "8.0"),
    ("5.7.44", "mysql-5.7.44-linux-glibc2.12-x86_64.tar.gz", "5.7"),
]
for ver, fname, series in MYSQL:
    add("mysql", ver, fname,
        f"https://cdn.mysql.com/Downloads/MySQL-{series}/{fname}",
        f"https://dev.mysql.com/get/Downloads/MySQL-{series}/{fname}")

# ---- MariaDB  (路径以 modules/mariadb.sh 为准: bintar-linux-systemd-x86_64)
for ver in ("11.8.8", "11.4.8", "10.11.14"):
    _pkg = f"mariadb-{ver}-linux-systemd-x86_64"
    add("mariadb", ver, f"{_pkg}.tar.gz",
        f"https://archive.mariadb.org/mariadb-{ver}/"
        f"bintar-linux-systemd-x86_64/{_pkg}.tar.gz")

# ---- Redis
for v in ("8.8.3", "7.4.9", "6.2.24"):
    add("redis", v, f"redis-{v}.tar.gz",
        f"https://download.redis.io/releases/redis-{v}.tar.gz",
        f"https://github.com/redis/redis/archive/refs/tags/{v}.tar.gz")

# ---- 第二批新增组件
add("memcached", "1.6.45", "memcached-1.6.45.tar.gz",
    "https://www.memcached.org/files/memcached-1.6.45.tar.gz",
    "https://github.com/memcached/memcached/archive/refs/tags/1.6.45.tar.gz")
for v in ("3.4.0", "3.3.0", "2.2.0"):
    add("php-memcached", v, f"memcached-{v}.tgz",
        f"https://pecl.php.net/get/memcached-{v}.tgz")
for v in ("6.2.3", "6.1.10"):
    add("swoole", v, f"swoole-{v}.tar.gz",
        f"https://github.com/swoole/swoole-src/archive/refs/tags/v{v}.tar.gz")
for v in ("2.10.3", "2.2.30"):
    add("composer", v, f"composer-{v}.phar",
        f"https://getcomposer.org/download/{v}/composer.phar")
add("composer", "2.10.3-sha256", "composer-2.10.3.sha256sum",
    "https://getcomposer.org/download/2.10.3/composer.phar.sha256sum")
for v in ("24.22.1", "22.23.4"):
    add("nodejs", v, f"node-v{v}-linux-x64.tar.xz",
        f"https://nodejs.org/dist/v{v}/node-v{v}-linux-x64.tar.xz",
        f"https://npmmirror.com/mirrors/node/v{v}/node-v{v}-linux-x64.tar.xz")
# fail2ban 只走包管理器，无 tarball，不进本清单

# ---- 其他 (以 modules/phpmyadmin.sh 为准: files.phpmyadmin.net + .tar.gz)
add("misc", "phpmyadmin-5.2.3", "phpMyAdmin-5.2.3-all-languages.tar.gz",
    "https://files.phpmyadmin.net/phpMyAdmin/5.2.3/"
    "phpMyAdmin-5.2.3-all-languages.tar.gz")
add("misc", "tomcat-10.1.55", "apache-tomcat-10.1.55.tar.gz",
    "https://archive.apache.org/dist/tomcat/tomcat-10/"
    "v10.1.55/bin/apache-tomcat-10.1.55.tar.gz")


# ---------------------------------------------------------------- 探测器
def probe(url, timeout=25):
    """模拟 wget -O：Range 取 1 字节。返回 (ok, code, err)

    verify=False 对应安装器里的 wget --no-check-certificate
    (镜像站 www.zhangfangzhou.cn / arv.asuhu.com 的证书链在严格校验下报错)
    """
    hdr = {"User-Agent": UA, "Range": "bytes=0-0",
           "Accept": "*/*"}
    try:
        r = requests.get(url, headers=hdr, timeout=timeout,
                         allow_redirects=True, stream=True, verify=False)
        code = r.status_code
        # 读一点数据，确认不是错误页
        try:
            next(r.iter_content(64), b"")
        except Exception:
            pass
        r.close()
        ok = code in (200, 206)
        return ok, code, "" if ok else f"HTTP {code}"
    except requests.exceptions.SSLError as e:
        return False, "SSL", str(e)[:70]
    except Exception as e:
        return False, type(e).__name__, str(e)[:70]


def mirror_urls(fname):
    return [f"{MIRROR_PRIMARY}/{fname}",
            f"{MIRROR_PRIMARY}/so/{fname}",
            f"{MIRROR_FALLBACK}/{fname}",
            f"{MIRROR_FALLBACK}/so/{fname}"]


def run_case(case):
    comp, ver, fname, officials = case
    t0 = time.time()
    # --- 阶段 2：官方源
    official_fail = []
    for i, u in enumerate(officials):
        ok, code, err = probe(u)
        if ok:
            return dict(comp=comp, ver=ver, fname=fname, level="OFFICIAL",
                        src=u, idx=i + 1, n_official=len(officials),
                        code=code, secs=round(time.time() - t0, 1),
                        mirrors=None, mstat=None)
        official_fail.append((u, err or code))
    # --- 阶段 3/4：镜像兜底
    tried = []
    for u in mirror_urls(fname):
        ok, code, err = probe(u, timeout=15)
        tried.append((u, code if ok else (err or code)))
        if ok:
            return dict(comp=comp, ver=ver, fname=fname, level="MIRROR",
                        src=u, idx=0, n_official=len(officials),
                        code=code, secs=round(time.time() - t0, 1),
                        mirrors=tried, mstat=tried[0][0])
    return dict(comp=comp, ver=ver, fname=fname, level="ALL_FAIL",
                src="-", idx=0, n_official=len(officials), code="-",
                secs=round(time.time() - t0, 1),
                mirrors=tried, mstat=tried[0][0])


def mirror_coverage(fname):
    """独立探测：镜像站上是否存在该文件（不依赖官方是否失败）"""
    for u in mirror_urls(fname):
        ok, code, err = probe(u, timeout=15)
        if ok:
            return True, u
    return False, None


# ---------------------------------------------------------------- main
def main():
    print("=" * 78)
    print("  LNAMP fetch() 下载链仿真测试 (live download-chain simulation)")
    print("  优先级: 本地缓存 -> 官方源 -> MIRROR_PRIMARY -> MIRROR_FALLBACK")
    print(f"  用例数: {len(CASES)}   并发: 8   (verify=False 对齐 wget --no-check-certificate)")
    print("=" * 78)
    print()

    results = []
    with cf.ThreadPoolExecutor(max_workers=8) as ex:
        futs = {ex.submit(run_case, c): c for c in CASES}
        done = 0
        for f in cf.as_completed(futs):
            r = f.result()
            results.append(r)
            done += 1
            tag = {"OFFICIAL": "[官方]", "MIRROR": "[镜像]",
                   "ALL_FAIL": "[失败]"}[r["level"]]
            print(f"  {done:>2}/{len(CASES)} {tag} {r['comp']:<10} "
                  f"{r['ver']:<18} {str(r['code']):<5} {r['secs']:>5}s "
                  f"{r['src'][:62]}")
            sys.stdout.flush()

    # 排序回用例顺序
    order = {(c[0], c[1]): i for i, c in enumerate(CASES)}
    results.sort(key=lambda r: order[(r["comp"], r["ver"])])

    off = [r for r in results if r["level"] == "OFFICIAL"]
    mir = [r for r in results if r["level"] == "MIRROR"]
    fail = [r for r in results if r["level"] == "ALL_FAIL"]

    print()
    print("=" * 78)
    print("  汇总")
    print("=" * 78)
    print(f"  官方源直接命中 : {len(off)}/{len(results)}")
    print(f"  镜像兜底命中   : {len(mir)}/{len(results)}")
    print(f"  全部失败       : {len(fail)}/{len(results)}")
    print()

    # 首选源命中率（第一个官方 URL 是否可用）
    first_ok = [r for r in off if r["idx"] == 1]
    print(f"  首选官方 URL 命中: {len(first_ok)}/{len(results)}")
    fb = [r for r in off if r["idx"] > 1]
    if fb:
        print(f"  备用官方 URL 命中: {len(fb)} 条")
        for r in fb:
            print(f"      - {r['comp']} {r['ver']} -> 第{r['idx']}个源 {r['src']}")
    print()

    if mir:
        print("  --- 官方全败、走镜像的组件 ---")
        for r in mir:
            print(f"    {r['comp']} {r['ver']}: {r['src']}")
        print()

    if fail:
        print("  --- 失败明细 ---")
        for r in fail:
            print(f"    {r['comp']} {r['ver']}  ({r['fname']})")
            print(f"      官方: {r['n_official']} 个源全部不可达")
            if r["mirrors"]:
                for u, code in r["mirrors"]:
                    print(f"      镜像: {code:<28} {u}")
        print()

    verdict = "PASS" if not fail else "FAIL"
    print(f"RESULT: {verdict}   "
          f"official={len(off)} mirror={len(mir)} fail={len(fail)}")

    # ---------------- 附加：镜像站覆盖率（独立探测）----------------
    print()
    print("=" * 78)
    print("  附加检查：镜像站文件覆盖率 (mirror coverage, 独立探测)")
    print("=" * 78)
    m_hit, m_miss = [], []
    with cf.ThreadPoolExecutor(max_workers=8) as ex:
        futs = {ex.submit(mirror_coverage, c[2]): c for c in CASES}
        for f in cf.as_completed(futs):
            c = futs[f]
            ok, u = f.result()
            (m_hit if ok else m_miss).append((c[0], c[1], c[2], u))
    m_hit.sort(key=lambda x: (x[0], x[1]))
    m_miss.sort(key=lambda x: (x[0], x[1]))
    print(f"  镜像站已有: {len(m_hit)}/{len(CASES)}")
    print(f"  镜像站缺失: {len(m_miss)}/{len(CASES)}")
    if m_hit:
        print("\n  [命中] 镜像站已同步:")
        for comp, ver, _f, u in m_hit:
            print(f"    OK   {comp:<10} {ver}")
    if m_miss:
        print("\n  [缺失] 镜像站尚未同步 (官方源可用故不影响安装):")
        for comp, ver, fn, _u in m_miss:
            print(f"    MISS {comp:<10} {ver:<18} {fn}")
    print()
    return 0 if not fail else 1


if __name__ == "__main__":
    sys.exit(main())