#!/bin/bash
# ============================================================================
#  modules/devtools.sh  ——  开发工具链：Composer + Node.js
# ----------------------------------------------------------------------------
#    install_composer <version> <mode>    mode=phar，下载官方 composer.phar 并校验 SHA256
#    install_nodejs   <version> <mode>    mode=binary，nodejs.org 官方预编译包
#
#  两者都不进 /usr/local/bin 之外的目录，也不改系统默认 PHP/PATH 顺序，
#  只追加一条 profile.d，便于随时卸载干净。
# ============================================================================

# ---------------------------------------------------------------------------
#  Composer
# ---------------------------------------------------------------------------
install_composer() {
  local ver="$1" mode="$2"
  case "${mode:-phar}" in
    phar) _composer_phar "$ver" ;;
    *)    die "composer: 只支持 phar 形式，收到: ${mode}" ;;
  esac
}

_composer_phar() {
  local ver="$1"
  local phpver
  phpver=$(php_bin_version)
  if [ -z "$phpver" ]; then
    log_warn "未检测到 PHP，Composer 装好后暂时无法运行（仍需 PHP 才能用）"
  else
    # 2.x 需要 PHP >= 7.2.5；PHP 5.x/7.0-7.1 必须用 2.2.x LTS
    if ver_ge "$ver" "2.10" && ! ver_ge "$phpver" "7.2.5"; then
      die "Composer ${ver} 需要 PHP >= 7.2.5，当前为 ${phpver}。请改用 --composer 2.2.30（PHP 5.3~7.1 的 LTS 分支）。"
    fi
  fi

  log "安装 Composer ${ver}  (mode=phar, PHP ${phpver:-未安装})"
  dep curl unzip git ca-certificates
  cd_src ~ "cd ~"

  local phar="composer-${ver}.phar"
  fetch "$phar" "https://getcomposer.org/download/${ver}/composer.phar" \
    || die "下载失败 (download failed): composer ${ver}"

  # SHA256 校验：官方提供 .sha256sum，校验不过就不安装（防中间人/镜像投毒）
  local sumf="composer-${ver}.sha256sum"
  if fetch "$sumf" "https://getcomposer.org/download/${ver}/composer.phar.sha256sum"; then
    if [ "${DRY_RUN:-0}" != 1 ] && command -v sha256sum >/dev/null 2>&1; then
      local want got
      want=$(awk '{print $1}' "$sumf" 2>/dev/null | head -1 | tr -d '\r')
      got=$(sha256sum "$phar" | awk '{print $1}')
      if [ -n "$want" ] && [ "$want" != "$got" ]; then
        die "Composer 校验失败 (checksum mismatch)：期望 ${want}，实际 ${got}"
      fi
      [ -n "$want" ] && log_ok "SHA256 校验通过 (${got:0:16}...)"
    fi
    rm -f "$sumf" 2>/dev/null
  else
    log_warn "未取到官方校验文件，跳过 SHA256 校验"
  fi

  log_run "composer: 安装到 /usr/local/bin/composer" \
    install -m 0755 "$phar" /usr/local/bin/composer
  rm -f "$phar" 2>/dev/null
  if [ "${DRY_RUN:-0}" != 1 ] && [ -x /usr/local/bin/composer ]; then
    log_ok "Composer 已安装: $(/usr/local/bin/composer --version 2>/dev/null | head -1)"
  else
    log_ok "Composer ${ver} 安装完成 (/usr/local/bin/composer)"
  fi
}

# ---------------------------------------------------------------------------
#  Node.js（官方二进制包）
# ---------------------------------------------------------------------------
# glibc 门槛判定：Node 18+ 的官方二进制基于 glibc 2.28 构建，CentOS 7 是 2.17，
# 结果是"装得上、跑不了" —— node -v 直接报 GLIBC_2.28 not found。
# 按实际 glibc 判定，而不是只看发行版（自定义 glibc 的机器同样会中招）。
_node_glibc_old() {
  local gv maj min
  if [ "${OS_FAMILY:-}" = rhel ] && [ "${OS_VER:-0}" -le 7 ] 2>/dev/null; then return 0; fi
  gv=$(ldd --version 2>/dev/null | head -1 | grep -oE '[0-9]+\.[0-9]+$')
  [ -n "$gv" ] || return 1
  maj="${gv%%.*}"; min="${gv##*.}"
  [ "$maj" -lt 2 ] 2>/dev/null && return 0
  [ "$maj" -eq 2 ] 2>/dev/null && [ "$min" -lt 28 ] 2>/dev/null && return 0
  return 1
}

# 版本回落：旧 glibc 上把 18+ 换成兜底版本（默认 16.20.2，可用
# NODE_FALLBACK_OLDGLIBC 覆盖）。菜单与 CLI --nodejs **都**走这里 ——
# 历史上只有交互菜单做了降级，命令行 --nodejs 24.22.1 在 CentOS 7 上照装不误，
# 装完才在冒烟测试里 die，白下载两百兆。
_node_fallback_ver() {
  local ver="$1" fb="${NODE_FALLBACK_OLDGLIBC:-16.20.2}"
  if [ "${LNAMP_NODE_NO_FALLBACK:-0}" = 1 ] || ! _node_glibc_old; then
    printf '%s' "$ver"; return 0
  fi
  if ver_ge "$ver" "18.0.0"; then
    log_warn "当前 glibc 低于 2.28，Node ${ver} 装得上但运行不了；自动改用 ${fb}（Node 16.20.x 是最后支持 glibc 2.17 的系列）"
    printf '%s' "$fb"; return 0
  fi
  printf '%s' "$ver"
}

install_nodejs() {
  local ver="$1" mode="$2"
  # 在下载**之前**回落，别等到解压完才发现跑不起来
  ver=$(_node_fallback_ver "$ver")
  case "${mode:-binary}" in
    binary) _nodejs_binary "$ver" ;;
    *)      die "nodejs: 只支持 binary 形式，收到: ${mode}" ;;
  esac
}

# uname -m -> Node 官方架构名
_node_arch() {
  case "$(uname -m 2>/dev/null)" in
    x86_64|amd64)   echo x64 ;;
    aarch64|arm64)  echo arm64 ;;
    armv7l)         echo armv7l ;;
    *)              echo x64 ;;
  esac
}

_nodejs_binary() {
  local ver="$1" arch tb
  arch=$(_node_arch)
  log "安装 Node.js ${ver}  (mode=binary, arch=${arch})"

  if [ "$OS_FAMILY" = debian ]; then
    dep xz-utils curl ca-certificates
  else
    dep xz curl ca-certificates
  fi

  cd_src ~ "cd ~"
  tb="node-v${ver}-linux-${arch}.tar.xz"
  fetch "$tb" \
    "https://nodejs.org/dist/v${ver}/${tb}" \
    "https://npmmirror.com/mirrors/node/v${ver}/${tb}" \
    || die "下载失败 (download failed): ${tb}"

  # 解压到前缀的父目录再改名，避免"先删后装"留下半成品
  safe_mkdir "${PREFIX_NODE%/*}"
  local extracted="node-v${ver}-linux-${arch}"
  log_run "nodejs: 解压" tar -xJf "$tb" -C "${PREFIX_NODE%/*}"
  if [ "${DRY_RUN:-0}" != 1 ] && [ ! -d "${PREFIX_NODE%/*}/${extracted}" ]; then
    die "解压后未找到目录 ${extracted}"
  fi
  safe_rm_rf "${PREFIX_NODE}"
  log_run "nodejs: 安装到 ${PREFIX_NODE}" \
    mv "${PREFIX_NODE%/*}/${extracted}" "${PREFIX_NODE}"
  register_path nodejs "${PREFIX_NODE}/bin" node npm npx corepack
  if [ "${DRY_RUN:-0}" != 1 ]; then
    ln -fs "${PREFIX_NODE}"/bin/* /usr/local/bin/ 2>/dev/null || true
  else
    log "  [dry-run] 将软链 ${PREFIX_NODE}/bin/* 到 /usr/local/bin/"
  fi
  cd ~ && safe_rm_rf "$tb"
  if [ "${DRY_RUN:-0}" != 1 ] && [ -x "${PREFIX_NODE}/bin/node" ]; then
    # 装后冒烟：Node 20+ 的官方预编译包基于 glibc 2.28 构建，在 CentOS 7
    # (glibc 2.17) 上"装得上但跑不了" —— node -v 直接报 GLIBC_2.28 not found。
    # 这里当场运行一次，早失败早提示，不要拖到 npm/composer 镜像那一步才暴露。
    if ! "${PREFIX_NODE}/bin/node" -v >/dev/null 2>&1; then
      local gv; gv=$(ldd --version 2>/dev/null | head -1 | grep -oE '[0-9]+\.[0-9]+$' || echo "?")
      die "Node.js ${ver} 无法在当前系统运行（node -v 失败，当前 glibc ${gv}）。Node 18+ 官方二进制需要 glibc 2.28；CentOS 7 (glibc 2.17) 请改用 16.20.x: $0 --nodejs 16.20.2"
    fi
    log_ok "Node.js 已安装: $("${PREFIX_NODE}/bin/node" -v 2>/dev/null)  npm $("${PREFIX_NODE}/bin/npm" -v 2>/dev/null)"
  else
    log_ok "Node.js ${ver} 安装完成 (${PREFIX_NODE}/bin)"
  fi
}
