#!/bin/bash
# ============================================================================
#  modules/java.sh —— OpenJDK(11/17, Eclipse Temurin 二进制) + Tomcat 10
#  install_java <11|17>  下载 Temurin JDK 到 ${PREFIX_JAVA}，设置 JAVA_HOME/PATH
#  install_tomcat        下载 Tomcat ${TOMCAT_VERSION} 到 ${PREFIX_TOMCAT}，systemd 管理
#  Tomcat 10.1 需要 Java 11+，故 Tomcat 安装前需先装 OpenJDK 11 或 17。
# ============================================================================

_java_arch() {
  case "$(uname -m)" in
    x86_64|amd64) echo x64 ;;
    aarch64|arm64) echo aarch64 ;;
    *) echo x64 ;;
  esac
}

# 安装 OpenJDK（Temurin），设置环境变量 JAVA_HOME / PATH / CLASSPATH
install_java() {
  local major="$1"
  case "$major" in 11|17) ;; *) die "Java: 仅支持 OpenJDK 11 或 17（收到 ${major}）" ;; esac
  local arch; arch=$(_java_arch)
  local prefix="${PREFIX_JAVA:-/usr/local/java}"
  log "安装 OpenJDK ${major} (Temurin, ${arch}) -> ${prefix}"
  dep tar gzip
  cd ~ || return 1
  # Adoptium 最新 GA 二进制（自动重定向到对应版本，wget 跟随跳转）
  fetch "OpenJDK${major}.tar.gz" \
    "https://api.adoptium.net/v3/binary/latest/${major}/ga/linux/${arch}/jdk/hotspot/normal/eclipse?project=jdk" \
    "https://mirrors.tuna.tsinghua.edu.cn/Adoptium/${major}/jdk/${arch}/linux/" \
    || die_with_log "OpenJDK ${major} 下载失败"
  local d; d=$(tar -tzf "OpenJDK${major}.tar.gz" 2>/dev/null | head -1 | cut -d/ -f1)
  [ -n "$d" ] || die "OpenJDK 解压目录探测失败"
  rm -rf "$prefix" "$d"
  tar -zxf "OpenJDK${major}.tar.gz" || die "OpenJDK 解包失败"
  mkdir -p "$(dirname "$prefix")"
  mv "$d" "$prefix"
  rm -f "OpenJDK${major}.tar.gz"

  # 环境变量（/etc/profile.d，新登录 shell 自动生效）
  cat > /etc/profile.d/lnamp-java.sh <<EOF
export JAVA_HOME=${prefix}
export JRE_HOME=\${JAVA_HOME}
export CLASSPATH=.:\${JAVA_HOME}/lib
export PATH=\${JAVA_HOME}/bin:\${PATH}
EOF
  chmod 644 /etc/profile.d/lnamp-java.sh
  ln -sf "${prefix}/bin/java"  /usr/local/bin/java
  ln -sf "${prefix}/bin/javac" /usr/local/bin/javac
  # 当前进程立即可用（供随后的 Tomcat 使用）
  export JAVA_HOME="$prefix"; export PATH="${JAVA_HOME}/bin:${PATH}"

  [ -x "${prefix}/bin/java" ] || die "OpenJDK ${major} 安装失败（${prefix}/bin/java 不存在）"
  log_ok "OpenJDK ${major} 安装完成: $(${prefix}/bin/java -version 2>&1 | head -1)"
  log_ok "  JAVA_HOME=${prefix} (已写入 /etc/profile.d/lnamp-java.sh)"
}

# 安装 Tomcat（默认 10.1.x，需先装 Java）
install_tomcat() {
  local ver="${TOMCAT_VERSION:-10.1.55}" maj prefix jh
  maj="${ver%%.*}"
  prefix="${PREFIX_TOMCAT:-/usr/local/tomcat}"
  jh="${JAVA_HOME:-${PREFIX_JAVA:-/usr/local/java}}"
  if [ ! -x "${jh}/bin/java" ] && ! command -v java >/dev/null 2>&1; then
    die "Tomcat 需要 Java，请先选择安装 OpenJDK 11 或 17（--java 11|17）"
  fi
  log "安装 Tomcat ${ver} -> ${prefix} (JAVA_HOME=${jh})"
  cd ~ || return 1
  local pkg="apache-tomcat-${ver}"
  fetch "${pkg}.tar.gz" \
    "https://dlcdn.apache.org/tomcat/tomcat-${maj}/v${ver}/bin/${pkg}.tar.gz" \
    "https://archive.apache.org/dist/tomcat/tomcat-${maj}/v${ver}/bin/${pkg}.tar.gz" \
    || die_with_log "Tomcat ${ver} 下载失败"
  rm -rf "$prefix" "$pkg"
  tar -zxf "${pkg}.tar.gz" || die "Tomcat 解包失败"
  rm -f "${pkg}.tar.gz"
  mkdir -p "$(dirname "$prefix")"
  mv "$pkg" "$prefix"

  # 运行用户 tomcat（无登录权限）
  ensure_sysuser tomcat 2>/dev/null || true
  chown -R tomcat:tomcat "$prefix" 2>/dev/null || chown -R www:www "$prefix" 2>/dev/null || true
  chmod +x "${prefix}"/bin/*.sh 2>/dev/null || true

  # systemd 服务
  local runuser=tomcat; id -u tomcat >/dev/null 2>&1 || runuser=www
  cat > "${SYSTEMD_DIR}/tomcat.service" <<EOF
[Unit]
Description=Apache Tomcat ${ver}
After=network.target

[Service]
Type=forking
Environment=JAVA_HOME=${jh}
Environment=CATALINA_HOME=${prefix}
Environment=CATALINA_BASE=${prefix}
Environment=CATALINA_PID=${prefix}/temp/tomcat.pid
Environment="CATALINA_OPTS=-Xms256m -Xmx512m -server"
ExecStart=${prefix}/bin/startup.sh
ExecStop=${prefix}/bin/shutdown.sh
User=${runuser}
Group=${runuser}
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF
  enable_service tomcat
  open_ports 8080

  hr
  log_ok "Tomcat ${ver} 安装完成，监听 8080 (CATALINA_HOME=${prefix})"
  log_ok "  管理: systemctl {start|stop|restart|status} tomcat"
  log_ok "  访问: http://<你的域名或IP>:8080/"
  hr
}
