#!/bin/bash
# ============================================================================
#  modules/mirror.sh  ——  Composer / npm 国内镜像 (package index mirrors)
# ----------------------------------------------------------------------------
#  解决的问题：
#    Composer 和 npm 装好了，但默认包索引都在境外。
#    `composer install` 在国内经常慢到超时，`npm install` 同理。
#    这一步只改**包索引地址**，不改下载源（MIRROR_PRIMARY / MIRROR_FALLBACK
#    是给安装器自己下 tar 包用的，两件事互不影响）。
#
#  改的是什么：
#    Composer -> 全局 config 的 repo.packagist
#                (~/.config/composer/config.json，root 用户即 /root/.config/composer)
#    npm      -> 全局 npmrc 的 registry
#                (${PREFIX_NODE}/etc/npmrc，所有用户生效)
#
#  三种模式（MIRROR_MODE / --mirror / install.sh mirror）：
#    cn        阿里云 Composer + npmmirror npm（默认，国内机器推荐）
#    official  显式恢复官方源（packagist.org / registry.npmjs.org）
#    none      完全不碰，保持现状
#
#  幂等：先读当前值，与目标一致就跳过，不重写配置、不打印噪音。
#  干跑：DRY_RUN=1 时只打印将要执行的命令。
#
#  用法:
#    install_mirrors [cn|official|none]       由 _run_installs_inner / mirror_main 调用
#    install.sh mirror                        查看当前包索引
#    install.sh mirror cn                     切换到国内镜像
#    install.sh mirror official               切回官方源
# ============================================================================

# ---- 定位可执行文件 --------------------------------------------------------
_mirror_composer_bin() {
  local c
  for c in "${PREFIX_PHP}/bin/composer" /usr/local/bin/composer /usr/bin/composer; do
    [ -x "$c" ] && { echo "$c"; return 0; }
  done
  c=$(command -v composer 2>/dev/null) && { echo "$c"; return 0; }
  return 1
}

_mirror_npm_bin() {
  local n
  for n in "${PREFIX_NODE}/bin/npm" /usr/local/bin/npm /usr/bin/npm; do
    [ -x "$n" ] && { echo "$n"; return 0; }
  done
  n=$(command -v npm 2>/dev/null) && { echo "$n"; return 0; }
  return 1
}

# ---- 读当前值 --------------------------------------------------------------
# composer 全局仓库的 url；未配置镜像（=官方源）时输出空
# 注意：不能用 `config -g repos.packagist` 读。用 repo.packagist 写入后配置里存的是
# "命名仓库"（repositories 数组里带 name 的条目），repos.packagist 这个键读取会直接报
# "There is no packagist repository defined" 并返回非零 —— 自检会误判成"官方源"。
# 改读整个 repositories，取 name=packagist 那条的 url（官方源时没有该条目 → 输出空）。
_mirror_composer_get() {
  local c out
  c=$(_mirror_composer_bin) || return 1
  out=$("$c" config -g repositories 2>/dev/null) || return 0
  printf '%s' "$out" | tr -d ' \t\n' \
    | grep -o '"name":"packagist"[^}]*"url":"[^"]*"' | head -1 \
    | sed 's/.*"url":"//;s/"$//'
}

# npm 生效中的 registry
_mirror_npm_get() {
  local n out
  n=$(_mirror_npm_bin) || return 1
  out=$("$n" config get registry 2>/dev/null | tail -1) || return 0
  printf '%s' "${out%/}"
}

# ---- 写 ---------------------------------------------------------------
# 参数: <url>|official ；返回 0=已生效/已跳过 1=工具缺失或写入失败
_mirror_composer_set() {
  local want="$1" c cur
  c=$(_mirror_composer_bin) || { log_warn "未找到 composer，跳过 Composer 镜像配置（装完 Composer 后可跑: $0 mirror cn）"; return 1; }

  if [ "$want" = official ]; then
    cur=$(_mirror_composer_get)
    if [ -z "$cur" ]; then
      log_ok "Composer 已是官方源 (packagist.org)，跳过 (unchanged)"
      return 0
    fi
    if [ "${DRY_RUN:-0}" = 1 ]; then
      log "  [dry-run] 将执行: ${c} config -g --unset repos.packagist"
      return 0
    fi
    "$c" config -g --unset repos.packagist >/dev/null 2>&1 \
      || { log_warn "Composer 官方源恢复失败（可手工执行: ${c} config -g --unset repos.packagist）"; return 1; }
    log_ok "Composer 已恢复官方源 (packagist.org)"
    return 0
  fi

  cur=$(_mirror_composer_get)
  if [ "$cur" = "$want" ]; then
    log_ok "Composer 镜像已是 ${want}，跳过 (unchanged)"
    return 0
  fi
  if [ "${DRY_RUN:-0}" = 1 ]; then
    log "  [dry-run] 将执行: ${c} config -g repo.packagist composer ${want}"
    return 0
  fi
  if "$c" config -g repo.packagist composer "$want" >/dev/null 2>&1; then
    log_ok "Composer 镜像已设为 ${want}"
    return 0
  fi
  log_warn "Composer 镜像写入失败（可手工执行: ${c} config -g repo.packagist composer ${want}）"
  return 1
}

_mirror_npm_set() {
  local want="$1" n cur
  n=$(_mirror_npm_bin) || { log_warn "未找到 npm，跳过 npm 镜像配置（装完 Node.js 后可跑: $0 mirror cn）"; return 1; }

  cur=$(_mirror_npm_get)
  if [ "${cur%/}" = "${want%/}" ]; then
    log_ok "npm registry 已是 ${want}，跳过 (unchanged)"
    return 0
  fi
  if [ "${DRY_RUN:-0}" = 1 ]; then
    log "  [dry-run] 将执行: ${n} config set registry ${want} --location=global"
    return 0
  fi
  # npm 9+ 用 --location=global；旧版只认 --global；再兜底写用户级
  if "$n" config set registry "$want" --location=global >/dev/null 2>&1 \
     || "$n" config set registry "$want" --global >/dev/null 2>&1 \
     || "$n" config set registry "$want" >/dev/null 2>&1; then
    log_ok "npm registry 已设为 ${want}"
    return 0
  fi
  log_warn "npm registry 写入失败（可手工执行: ${n} config set registry ${want} --location=global）"
  return 1
}

# ---- 主入口 ---------------------------------------------------------------
# 用法: install_mirrors [cn|official|none] [soft]
#   soft=1：单项失败只告警、整体仍返回 0。整栈安装时由 install.sh 传入 ——
#   Composer/npm 包索引只是便利性配置（npm 写入失败、甚至没装 npm），
#   不该让整套 LNAMP 安装中止（曾因 npm config set 失败 abort 全场）。
install_mirrors() {
  local mode="${1:-${MIRROR_MODE:-cn}}"
  local soft="${2:-0}"
  case "$soft" in 1|soft|yes|y) soft=1 ;; *) soft=0 ;; esac
  case "$mode" in
    cn|aliyun)        mode=cn ;;
    official|off|no)  mode=official ;;
    none|skip)        mode=none ;;
    *) die "mirror 模式只能是 cn|official|none，收到: ${mode}" ;;
  esac

  if [ "$mode" = none ]; then
    log "跳过 Composer/npm 包镜像配置 (mirror mode=none)"
    return 0
  fi

  log "Composer/npm 包索引镜像 (package index mirrors, mode=${mode})"
  local rc=0
  if [ "$mode" = cn ]; then
    _mirror_composer_set "$COMPOSER_MIRROR_CN" || rc=1
    _mirror_npm_set "$NPM_REGISTRY_CN"         || rc=1
  else
    _mirror_composer_set official              || rc=1
    _mirror_npm_set "https://registry.npmjs.org/" || rc=1
  fi
  if [ "$rc" -ne 0 ] && [ "$soft" = 1 ]; then
    log_warn "包索引镜像有未生效项（便利性配置，不影响栈运行）。可稍后手动执行: $0 mirror ${mode}"
    return 0
  fi
  return "$rc"
}

# 当前包索引一行摘要（verify.sh 用）
mirror_status() {
  local c n
  c=$(_mirror_composer_get) || c=""
  n=$(_mirror_npm_get)      || n=""
  [ -n "$c" ] || c="official(packagist.org)"
  [ -n "$n" ] || n="official(registry.npmjs.org)"
  echo "composer=${c} npm=${n}"
}

# install.sh mirror 子命令入口
mirror_main() {
  local mode="${1:-}"
  if [ -z "$mode" ]; then
    hr
    log "当前包索引 (current package index)"
    hr
    local c n
    c=$(_mirror_composer_get) || c=""
    n=$(_mirror_npm_get)      || n=""
    printf '  Composer : %s\n' "${c:-官方 packagist.org（未配置镜像）}"
    printf '  npm      : %s\n' "${n:-官方 registry.npmjs.org（未配置镜像）}"
    hr
    echo "切换: $0 mirror cn|official|none"
    echo "  cn        -> Composer=${COMPOSER_MIRROR_CN}  npm=${NPM_REGISTRY_CN}"
    echo "  official  -> 恢复官方源"
    echo "  none      -> 不做改动"
    return 0
  fi
  install_mirrors "$mode"
}
