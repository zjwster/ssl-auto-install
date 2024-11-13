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
log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# 检查必要的命令是否存在
check_dependencies() {
    local deps=("curl" "crontab" "nginx")
    for dep in "${deps[@]}"; do
        if ! command -v "$dep" &> /dev/null; then
            log_error "缺少依赖: $dep"
            exit 1
        fi
    done
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

# 备份现有证书
backup_certs() {
    local domain=$1
    local backup_dir="/etc/nginx/ssl/backup/$(date +%Y%m%d_%H%M%S)"
    
    if [[ -f "/etc/nginx/ssl/$domain.key" ]]; then
        mkdir -p "$backup_dir"
        cp "/etc/nginx/ssl/$domain."{key,cer} "$backup_dir/" 2>/dev/null || true
        log_info "已备份现有证书到 $backup_dir"
    fi
}

# 检查 nginx 配置
check_nginx_config() {
    if ! nginx -t &>/dev/null; then
        log_error "Nginx 配置测试失败"
        exit 1
    fi
}

# 主函数
main() {
    # 检查依赖
    check_dependencies

    # 检查并安装 acme.sh
    if [[ ! -f ~/.acme.sh/acme.sh ]]; then
        log_info "安装 acme.sh..."
        curl https://get.acme.sh | sh -s email="${CF_Email:=''}"
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

    # 创建证书目录
    mkdir -p /etc/nginx/ssl

    # 备份现有证书
    backup_certs "$domain"

    # 申请证书
    log_info "正在申请证书..."
    if ! ~/.acme.sh/acme.sh --issue -d "$domain" --dns dns_cf; then
        log_error "证书申请失败"
        exit 1
    fi

    # 安装证书
    log_info "正在安装证书..."
    if ! ~/.acme.sh/acme.sh --install-cert -d "$domain" \
        --key-file "/etc/nginx/ssl/$domain.key" \
        --fullchain-file "/etc/nginx/ssl/$domain.cer" \
        --reloadcmd "nginx -t && systemctl reload nginx"; then
        log_error "证书安装失败"
        exit 1
    fi

    # 设置自动更新
    if ! (crontab -l 2>/dev/null | grep -q '~/.acme.sh/acme.sh --cron'); then
        (crontab -l 2>/dev/null; echo "0 0 * * 0 ~/.acme.sh/acme.sh --cron --home ~/.acme.sh/ --user-agent acme.sh-auto-update > /dev/null 2>&1") | crontab -
        log_info "已设置自动更新任务"
    fi

    # 验证 nginx 配置
    check_nginx_config

    log_info "SSL 证书配置完成！"
    log_info "证书文件位置:"
    log_info "私钥: /etc/nginx/ssl/$domain.key"
    log_info "证书: /etc/nginx/ssl/$domain.cer"
}

# 捕获错误
trap 'log_error "脚本执行失败，请检查错误信息"; exit 1' ERR

# 运行主函数
main "$@"
