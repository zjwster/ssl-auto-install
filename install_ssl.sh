#!/bin/bash

# 1. 创建 scripts 目录（如果不存在）
mkdir -p ~/scripts

# 2. 创建 install_ssl.sh 文件并写入脚本内容
cat > ~/scripts/install_ssl.sh << 'EOF'
#!/bin/bash

# 检查并安装 acme.sh
if [ ! -f ~/.acme.sh/acme.sh ]; then
    echo "acme.sh 未安装，正在安装..."
    curl https://get.acme.sh | sh
else
    echo "acme.sh 已安装，跳过安装步骤。"
fi

# 设置默认 CA 为 Let's Encrypt
~/.acme.sh/acme.sh --set-default-ca --server letsencrypt

# 要求用户输入 Cloudflare API Key 和域名
read -p "请输入你的 Cloudflare API Key: " CF_Key
export CF_Key

read -p "请输入你的域名: " domain
export domain

# 创建 SSL 目录（如果不存在）
mkdir -p /etc/nginx/ssl

# 申请证书
echo "正在申请证书..."
~/.acme.sh/acme.sh --issue -d "$domain" --dns dns_cf
if [ $? -ne 0 ]; then
    echo "证书申请失败，请检查 Cloudflare API 设置及域名解析。"
    exit 1
fi

# 安装证书到指定目录
echo "安装证书..."
~/.acme.sh/acme.sh --install-cert -d "$domain" \
    --key-file /etc/nginx/ssl/"$domain".key \
    --fullchain-file /etc/nginx/ssl/"$domain".cer \
    --reloadcmd "systemctl reload nginx"
if [ $? -ne 0 ]; then
    echo "证书安装失败。"
    exit 1
fi

# 设置定时任务以每周自动更新证书
(crontab -l 2>/dev/null | grep -q '~/.acme.sh/acme.sh --cron' ) || \
(crontab -l 2>/dev/null; echo "0 0 * * 0 ~/.acme.sh/acme.sh --cron --home ~/.acme.sh/ --user-agent acme.sh-auto-update") | crontab -

echo "定时任务已设置，每周自动更新证书。"
echo "SSL 证书申请和安装完成。"
EOF

# 3. 赋予执行权限
chmod +x ~/scripts/install_ssl.sh

# 4. 运行脚本
~/scripts/install_ssl.sh
