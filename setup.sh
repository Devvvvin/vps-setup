#!/bin/bash
# Debian 12/13 一键初始化脚本（循环菜单式安装向导）
# 版本: 1.0.0
# 日期: 2025-12-07
# 注意：请以 root 用户执行
set -e

# ------------------------------
# 前置检查
# ------------------------------
# 提示当前目录是否包含 Prezto 本地配置目录 `prezto-config`（仅做提醒）
if [ -d "$PWD/prezto-config" ]; then
    echo "检测到本地 Prezto 配置目录: $PWD/prezto-config"
else
    echo "警告: 未在当前目录找到 prezto-config 目录。若要安装 Zsh+Prezto，请将 prezto-config 目录放在当前目录后再运行脚本。"
fi

# 强制以 root 运行
if [ "$EUID" -ne 0 ]; then
    echo "请以 root 用户运行此脚本。"
    exit 1
fi

# ------------------------------
# 配置参数
# ------------------------------
SSHD_CONFIG="/etc/ssh/sshd_config"
BACKUP_FILE="/etc/ssh/sshd_config.bak.$(date +%F_%H%M%S)"
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

# Prompt interactively for a password and set it for the given user
set_user_password() {
    local user="$1"
    # Require chpasswd available
    if ! command -v chpasswd >/dev/null 2>&1; then
        echo "警告: 系统上没有 chpasswd，无法为用户设置密码。"
        return 1
    fi
    while true; do
        read -s -p "为用户 $user 设置密码: " passwd1
        echo
        read -s -p "请再次输入密码以确认: " passwd2
        echo
        if [ -z "$passwd1" ]; then
            echo "密码不能为空，请重试。"
            continue
        fi
        if [ "$passwd1" != "$passwd2" ]; then
            echo "两次输入不匹配，请重试。"
            continue
        fi
        echo "$user:$passwd1" | chpasswd
        if [ $? -eq 0 ]; then
            echo "密码已设置。"
            return 0
        else
            echo "设置密码失败，请检查系统工具。"
            return 1
        fi
    done
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
    *)
        echo "无效选项: $1"
        return
        ;;
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
        echo "配置 SSH：禁用 root 密码登录，检查公钥，不存在则自动生成"
        SSHD_CONFIG="/etc/ssh/sshd_config"
        BACKUP_FILE="/etc/ssh/sshd_config.bak.$(date +%F_%H%M%S)"
        ROOT_SSH_DIR="/root/.ssh"
        AUTH_KEYS="$ROOT_SSH_DIR/authorized_keys"
        # 1. 备份配置
        cp "$SSHD_CONFIG" "$BACKUP_FILE"
        # 2. 禁止 root 密码登录（只允许密钥）
        if grep -q "^PermitRootLogin" "$SSHD_CONFIG"; then
            sed -i 's/^PermitRootLogin.*/PermitRootLogin prohibit-password/' "$SSHD_CONFIG"
        else
            echo "PermitRootLogin prohibit-password" >> "$SSHD_CONFIG"
        fi
        # 3. 准备 .ssh 目录
        mkdir -p "$ROOT_SSH_DIR"
        chmod 700 "$ROOT_SSH_DIR"
        # 4. 检查是否已存在 authorized_keys
        if [ ! -s "$AUTH_KEYS" ]; then
            echo "未检测到 root 公钥，正在生成新密钥..."
            ssh-keygen -t ed25519 -f /tmp/root_sshkey_tmp -N ""
            PUB_KEY=$(cat /tmp/root_sshkey_tmp.pub)
            PRIV_KEY=$(cat /tmp/root_sshkey_tmp)
            echo "$PUB_KEY" >> "$AUTH_KEYS"
            chmod 600 "$AUTH_KEYS"
            rm -f /tmp/root_sshkey_tmp /tmp/root_sshkey_tmp.pub
            echo ""
            echo "================= 私钥开始 ================="
            echo "$PRIV_KEY"
            echo "================= 私钥结束 ================="
            echo ""
            echo "⚠️ 请立即复制保存该私钥！后续将无法再次显示！"
        else
            echo "✅ 已存在 root 公钥，跳过生成"
        fi
        # 5. 验证配置
        if ! sshd -t >/dev/null 2>&1; then
            echo "❌ SSH 配置语法错误，已回滚"
            cp "$BACKUP_FILE" "$SSHD_CONFIG"
            return 1
        fi
        # 6. 重启 SSH 服务
        if systemctl restart ssh 2>/dev/null || systemctl restart sshd 2>/dev/null; then
            echo "✅ SSH 配置完成"
            add_installed "$component_name"
        else
            echo "❌ SSH 服务重启失败，请手动检查"
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
            # 交互式设置用户密码
            set_user_password "$USERNAME"
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
            echo "$USERNAME ALL=(ALL) NOPASSWD:ALL" >/etc/sudoers.d/90-"$USERNAME"
            chmod 440 /etc/sudoers.d/90-"$USERNAME"
            set_user_password "$USERNAME"
        fi
        USER_HOME=$(eval echo "~$USERNAME")

        # 安装 Zsh 和 Git
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

        # 使用本地 prezto-config 目录（无需压缩包）
        LOCAL_PREZTO_DIR="$PWD/prezto-config"
        if [ ! -d "$LOCAL_PREZTO_DIR" ]; then
            echo "错误: 未找到目录 $LOCAL_PREZTO_DIR"
            return 1
        fi

        # 覆盖 runcoms
        if [ -d "$LOCAL_PREZTO_DIR/runcoms" ]; then
            cp -r "$LOCAL_PREZTO_DIR/runcoms/." "$USER_HOME/.zprezto/runcoms/"
            chown -R "$USERNAME:$USERNAME" "$USER_HOME/.zprezto/runcoms"
        fi

        # 覆盖 prompt 模块
        if [ -d "$LOCAL_PREZTO_DIR/modules/prompt" ]; then
            cp -r "$LOCAL_PREZTO_DIR/modules/prompt/." "$USER_HOME/.zprezto/modules/prompt/"
            chown -R "$USERNAME:$USERNAME" "$USER_HOME/.zprezto/modules/prompt"
        fi

        # 覆盖 .p10k.zsh
        if [ -f "$LOCAL_PREZTO_DIR/.p10k.zsh" ]; then
            cp "$LOCAL_PREZTO_DIR/.p10k.zsh" "$USER_HOME/.p10k.zsh"
            chown "$USERNAME:$USERNAME" "$USER_HOME/.p10k.zsh"
        fi

        # 创建 runcoms 符号链接
        for rcfile in "$USER_HOME/.zprezto/runcoms/"*; do
            filename=$(basename "$rcfile")
            if [ "$filename" != "README.md" ]; then
                ln -sf "$rcfile" "$USER_HOME/.$filename"
                chown "$USERNAME:$USERNAME" "$USER_HOME/.$filename"
            fi
        done

        # 禁用 zsh-newuser-install
        echo 'export DISABLE_ZSH_NEWUSER_INSTALL=true' >>"$USER_HOME/.zshrc"
        chown "$USERNAME:$USERNAME" "$USER_HOME/.zshrc"

        # 设置 zsh 为默认 shell
        chsh -s /bin/zsh "$USERNAME"

        echo "Prezto 安装完成并应用本地自定义配置（runcoms + modules/prompt + .p10k.zsh）"
        echo "请重新登录用户 $USERNAME 生效。"
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
        # 放行 tailscale0 网卡流量
        ufw allow in on tailscale0
        ufw allow out on tailscale0
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
