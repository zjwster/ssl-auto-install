#!/bin/bash

# 检查是否以 root 身份运行
if [ "$EUID" -ne 0 ]; then
    echo "请以 root 用户身份运行此脚本，或者在命令前加上 'sudo'。"
    exit 1
fi

# 检查并安装 acme.sh
if [ ! -f /root/.acme.sh/acme.sh ]; then
    echo "acme.sh 未安装，正在安装..."
    curl https://get.acme.sh | sh
else
    echo "acme.sh 已安装，跳过安装步骤。"
fi

# 更新 acme.sh 到最新版本
/root/.acme.sh/acme.sh --upgrade

# 设置默认 CA 为 Let's Encrypt
/root/.acme.sh/acme.sh --set-default-ca --server letsencrypt

# 要求用户输入 Cloudflare API Key、Email 和域名
read -p "请输入你的 Cloudflare API Key: " CF_Key
export CF_Key

read -p "请输入你的 Cloudflare Email: " CF_Email
export CF_Email

read -p "请输入你的域名: " domain
export domain

# 检查并创建 /etc/ssl/ 目录
if [ ! -d /etc/ssl/ ]; then
    echo "/etc/ssl/ 目录不存在，正在创建..."
    mkdir -p /etc/ssl/
    if [ $? -ne 0 ]; then
        echo "无法创建 /etc/ssl/ 目录，请检查权限。"
        exit 1
    fi
fi

# 申请证书并指定安装路径
echo "正在申请证书..."
/root/.acme.sh/acme.sh --issue -d "$domain" --dns dns_cf \
--key-file /etc/ssl/"$domain".key \
--fullchain-file /etc/ssl/"$domain".crt

if [ $? -ne 0 ]; then
    echo "证书申请失败，请检查 Cloudflare API 设置及域名解析。"
    exit 1
fi

# 设置证书文件的权限
chmod 600 /etc/ssl/"$domain".key
chmod 644 /etc/ssl/"$domain".crt

echo "证书已安装到 /etc/ssl/ 目录中。"

# 设置定时任务以每周自动更新证书
(crontab -l 2>/dev/null | grep -q '/root/.acme.sh/acme.sh --cron' ) || \
(crontab -l 2>/dev/null; echo "0 0 * * 0 /root/.acme.sh/acme.sh --cron --home /root/.acme.sh/ --user-agent acme.sh-auto-update") | crontab -

echo "定时任务已设置，每周自动更新证书。"
echo "SSL 证书申请和安装完成。"
