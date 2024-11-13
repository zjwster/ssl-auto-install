#!/bin/bash

# 设置严格模式
set -euo pipefail
IFS=$'\n\t'

# 定义颜色输出
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# 定义日志函数
log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# 检查基本依赖
check_dependencies() {
    local deps=("curl" "dig")
    for dep in "${deps[@]}"; do
        if ! command -v "$dep" &> /dev/null; then
            log_error "缺少依赖: $dep"
            exit 1
        fi
    done
}

# 检查并设置证书目录
setup_cert_dir() {
    local ssl_dir
    # 让用户选择证书存储位置
    read -p "请输入证书存储目录 [默认: /etc/ssl/private]: " ssl_dir
    ssl_dir=${ssl_dir:-/etc/ssl/private}
    
    # 创建目录
    mkdir -p "$ssl_dir"
    chmod 700 "$ssl_dir"
    log_info "证书将保存在: $ssl_dir"
    
    echo "$ssl_dir"  # 使用echo返回值而不是return
}

# 检测 Web 服务器类型
detect_web_server() {
    local reload_cmd=""
    
    if command -v nginx &> /dev/null; then
        log_info "检测到 Nginx"
        if nginx -t &> /dev/null; then
            reload_cmd="systemctl reload nginx"
        fi
    elif command -v apache2 &> /dev/null || command -v httpd &> /dev/null; then
        log_info "检测到 Apache"
        if apache2ctl -t &> /dev/null || httpd -t &> /dev/null; then
            reload_cmd="systemctl reload apache2 2>/dev/null || systemctl reload httpd"
        fi
    else
        log_warn "未检测到 Web 服务器，证书将只进行安装但不会自动重载服务"
    fi
    
    echo "$reload_cmd"
}

# 获取域名
get_domain() {
    local domain
    read -p "请输入您的域名: " domain
    if [[ -z "$domain" ]]; then
        log_error "域名不能为空"
        exit 1
    fi
    echo "$domain"
}

# 验证域名DNS解析
verify_domain_dns() {
    local domain="$1"
    local public_ip
    public_ip=$(curl -s http://ipinfo.io/ip)
    local domain_ip
    domain_ip=$(dig +short "$domain" | tail -n1)

    if [[ "$domain_ip" != "$public_ip" ]]; then
        log_warn "域名 $domain 的解析IP ($domain_ip) 与当前服务器IP ($public_ip) 不一致"
        read -p "仍要继续吗？[y/N]: " yn
        yn=${yn:-N}
        if [[ ! "$yn" =~ ^[Yy]$ ]]; then
            log_error "已取消操作"
            exit 1
        fi
    else
        log_info "域名 $domain 的解析IP 与当前服务器IP一致"
    fi
}

# 生成SSL证书 (使用 Let's Encrypt)
generate_ssl_certificate() {
    local domain="$1"
    local ssl_dir="$2"

    # 检查 certbot 是否安装
    if ! command -v certbot &> /dev/null; then
        log_info "正在安装 Certbot..."
        apt-get update
        apt-get install -y certbot
    fi

    # 生成证书
    certbot certonly --standalone -d "$domain" --agree-tos --email your-email@example.com --non-interactive

    # 复制证书到指定目录
    local cert_source="/etc/letsencrypt/live/$domain"
    if [[ -d "$cert_source" ]]; then
        cp "$cert_source/fullchain.pem" "$ssl_dir/$domain.crt"
        cp "$cert_source/privkey.pem" "$ssl_dir/$domain.key"
        log_info "证书已生成并保存到 $ssl_dir"
    else
        log_error "证书生成失败"
        exit 1
    fi
}

# 更新 Web 服务器配置
update_web_server_config() {
    local domain="$1"
    local ssl_dir="$2"
    local reload_cmd="$3"

    if command -v nginx &> /dev/null; then
        # 更新 Nginx 配置
        local nginx_conf="/etc/nginx/sites-available/$domain.conf"
        cat > "$nginx_conf" <<EOF
server {
    listen 443 ssl;
    server_name $domain;

    ssl_certificate     $ssl_dir/$domain.crt;
    ssl_certificate_key $ssl_dir/$domain.key;

    # 其他配置...
}
EOF
        ln -sf "$nginx_conf" /etc/nginx/sites-enabled/
        log_info "Nginx 配置已更新"

    elif command -v apache2 &> /dev/null || command -v httpd &> /dev/null; then
        # 更新 Apache 配置
        local apache_conf="/etc/apache2/sites-available/$domain.conf"
        cat > "$apache_conf" <<EOF
<VirtualHost *:443>
    ServerName $domain

    SSLEngine on
    SSLCertificateFile      $ssl_dir/$domain.crt
    SSLCertificateKeyFile   $ssl_dir/$domain.key

    # 其他配置...
</VirtualHost>
EOF
        a2ensite "$domain.conf"
        a2enmod ssl
        log_info "Apache 配置已更新"
    fi

    # 重载服务
    if [[ -n "$reload_cmd" ]]; then
        eval "$reload_cmd"
        log_info "Web 服务器已重载"
    else
        log_warn "未自动重载 Web 服务器，请手动重启"
    fi
}

# 主函数
main() {
    # 检查依赖
    check_dependencies

    # 设置证书目录
    ssl_dir=$(setup_cert_dir)

    # 检测 Web 服务器并获取重载命令
    reload_cmd=$(detect_web_server)

    # 获取域名
    domain=$(get_domain)

    # 验证域名 DNS 解析
    verify_domain_dns "$domain"

    # 生成 SSL 证书
    generate_ssl_certificate "$domain" "$ssl_dir"

    # 更新 Web 服务器配置
    update_web_server_config "$domain" "$ssl_dir" "$reload_cmd"

    log_info "SSL 证书安装和配置已完成"
}

# 捕获错误
trap 'log_error "脚本执行失败，请检查错误信息"; exit 1' ERR

# 运行主函数
main "$@"
