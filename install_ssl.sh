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
    # 让用户选择证书存储位置
    read -p "请输入证书存储目录 [默认: /etc/ssl/private]: " ssl_dir
    ssl_dir=${ssl_dir:-/etc/ssl/private}
    
    # 创建目录
    mkdir -p "$ssl_dir"
    chmod 700 "$ssl_dir"
    log_info "证书将保存在: $ssl_dir"
    
    return "$ssl_dir"
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

# 验证输入值
validate_input() {
    local value=$1
    local name=$2
    if [[ -z "$value" ]]; then
        log_error "$name 不能为空"
        exit 1
    fi
}

# 检查域名的 DNS 记录
check_dns_records() {
    local domain=$1
    log_info "正在检查域名 $domain 的 DNS 记录..."
    
    local server_ip=$(curl -s4 ifconfig.me)
    local domain_ip=$(dig +short $domain A)
    
    if [[ -n "$domain_ip" && "$domain_ip" != "$server_ip" ]]; then
        log_warn "警告: 域名 $domain 当前指向 $domain_ip"
        log_warn "当前服务器 IP 为 $server_ip"
        read -p "域名似乎没有指向这台服务器,是否继续? (y/N) " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            log_error "操作已取消"
            exit 1
        fi
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
    
    # 检查并安装 acme.sh
    if [[ ! -f ~/.acme.sh/acme.sh ]]; then
        log_info "安装 acme.sh..."
        curl https://get.acme.sh | sh
    else
        log_info "acme.sh 已安装，正在更新..."
        ~/.acme.sh/acme.sh --upgrade
    fi

    # 设置默认 CA
    ~/.acme.sh/acme.sh --set-default-ca --server letsencrypt

    # 获取用户输入
    read -p "请输入你的 Cloudflare API Key: " CF_Key
    read -p "请输入你的 Cloudflare Email: " CF_Email
    read -p "请输入你的域名: " domain

    # 验证输入
    validate_input "$CF_Key" "Cloudflare API Key"
    validate_input "$CF_Email" "Cloudflare Email"
    validate_input "$domain" "域名"

    # 导出变量
    export CF_Key CF_Email domain

    # 检查 DNS 记录
    check_dns_records "$domain"

    # 申请证书
    log_info "正在申请证书..."
    if ! ~/.acme.sh/acme.sh --issue -d "$domain" --dns dns_cf; then
        log_error "证书申请失败"
        exit 1
    fi

    # 安装证书
    log_info "正在安装证书..."
    if ! ~/.acme.sh/acme.sh --install-cert -d "$domain" \
        --key-file "$ssl_dir/$domain.key" \
        --fullchain-file "$ssl_dir/$domain.cer" \
        ${reload_cmd:+--reloadcmd "$reload_cmd"}; then
        log_error "证书安装失败"
        exit 1
    fi

    # 设置证书权限
    chmod 600 "$ssl_dir/$domain.key"
    chmod 644 "$ssl_dir/$domain.cer"

    # 设置自动更新
    if ! (crontab -l 2>/dev/null | grep -q '~/.acme.sh/acme.sh --cron'); then
        (crontab -l 2>/dev/null; echo "0 0 * * 0 ~/.acme.sh/acme.sh --cron --home ~/.acme.sh/ > /dev/null 2>&1") | crontab -
        log_info "已设置自动更新任务"
    fi

    log_info "SSL 证书配置完成！"
    log_info "证书文件位置:"
    log_info "私钥: $ssl_dir/$domain.key"
    log_info "证书: $ssl_dir/$domain.cer"
    
    # 如果没有检测到 Web 服务器，提供使用建议
    if [[ -z "$reload_cmd" ]]; then
        log_info "提示: 证书已安装但需要手动配置 Web 服务器使用这些证书"
        log_info "常见 Web 服务器配置示例:"
        log_info "Nginx:"
        echo "    ssl_certificate $ssl_dir/$domain.cer;"
        echo "    ssl_certificate_key $ssl_dir/$domain.key;"
        log_info "Apache:"
        echo "    SSLCertificateFile $ssl_dir/$domain.cer"
        echo "    SSLCertificateKeyFile $ssl_dir/$domain.key"
    fi
}

# 捕获错误
trap 'log_error "脚本执行失败，请检查错误信息"; exit 1' ERR

# 运行主函数
main "$@"
