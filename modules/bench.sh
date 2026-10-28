#!/bin/bash
# ============================================================================
#  modules/bench.sh  ——  本地压测 + 并发参数推荐
# ----------------------------------------------------------------------------
#  解决的问题：worker_processes / pm.max_children 这类值，装的时候是"默认值"，
#  没人知道合不合适。机器 48 核却只开 1 个 worker，或者 2 核机器把
#  pm.max_children 开到 50 —— 两种都见过，但都没有数据支撑。
#
#  做法：
#    1) 在 127.0.0.1 上压静态文件与 PHP，拿到 QPS / 平均延迟 / P95；
#    2) 采样 php-fpm worker 的实际 RSS（压测后再采，此时扩展都已加载）；
#    3) 按 CPU 核数与内存两个上限反推 pm.max_children，取小者；
#    4) 与当前配置逐项对比，给出"当前 / 建议 / 依据"。
#
#  默认只读：不改任何配置。加 --apply 才写回（备份 → 配置校验 → reload，
#  失败自动回滚）。
#
#  用法:
#     install.sh bench                       # 静态 + PHP，默认 -n 2000 -c 20
#     install.sh bench -n 5000 -c 50         # 加大压力
#     install.sh bench static                # 只测静态
#     install.sh bench --url http://127.0.0.1/foo/   # 指定已有页面
#     install.sh bench --apply               # 顺手写回推荐值
#     install.sh bench --no-install          # 不自动装压测工具
# ============================================================================

BENCH_MARK="__lnamp_bench"

bench_usage() {
  cat <<EOF
用法:
  $0 bench [选项] [static|php|both]

选项:
  -n, --requests N     总请求数（默认 2000）
  -c, --concurrency N  并发数（默认 20）
  --url URL            压测指定 URL（默认用 127.0.0.1 上的临时探针）
  --apply              把推荐值写回配置（备份 + 校验 + reload，失败回滚）
  --no-install         不自动安装压测工具（ab 缺失时只做硬件推算）
  -h, --help           显示本帮助

说明:
  默认**只读**：只在 $WWWROOT/web 下临时放两个探针文件，测完即删，不动任何配置。
  压测会在本机产生真实负载；生产机请自行调小 -n/-c。
  压测工具优先用 ab（apache2-utils / httpd-tools），缺失时自动安装；
  装不上则跳过压测，仍按 CPU/内存给出推算值（会明确标注"未压测"）。
EOF
}

# ---- 工具 ------------------------------------------------------------------
_bench_pick_tool() {
  command -v ab  >/dev/null 2>&1 && { echo ab;  return 0; }
  command -v wrk >/dev/null 2>&1 && { echo wrk; return 0; }
  return 1
}

# 装压测工具。ab 在 debian 是 apache2-utils，rhel 是 httpd-tools。
_bench_ensure_tool() {
  local allow_install="$1" t
  t=$(_bench_pick_tool) && { echo "$t"; return 0; }
  [ "$allow_install" = 1 ] || return 1

  log "未找到压测工具，尝试安装 (ab)..." >&2
  case "$(_pc_pm 2>/dev/null || echo "${OS_FAMILY:-rhel}")" in
    apt|debian) pkg_install apache2-utils >/dev/null 2>&1 || true ;;
    *)          pkg_install httpd-tools   >/dev/null 2>&1 || true ;;
  esac
  t=$(_bench_pick_tool) && { echo "$t"; return 0; }
  return 1
}

# ---- 压测 ------------------------------------------------------------------
# 输出 "qps|avg_ms|p95_ms|failed"
_bench_ab() {
  local tool="$1" n="$2" c="$3" url="$4" out
  if [ "$tool" = "ab" ]; then
    out=$(ab -n "$n" -c "$c" -k "$url" 2>/dev/null)
  else
    # wrk：-t 线程数取 min(核, 4)，避免客户端自己成为瓶颈
    local th; th=$(_bench_cores); [ "$th" -gt 4 ] && th=4
    out=$(wrk -t"$th" -c"$c" -d"$(( n / (c > 0 ? c : 1) + 3 ))s" --latency "$url" 2>/dev/null)
  fi
  [ -n "$out" ] || { echo "0|0|0|0"; return 1; }

  if [ "$tool" = "ab" ]; then
    printf '%s' "$out" | awk '
      /Requests per second:/ { qps=$4 }
      /^ *50%/ { p50=$2 }
      /^ *95%/ { p95=$2 }
      /Time per request:/ { if ($0 ~ /\(mean\)/ && !seen) { avg=$4; seen=1 } }
      /Failed requests:/ { fail=$3 }
      END { printf "%s|%s|%s|%s\n", (qps?qps:0), (avg?avg:0), (p95?p95:0), (fail?fail:0) }'
  else
    printf '%s' "$out" | awk '
      /Requests\/sec:/ { qps=$2 }
      /Latency/ { avg=$2; sub(/ms/,"",avg) }
      /^ *95%/ { p95=$2; sub(/ms/,"",p95) }
      END { printf "%s|%s|%s|0\n", (qps?qps:0), (avg?avg:0), (p95?p95:0) }'
  fi
}

_bench_cores() { nproc 2>/dev/null || getconf _NPROCESSORS_ONLN 2>/dev/null || echo 1; }

_bench_mem_mb() {
  awk '/MemTotal/{printf "%d", $2/1024}' /proc/meminfo 2>/dev/null || echo 0
}

# php-fpm worker 平均 RSS（MB）。压测刚结束就采，此时扩展已全部加载，
# 数值才是真实常驻内存；空闲时采会明显偏低，导致 max_children 算大。
_bench_php_rss() {
  local pids p r sum=0 n=0
  pids=$(pgrep -f 'php-fpm: pool' 2>/dev/null)
  [ -n "$pids" ] || pids=$(pgrep -x php-fpm 2>/dev/null)
  for p in $pids; do
    r=$(awk '/VmRSS/{print $2}' "/proc/$p/status" 2>/dev/null)
    [ -n "$r" ] && { sum=$((sum + r)); n=$((n + 1)); }
  done
  if [ "$n" -gt 0 ]; then echo $((sum / n / 1024)); else echo 0; fi
}

# ---- 当前配置 --------------------------------------------------------------
_bench_nginx_conf() {
  local f
  for f in "${PREFIX_NGINX}/conf/nginx.conf" /etc/nginx/nginx.conf; do
    [ -f "$f" ] && { echo "$f"; return 0; }
  done
  return 1
}

_bench_cur_worker_processes() {
  local f; f=$(_bench_nginx_conf) || { echo "-"; return; }
  awk '/^[ \t]*worker_processes[ \t]/{gsub(/;/,"",$2); print $2; exit}' "$f" 2>/dev/null | sed 's/^$/auto/'
}

_bench_cur_worker_connections() {
  local f; f=$(_bench_nginx_conf) || { echo "-"; return; }
  awk '/^[ \t]*worker_connections[ \t]/{gsub(/;/,"",$2); print $2; exit}' "$f" 2>/dev/null
}

# php-fpm 主池文件：优先 www.conf，退回 php-fpm.conf 里 include 的任意池
_bench_fpm_pool() {
  local d f
  for d in "${PREFIX_PHP}/etc/php-fpm.d" /etc/php-fpm.d /usr/local/php/etc; do
    [ -f "${d}/www.conf" ] && { echo "${d}/www.conf"; return 0; }
    for f in "$d"/*.conf; do
      [ -f "$f" ] || continue
      grep -q '^[ \t]*pm[ \t]*=' "$f" 2>/dev/null && { echo "$f"; return 0; }
    done
  done
  return 1
}

_bench_cur_fpm() {  # $1 键名
  local f; f=$(_bench_fpm_pool) || { echo "-"; return; }
  awk -v k="$1" '$1==k {gsub(/;/,"",$3); print $3; exit}' "$f" 2>/dev/null
}

# apache MPM 的主并发值（mod_php 场景代替 pm.max_children）
_bench_cur_apache_workers() {
  local f="${PREFIX_APACHE}/conf/extra/httpd-mpm.conf"
  [ -f "$f" ] || f=$(ls "${PREFIX_APACHE}"/conf/extra/*mpm* 2>/dev/null | head -1)
  [ -f "$f" ] || { echo "-"; return; }
  awk '/MaxRequestWorkers|MaxClients/{gsub(/[^0-9]/,"",$2); print $2; exit}' "$f" 2>/dev/null
}

# ---- 推荐 ------------------------------------------------------------------
# 输出 "worker_processes|worker_connections|max_children|start|min_spare|max_spare|依据"
_bench_recommend() {
  local cores="$1" mem_mb="$2" rss_mb="$3" conc="$4"
  local wp wc mc cpu_cap mem_cap basis

  if [ "$cores" -le 2 ]; then wp=1; else wp=$cores; fi

  wc=1024
  [ "$conc" -gt 512 ] && wc=$(( (conc * 2 + 1023) / 1024 * 1024 ))

  # CPU 上限：PHP 是 CPU 密集，worker 数超过核数×2 基本只是在排队
  cpu_cap=$(( cores * 2 ))
  [ "$cpu_cap" -lt 8 ] && cpu_cap=8
  # 内存上限：留 20% 给系统与磁盘缓存
  mem_cap=0
  if [ "$rss_mb" -gt 0 ] && [ "$mem_mb" -gt 0 ]; then
    mem_cap=$(( mem_mb * 8 / 10 / rss_mb ))
  fi

  if [ "$mem_cap" -gt 0 ] && [ "$mem_cap" -lt "$cpu_cap" ]; then
    mc=$mem_cap
    basis="单 worker RSS ${rss_mb}MB，可用内存 $((mem_mb*8/10))MB → 内存上限 ${mem_cap}；CPU ${cores} 核 ×2 = ${cpu_cap} → 取内存上限"
  else
    mc=$cpu_cap
    basis="CPU ${cores} 核 ×2 = ${cpu_cap}"
    [ "$mem_cap" -gt 0 ] && basis="${basis}；内存上限 ${mem_cap}（更宽松）→ 取 CPU 上限"
  fi
  # 下限的作用是"别把并发压到个位数"，但它不能大过内存能撑的量：
  # 2G 内存 × 300MB/worker 只够 5 个，硬抬到 8 会直接 OOM。
  local floor=8
  if [ "$mem_cap" -gt 0 ] && [ "$mem_cap" -lt "$floor" ]; then floor=$mem_cap; fi
  [ "$mc" -lt "$floor" ] && mc=$floor
  [ "$mc" -lt 1 ] && mc=1
  [ "$mc" -gt 256 ] && mc=256

  local start min_s max_s
  start=$(( (mc + 3) / 4 )); [ "$start" -lt 2 ] && start=2
  min_s=$start
  max_s=$(( mc / 2 )); [ "$max_s" -lt "$min_s" ] && max_s=$min_s

  printf '%s|%s|%s|%s|%s|%s|%s\n' "$wp" "$wc" "$mc" "$start" "$min_s" "$max_s" "$basis"
}

# ---- 写回（可选）-----------------------------------------------------------
# 改配置文件：备份 → 改 → 校验 → 失败回滚
_bench_apply_kv() {
  local file="$1" key="$2" val="$3" check_cmd="$4" reload_cmd="$5"
  [ -f "$file" ] || { log_warn "  找不到 $file，跳过"; return 1; }
  local bak="${file}.bak.$(date +%Y%m%d_%H%M%S)"
  cp -f "$file" "$bak" 2>/dev/null || { log_warn "  备份失败，跳过 $file"; return 1; }

  # 两种配置语法：nginx 要结尾分号（worker_processes 8;），php-fpm 是 ini 风格
  # 不要分号（pm.max_children = 32）。以前统一加分号会把 php-fpm 写成
  # "32;"，值变成非法字符串。按文件里有没有 [section] 判断。
  local semi=";"
  grep -qE '^\[[A-Za-z]' "$file" 2>/dev/null && semi=""
  # 键名里的点要转义，否则 "pm.max_children" 的正则里 . 会匹配任意字符
  local key_re; key_re=$(printf '%s' "$key" | sed 's/\./\\./g')

  if grep -qE "^[[:space:]]*${key_re}[[:space:]=]" "$file"; then
    # [^;]*;? 要连原来的分号一起吃，否则 nginx 会写成 "worker_processes 16;;"
    sed -i -E "s|^([[:space:]]*${key_re}[[:space:]=]+)[^;]*;?|\1${val}${semi}|" "$file"
  else
    printf '\n%s%s %s%s\n' "$key" "$([ "$semi" = ";" ] && echo "" || echo " =")" "$val" "$semi" >> "$file"
  fi

  if [ -n "$check_cmd" ] && ! eval "$check_cmd" >/dev/null 2>&1; then
    cp -f "$bak" "$file"
    log_err "  配置校验失败，已回滚 $file"
    return 1
  fi
  [ -n "$reload_cmd" ] && eval "$reload_cmd" >/dev/null 2>&1
  log_ok "  已更新 ${key} = ${val}  ($(basename "$file")，备份 $(basename "$bak"))"
  return 0
}

# ---- 主流程 ----------------------------------------------------------------
bench_main() {
  local n=2000 c=20 apply=0 allow_install=1 target=both url=""
  while [ $# -gt 0 ]; do
    case "$1" in
      -n|--requests)     n="${2:-2000}"; shift 2 ;;
      -c|--concurrency)  c="${2:-20}";   shift 2 ;;
      --apply)           apply=1; shift ;;
      --no-install)      allow_install=0; shift ;;
      --url)             url="${2:-}"; shift 2 ;;
      static|php|both)   target="$1"; shift ;;
      -h|--help)         bench_usage; return 0 ;;
      *) die "bench: 未知参数 $1（-h 看用法）" ;;
    esac
  done
  case "$n$c" in *[!0-9]*) die "bench: -n/-c 必须是正整数" ;; esac
  [ "$n" -gt 0 ] && [ "$c" -gt 0 ] || die "bench: -n/-c 必须大于 0"
  [ "$c" -le "$n" ] || die "bench: 并发 -c 不能大于总请求数 -n"

  local cores mem_mb
  cores=$(_bench_cores); mem_mb=$(_bench_mem_mb)

  # --- 环境探测 ---
  local ws="" php_sapi="" php_ver=""
  _have_nginx  && ws=nginx
  [ -z "$ws" ] && _have_apache && ws=apache
  if [ -x "${PREFIX_PHP}/bin/php" ]; then
    php_ver=$("${PREFIX_PHP}/bin/php" -r 'echo PHP_VERSION;' 2>/dev/null)
    # 注意别写成 $("${PREFIX_PHP}/bin/php -r 'echo PHP_SAPI;'") —— 命令替换里被
    # 双引号包住的整条命令会把里面的单引号重新解析，导致后面引号全部错位。
    php_sapi=$("${PREFIX_PHP}/bin/php" -r 'echo PHP_SAPI;' 2>/dev/null)
    [ -n "$php_sapi" ] || php_sapi="?"
  fi

  hr
  log "本机压测 (bench)"
  # 注意：别用 "${php_ver:+ ... (...)}" 这种写法 —— bash 解析 ${...} 时会把里面的
  # 括号当语法结构，直接报 unexpected token。先拼好再打印。
  local envdesc="${ws:-未检测到 Web 服务器}"
  if [ -n "$php_ver" ]; then envdesc="${envdesc} + PHP ${php_ver} (${php_sapi})"; fi
  printf '  环境: %s   CPU %s 核   内存 %s GB\n' \
    "$envdesc" \
    "$cores" "$(awk -v m="$mem_mb" 'BEGIN{printf "%.1f", m/1024}')"
  printf '  参数: -n %s -c %s\n' "$n" "$c"
  hr

  # --- 压测 ---
  local tool="" created_dir="" created="" static_res="-" php_res="-"
  local need_http=0
  [ "$target" = static ] || [ "$target" = php ] || [ "$target" = both ] && need_http=1

  if [ -n "$url" ]; then
    [ "$target" = both ] && target=static
  else
    tool=$(_bench_ensure_tool "$allow_install") || tool=""
  fi

  if [ "$need_http" = 1 ] && [ -n "$ws" ] && [ -z "$url" ]; then
    # 探针放在默认站点根（安装器保证存在），测完删除
    local root="${WWWROOT}/web"
    if [ -d "$root" ] && [ -w "$root" ]; then
      created_dir="$root"
      created=""
      if [ "$target" != "php" ]; then
        printf 'lnamp-bench-%s\n' "$(date +%s)" > "${root}/${BENCH_MARK}.txt" 2>/dev/null \
          && created="$created ${root}/${BENCH_MARK}.txt"
      fi
      if [ "$target" != "static" ] && [ -n "$php_ver" ]; then
        printf '%s\n' '<?php echo "LNampBenchOK";' > "${root}/${BENCH_MARK}.php" 2>/dev/null \
          && created="$created ${root}/${BENCH_MARK}.php"
      fi
    else
      log_warn "默认站点根 ${root} 不可写，跳过压测（可用 --url 指定页面）"
    fi
  fi

  # 无论成功失败都要删探针
  _bench_cleanup() {
    local f
    for f in $created; do rm -f "$f" 2>/dev/null; done
  }
  trap '_bench_cleanup' EXIT INT TERM

  if [ -n "$url" ]; then
    static_res=$(_bench_ab "${tool:-ab}" "$n" "$c" "$url")
  elif [ -n "$tool" ] && [ -n "$created_dir" ]; then
    if [ "$target" != "php" ]; then
      local u="http://127.0.0.1/${BENCH_MARK}.txt"
      if curl -fsS -m 5 -o /dev/null "$u" 2>/dev/null; then
        static_res=$(_bench_ab "$tool" "$n" "$c" "$u")
      else
        log_warn "静态探针访问失败（$u），跳过静态压测"
      fi
    fi
    if [ "$target" != "static" ] && [ -n "$php_ver" ]; then
      local pu="http://127.0.0.1/${BENCH_MARK}.php"
      if curl -fsS -m 5 "$pu" 2>/dev/null | grep -q LNampBenchOK; then
        php_res=$(_bench_ab "$tool" "$n" "$c" "$pu")
      else
        log_warn "PHP 探针访问失败（$pu），跳过 PHP 压测"
      fi
    fi
  elif [ -z "$url" ]; then
    log_warn "没有可用的压测工具，跳过实际压测（仅按硬件推算）"
  fi

  # --- 采样 ---
  local rss_mb; rss_mb=$(_bench_php_rss)
  _bench_cleanup
  trap - EXIT INT TERM

  # --- 结果 ---
  echo
  printf '%s\n' "$(_c '1;37' "压测结果 (results)")"
  if [ "$static_res" = "-" ]; then
    printf '  %-10s %s\n' "静态" "未执行"
  else
    IFS='|' read -r q a p f <<< "$static_res"
    printf '  %-10s %10s req/s   平均 %6s ms   P95 %6s ms   失败 %s\n' "静态" "$q" "$a" "$p" "$f"
  fi
  if [ "$php_res" = "-" ]; then
    printf '  %-10s %s\n' "PHP" "未执行"
  else
    IFS='|' read -r q a p f <<< "$php_res"
    printf '  %-10s %10s req/s   平均 %6s ms   P95 %6s ms   失败 %s\n' "PHP" "$q" "$a" "$p" "$f"
  fi

  # --- 建议 ---
  local rec wp wc mc st mins maxs basis
  rec=$(_bench_recommend "$cores" "$mem_mb" "$rss_mb" "$c")
  IFS='|' read -r wp wc mc st mins maxs basis <<< "$rec"

  local cur_wp cur_wc cur_mc cur_st cur_mins cur_maxs
  cur_wp=$(_bench_cur_worker_processes);      [ -n "$cur_wp" ] || cur_wp="-"
  cur_wc=$(_bench_cur_worker_connections);    [ -n "$cur_wc" ] || cur_wc="-"
  cur_mc=$(_bench_cur_fpm pm.max_children);   [ -n "$cur_mc" ] || cur_mc="-"
  cur_st=$(_bench_cur_fpm pm.start_servers)
  cur_mins=$(_bench_cur_fpm pm.min_spare_servers)
  cur_maxs=$(_bench_cur_fpm pm.max_spare_servers)

  echo
  printf '%s\n' "$(_c '1;37' "参数建议 (recommendations)")"
  printf '  %-30s %-10s %-10s %s\n' "项" "当前" "建议" "依据"
  printf '  %-30s %-10s %-10s %s\n' "------------------------------" "----------" "----------" "------------------------------"

  # worker_processes：当前写 auto 时**不要**建议改成数字 —— auto 本身就是
  # "跟随核数"，比写死一个数更适应以后加核；把它算成"不一致"纯属误导。
  local wp_sug="$wp" mark_wp=""
  if [ "$cur_wp" = "auto" ]; then
    wp_sug="auto"; wp_note="当前 auto = 自动跟随核数（${cores} 核），保持即可"
  else
    wp_note="CPU ${cores} 核，worker 数应等于核数（≤2 核用 1）"
    [ "$cur_wp" != "-" ] && [ "$cur_wp" != "$wp" ] && mark_wp="  ← 建议调整"
  fi
  printf '  %-30s %-10s %-10s %s%s\n' "nginx worker_processes" "$cur_wp" "$wp_sug" "$wp_note" "$mark_wp"

  # worker_connections：这是**上限**，当前值够大就别动 —— 建议把 51200 改成 1024
  # 属于降配，除了更容易打满没有任何好处。
  local wc_sug="$wc" mark_wc="" wc_note="并发 ${c} 的 2 倍向上取整到 1024 的倍数"
  if [ "$cur_wc" != "-" ] && [ "$cur_wc" -ge "$wc" ] 2>/dev/null; then
    wc_sug="$cur_wc"; wc_note="当前 ${cur_wc} 已 ≥ 需求 ${wc}，保持"
  else
    [ "$cur_wc" != "-" ] && mark_wc="  ← 建议调整"
  fi
  printf '  %-30s %-10s %-10s %s%s\n' "nginx worker_connections" "$cur_wc" "$wc_sug" "$wc_note" "$mark_wc"

  local mark_mc=""
  if [ -n "$cur_mc" ] && [ "$cur_mc" != "-" ]; then
    [ "$cur_mc" != "$mc" ] && mark_mc="  ← 建议调整"
    printf '  %-30s %-10s %-10s %s%s\n' "php-fpm pm.max_children" "$cur_mc" "$mc" "$basis" "$mark_mc"
    printf '  %-30s %-10s %-10s %s\n' "php-fpm pm.start_servers" "${cur_st:--}" "$st" "max_children / 4"
    printf '  %-30s %-10s %-10s %s\n' "php-fpm pm.min_spare_servers" "${cur_mins:--}" "$mins" "max_children / 4"
    printf '  %-30s %-10s %-10s %s\n' "php-fpm pm.max_spare_servers" "${cur_maxs:--}" "$maxs" "max_children / 2"
  elif [ "$php_sapi" = "apache2handler" ]; then
    local cur_ap; cur_ap=$(_bench_cur_apache_workers); [ -n "$cur_ap" ] || cur_ap="-"
    printf '  %-30s %-10s %-10s %s\n' "apache MaxRequestWorkers" "$cur_ap" "$mc" "$basis（mod_php 形态，无 php-fpm）"
  else
    printf '  %-30s %-10s %-10s %s\n' "php-fpm pm.max_children" "-" "$mc" "$basis"
  fi

  [ "$rss_mb" -gt 0 ] && printf '\n  采样: php-fpm worker 平均 RSS %s MB（压测后采样，已含扩展）\n' "$rss_mb"
  if [ -n "$mark_wp$mark_wc$mark_mc" ]; then
    printf '  %s\n' "$(_c '1;33' "标了 ← 的项与建议不一致，可用 --apply 写回")"
  else
    printf '  %s\n' "当前配置与建议一致，无需调整"
  fi

  # --- 写回 ---
  if [ "$apply" = 1 ]; then
    echo
    log "写回推荐值 (--apply)"

    # nginx：systemctl reload 在部分 unit 上没有 ExecReload（返回 0 但什么都不做），
    # 所以优先用 nginx -s reload —— 它一定真的重载。
    local nf; nf=$(_bench_nginx_conf) || nf=""
    if [ -n "$nf" ] && [ "$cur_wp" != "-" ] && [ "$wp_sug" != "$cur_wp" ] && [ "$wp_sug" != "auto" ]; then
      if _bench_apply_kv "$nf" "worker_processes" "$wp_sug" "${PREFIX_NGINX}/sbin/nginx -t" ""; then
        if "${PREFIX_NGINX}/sbin/nginx" -s reload 2>/dev/null; then
          log_ok "  nginx 已重载 (nginx -s reload)"
        else
          log_warn "  nginx 重载失败，请手工: nginx -t && nginx -s reload"
        fi
      fi
    fi

    # php-fpm：unit 一般没有 ExecReload，systemctl reload 是"假成功"。
    # 正确姿势是 SIGUSR2（平滑重载，不中断连接），拿不到 pid 才退回 restart。
    local pf; pf=$(_bench_fpm_pool) || pf=""
    if [ -n "$pf" ] && [ "$cur_mc" != "-" ] && [ "$cur_mc" != "$mc" ]; then
      _bench_apply_kv "$pf" "pm.max_children"      "$mc"    "" ""
      _bench_apply_kv "$pf" "pm.start_servers"     "$st"    "" ""
      _bench_apply_kv "$pf" "pm.min_spare_servers" "$mins"  "" ""
      _bench_apply_kv "$pf" "pm.max_spare_servers" "$maxs"  "" ""

      local fpmbin="${PREFIX_PHP}/sbin/php-fpm" pidf fpm_pid=""
      for pidf in "${PREFIX_PHP}/var/run/php-fpm.pid" /run/php-fpm/php-fpm.pid /var/run/php-fpm.pid; do
        [ -f "$pidf" ] && { fpm_pid=$(cat "$pidf" 2>/dev/null); break; }
      done
      if ! "$fpmbin" -t >/dev/null 2>&1; then
        log_err "  php-fpm 配置校验失败（pm.* 之间的约束不满足？）—— 请检查 $pf"
      elif [ -n "$fpm_pid" ] && kill -USR2 "$fpm_pid" 2>/dev/null; then
        log_ok "  php-fpm 已平滑重载 (SIGUSR2, pid ${fpm_pid})"
      elif systemctl restart php-fpm >/dev/null 2>&1; then
        log_ok "  php-fpm 已重启 (systemctl restart)"
      else
        log_warn "  php-fpm 未能重载，请手工: kill -USR2 <pid> 或 systemctl restart php-fpm"
      fi
    fi
  else
    echo
    log "以上仅为建议，未修改任何配置。确认写回: $0 bench --apply"
  fi
  hr
  return 0
}
