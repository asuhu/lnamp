#!/bin/bash
# ============================================================================
#  modules/scan.sh  ——  Web 目录 webshell 巡检 (lnamp scan)
# ----------------------------------------------------------------------------
#  disable_functions / open_basedir 是"预防"，scan 是"事后发现"。两者缺一不可：
#  纯 PHP 的 webshell（文件管理型）根本不调用系统命令，disable_functions 拦不住；
#  它只需要 file_get_contents + mysqli 就能把源码和数据库全捞走。
#
#  检查分为两类：
#    HIT  (高置信度，基本可以直接判死)  特征匹配、上传目录里的可执行文件、图片马
#    WARN (需要人看一眼)               近期改动、可疑文件名、权限过宽、.user.ini
#
#  用法:
#    lnamp scan                       # 扫 ${WWWROOT}
#    lnamp scan --path /home/wwwroot/a.com
#    lnamp scan --since 3             # 只看 3 天内改过的 PHP
#    lnamp scan --fast                # 跳过 vendor/node_modules（大项目快很多）
#    lnamp scan --quiet               # 只输出发现项（给 cron/监控用）
#  退出码: 0=未发现  1=有 HIT 或 WARN
#
#  设计原则：**只读**，绝不自动删除。误删业务文件的代价远大于漏报 —— 报告里
#  给出隔离命令，由人来决定。真正的清理请用 `mv` 到隔离目录而不是 `rm`。
# ============================================================================

_S_HIT=0; _S_WARN=0; _S_OK=0; _S_SKIP=0
_S_QUIET=0; _S_FAST=0; _S_SINCE=7; _S_EXCLUDES="${LNAMP_SCAN_EXCLUDE:-}"
_S_ROOTS=""          # 空格分隔的扫描根
_S_MAXLIST=10        # 每类最多列几条，避免刷屏

_scan_sec() {
  [ "$_S_QUIET" = 1 ] && return 0
  echo
  printf '%s\n' "$(_c '1;36' "== $* ==")"
}
_scan_ok()   { _S_OK=$((_S_OK + 1));   [ "$_S_QUIET" = 1 ] && return 0; printf '  [OK]  %s\n' "$*"; }
_scan_warn() { _S_WARN=$((_S_WARN + 1)); printf '  [!]   %s\n' "$*"; }
_scan_hit()  { _S_HIT=$((_S_HIT + 1));   printf '  [X]   %s\n' "$*"; }
_scan_skip() { _S_SKIP=$((_S_SKIP + 1)); [ "$_S_QUIET" = 1 ] && return 0; printf '  [-]   %s\n' "$*"; }
_scan_item() { printf '        %s\n' "$*"; }
_scan_hint() { printf '        处理: %s\n' "$*"; }

# 构造 prune 表达式，结果放进全局数组 _SCAN_PRUNE（bash 4.2 没有 nameref，
# 只能这样回传）。
#
# 历史写法把整条表达式塞进一个字符串再 `find "$root" $prune ...`：
# 变量展开后单引号是**字面字符**，find 收到的是 '*/node_modules'（带引号的模式），
# 永远匹配不上；而 '(' ')' 也变成普通参数，find 直接报错退出（stderr 还被丢掉），
# 结果是"排除"和 --fast 全都静默失效 —— 扫一遍几十万文件的 node_modules。
# 必须用数组让每个 token 原样传给 find。
_SCAN_PRUNE=()
_scan_build_prune() {
  _SCAN_PRUNE=( '(' -path '*/node_modules' -o -path '*/.git' -o -path '*/.svn' -o -path '*/.hg' )
  if [ "$_S_FAST" = 1 ]; then
    _SCAN_PRUNE+=( -o -path '*/vendor' -o -path '*/.cache' -o -path '*/dist' -o -path '*/build' )
  fi
  local p
  for p in $_S_EXCLUDES; do
    [ -n "$p" ] || continue
    # 给了通配符就按 -path 原样匹配；只给目录名则按"任意层级的该目录及其内容"处理
    case "$p" in
      *'*'*|*'?'*|*'/'*) _SCAN_PRUNE+=( -o -path "$p" ) ;;
      *)                 _SCAN_PRUNE+=( -o -path "*/$p" -o -path "*/$p/*" ) ;;
    esac
  done
  _SCAN_PRUNE+=( ')' )
}

# find 包装：统一跳过版本库/依赖目录，避免把 node_modules 里几万个 js 也走一遍
# 用法: _scan_find <目录> <find 表达式...>
_scan_find() {
  local root="$1"; shift
  _scan_build_prune
  find "$root" "${_SCAN_PRUNE[@]}" -prune -o "$@" -print 2>/dev/null
}

# 同上但输出 NUL 分隔（交给 xargs -0，文件名含空格也不会断）
_scan_find0() {
  local root="$1"; shift
  _scan_build_prune
  find "$root" "${_SCAN_PRUNE[@]}" -prune -o "$@" -print0 2>/dev/null
}

# 把文件列表截断成前 N 条，其余汇总一行
_scan_list() {
  local total n=0 f
  # grep -c 在没有匹配时输出 "0" 且退出码为 1，**不能**写 `|| echo 0`，
  # 否则会得到 "0\n0" 两行（这个坑在别的脚本里踩过一次）。
  total=$(printf '%s\n' "$1" | grep -c . 2>/dev/null)
  total=${total:-0}
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    n=$((n + 1))
    [ "$n" -gt "$_S_MAXLIST" ] && break
    _scan_item "$f"
  done <<< "$1"
  [ "$total" -gt "$_S_MAXLIST" ] && _scan_item "... 另有 $((total - _S_MAXLIST)) 个，用 --path 缩小范围后重扫"
  return 0
}

# ---------------------------------------------------------------------------
# 1. 已知 webshell 特征
# ---------------------------------------------------------------------------
# 这些正则刻意写得"窄"：只认真正能造成代码执行/文件落地的组合。
# 宽泛的关键字（比如单独一个 base64_decode）在正常业务里到处都是，报了也没人看，
# 反而会让真正的高危项被淹掉。
_RE_DIRECT='eval[[:space:]]*\([[:space:]]*\$_(POST|GET|REQUEST|COOKIE|SERVER)'
# 注意：双引号拼接里 `\$` 会被 shell 吃掉反斜杠，最终模式变成 `$_(POST...)`。
# GNU grep 的 ERE 中 `$` 出现在中间**不是**字面字符，而是要求"其后即行尾"，
# 于是整条分支永远匹配不上（实测只有第 1 条 eval 生效，system/passthru 全漏）。
# 必须写 `\\\$_` 才能在最终模式里留下 `\$_`。
_RE_DIRECT="$_RE_DIRECT|assert[[:space:]]*\([[:space:]]*\\\$_(POST|GET|REQUEST|COOKIE)"
_RE_DIRECT="$_RE_DIRECT|(call_user_func|call_user_func_array|array_map|array_filter|usort|preg_replace_callback)[[:space:]]*\([[:space:]]*\\\$_(POST|GET|REQUEST|COOKIE)"
_RE_DIRECT="$_RE_DIRECT|(system|exec|passthru|shell_exec|popen|proc_open)[[:space:]]*\([[:space:]]*\\\$_(POST|GET|REQUEST|COOKIE)"
_RE_DIRECT="$_RE_DIRECT|\\\$[A-Za-z_][A-Za-z0-9_]*[[:space:]]*\([[:space:]]*\\\$_(POST|GET|REQUEST)[^)]*\)[[:space:]]*;"
_RE_OBF='(eval|assert|create_function)[[:space:]]*\(.*(base64_decode|gzinflate|gzuncompress|gzdecode|str_rot13|strrev|hex2bin|pack[[:space:]]*\()'
_RE_OBF="$_RE_OBF|preg_replace[[:space:]]*\([[:space:]]*.[^,]*/[a-zA-Z]*e[a-zA-Z]*['\"]"

_scan_sig() {
  _scan_sec "1. 特征匹配 (webshell signature)"
  local root hits f line shown=0
  for root in $_S_ROOTS; do
    [ -d "$root" ] || continue
    # 只扫常见可执行后缀，且跳过 >3MB 的（压缩打包的单文件里正则匹配会拖死机器）
    hits=$(
      _scan_find0 "$root" -type f \
        \( -name '*.php' -o -name '*.php3' -o -name '*.php4' -o -name '*.php5' -o -name '*.php7' -o -name '*.phtml' -o -name '*.pht' -o -name '*.inc' \) \
        -size -3072k 2>/dev/null \
      | xargs -0 -r grep -lE "$_RE_DIRECT|$_RE_OBF" 2>/dev/null | head -n 200
    )
    [ -n "$hits" ] || continue
    shown=1
    local cnt; cnt=$(printf '%s\n' "$hits" | grep -c .)
    _scan_hit "${root}: ${cnt} 个文件命中高危特征"
    while IFS= read -r f; do
      [ -n "$f" ] || continue
      line=$(grep -nE -m1 "$_RE_DIRECT|$_RE_OBF" "$f" 2>/dev/null | cut -c1-130)
      _scan_item "${f}"
      [ -n "$line" ] && _scan_item "  -> ${line}"
    done <<< "$(printf '%s\n' "$hits" | head -n "$_S_MAXLIST")"
    [ "$cnt" -gt "$_S_MAXLIST" ] && _scan_item "... 另有 $((cnt - _S_MAXLIST)) 个"
    _scan_hint "先确认是否业务代码；确定是马就隔离（不要 rm）: mkdir -p /var/lib/lnamp/quarantine && mv <文件> /var/lib/lnamp/quarantine/"
  done
  [ "$shown" = 0 ] && _scan_ok "未发现典型的代码执行/混淆特征"
  return 0
}

# ---------------------------------------------------------------------------
# 2. 上传/缓存目录里的可执行文件
# ---------------------------------------------------------------------------
# 和 vhost 的"上传目录禁执行"规则是同一份名单：即使 nginx 那条规则在，文件本身
# 已经在盘上了，说明上传校验被绕过；而且换个后缀 / 被别的站点 include 一样能跑。
_scan_upload_exec() {
  _scan_sec "2. 上传/数据目录中的可执行文件"
  local root dirs d hits found=0
  for root in $_S_ROOTS; do
    [ -d "$root" ] || continue
    dirs=$(_scan_find "$root" -type d \
      \( -name 'uploads' -o -name 'upload' -o -name 'uploadfiles' -o -name 'attachments' \
         -o -name 'attachment' -o -name 'runtime' -o -name 'storage' -o -name 'cache' \
         -o -name 'temp' -o -name 'tmp' -o -name 'data' \) 2>/dev/null | head -n 300)
    while IFS= read -r d; do
      [ -n "$d" ] && [ -d "$d" ] || continue
      hits=$(_scan_find "$d" -type f \
        \( -name '*.php' -o -name '*.php[0-9]' -o -name '*.phtml' -o -name '*.phar' -o -name '*.pht' -o -name '*.inc' \) 2>/dev/null)
      [ -n "$hits" ] || continue
      found=1
      local cnt; cnt=$(printf '%s\n' "$hits" | grep -c .)
      _scan_hit "${d}: 存在 ${cnt} 个可执行脚本（上传目录不该有 PHP）"
      _scan_list "$hits"
      _scan_hint "确认后隔离；并检查应用的 upload 校验（后缀白名单 + MIME + 重命名）"
    done <<< "$dirs"
  done
  [ "$found" = 0 ] && _scan_ok "上传/缓存目录内未发现 PHP 等可执行文件"
  return 0
}

# ---------------------------------------------------------------------------
# 3. 图片马（GIF89a 头 + <?php）
# ---------------------------------------------------------------------------
_scan_image_shell() {
  _scan_sec "3. 图片文件内嵌 PHP 代码"
  local root hits found=0 cnt
  for root in $_S_ROOTS; do
    [ -d "$root" ] || continue
    hits=$(
      _scan_find0 "$root" -type f \
        \( -name '*.jpg' -o -name '*.jpeg' -o -name '*.png' -o -name '*.gif' -o -name '*.bmp' -o -name '*.webp' -o -name '*.ico' \) \
        -size -5120k 2>/dev/null \
      | xargs -0 -r grep -lE '<\?php|<\?=' 2>/dev/null | head -n 100
    )
    [ -n "$hits" ] || continue
    found=1
    cnt=$(printf '%s\n' "$hits" | grep -c .)
    _scan_hit "${root}: ${cnt} 个图片文件内含 PHP 标签（图片马）"
    _scan_list "$hits"
    _scan_hint "正常图片不可能含 <?php。隔离后重传，并检查图片处理是否走了重新编码"
  done
  [ "$found" = 0 ] && _scan_ok "未发现图片马（图片内无 PHP 标签）"
  return 0
}

# ---------------------------------------------------------------------------
# 4. .user.ini / .htaccess 注入
# ---------------------------------------------------------------------------
# PHP 会主动读取站点目录下的 .user.ini —— 如果攻击者能写文件，放一个
# auto_prepend_file 就能让每个请求都先执行他的代码，比单文件 webshell 更隐蔽。
_scan_ini() {
  _scan_sec "4. .user.ini / .htaccess 配置注入"
  local root files f hits="" found=0
  for root in $_S_ROOTS; do
    [ -d "$root" ] || continue
    files=$(_scan_find "$root" -type f \( -name '.user.ini' -o -name '.htaccess' \) -size -256k 2>/dev/null | head -n 200)
    while IFS= read -r f; do
      [ -n "$f" ] || continue
      hits=$(grep -nE -m2 'auto_prepend_file|auto_append_file' "$f" 2>/dev/null)
      [ -n "$hits" ] || continue
      found=1
      _scan_hit "${f} 含自动插入配置（每个请求都会执行它指向的文件）"
      printf '%s\n' "$hits" | sed 's/^/          /'
      _scan_hint "确认非业务需要后隔离；并确认 Web 根不可被 www 写入（否则删了还会再生成）"
    done <<< "$files"
  done
  [ "$found" = 0 ] && _scan_ok "未发现 auto_prepend_file / auto_append_file 注入"
  return 0
}

# ---------------------------------------------------------------------------
# 5. 权限与属主
# ---------------------------------------------------------------------------
_scan_perm() {
  _scan_sec "5. 权限与属主"
  local root world owner bad=0
  for root in $_S_ROOTS; do
    [ -d "$root" ] || continue
    # 全局可写（o+w）的文件：任何本机用户都能改，等于给 webshell 开后门
    world=$(_scan_find "$root" -type f -perm -0002 -size -51200k 2>/dev/null | head -n 50)
    if [ -n "$world" ]; then
      bad=1
      _scan_hit "${root}: 存在全局可写（other+w）文件"
      _scan_list "$world"
      _scan_hint "chmod o-w <文件>；目录同理 chmod o-w"
    fi
    # 站点根属主是 www：Web 进程能改写自己的代码，webshell 可以自我复制/持久化
    owner=$(stat -c '%U' "$root" 2>/dev/null)
    case "$owner" in
      www)
        bad=1
        _scan_warn "${root} 属主是 www —— Web 进程可改写自身代码（webshell 可持久化）"
        _scan_hint "chown root:www ${root}; find ${root} -type d -exec chmod 755 {} \\; ; find ${root} -type f -exec chmod 644 {} \\;"
        _scan_hint "只把确实需要写的目录（uploads/runtime/storage）留给 www"
        ;;
    esac
  done
  [ "$bad" = 0 ] && _scan_ok "权限与属主未发现明显问题"
  return 0
}

# ---------------------------------------------------------------------------
# 6. 近期改动
# ---------------------------------------------------------------------------
_scan_recent() {
  _scan_sec "6. 最近 ${_S_SINCE} 天内修改过的 PHP"
  local root hits found=0 cnt
  for root in $_S_ROOTS; do
    [ -d "$root" ] || continue
    hits=$(_scan_find "$root" -type f \( -name '*.php' -o -name '*.phtml' -o -name '*.phar' \) \
      -newermt "-${_S_SINCE} days" 2>/dev/null | head -n 100)
    [ -n "$hits" ] || continue
    cnt=$(printf '%s\n' "$hits" | grep -c .)
    # 正常发版也会改文件，所以这里是 WARN 不是 HIT
    found=1
    _scan_warn "${root}: ${cnt} 个脚本在 ${_S_SINCE} 天内被修改（正常发版也会这样，请自行核对）"
    _scan_list "$hits"
  done
  [ "$found" = 0 ] && _scan_ok "最近 ${_S_SINCE} 天没有新增/修改的脚本"
  return 0
}

# ---------------------------------------------------------------------------
# 7. 可疑文件名
# ---------------------------------------------------------------------------
_scan_names() {
  _scan_sec "7. 可疑文件名"
  local root hits found=0
  for root in $_S_ROOTS; do
    [ -d "$root" ] || continue
    hits=$(_scan_find "$root" -type f -name '*.php' 2>/dev/null \
      | grep -Ei '/(shell|cmd|backdoor|webshell|wso|b374k|c99|r57|bypass|hack|spam|uploader)[^/]*\.php$' \
      | head -n 50)
    [ -n "$hits" ] || continue
    found=1
    _scan_warn "${root}: 文件名疑似（可能只是业务命名，请确认）"
    _scan_list "$hits"
  done
  [ "$found" = 0 ] && _scan_ok "未发现明显可疑的文件名"
  return 0
}

# ---------------------------------------------------------------------------
# 入口
# ---------------------------------------------------------------------------
scan_usage() {
  cat <<EOF
用法: $0 scan [选项]
  只读巡检 Web 目录里的 webshell / 可疑文件，不做任何修改

  --path <目录>   指定扫描目录（可多次，默认 ${WWWROOT}）
  --since <天数>  近期改动的检查窗口（默认 7）
  --fast          跳过 vendor / dist / build / .cache（大项目快很多）
  --exclude <模式> 额外排除（可多次）。给目录名(cache)按任意层级匹配，
                  给路径片段(*/storage/logs)按 -path 匹配
  --quiet, -q     只输出发现项（给 cron / 监控用）
  -h, --help      显示本帮助

退出码: 0=未发现   1=有发现（HIT 或 WARN）
EOF
}

scan_main() {
  local a
  while [ $# -gt 0 ]; do
    case "$1" in
      --path)     [ -n "${2:-}" ] || die "scan: --path 需要目录"; _S_ROOTS="${_S_ROOTS} $2"; shift 2 ;;
      --path=*)   _S_ROOTS="${_S_ROOTS} ${1#*=}"; shift ;;
      --since)    [ -n "${2:-}" ] || die "scan: --since 需要天数"; _S_SINCE="$2"; shift 2 ;;
      --since=*)  _S_SINCE="${1#*=}"; shift ;;
      --fast)     _S_FAST=1; shift ;;
      --exclude)  [ -n "${2:-}" ] || die "scan: --exclude 需要模式"; _S_EXCLUDES="${_S_EXCLUDES} $2"; shift 2 ;;
      --exclude=*) _S_EXCLUDES="${_S_EXCLUDES} ${1#*=}"; shift ;;
      --quiet|-q) _S_QUIET=1; shift ;;
      -h|--help)  scan_usage; return 0 ;;
      # 每个错误分支都必须 shift：die 正常是 exit，但测试桩里 die 被换成
      # "return 1"，没有 shift 就会在 while 里原地打转（死循环，实测把整个
      # 测试挂死）。防御性写法，代价为零。
      *)          die "scan: 未知参数 $1（见 --help）"; shift ;;
    esac
  done
  case "$_S_SINCE" in ''|*[!0-9]*) die "scan: --since 必须是数字" ;; esac

  [ -n "$_S_ROOTS" ] || _S_ROOTS="${LNAMP_SCAN_ROOTS:-$WWWROOT}"
  local r
  for r in $_S_ROOTS; do
    [ -d "$r" ] || die "scan: 目录不存在: $r"
  done

  echo
  printf '%s\n' "$(_c '1;37' "lnamp scan  $(date '+%Y-%m-%d %H:%M:%S')")"
  echo "  扫描范围: $(printf '%s' "$_S_ROOTS" | sed 's/^ *//')"
  echo "  检查窗口: 最近 ${_S_SINCE} 天$([ "$_S_FAST" = 1 ] && echo '（fast: 跳过 vendor/dist/build/.cache）')"
  local _ex; _ex=$(printf '%s' "$_S_EXCLUDES" | sed 's/^ *//;s/ *$//')
  [ -n "$_ex" ] && echo "  额外排除: ${_ex}"
  # 自检：prune 表达式若失效（比如 find 版本不认 -path），这里会立刻暴露，
  # 而不是"跑半小时扫完整个 node_modules 才发现没生效"。
  _scan_build_prune
  if ! find "$r" "${_SCAN_PRUNE[@]}" -prune -o -false -print >/dev/null 2>&1; then
    log_warn "排除表达式未被 find 接受（--fast/--exclude 可能失效），请检查 find 版本"
  fi

  _scan_sig
  _scan_upload_exec
  _scan_image_shell
  _scan_ini
  _scan_perm
  _scan_recent
  _scan_names

  echo
  printf '汇总: OK=%d  HIT=%d  WARN=%d  SKIP=%d\n' "$_S_OK" "$_S_HIT" "$_S_WARN" "$_S_SKIP"
  if [ "$_S_HIT" -gt 0 ]; then
    log_err "发现 ${_S_HIT} 项高危，请逐条确认（先隔离再分析，不要直接 rm）"
    echo "  隔离: mkdir -p /var/lib/lnamp/quarantine && mv <文件> /var/lib/lnamp/quarantine/"
    echo "  取证: cp -a <文件> /root/evidence-\$(date +%F)/ && sha256sum <文件>"
    return 1
  elif [ "$_S_WARN" -gt 0 ]; then
    log_warn "有 ${_S_WARN} 项需要人工确认"
    return 1
  fi
  log_ok "未发现可疑文件"
  return 0
}
