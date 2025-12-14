#!/bin/bash
set -u # 变量未定义报错

# ==========================================
# 服务器全能初始化脚本 (加固 + 全模块版)
# ==========================================

# --- 全局配置 (可修改此处或通过环境变量覆盖) ---
TARGET_USER="${TARGET_USER:-devvin}"                           # 目标用户名
SSH_PORT="${SSH_PORT:-22}"                                     # 目标 SSH 端口
TCP_PORTS=("${TCP_PORTS[@]:-80 443 3478 8000:9000}")           # 额外开放的 TCP 端口
UDP_PORTS=("${UDP_PORTS[@]:-443 3478 8000:9000}")              # 额外开放的 UDP 端口
DOCKER_MIN_VERSION="${DOCKER_MIN_VERSION:-20.10}"              # 最低 Docker 版本要求
PREZTO_CONFIG_DIR="${PREZTO_CONFIG_DIR:-$(pwd)/prezto-config}" # Prezto 配置目录
TAILSCALE_AUTH_KEY="${TAILSCALE_AUTH_KEY:-}"                   # Tailscale 认证密钥 (可选)

# 颜色定义
RED='\033[31m'
GREEN='\033[32m'
YELLOW='\033[33m'
BLUE='\033[34m'
NC='\033[0m'

# --- 基础工具函数 ---
log() { echo -e "${GREEN}[+]${NC} $*"; }
info() { echo -e "${BLUE}[i]${NC} $*"; }
warn() { echo -e "${YELLOW}[!]${NC} $*"; }
error() { echo -e "${RED}[-]${NC} $*"; }

require_root() {
	if [ "$EUID" -ne 0 ]; then
		error "请以 root 权限运行此脚本"
		exit 1
	fi
}

# --- 环境检测 ---
is_wsl() { grep -qE "(Microsoft|WSL)" /proc/version &>/dev/null; }

# ==========================================
# 模块 1: 基础用户管理
# ==========================================
install_user() {
	info "检查用户配置..."
	if id "$TARGET_USER" &>/dev/null; then
		log "用户 $TARGET_USER 已存在"
	else
		useradd -m -s /bin/bash -G sudo "$TARGET_USER"
		log "用户 $TARGET_USER 创建成功"
		log "请设置密码:"
		passwd "$TARGET_USER"
	fi
}

# ==========================================
# 模块 2: DNS 安全配置 (Systemd/WSL 兼容)
# ==========================================
configure_dns() {
	info "开始配置 DNS..."

	if is_wsl; then
		warn "检测到 WSL 环境，跳过 DNS 修改以防断网。"
		return
	fi

	# 测试解析结果
	local TEST_DOMAIN_INTL="google.com"
	local TEST_DOMAIN_CN="baidu.com"
	echo "测试解析结果："
	if ! ping -c 3 "$TEST_DOMAIN_INTL" >/dev/null 2>&1; then
		echo "⚠️ 国际域名解析失败: $TEST_DOMAIN_INTL"
	else
		echo "✅ 国际域名解析成功: $TEST_DOMAIN_INTL"
	fi

	if ! ping -c 3 "$TEST_DOMAIN_CN" >/dev/null 2>&1; then
		echo "⚠️ 国内域名解析失败: $TEST_DOMAIN_CN"
	else
		echo "✅ 国内域名解析成功: $TEST_DOMAIN_CN"
	fi

	read -rp "是否修改DNS配置？(y/N): " confirm
	if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
		echo "取消操作"
		return 0
	fi

	# 解锁文件防止修改失败
	lsattr /etc/resolv.conf 2>/dev/null | grep -q "i" && chattr -i /etc/resolv.conf

	local dns_list="8.8.8.8 1.1.1.1 223.5.5.5"

	if systemctl is-active systemd-resolved &>/dev/null; then
		local conf="/etc/systemd/resolved.conf"
		cp "$conf" "${conf}.bak"
		# 使用 sed 修改配置
		grep -q "^DNS=" "$conf" && sed -i "s/^DNS=.*/DNS=$dns_list/" "$conf" || echo "DNS=$dns_list" >>"$conf"
		grep -q "^FallbackDNS=" "$conf" || echo "FallbackDNS=114.114.114.114" >>"$conf"

		systemctl restart systemd-resolved
		log "Systemd-resolved DNS 已更新"
	else
		# 传统方式
		cp /etc/resolv.conf /etc/resolv.conf.bak
		[ -L /etc/resolv.conf ] && unlink /etc/resolv.conf
		echo -e "nameserver 8.8.8.8\nnameserver 1.1.1.1" >/etc/resolv.conf
		log "DNS 已写入 /etc/resolv.conf"
	fi
}

# ==========================================
# 模块 3: Zsh + Prezto
# ==========================================
install_zsh() {
	if ! id "$TARGET_USER" &>/dev/null; then
		error "用户不存在，请先执行步骤 1"
		return 1
	fi

	info "安装 Zsh 和 Git..."
	apt-get update && apt-get install -y zsh git curl

	local home="/home/$TARGET_USER"
	local target="$home/.zprezto"
	local tmp="$target.tmp"

	rm -rf "$tmp"
	sudo -u "$TARGET_USER" git clone --recursive \
		https://github.com/sorin-ionescu/prezto.git "$tmp" || {
		rm -rf "$tmp"
		error "Prezto clone 失败"
		return 1
	}

	rm -rf "$target"
	mv "$tmp" "$target"

	cp -r "$PREZTO_CONFIG_DIR/runcoms/." "$target/runcoms/"
	cp "$PREZTO_CONFIG_DIR/.p10k.zsh" "$home/.p10k.zsh"

	# 创建 runcoms 符号链接
	for rcfile in "$target/runcoms/"*; do
		filename=$(basename "$rcfile")
		if [ "$filename" != "README.md" ]; then
			ln -sf "$rcfile" "$home/.$filename"
			chown "$TARGET_USER:$TARGET_USER" "$home/.$filename"
		fi
	done

	# 禁用 zsh-newuser-install
	echo 'export DISABLE_ZSH_NEWUSER_INSTALL=true' >>"$home/.zshrc"
	chown "$TARGET_USER:$TARGET_USER" "$home/.zshrc"

	chown -R "$TARGET_USER:$TARGET_USER" "$home"
	chsh -s /bin/zsh "$TARGET_USER"

	log "Zsh + Prezto 安装完成"
}

# ==========================================
# 模块 4: Docker
# ==========================================
need_official_docker() {
	local cur
	cur=$(docker version --format '{{.Server.Version}}' 2>/dev/null || echo 0)
	dpkg --compare-versions "$cur" lt "$DOCKER_MIN_VERSION"
}
install_docker() {
	if command -v docker &>/dev/null; then
		log "Docker 已安装"
		if ! need_official_docker; then
			log "Docker 已满足版本要求"
			return
		else
			info "当前 Docker 版本过低，正在升级..."
		fi
	else
		info "正在安装 Docker..."
		curl -fsSL https://get.docker.com | sh
	fi

	# 限制日志大小
	local daemon_json="/etc/docker/daemon.json"
	if [ ! -f "$daemon_json" ]; then
		info "创建 Docker 配置文件 $daemon_json"
		mkdir -p "$(dirname "$daemon_json")"
		touch "$daemon_json"
	fi
	# 添加日志配置
	if ! grep -q '"log-driver": "json-file"' "$daemon_json"; then
		info "添加 Docker 日志配置到 $daemon_json"
		cat >>"$daemon_json" <<EOF
{
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "50m",
    "max-file": "5"
  }
}
EOF
	fi

	systemctl enable --now docker

	# 确保用户在 docker 组
	if ! id -nG "$TARGET_USER" | grep -qw docker; then
		usermod -aG docker "$TARGET_USER"
		log "用户 $TARGET_USER 已加入 Docker 组 (需重新登录生效)"
	fi
}

# ==========================================
# 模块 5: Fail2Ban (自动联动 SSH 端口)
# ==========================================
install_fail2ban() {
	info "安装 Fail2Ban..."
	if ! command -v fail2ban-server &>/dev/null; then
		apt install -y fail2ban
	fi

	# 生成配置
	if [ ! -f "/etc/fail2ban/jail.local" ]; then
		info "配置 Jail 规则 (保护ssh端口: $SSH_PORT)..."
		cat >/etc/fail2ban/jail.local <<EOF
[DEFAULT]
bantime = 1h
findtime = 10m
maxretry = 5
backend = systemd

[sshd]
enabled = true
port = ssh
logpath = %(sshd_log)s
filter = sshd
EOF
	fi

	# 拷贝自定义配置文件（如果有）
	if [ -d "fail2ban/jail.d" ]; then
		info "拷贝自定义配置文件..."
		mkdir -p /etc/fail2ban/jail.d
		cp fail2ban/jail.d/* /etc/fail2ban/jail.d/
	fi

	# 拷贝自定义 filter 文件（如果有）
	if [ -d "fail2ban/filter.d" ]; then
		info "拷贝自定义 filter 文件..."
		mkdir -p /etc/fail2ban/filter.d
		cp fail2ban/filter.d/* /etc/fail2ban/filter.d/
	fi

	systemctl enable --now fail2ban
	systemctl restart fail2ban
	log "Fail2Ban 已启用"
}

# ==========================================
# 模块 6: Tailscale
# ==========================================
install_tailscale() {
	if command -v tailscale &>/dev/null; then
		log "Tailscale 已安装"
	else
		info "安装 Tailscale..."
		curl -fsSL https://tailscale.com/install.sh | sh
		systemctl enable --now tailscaled

		if [ -n "${TAILSCALE_AUTH_KEY:-}" ]; then
			tailscale up --authkey "$TAILSCALE_AUTH_KEY"
			log "Tailscale 已自动连接"
		else
			warn "Tailscale 安装完成。请手动运行 'tailscale up' 进行登录。"
		fi
	fi
}

# ==========================================
# 模块 7: UFW (防火墙) - 基础配置
# ==========================================
configure_ufw_base() {
	if ! command -v ufw &>/dev/null; then apt-get install -y ufw; fi

	info "重置 UFW 规则..."
	# 获取当前实际 SSH 端口，防止把自己锁外面
	local current_port
	current_port=$(sshd -T 2>/dev/null | grep "^port " | awk '{print $2}' | head -n 1)

	ufw --force reset
	ufw default deny incoming
	ufw default allow outgoing

	# 放行当前端口 (保命)
	ufw allow "${current_port:-22}/tcp"
	log "保命规则: 放行当前端口 ${current_port:-22}"

	# 放行业务端口
	# TCP 放行
	for port_item in "${TCP_PORTS[@]}"; do
		for p in $port_item; do ufw allow "$p"/tcp; done
	done

	# UDP 放行
	for port_item in "${UDP_PORTS[@]}"; do
		for p in $port_item; do ufw allow "$p"/udp; done
	done

	echo "放行 TCP: ${TCP_PORTS[*]}, UDP: ${UDP_PORTS[*]}"

	ufw --force enable
	log "UFW 已启用"
}

# ==========================================
# 模块 8: SSH 加固（root密钥登录）
# ==========================================
configure_ssh() {
	if ! id "$TARGET_USER" &>/dev/null; then
		error "请先创建用户 $TARGET_USER"
		return 1
	fi

	local drop_in_dir="/etc/ssh/sshd_config.d"
	local custom_config="$drop_in_dir/99-hardened.conf"
	local ssh_config="/etc/ssh/sshd_config"
	local user_ssh_dir home_dir

	# 获取用户家目录
	home_dir=$(eval echo "~$TARGET_USER")
	user_ssh_dir="$home_dir/.ssh"

	# 创建 Drop-in 目录
	if [ ! -d "$drop_in_dir" ]; then
		mkdir -p "$drop_in_dir"
		echo "创建 SSH Drop-in 目录 $drop_in_dir"
	fi

	# 确保 Include 行存在且唯一
	if ! grep -Eq "^[[:space:]]*Include[[:space:]]+/etc/ssh/sshd_config.d/\*\.conf" "$ssh_config"; then
		echo "Include /etc/ssh/sshd_config.d/*.conf" >>"$ssh_config"
	fi

	# 创建加固配置文件
	if [ ! -f "$custom_config" ]; then
		touch "$custom_config"
		chmod 600 "$custom_config"
		echo "创建 SSH 加固配置文件 $custom_config"
	fi

	# 写入基础配置
	cat >"$custom_config" <<EOF
Port $SSH_PORT
PermitRootLogin prohibit-password
PasswordAuthentication no
PubkeyAuthentication yes
EOF

	# 如果没有公钥，允许密码登录
	if [ ! -f "$user_ssh_dir/authorized_keys" ] || [ ! -s "$user_ssh_dir/authorized_keys" ]; then
		warn "未检测到公钥，强制开启密码登录以防锁死"
		# 如果已有 PasswordAuthentication no，替换；否则追加
		if grep -q "^PasswordAuthentication no" "$custom_config"; then
			sed -i 's/^PasswordAuthentication no/PasswordAuthentication yes/' "$custom_config"
		else
			echo "PasswordAuthentication yes" >>"$custom_config"
		fi
	fi

	systemctl restart sshd || warn "sshd 重启失败，请手动检查"
	log "SSH 加固完成"
}

# ==========================================
# 菜单系统
# ==========================================
show_menu() {
	echo "------------------------------------------------"
	echo " 全能初始化脚本 - 目标用户: $TARGET_USER | SSH端口: $SSH_PORT"
	echo "------------------------------------------------"
	echo "1) [基础] 创建用户 & Sudo"
	echo "2) [系统] DNS 优化 (Systemd/WSL 兼容)"
	echo "3) [软件] 安装 Zsh + Prezto"
	echo "4) [软件] 安装 Docker (自动加组，日志限制)"
	echo "5) [网络] 安装 Tailscale"
	echo "6) [安全] 配置 UFW 防火墙 (基础)"
	echo "7) [安全] SSH 加固（root密钥登录）"
	echo "8) [安全] 安装 Fail2Ban (自动适配SSH端口)"
	echo "9) [一键] 执行所有步骤 (推荐)"
	echo "0) 退出"
	echo "------------------------------------------------"
}

run_all() {
	install_user
	configure_dns
	install_zsh
	install_docker
	install_tailscale
	configure_ufw_base
	configure_ssh
	install_fail2ban # 最后运行以捕获最终SSH端口
}

# --- 主程序入口 ---
require_root

while true; do
	show_menu
	read -rp "请选择: " choice
	case $choice in
	1) install_user ;;
	2) configure_dns ;;
	3) install_zsh ;;
	4) install_docker ;;
	5) install_tailscale ;;
	6) configure_ufw_base ;;
	7) configure_ssh ;;
	8) install_fail2ban ;;
	9) run_all ;;
	0) exit 0 ;;
	*) error "无效选择" ;;
	esac
	echo ""
	read -rp "按回车键继续..."
done
