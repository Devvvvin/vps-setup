#!/bin/bash
# Debian 12/13 一键初始化脚本（循环菜单式安装向导）
# 版本: 1.0.0
# 日期: 2025-12-07
# 注意：请以 root 用户执行
set -e

# ------------------------------
# 前置检查
# ------------------------------
# 提示当前目录是否包含 Prezto 本地配置包 prezto-config.tar.gz（仅做提醒）
if [ -f "$PWD/prezto-config.tar.gz" ]; then
    echo "检测到本地 Prezto 配置: $PWD/prezto-config.tar.gz"
else
    echo "警告: 未在当前目录找到 prezto-config.tar.gz。若要安装 Zsh+Prezto，请将 prezto-config.tar.gz 放在当前目录后再运行脚本。"
fi

# 强制以 root 运行
if [ "$EUID" -ne 0 ]; then
    echo "请以 root 用户运行此脚本。"
    exit 1
fi

# ------------------------------
# 配置参数
# ------------------------------
SSH_PORT=8022
USERNAME=devvin
USER_HOME="/home/$USERNAME"

# UFW 默认端口
ALLOWED_TCP_PORTS=("$SSH_PORT" "80" "443" "3478" "8443")
ALLOWED_UDP_PORTS=("$SSH_PORT" "80" "443" "3478" "8443")

# ------------------------------
# 已安装标记
# ------------------------------
installed=()

# Helper: add component to installed list if not present
add_installed() {
    local name="$1"
    for it in "${installed[@]}"; do
        if [ "$it" = "$name" ]; then
            return
        fi
    done
    installed+=("$name")
}

# ------------------------------
# 菜单显示函数
# ------------------------------
show_menu() {
    echo "=============================="
    echo "请选择要安装的组件（输入数字，多个用空格分隔）："
    echo "1) 修改 SSH 端口为 $SSH_PORT"
    echo "2) 新增用户 $USERNAME 并设置 sudo 免密码"
    echo "3) 安装 Zsh + Prezto（官方 Prezto + 本地配置）"
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
    # 定义组件名称映射
    case $1 in
    1) component_name="SSH端口" ;;
    2) component_name="新增用户" ;;
    3) component_name="Zsh+Prezto" ;;
    4) component_name="Docker + Docker Compose" ;;
    5) component_name="UFW" ;;
    6) component_name="Fail2Ban" ;;
    7) component_name="Tailscale" ;;
    0) return 1 ;;
    *) echo "无效选项: $1"; return ;;
    esac

    # 检查组件是否已安装。
    # 仅对 1 和 2 项（SSH 端口、新增用户）在已安装时跳过，其他项允许重新安装/覆盖。
    if [[ " ${installed[*]} " =~ ${component_name} ]]; then
        if [ "$1" -eq 1 ] || [ "$1" -eq 2 ]; then
            echo "组件 $component_name 已安装，跳过"
            return
        else
            echo "组件 $component_name 已安装，继续执行以重新安装/覆盖..."
        fi
    fi

    # 执行具体安装逻辑
    case $1 in
    1)
        # 更稳健地设置 SSH 端口：支持已存在的 Port 行或追加新的 Port 行
        if grep -qE '^[[:space:]]*Port[[:space:]]+' /etc/ssh/sshd_config >/dev/null 2>&1; then
            sed -ri "s/^[[:space:]]*Port[[:space:]]+.*/Port $SSH_PORT/" /etc/ssh/sshd_config
        else
            echo "Port $SSH_PORT" >> /etc/ssh/sshd_config
        fi

        # 检查 SSH 配置语法
        if ! sshd -t >/dev/null 2>&1; then
            echo "警告: SSH 配置语法错误，请检查 /etc/ssh/sshd_config"
            return 1
        fi

        # 尝试重启 ssh 服务，兼容不同系统的服务名
        if systemctl restart ssh 2>/dev/null || systemctl restart sshd 2>/dev/null; then
            echo "SSH端口已修改为 $SSH_PORT"
            add_installed "$component_name"
        else
            echo "已更新 /etc/ssh/sshd_config，但重启 ssh 服务失败，请手动重启并检查配置。"
        fi
        ;;
    2)
        if ! id "$USERNAME" &>/dev/null; then
            useradd -m -s /bin/bash "$USERNAME"
            if [ ! -f /etc/sudoers.d/90-$USERNAME ]; then
                echo "$USERNAME ALL=(ALL) NOPASSWD:ALL" >/etc/sudoers.d/90-$USERNAME
                chmod 440 /etc/sudoers.d/90-$USERNAME
            fi
            USER_HOME=$(eval echo "~$USERNAME")
            echo "用户 $USERNAME 创建完成并设置 sudo 免密码"
            add_installed "$component_name"
        else
            echo "用户 $USERNAME 已存在"
        fi
        ;;
    3)
        # 安装 Zsh + Prezto
        # 确保目标用户存在（若不存在则自动创建并配置 sudo 免密码）
        if ! id "$USERNAME" &>/dev/null; then
            echo "用户 $USERNAME 不存在，正在创建..."
            useradd -m -s /bin/bash "$USERNAME"
            if [ ! -f /etc/sudoers.d/90-"$USERNAME" ]; then
                echo "$USERNAME ALL=(ALL) NOPASSWD:ALL" >/etc/sudoers.d/90-"$USERNAME"
                chmod 440 /etc/sudoers.d/90-"$USERNAME"
            fi
        fi
        USER_HOME=$(eval echo "~$USERNAME")

        if ! command -v zsh &>/dev/null; then
            apt update
            apt install -y zsh git curl
            echo "Zsh 已安装"
        fi

        # 克隆官方 Prezto
        if [ ! -d "$USER_HOME/.zprezto" ]; then
            sudo -u "$USERNAME" git clone --recursive https://github.com/sorin-ionescu/prezto.git "$USER_HOME/.zprezto"
            echo "官方 Prezto 仓库已克隆"
        fi

        # 获取自定义配置文件：仅从当前目录读取 runcoms.tar.gz
        TEMP_DIR=$(mktemp -d)
        if [ -f "$PWD/prezto-config.tar.gz" ]; then
            cp "$PWD/prezto-config.tar.gz" "$TEMP_DIR/config.tar.gz"
        else
            echo "错误: 未找到 $PWD/prezto-config.tar.gz — 请将 prezto-config.tar.gz 放在当前目录后再运行此选项。"
            rm -rf "$TEMP_DIR"
            return 1
        fi
        tar -xzf "$TEMP_DIR/prezto-config.tar.gz" -C "$TEMP_DIR"

        # 只覆盖 Prezto runcoms 文件
        for rcfile in zshrc zlogin zlogout zpreztorc; do
            if [ -f "$TEMP_DIR/$rcfile" ]; then
                cp "$TEMP_DIR/$rcfile" "$USER_HOME/.$rcfile"
                chown "$USERNAME:$USERNAME" "$USER_HOME/.$rcfile"
            fi
        done

        # 查找并安装自定义 prompt 主题（支持压缩包任意位置的 prompt 目录）
        PROMPT_SRC=$(find "$TEMP_DIR" -type d -name prompt -print -quit || true)
        if [ -n "$PROMPT_SRC" ]; then
            PREZTO_PROMPT_DIR="$USER_HOME/.zprezto/modules/prompt"
            mkdir -p "$PREZTO_PROMPT_DIR"
            cp -r "$PROMPT_SRC/." "$PREZTO_PROMPT_DIR/"
            chown -R "$USERNAME:$USERNAME" "$PREZTO_PROMPT_DIR"
            echo "已安装自定义 Prezto prompt 主题到 $PREZTO_PROMPT_DIR"
        fi

        # 创建 runcoms 符号链接（使用官方 Prezto runcoms），在 zsh 中运行以正确处理 :t
        sudo -u "$USERNAME" zsh -ic 'setopt EXTENDED_GLOB; for rcfile in $HOME/.zprezto/runcoms/^README.md(.N); do ln -sf "$rcfile" "$HOME/.${rcfile:t}"; done'

        # 设置 zsh 为默认 shell
        chsh -s /bin/zsh "$USERNAME"
        chown -R "$USERNAME:$USERNAME" "$USER_HOME/.zprezto"
        rm -rf "$TEMP_DIR"
        echo "Prezto 安装完成并应用本地自定义配置"
        echo "提示：设置 zsh 为默认 shell 后，需重新登录用户 $USERNAME 生效"
        add_installed "$component_name"
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

        # 优先检测现有的 docker compose
        if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
            echo "检测到 'docker compose' 可用，跳过安装。"
        else
			read -p "Docker Compose 未安装，是否安装 Docker Compose? (y/N): " install_compose_choice
			if [[ "$install_compose_choice" =~ ^[Yy]$ ]]; then
				apt update
				apt install -y docker-compose
				echo "Docker Compose 已安装"
			else
				echo "未安装 Docker Compose"
				return
			fi
        fi
        add_installed "$component_name"
        ;;
    5)
        if ! command -v ufw &>/dev/null; then
            apt install -y ufw
        fi
        echo "警告: 这将重置现有的 UFW 规则并应用默认策略。"
        read -p "确定要继续并重置 UFW 吗? (y/N): " ufw_confirm
        if [[ "$ufw_confirm" =~ ^[Yy]$ ]]; then
            ufw --force reset
            ufw default deny incoming
            ufw default allow outgoing
            for port in "${ALLOWED_TCP_PORTS[@]}"; do ufw allow "$port"/tcp; done
            for port in "${ALLOWED_UDP_PORTS[@]}"; do ufw allow "$port"/udp; done
            ufw --force enable
            echo "UFW 已启用，放行 TCP: ${ALLOWED_TCP_PORTS[*]}, UDP: ${ALLOWED_UDP_PORTS[*]}"
            add_installed "$component_name"
        else
            echo "已取消 UFW 配置"
        fi
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
# 注意：Docker 容器日志路径可能因系统配置不同而变化，若监控异常请检查路径
EOL
        systemctl enable --now fail2ban
        echo "Fail2Ban 已安装并启用"
        add_installed "$component_name"
        ;;
    7)
        curl -fsSL https://tailscale.com/install.sh | sh
        systemctl enable --now tailscaled
        echo "Tailscale 已安装"
        add_installed "$component_name"
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
