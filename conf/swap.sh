#!/bin/bash
# ============================================================================
#  conf/swap.sh  ——  可选 swap 创建（被 install.sh 的 system_prep 以 source 调用）
# ----------------------------------------------------------------------------
#  说明：install.sh 用 `[ -f conf/swap.sh ] && source conf/swap.sh` 调用本文件，
#        因此文件末尾自行调用 setup_swap —— 被 source 即执行。
#        依赖 common.sh 的 detect_mem / log* 以及 install.sh 的 ASSUME_YES。
#
#  相比旧版 legacy/sh/swap.sh 的修复：
#    · 补齐内存分档边界（旧版用 -gt/-lt 留有 1024/8192/16384 等空档，
#      命中空档时 swapcreat 变量为空 → 计算出错）；这里改用 -le 链，无空档。
#    · 非交互：-y (ASSUME_YES=1) 时不再用 read 阻塞等待，直接创建。
#    · 用 fallocate 秒级创建，失败再回落 dd bs=1M（旧版 dd bs=小值 极慢）。
#    · 幂等：已有 swap 或 /swapfile 存在则跳过；fstab / swappiness 去重写入。
#    · best-effort：任何步骤失败只告警，绝不中断整体安装。
# ============================================================================

setup_swap() {
  local swapfile=/swapfile

  # 已有任意 swap（分区或文件）→ 跳过
  local cur_swap; cur_swap=$(free -m 2>/dev/null | awk '/Swap/ {print $2}')
  if [ -n "$cur_swap" ] && [ "$cur_swap" -gt 0 ] 2>/dev/null; then
    log "已存在 swap (${cur_swap}MB)，跳过创建 (swap already present, skip)"
    return 0
  fi
  if [ -e "$swapfile" ]; then
    log_warn "${swapfile} 已存在，跳过创建 (exists, skip)"
    return 0
  fi

  # 按物理内存决定 swap 大小（MB）。用 -le 链，边界无空档。
  [ -n "$MEM_MB" ] || detect_mem
  local sz
  if   [ "$MEM_MB" -le 1024 ];  then sz=512
  elif [ "$MEM_MB" -le 8192 ];  then sz=1024
  elif [ "$MEM_MB" -le 16384 ]; then sz=2048
  else                               sz=8192
  fi

  # 交互确认；-y / 非交互(无 tty) 时默认创建
  if [ "${ASSUME_YES:-0}" -ne 1 ] && [ -t 0 ]; then
    local yn
    read -rp "是否创建 ${sz}MB swap 文件 ${swapfile}? (create swap?) [y/N]: " yn
    [[ "$yn" =~ ^[Yy]$ ]] || { log "跳过 swap 创建 (skipped by user)"; return 0; }
  fi

  log "创建 swap: ${swapfile} (${sz}MB)"
  # 优先 fallocate（秒级）；失败回落 dd bs=1M（比旧版 bs=小值快得多）
  if ! fallocate -l "${sz}M" "$swapfile" 2>/dev/null; then
    log_warn "fallocate 不可用，改用 dd 创建（较慢）"
    if ! dd if=/dev/zero of="$swapfile" bs=1M count="$sz" status=none 2>/dev/null; then
      rm -f "$swapfile" 2>/dev/null
      log_warn "swap 文件创建失败，已跳过 (creation failed, skipped)"
      return 0
    fi
  fi

  chmod 600 "$swapfile" 2>/dev/null
  if ! mkswap "$swapfile" >/dev/null 2>&1; then
    rm -f "$swapfile" 2>/dev/null
    log_warn "mkswap 失败，已清理并跳过 (mkswap failed, skipped)"
    return 0
  fi
  if ! swapon "$swapfile" 2>/dev/null; then
    rm -f "$swapfile" 2>/dev/null
    log_warn "swapon 失败，已清理并跳过 (swapon failed, skipped)"
    return 0
  fi

  # 开机自动挂载（去重，避免重复行）
  if ! grep -qE "^[^#]*[[:space:]]${swapfile}[[:space:]]" /etc/fstab 2>/dev/null \
     && ! grep -qE "^${swapfile}[[:space:]]" /etc/fstab 2>/dev/null; then
    printf '%s none swap sw 0 0\n' "$swapfile" >> /etc/fstab
  fi

  # vm.swappiness=10（去重后写入并即时生效）
  if [ -f /etc/sysctl.conf ]; then
    if grep -qE '^[[:space:]]*vm\.swappiness' /etc/sysctl.conf; then
      sed -i 's@^[[:space:]]*vm\.swappiness.*@vm.swappiness=10@' /etc/sysctl.conf
    else
      echo 'vm.swappiness=10' >> /etc/sysctl.conf
    fi
    sysctl -w vm.swappiness=10 >/dev/null 2>&1 || true
  fi

  log_ok "swap 已启用 (${sz}MB, vm.swappiness=10)"
  free -m 2>/dev/null | awk '/Swap/ {printf "  Swap: total=%sMB used=%sMB free=%sMB\n",$2,$3,$4}'
}

# 被 source 即执行（install.sh system_prep 中 `source conf/swap.sh`）
setup_swap
