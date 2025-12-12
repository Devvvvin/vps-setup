#!/bin/bash
# ------------------------------
# Debian 12/13 DNS 自动检测与修复（国内 + 国际）
# ------------------------------

set -e

# 公共 DNS 列表
INTERNATIONAL_DNS=("8.8.8.8")
DOMESTIC_DNS=("223.5.5.5")

# 测试域名
TEST_DOMAIN_INTL="google.com"
TEST_DOMAIN_CN="baidu.com"

# 检测单个 DNS 是否可用
check_dns() {
    local dns="$1"
    local domain="$2"

    if command -v dig >/dev/null 2>&1; then
        if dig @"$dns" "$domain" +short | grep -q '[0-9]'; then
            return 0
        fi
    elif command -v nslookup >/dev/null 2>&1; then
        if nslookup "$domain" "$dns" >/dev/null 2>&1; then
            return 0
        fi
    fi
    return 1
}

# 从列表中选出可用 DNS
select_working_dns() {
    local domain="$1"
    shift
    local dns_list=("$@")
    local working=()

    for dns in "${dns_list[@]}"; do
        if check_dns "$dns" "$domain"; then
            working+=("$dns")
        fi
    done
    echo "${working[@]}"
}

# 修复 DNS
fix_dns() {
    local dns_list=("$@")
    if [ ${#dns_list[@]} -eq 0 ]; then
        echo "没有可用 DNS，跳过修复"
        return 1
    fi

    echo "写入可用 DNS 到 /etc/resolv.conf"

    # 禁用 systemd-resolved stub
    if systemctl is-active --quiet systemd-resolved; then
        echo "禁用 systemd-resolved 避免 stub resolver 卡住"
        systemctl disable --now systemd-resolved
        rm -f /etc/resolv.conf
    fi

    {
        for dns in "${dns_list[@]}"; do
            echo "nameserver $dns"
        done
    } >>/etc/resolv.conf

    echo "DNS 已追加：${dns_list[*]}"
}

# ------------------------------
# 检测国际 DNS
echo "检测国际 DNS..."
WORKING_INTL=$(select_working_dns "$TEST_DOMAIN_INTL" "${INTERNATIONAL_DNS[@]}")
if [ -z "$WORKING_INTL" ]; then
    echo "国际 DNS 不可用，使用备用列表"
    WORKING_INTL=("${INTERNATIONAL_DNS[@]}")
fi

# 检测国内 DNS
echo "检测国内 DNS..."
WORKING_CN=$(select_working_dns "$TEST_DOMAIN_CN" "${DOMESTIC_DNS[@]}")
if [ -z "$WORKING_CN" ]; then
    echo "国内 DNS 不可用，使用备用列表"
    WORKING_CN=("${DOMESTIC_DNS[@]}")
fi

# 合并可用 DNS
ALL_DNS=("${WORKING_INTL[@]}" "${WORKING_CN[@]}")
fix_dns "${ALL_DNS[@]}"

# 测试解析结果
echo "测试解析结果："
ping -c 3 "$TEST_DOMAIN_INTL" || echo "国际域名解析失败"
ping -c 3 "$TEST_DOMAIN_CN" || echo "国内域名解析失败"
