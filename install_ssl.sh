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

# ... (其他函数保持不变)

# 主函数
main() {
    # 检查依赖
    check_dependencies
    
    # 设置证书目录
    ssl_dir=$(setup_cert_dir)
    
    # 检测 Web 服务器并获取重载命令
    reload_cmd=$(detect_web_server)
    
    # ... (后续代码保持不变)
}

# 捕获错误
trap 'log_error "脚本执行失败，请检查错误信息"; exit 1' ERR

# 运行主函数
main "$@"
