#!/bin/bash

# 严格模式
# set -e: 如果任何命令以非零状态退出，则立即退出脚本。
# set -u: 在替换时将未设置的变量视为错误。
# set -o pipefail: 管道命令的返回值是最后一个以非零状态退出的命令的状态，
#                 如果所有命令都以零状态退出，则返回值为零。
set -euo pipefail

# --- 默认配置 ---
DEFAULT_CRED_FILE="/root/.cf_credentials" # 默认凭证文件路径
DEFAULT_CERT_DIR="/etc/ssl"             # 默认证书安装目录
DEFAULT_ACME_HOME="/root/.acme.sh"      # root 用户运行时的默认 acme.sh 安装路径

# --- 脚本变量 ---
DOMAIN=""                               # 需要申请证书的域名 (必需)
CRED_FILE="${DEFAULT_CRED_FILE}"        # 凭证文件路径
CERT_DIR="${DEFAULT_CERT_DIR}"          # 证书安装目录
RELOAD_CMD=""                           # 证书安装/续期后执行的重载命令 (可选)
LE_ACCOUNT_EMAIL=""                     # Let's Encrypt 账户注册/恢复邮箱 (可选，但推荐)
ACME_HOME="${DEFAULT_ACME_HOME}"        # acme.sh 的主目录
ACME_CMD="${ACME_HOME}/acme.sh"         # acme.sh 命令的完整路径

# --- 辅助函数 ---
log_info() {
    # 输出信息日志，包含时间戳
    echo "[信息] $(date '+%Y-%m-%d %H:%M:%S') - $1"
}

log_error() {
    # 输出错误日志到标准错误流，包含时间戳
    echo "[错误] $(date '+%Y-%m-%d %H:%M:%S') - $1" >&2
}

usage() {
    # 显示脚本用法并退出
    cat << EOF
用法: $(basename "$0") -d <域名> [选项]

使用 acme.sh 和 Cloudflare DNS 自动化申请 Let's Encrypt SSL 证书。

必需参数:
  -d, --domain <域名>      要为其颁发证书的域名。

选项:
  -c, --credentials <文件路径>  Cloudflare 凭证文件路径。
                              (默认: ${DEFAULT_CRED_FILE})
                              必须包含 CF_Key 和 CF_Email。也可以通过环境变量设置。
  -m, --email <邮箱地址>      用于 Let's Encrypt 账户注册/恢复的邮箱地址。推荐提供。
  --cert-dir <目录>           安装证书和密钥文件的目录。
                              (默认: ${DEFAULT_CERT_DIR})
  -r, --reloadcmd <命令>      证书成功安装/续期后执行的命令
                              (例如: "systemctl reload nginx")。
  --acme-home <目录>          acme.sh 的安装目录路径。
                              (默认: ${DEFAULT_ACME_HOME})
  -h, --help                  显示此帮助信息。
EOF
    exit 0
}

check_root() {
    # 检查脚本是否以 root 用户身份运行
    if [ "$EUID" -ne 0 ]; then
        log_error "请以 root 用户身份运行此脚本，或使用 'sudo'。"
        exit 1
    fi
    log_info "脚本正以 root 权限运行。"
}

# 安全地安装或检查 acme.sh 的安装状态
install_acme() {
    ACME_CMD="${ACME_HOME}/acme.sh"
    if [ ! -f "${ACME_CMD}" ]; then
        log_info "在 ${ACME_HOME} 中未找到 acme.sh。尝试安装..."
        # 如果目录不存在，则创建它 (curl 输出需要)
        mkdir -p "$(dirname "${ACME_HOME}")"
        local install_script="get-acme.sh" # 临时安装脚本文件名
        # 下载 acme.sh 安装脚本
        if curl -fsS https://get.acme.sh -o "${install_script}"; then
            log_info "已下载 acme.sh 安装脚本。"
            # 执行安装脚本，指定安装主目录和账户邮箱 (如果提供的话)
            sh "${install_script}" --home "${ACME_HOME}" ${LE_ACCOUNT_EMAIL:+"--accountemail"} ${LE_ACCOUNT_EMAIL:-}
            rm -f "${install_script}" # 清理安装脚本
            log_info "acme.sh 已成功安装到 ${ACME_HOME}。"
            # 确保 ACME_CMD 在安装后正确设置
            ACME_CMD="${ACME_HOME}/acme.sh"
            if [ ! -f "${ACME_CMD}" ]; then
               log_error "即使在尝试安装后，仍然在 ${ACME_CMD} 找不到 acme.sh 命令。"
               exit 1
            fi
        else
            log_error "下载 acme.sh 安装脚本失败。"
            exit 1
        fi
    else
        log_info "acme.sh 已安装在 ${ACME_CMD}。"
    fi
}

# 从文件或环境变量加载 Cloudflare 凭证
load_credentials() {
    log_info "正在加载 Cloudflare 凭证..."
    # 如果环境变量未完全设置，则尝试从文件加载
    if [ -z "${CF_Key:-}" ] || [ -z "${CF_Email:-}" ]; then
        if [ -f "${CRED_FILE}" ]; then
            log_info "从文件 ${CRED_FILE} 加载凭证。"
            # 临时禁用未设置变量检查以便 source 文件
            set +u
            # shellcheck source=/dev/null # 告诉 ShellCheck 不用检查此 source
            source "${CRED_FILE}"
            set -u # 重新启用未设置变量检查
        else
            log_info "凭证文件 ${CRED_FILE} 未找到。将依赖环境变量。"
        fi
    else
      log_info "正在使用环境变量中的 Cloudflare 凭证。"
    fi

    # 检查变量现在是否已设置
    if [ -z "${CF_Key:-}" ] || [ -z "${CF_Email:-}" ]; then
        log_error "Cloudflare 凭证 (CF_Key 和 CF_Email) 未设置。"
        log_error "请将它们设置为环境变量，或在 ${CRED_FILE} 文件中配置。"
        exit 1
    fi

    # 导出变量供 acme.sh 子进程使用
    export CF_Key
    export CF_Email
    log_info "Cloudflare 凭证已加载并导出。"
}

# 更新 acme.sh, 设置默认 CA, 如果提供了邮箱则注册账户
setup_acme() {
    log_info "正在配置 acme.sh..."
    "${ACME_CMD}" --upgrade # 更新 acme.sh 到最新版本
    "${ACME_CMD}" --set-default-ca --server letsencrypt # 设置默认 CA 为 Let's Encrypt

    if [ -n "${LE_ACCOUNT_EMAIL}" ]; then
        log_info "正在注册/更新 Let's Encrypt 账户邮箱: ${LE_ACCOUNT_EMAIL}"
        # 使用 --register-account 命令，该命令是幂等的
        if ! "${ACME_CMD}" --register-account -m "${LE_ACCOUNT_EMAIL}"; then
            log_error "使用邮箱 ${LE_ACCOUNT_EMAIL} 注册 Let's Encrypt 账户失败。请检查 acme.sh 日志。"
            # 可以根据需要决定这是否是致命错误。如果账户已存在，通常不影响签发。
            # exit 1
        fi
    else
        log_info "未提供用于注册/更新的 Let's Encrypt 账户邮箱。"
    fi
}

# 使用 DNS 验证颁发证书并安装
issue_and_install_cert() {
    log_info "正在为域名 ${DOMAIN} 签发证书 (使用 dns_cf 方式)..."
    # 确保证书目标目录存在
    mkdir -p "${CERT_DIR}"
    if [ ! -d "${CERT_DIR}" ]; then
        log_error "创建证书目录失败: ${CERT_DIR}"
        exit 1
    fi

    # 签发证书 (acme.sh 会自动检查是否需要续期)
    log_info "执行签发命令: ${ACME_CMD} --issue --dns dns_cf -d ${DOMAIN}"
    if ! "${ACME_CMD}" --issue --dns dns_cf -d "${DOMAIN}"; then
        log_error "为 ${DOMAIN} 签发证书失败。请检查 Cloudflare API 设置和 DNS 记录是否正确传播。"
        log_error "您可以检查 acme.sh 日志文件: ${ACME_HOME}/acme.sh.log"
        exit 1
    fi
    log_info "证书签发成功。"

    log_info "正在将证书安装到 ${CERT_DIR}..."
    local key_file="${CERT_DIR}/${DOMAIN}.key"           # 私钥文件路径
    local fullchain_file="${CERT_DIR}/${DOMAIN}.crt"     # 完整证书链文件路径

    # 准备安装命令的参数数组
    local install_args=(
        "--install-cert"             # 安装证书命令
        "-d" "${DOMAIN}"             # 指定域名
        "--key-file" "${key_file}"   # 指定私钥安装路径
        "--fullchain-file" "${fullchain_file}" # 指定完整证书链安装路径
    )
    # 如果指定了重载命令，则添加到参数中
    if [ -n "${RELOAD_CMD}" ]; then
        install_args+=("--reloadcmd" "${RELOAD_CMD}")
    fi

    log_info "执行安装命令: ${ACME_CMD} ${install_args[*]}"
    # 执行安装证书命令
    if ! "${ACME_CMD}" "${install_args[@]}"; then
        log_error "为 ${DOMAIN} 安装证书失败。"
        exit 1
    fi

    # --install-cert 通常会自动设置正确的权限，如果需要可以取消下面的注释来强制设置
    # chmod 600 "${key_file}"
    # chmod 644 "${fullchain_file}"

    log_info "证书已成功安装到 ${CERT_DIR}。"
    if [ -n "${RELOAD_CMD}" ]; then
      log_info "已执行重载命令: ${RELOAD_CMD}"
    fi
}

# 确保 acme.sh 的 cron 任务已安装
setup_cron() {
    log_info "正在检查 acme.sh 的 cron 任务..."
    # 使用 acme.sh 自身的 --list 命令检查可能更可靠
    # 检查输出中是否包含自动升级任务 (这是 acme.sh cron 任务的一个标志)
    if ! "${ACME_CMD}" --list | grep -q 'Auto upgrade'; then
       log_info "未找到 cron 任务或自动升级被禁用。正在安装/更新 cron 任务..."
       # 安装 cron 任务
       if ! "${ACME_CMD}" --install-cronjob; then
           log_error "安装 acme.sh cron 任务失败。可能需要手动设置。"
           # 非致命错误，但警告用户
           # exit 1
       else
           log_info "acme.sh cron 任务已成功安装/更新。"
       fi
    else
       log_info "acme.sh cron 任务看起来已安装。"
    fi
}

# --- 主程序执行 ---

# 解析命令行参数
# 使用 getopt 进行稳健的参数解析
ARGS=$(getopt -o d:c:m:r:h --long domain:,credentials:,email:,cert-dir:,reloadcmd:,acme-home:,help -n "$(basename "$0")" -- "$@")
if [ $? -ne 0 ]; then
    # getopt 解析失败，显示用法
    usage
    exit 1
fi
# 将解析后的参数重新设置给位置参数 ($1, $2, ...)
eval set -- "$ARGS"

# 循环处理解析后的参数
while true; do
    case "$1" in
        -d|--domain) DOMAIN="$2"; shift 2 ;;          # 域名
        -c|--credentials) CRED_FILE="$2"; shift 2 ;;  # 凭证文件
        -m|--email) LE_ACCOUNT_EMAIL="$2"; shift 2 ;; # Let's Encrypt 邮箱
        --cert-dir) CERT_DIR="$2"; shift 2 ;;         # 证书目录
        -r|--reloadcmd) RELOAD_CMD="$2"; shift 2 ;;   # 重载命令
        --acme-home) ACME_HOME="$2"; shift 2 ;;       # acme.sh 主目录
        -h|--help) usage ;;                           # 帮助
        --) shift; break ;;                           # 参数结束标志
        *) echo "内部错误！参数解析失败。" ; exit 1 ;; # 不应发生的情况
    esac
done

# 验证必需的参数
if [ -z "${DOMAIN}" ]; then
    log_error "必须提供域名 (-d 或 --domain)。"
    usage
    exit 1
fi

# --- 开始执行主要逻辑 ---
log_info "开始为域名 ${DOMAIN} 进行 SSL 证书自动化处理"

check_root                   # 检查 root 权限
install_acme                 # 安装或检查 acme.sh (需要在早期执行以确定 ACME_CMD)
load_credentials             # 加载凭证
setup_acme                   # 配置 acme.sh (更新, CA, 账户)
issue_and_install_cert       # 签发和安装证书
setup_cron                   # 设置定时续期任务

log_info "域名 ${DOMAIN} 的 SSL 证书设置已成功完成。"

exit 0 # 脚本成功结束
