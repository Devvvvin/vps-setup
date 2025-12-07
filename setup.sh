#!/bin/bash
# Debian 12/13 一键初始化脚本（循环菜单式安装向导）
# 注意：请以 root 用户执行
set -e

# ------------------------------
# 配置参数
# ------------------------------
SSH_PORT=10022
USERNAME=devvin
USER_HOME=$(eval echo "~$USERNAME")
REMOTE_PREZTO_CONFIG_URL="https://raw.githubusercontent.com/Devvvvin/vps-setup/refs/heads/main/runcoms.tar.gz"

# UFW 默认端口
ALLOWED_TCP_PORTS=("$SSH_PORT" "80" "443" "3478" "8443")
ALLOWED_UDP_PORTS=("$SSH_PORT" "80" "443" "3478" "8443")

# ------------------------------
# 已安装标记
# ------------------------------
installed=()

# ------------------------------
# 菜单显示函数
# ------------------------------
show_menu() {
	echo "=============================="
	echo "请选择要安装的组件（输入数字，多个用空格分隔）："
	echo "1) 修改 SSH 端口为 $SSH_PORT"
	echo "2) 新增用户 $USERNAME 并设置 sudo 免密码"
	echo "3) 安装 Zsh + Prezto（官方 Prezto + 远程配置）"
	echo "4) 安装 Docker + Docker Compose（系统包）"
	echo "5) 安装并配置 UFW（TCP/UDP）"
	echo "6) 安装并配置 Fail2Ban"
	echo "7) 安装 Tailscale"
	echo "0) 完成并退出"
	echo "=============================="
}

# ------------------------------
# 安装组件函数
# ------------------------------
install_component() {
	case $1 in
	1)
		if ! grep -q "Port $SSH_PORT" /etc/ssh/sshd_config; then
			sed -i "s/#Port 22/Port $SSH_PORT/" /etc/ssh/sshd_config
			systemctl restart sshd
			echo "SSH端口已修改为 $SSH_PORT"
		else
			echo "SSH端口已是 $SSH_PORT"
		fi
		installed+=("SSH端口")
		;;
	2)
		if ! id "$USERNAME" &>/dev/null; then
			useradd -m -s /bin/bash "$USERNAME"
			echo "$USERNAME ALL=(ALL) NOPASSWD:ALL" >>/etc/sudoers.d/90-$USERNAME
			chmod 440 /etc/sudoers.d/90-$USERNAME
			echo "用户 $USERNAME 创建完成并设置 sudo 免密码"
		else
			echo "用户 $USERNAME 已存在"
		fi
		installed+=("新增用户")
		;;
	3)
		# 安装 Zsh + Prezto
		if ! command -v zsh &>/dev/null; then
			apt update
			apt install -y zsh git curl
			echo "Zsh 已安装"
		fi

		# 克隆官方 Prezto
		if [ ! -d "$USER_HOME/.zprezto" ]; then
			sudo -u $USERNAME git clone --recursive https://github.com/sorin-ionescu/prezto.git "$USER_HOME/.zprezto"
			echo "官方 Prezto 仓库已克隆"
		fi

		# 下载远程自定义配置文件
		TEMP_DIR=$(mktemp -d)
		curl -L $REMOTE_PREZTO_CONFIG_URL -o "$TEMP_DIR/config.tar.gz"
		tar -xzf "$TEMP_DIR/config.tar.gz" -C "$TEMP_DIR"

		# 只覆盖 Prezto runcoms 文件
		for rcfile in zshrc zlogin zlogout zpreztorc; do
			if [ -f "$TEMP_DIR/$rcfile" ]; then
				cp "$TEMP_DIR/$rcfile" "$USER_HOME/.$rcfile"
				chown $USERNAME:$USERNAME "$USER_HOME/.$rcfile"
			fi
		done

		# 创建 runcoms 符号链接（使用官方 Prezto runcoms）
		sudo -u $USERNAME zsh -c "setopt EXTENDED_GLOB; for rcfile in $USER_HOME/.zprezto/runcoms/^README.md(.N); do ln -sf \$rcfile $USER_HOME/.${rcfile##*/}; done"

		# 设置 zsh 为默认 shell
		chsh -s /bin/zsh "$USERNAME"
		chown -R $USERNAME:$USERNAME "$USER_HOME/.zprezto"
		rm -rf "$TEMP_DIR"
		echo "Prezto 安装完成并应用远程自定义配置"
		installed+=("Zsh+Prezto")
		;;
	4)
		# 安装 Docker + Docker Compose（系统包）
		if ! command -v docker &>/dev/null; then
			read -p "Docker 未安装，是否安装 Docker? (y/N): " install_docker_choice
			if [[ "$install_docker_choice" =~ ^[Yy]$ ]]; then
				apt update
				apt install -y docker.io
				systemctl enable --now docker
				echo "Docker 已安装并启动"
			else
				echo "未安装 Docker，将无法使用 Docker Compose"
			fi
		fi

		if ! dpkg -s docker-compose-plugin &>/dev/null 2>&1; then
			apt install -y docker-compose-plugin
			echo "Docker Compose 插件已安装，可使用 'docker compose' 命令"
		else
			echo "Docker Compose 插件已存在"
		fi
		installed+=("Docker + Docker Compose")
		;;
	5)
		if ! command -v ufw &>/dev/null; then
			apt install -y ufw
		fi
		ufw --force reset
		ufw default deny incoming
		ufw default allow outgoing
		for port in "${ALLOWED_TCP_PORTS[@]}"; do ufw allow "$port"/tcp; done
		for port in "${ALLOWED_UDP_PORTS[@]}"; do ufw allow "$port"/udp; done
		ufw --force enable
		echo "UFW 已启用，放行 TCP: ${ALLOWED_TCP_PORTS[*]}, UDP: ${ALLOWED_UDP_PORTS[*]}"
		installed+=("UFW")
		;;
	6)
		if ! command -v fail2ban-server &>/dev/null; then
			apt install -y fail2ban
		fi
		cat >/etc/fail2ban/jail.local <<EOL
[DEFAULT]
bantime = 3600
findtime = 600
maxretry = 5
backend = systemd

[sshd]
enabled = true
port = $SSH_PORT
logpath = /var/log/auth.log

[docker]
enabled = true
port = all
logpath = /var/lib/docker/containers/*/*.log
EOL
		systemctl enable --now fail2ban
		echo "Fail2Ban 已安装并启用"
		installed+=("Fail2Ban")
		;;
	7)
		curl -fsSL https://tailscale.com/install.sh | sh
		systemctl enable --now tailscaled
		echo "Tailscale 已安装"
		installed+=("Tailscale")
		;;
	0)
		return 1
		;;
	*)
		echo "无效选项: $1"
		;;
	esac
}

# ------------------------------
# 循环菜单
# ------------------------------
while true; do
	echo
	show_menu
	read -p "请输入数字选择（多个用空格分隔）: " -a choices
	for choice in "${choices[@]}"; do
		install_component $choice || exit 0
	done
	echo "=============================="
	echo "已安装组件: ${installed[*]}"
	echo "可以继续选择其他组件或输入 0 完成"
done
