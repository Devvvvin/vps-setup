#!/bin/bash
# ------------------------------
# Debian 12/13 DNS 自动检测与修复（国内 + 国际）
# ------------------------------

# 公共 DNS 列表
INTERNATIONAL_DNS=("1.1.1.1" "8.8.8.8")
DOMESTIC_DNS=("223.5.5.5" "114.114.114.114")

# 测试域名
TEST_DOMAIN_INTL="google.com"
TEST_DOMAIN_CN="baidu.com"

# 检测 DNS 是否可用
check_dns_list() {
    local dns_list=("$@")
    local test_domain="$1"
    shift
    local dns_list=("$@")

    for dns in "${dns_list[@]}"; do
        if command -v dig >/dev/null 2>&1; then
            if dig @"$dns" "$test_domain" +short | grep -q '[0-9]'; then
                echo "$dns"
                return 0
            fi
        elif command -v nslookup >/dev/null 2>&1; then
            if nslookup "$test_domain" "$dns" >/dev/null 2>&1; then
                echo "$dns"
                return 0
            fi
        fi
    done
    return 1
}

# 修复 DNS
fix_dns() {
    echo "写入可用 DNS 到 /etc/resolv.conf"
    {
        for dns in "${INTERNATIONAL_DNS[@]}"; do
            echo "nameserver $dns"
        done
        for dns in "${DOMESTIC_DNS[@]}"; do
            echo "nameserver $dns"
        done
    } >/etc/resolv.conf

    if systemctl is-active --quiet systemd-resolved; then
        systemctl restart systemd-resolved
    fi
    echo "DNS 已修复"
}

# ------------------------------
# 检测外网 DNS
echo "检测国际 DNS..."
if ! check_dns_list "$TEST_DOMAIN_INTL" "${INTERNATIONAL_DNS[@]}"; then
    echo "国际 DNS 不可用，将写入公共 DNS"
    fix_dns
else
    echo "国际 DNS 可用"
fi

# 检测国内 DNS
echo "检测国内 DNS..."
if ! check_dns_list "$TEST_DOMAIN_CN" "${DOMESTIC_DNS[@]}"; then
    echo "国内 DNS 不可用，将写入公共 + 国内 DNS"
    fix_dns
else
    echo "国内 DNS 可用"
fi

# 测试解析结果
echo "测试解析结果："
ping -c 3 google.com || echo "国际域名解析失败"
ping -c 3 baidu.com || echo "国内域名解析失败"
