#!/bin/bash
set -euo pipefail

# =====================================================
# 🚀 VPS 初始化
# =====================================================

####################################
# ⚙️ 全局配置（统一管理）
####################################
TARGET_USER="${TARGET_USER:-devvin}"
INITIAL_PASSWORD="${INITIAL_PASSWORD:-}"  # 留空则不设密码，纯密钥认证

SSH_PORT="${SSH_PORT:-22}"
SECOND_SSH_PORT="${SECOND_SSH_PORT:-2222}"

TCP_PORTS=(80 443 3478 8000-9000)
UDP_PORTS=(3478 443)

DNS1="1.1.1.1"
DNS2="8.8.8.8"
DNS_CN="223.5.5.5"

PREZTO_DIR="/opt/prezto-config"
FAIL2BAN_DIR="/opt/fail2ban-config"

DOCKER_LOG_SIZE="10m"
DOCKER_LOG_FILES="3"

INTERACTIVE="${INTERACTIVE:-1}"

####################################
# 🎨 日志工具
####################################
log()  { echo -e "\033[32m[+]\033[0m $*"; }
warn() { echo -e "\033[33m[!]\033[0m $*" >&2; }
die()  { echo -e "\033[31m[✘]\033[0m $*" >&2; exit 1; }

####################################
# 🧠 运行确认
####################################
confirm() {
  if [[ "$INTERACTIVE" == "1" ]]; then
    echo "=============================="
    echo "V2 FULL 初始化 (Hardened)"
    echo "USER=$TARGET_USER"
    echo "SSH=$SSH_PORT + $SECOND_SSH_PORT"
    echo "=============================="
    read -rp "确认执行 (yes): " x
    [[ "$x" == "yes" ]] || exit 0
  fi
}

####################################
# 👤 用户管理（安全版）
####################################
setup_user() {
  if id "$TARGET_USER" &>/dev/null; then
    log "用户 $TARGET_USER 已存在，跳过创建"
    return
  fi

  useradd -m -s /bin/bash -G sudo "$TARGET_USER"

  if [[ -n "$INITIAL_PASSWORD" ]]; then
    echo "$TARGET_USER:$INITIAL_PASSWORD" | chpasswd
    warn "已为用户 $TARGET_USER 设置初始密码（请尽快改用密钥认证）"
  else
    log "未设置密码，请确保已部署 SSH Key"
  fi
}

####################################
# 🔐 SSH 安全加固（含防锁保护）
####################################
setup_ssh() {
  log "配置 SSH"

  local auth_keys="/home/$TARGET_USER/.ssh/authorized_keys"

  # ⚠️ 防锁安全检查
  if [[ ! -s "$auth_keys" ]]; then
    warn "⚠️  $TARGET_USER 没有 authorized_keys！"
    warn "   禁用密码登录后你可能无法登录！"
    if [[ "$INTERACTIVE" == "1" ]]; then
      read -rp "是否仍要继续禁用密码登录？(yes/no): " confirm_ssh
      if [[ "$confirm_ssh" != "yes" ]]; then
        warn "跳过 SSH 硬化，保留当前 SSH 配置"
        return
      fi
    else
      die "非交互模式下拒绝在无密钥时禁用密码登录（安全保护）"
    fi
  fi

  mkdir -p /etc/ssh/sshd_config.d
  cat > /etc/ssh/sshd_config.d/99-v2.conf <<EOF
# Managed by vps-init-v2, DO NOT EDIT MANUALLY
Port $SSH_PORT
Port $SECOND_SSH_PORT
PermitRootLogin no
PasswordAuthentication no
PubkeyAuthentication yes
MaxAuthTries 3
ClientAliveInterval 300
ClientAliveCountMax 2
EOF

  # ✅ 验证语法后再重启，防止配置错误导致 SSH 不可用
  if sshd -t -f /etc/ssh/sshd_config 2>/dev/null; then
    systemctl try-reload-or-restart sshd ssh 2>/dev/null \
      || systemctl restart sshd 2>/dev/null \
      || systemctl restart ssh 2>/dev/null \
      || warn "SSH 服务重启失败，请手动检查"
    log "SSH 配置已生效: 端口 $SSH_PORT/$SECOND_SSH_PORT, Root/密码登录已禁用"
  else
    rm -f /etc/ssh/sshd_config.d/99-v2.conf
    die "❌ SSH 配置语法错误！已回滚，请检查后重试"
  fi
}

####################################
# 🌐 DNS（使用 drop-in 避免覆盖全局）
####################################
setup_dns() {
  log "配置 DNS"

  if systemctl is-active systemd-resolved &>/dev/null; then
    mkdir -p /etc/systemd/resolved.conf.d
    cat > /etc/systemd/resolved.conf.d/vps-dns.conf <<EOF
# Managed by vps-init-v2
[Resolve]
DNS=$DNS1 $DNS2
FallbackDNS=$DNS_CN
EOF
    systemctl restart systemd-resolved
    log "systemd-resolved DNS 已配置 (drop-in)"
  else
    cat > /etc/resolv.conf <<EOF
nameserver $DNS1
nameserver $DNS2
EOF
    log "resolv.conf DNS 已配置"
  fi
}

####################################
# 🔥 UFW 防火墙（幂等版）
####################################
setup_ufw() {
  log "配置 UFW"

  apt-get update -y -qq
  apt-get install -y -qq ufw

  # 仅在 UFW 未激活时重置，避免中断已有连接
  if ! ufw status | grep -q "Status: active"; then
    ufw --force reset
    ufw default deny incoming
    ufw default allow outgoing
  else
    log "UFW 已激活，跳过重置，仅追加规则"
  fi

  ufw allow "$SSH_PORT/tcp"
  ufw allow "$SECOND_SSH_PORT/tcp"

  for p in "${TCP_PORTS[@]}"; do ufw allow "$p/tcp" 2>/dev/null || true; done
  for p in "${UDP_PORTS[@]}"; do ufw allow "$p/udp" 2>/dev/null || true; done

  ufw --force enable
  log "UFW 已启用，已开放端口: ${TCP_PORTS[*]}(tcp) ${UDP_PORTS[*]}(udp)"
}

####################################
# 🛡 Fail2Ban
####################################
setup_fail2ban() {
  log "安装 Fail2Ban"

  apt-get install -y -qq fail2ban

  cat > /etc/fail2ban/jail.local <<EOF
# Managed by vps-init-v2
[DEFAULT]
bantime = 1h
findtime = 10m
maxretry = 5
backend = systemd
banaction = ufw

[sshd]
enabled = true
port = $SSH_PORT,$SECOND_SSH_PORT
EOF

  systemctl enable fail2ban
  systemctl restart fail2ban
  log "Fail2Ban 已配置并启动"
}

####################################
# 📦 Fail2Ban 自定义配置
####################################
setup_fail2ban_custom() {
  log "加载 Fail2Ban 自定义配置"

  local has_custom=false

  if [[ -d "$FAIL2BAN_DIR/jail.d" ]] && ls "$FAIL2BAN_DIR/jail.d/"* &>/dev/null; then
    mkdir -p /etc/fail2ban/jail.d
    cp -r "$FAIL2BAN_DIR/jail.d/"* /etc/fail2ban/jail.d/
    has_custom=true
    log "已复制 jail.d 自定义配置"
  fi

  if [[ -d "$FAIL2BAN_DIR/filter.d" ]] && ls "$FAIL2BAN_DIR/filter.d/"* &>/dev/null; then
    mkdir -p /etc/fail2ban/filter.d
    cp -r "$FAIL2BAN_DIR/filter.d/"* /etc/fail2ban/filter.d/
    has_custom=true
    log "已复制 filter.d 自定义配置"
  fi

  if [[ "$has_custom" == true ]]; then
    systemctl restart fail2ban
  else
    warn "未找到 Fail2Ban 自定义配置目录或目录为空，跳过"
  fi
}

####################################
# ⚡ sysctl 内核优化（幂等 + BBR 验证）
####################################
setup_sysctl() {
  log "系统内核优化"

  cat > /etc/sysctl.d/99-vps-init.conf <<EOF
# Managed by vps-init-v2, DO NOT EDIT MANUALLY
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
net.core.somaxconn=65535
net.ipv4.tcp_max_syn_backlog=16384
net.ipv4.ip_local_port_range=1024 65535
net.ipv4.tcp_fin_timeout=30
net.ipv4.tcp_keepalive_time=300
net.ipv4.tcp_fastopen=3
EOF

  sysctl --system >/dev/null 2>&1

  local cc
  cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "unknown")
  if [[ "$cc" == "bbr" ]]; then
    log "✅ BBR 已启用"
  else
    warn "⚠️  BBR 未生效 (当前: $cc)，可能需要更新内核或加载 tcp_bbr 模块"
  fi
}

####################################
# 🧱 Docker
####################################
setup_docker() {
  log "安装 Docker"

  if ! command -v docker &>/dev/null; then
    curl -fsSL https://get.docker.com | sh
  else
    log "Docker 已安装，跳过安装步骤"
  fi

  mkdir -p /etc/docker
  cat > /etc/docker/daemon.json <<EOF
{
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "$DOCKER_LOG_SIZE",
    "max-file": "$DOCKER_LOG_FILES"
  }
}
EOF

  systemctl enable docker
  systemctl restart docker

  usermod -aG docker "$TARGET_USER" 2>/dev/null || true
  log "Docker 已配置，$TARGET_USER 已加入 docker 组（需重新登录生效）"
}

####################################
# 🌿 Prezto
####################################
setup_prezto() {
  log "安装 Prezto"

  apt-get install -y -qq git zsh 2>/dev/null || true

  local tmp
  tmp=$(mktemp -d /tmp/prezto-XXXXXX)

  if sudo -u "$TARGET_USER" git clone --recursive \
    https://github.com/sorin-ionescu/prezto.git "$tmp" 2>/dev/null; then
    rm -rf "/home/$TARGET_USER/.zprezto"
    mv "$tmp" "/home/$TARGET_USER/.zprezto"
    chown -R "$TARGET_USER:$TARGET_USER" "/home/$TARGET_USER/.zprezto"
    log "Prezto 已安装"
  else
    warn "Prezto 下载失败，跳过"
  fi

  rm -rf "$tmp"
}

####################################
# 📦 Prezto 自定义配置
####################################
setup_prezto_custom() {
  log "加载 Prezto 自定义配置"

  local home="/home/$TARGET_USER"
  local has_custom=false

  if [[ -d "$PREZTO_DIR/runcoms" ]] && ls "$PREZTO_DIR/runcoms/"* &>/dev/null; then
    cp -r "$PREZTO_DIR/runcoms/"* "$home/.zprezto/runcoms/"
    has_custom=true
    log "已复制 Prezto runcoms 配置"
  fi

  if [[ -f "$PREZTO_DIR/.p10k.zsh" ]]; then
    cp "$PREZTO_DIR/.p10k.zsh" "$home/"
    has_custom=true
    log "已复制 p10k 配置"
  fi

  if [[ "$has_custom" == true ]]; then
    chown -R "$TARGET_USER:$TARGET_USER" "$home"
  else
    warn "未找到 Prezto 自定义配置，跳过"
  fi
}

####################################
# 🚀 主流程
####################################
main() {
  confirm

  setup_user
  setup_ssh

  # ⚠️ SSH 变更后安全断点
  echo ""
  warn "⚠️  SSH 配置已变更！"
  warn "   请打开【新终端】测试: ssh -p $SSH_PORT $TARGET_USER@<服务器IP>"
  warn "   确认能正常登录后再继续，否则你将失去访问权限！"
  echo ""
  if [[ "$INTERACTIVE" == "1" ]]; then
    read -rp "新终端测试成功？(yes): " x
    [[ "$x" == "yes" ]] || die "用户取消，请排查 SSH 问题后重新运行"
  fi

  setup_dns
  setup_ufw
  setup_fail2ban
  setup_fail2ban_custom
  setup_sysctl
  setup_docker
  setup_prezto
  setup_prezto_custom

  echo ""
  log "🎉 V2 FULL 初始化完成！"
  log "   用户: $TARGET_USER"
  log "   SSH:  端口 $SSH_PORT / $SECOND_SSH_PORT (密码登录已禁用)"
  log "   提示: 请重新 SSH 登录以使 docker 组和 zsh 配置生效"
}

main "$@"