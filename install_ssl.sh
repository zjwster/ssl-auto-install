#!/bin/bash

# 严格模式
set -euo pipefail

# --- 默认配置 ---
DEFAULT_CRED_FILE="/root/.cf_credentials" # 默认凭证文件路径
DEFAULT_CERT_DIR="/etc/ssl"             # 默认证书安装目录
DEFAULT_ACME_HOME="/root/.acme.sh"      # root 用户运行时的默认 acme.sh 安装路径

# --- 脚本变量 ---
# DOMAIN 变量不再通过 -d 参数获取，将在加载凭证后从文件中的 domain 变量赋值
TARGET_DOMAIN=""                        # 将从凭证文件中加载的目标域名
CRED_FILE="${DEFAULT_CRED_FILE}"        # 凭证文件路径
CERT_DIR="${DEFAULT_CERT_DIR}"          # 证书安装目录
RELOAD_CMD=""                           # 证书安装/续期后执行的重载命令 (可选)
LE_ACCOUNT_EMAIL=""                     # Let's Encrypt 账户注册/恢复邮箱 (可选，但推荐)
ACME_HOME="${DEFAULT_ACME_HOME}"        # acme.sh 的主目录
ACME_CMD="${ACME_HOME}/acme.sh"         # acme.sh 命令的完整路径

# --- Cloudflare 凭证变量 (由 load_credentials 导出) ---
# 这些变量将在 load_credentials 函数中被导出
# export CF_Key=""
# export CF_Email=""
# export domain="" # 从凭证文件中加载的域名, 将赋值给 TARGET_DOMAIN

# --- 辅助函数 ---
log_info() {
    echo "[信息] $(date '+%Y-%m-%d %H:%M:%S') - $1"
}

log_error() {
    echo "[错误] $(date '+%Y-%m-%d %H:%M:%S') - $1" >&2
}

usage() {
    # 显示脚本用法并退出
    cat << EOF
用法: $(basename "$0") [选项]

使用 acme.sh 和 Cloudflare DNS 自动化申请 Let's Encrypt SSL 证书。
证书的目标域名将从 Cloudflare 凭证文件 (${CRED_FILE}) 中的 'domain' 变量获取。

选项:
  -c, --credentials <文件路径>  Cloudflare 凭证文件路径。
                              (默认: ${DEFAULT_CRED_FILE})
                              此文件必须包含 export CF_Key、export CF_Email 和 export domain。
                              如果文件不存在或内容不全，脚本将提示输入。
                              可以通过环境变量 CF_Key 和 CF_Email 设置认证凭证 (优先级更高)。
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
    if [ "$EUID" -ne 0 ]; then
        log_error "请以 root 用户身份运行此脚本，或使用 'sudo'。"
        exit 1
    fi
    log_info "脚本正以 root 权限运行。"
}

install_acme() {
    ACME_CMD="${ACME_HOME}/acme.sh"
    if [ ! -f "${ACME_CMD}" ]; then
        log_info "在 ${ACME_HOME} 中未找到 acme.sh。尝试安装..."
        # 确保父目录存在，虽然对于 /root 通常不是问题
        mkdir -p "$(dirname "${ACME_HOME}")"
        local install_script="get-acme.sh"
        if curl -fsS https://get.acme.sh -o "${install_script}"; then
            log_info "已下载 acme.sh 安装脚本。"

            # 准备安装参数数组 - **不再包含 --home**
            local install_args=() # 初始化为空数组
            if [ -n "${LE_ACCOUNT_EMAIL}" ]; then
                # 如果提供了邮箱，添加 --accountemail 参数和邮箱值
                install_args+=("--accountemail" "${LE_ACCOUNT_EMAIL}")
            fi

            log_info "执行安装命令: sh ${install_script}${install_args:+ ${install_args[*]}}" # 日志稍微调整以适应可能没有参数的情况
            # 直接执行安装脚本，将数组元素作为独立参数传递
            # 如果 install_args 为空，则只执行 sh "${install_script}"
            if sh "${install_script}" "${install_args[@]}"; then
                log_info "acme.sh 安装脚本执行完成。"
            else
                # 如果安装脚本本身返回错误
                log_error "acme.sh 安装脚本执行失败。请检查上面的输出。"
                rm -f "${install_script}" # 仍然尝试清理
                exit 1
            fi

            rm -f "${install_script}" # 清理安装脚本

            # 确认 acme.sh 命令现在是否存在
            ACME_CMD="${ACME_HOME}/acme.sh" # 重新确认路径
            # 安装脚本成功后，acme.sh 应该在 ACME_HOME 下
            if [ ! -f "${ACME_CMD}" ]; then
                # 如果安装脚本成功执行但文件仍不存在，则有问题
                log_error "即使安装脚本执行完成，仍然在 ${ACME_CMD} 找不到 acme.sh 命令。"
                log_error "请检查 ${ACME_HOME} 目录的内容和权限，以及安装脚本的输出。"
                exit 1
            else
                 log_info "acme.sh 已成功安装到 ${ACME_HOME}。"
            fi
        else
            log_error "下载 acme.sh 安装脚本失败。"
            exit 1
        fi
    else
        log_info "acme.sh 已安装在 ${ACME_CMD}。"
    fi
}

ensure_credentials_file() {
    log_info "正在检查 Cloudflare 凭证文件: ${CRED_FILE}"
    local needs_update=0
    local current_cf_key=""
    local current_cf_email=""
    local current_domain=""

    # 确保证书目录存在
    mkdir -p "$(dirname "${CRED_FILE}")"

    if [ -f "${CRED_FILE}" ]; then
        log_info "找到凭证文件。正在检查内容..."
        set +u
        CF_Key=""
        CF_Email=""
        domain=""
        # shellcheck source=/dev/null
        source "${CRED_FILE}"
        current_cf_key="${CF_Key:-}"
        current_cf_email="${CF_Email:-}"
        current_domain="${domain:-}"
        set -u

        if [ -z "${current_cf_key}" ]; then
            log_info "文件 ${CRED_FILE} 中缺少 CF_Key。"
            needs_update=1
        fi
        if [ -z "${current_cf_email}" ]; then
            log_info "文件 ${CRED_FILE} 中缺少 CF_Email。"
            needs_update=1
        fi
        # 检查 domain 是否为空是必须的，因为它是目标域名
        if [ -z "${current_domain}" ]; then
            log_info "文件 ${CRED_FILE} 中缺少 'domain' 变量。"
            needs_update=1
        fi

        if [ ${needs_update} -eq 0 ]; then
             log_info "凭证文件包含 CF_Key, CF_Email 和 domain。"
        fi
    else
        log_info "凭证文件 ${CRED_FILE} 不存在。"
        needs_update=1
    fi

    if [ ${needs_update} -eq 1 ]; then
        log_info "需要获取 Cloudflare API 凭证和目标域名。"
        local input_email=""
        local input_key=""
        local input_domain="" # 用于用户输入的目标域名

        local default_email="${current_cf_email:-}"
        local default_domain="${current_domain:-}" # 使用文件中可能已有的 domain 作为默认值

        log_info "请输入以下信息："
        while [ -z "$input_email" ]; do
            read -rp "Cloudflare 账户邮箱 (CF_Email) [${default_email}]: " input_email
            input_email="${input_email:-${default_email}}"
            if [ -z "$input_email" ]; then echo "[警告] 邮箱不能为空。" >&2; fi
        done

        while [ -z "$input_key" ]; do
            read -rsp "Cloudflare Global API Key (CF_Key) (必须输入): " input_key
            echo
            if [ -z "$input_key" ]; then echo "[警告] API Key 不能为空。" >&2; fi
        done

        # 获取目标域名
        while [ -z "$input_domain" ]; do
            read -rp "要申请证书的域名 (将写入文件中的 'domain') [${default_domain}]: " input_domain
            input_domain="${input_domain:-${default_domain}}"
            if [ -z "$input_domain" ]; then echo "[警告] 域名不能为空。" >&2; fi
        done

        log_info "正在将凭证和域名写入文件: ${CRED_FILE}"
        if printf "export CF_Key=\"%s\"\nexport CF_Email=\"%s\"\nexport domain=\"%s\"\n" "${input_key}" "${input_email}" "${input_domain}" > "${CRED_FILE}"; then
           chmod 600 "${CRED_FILE}"
           log_info "凭证和域名已成功写入 ${CRED_FILE} 并设置权限为 600。"
        else
            log_error "写入凭证文件 ${CRED_FILE} 失败。"
            exit 1
        fi
    fi
}

load_credentials() {
    log_info "正在加载 Cloudflare 凭证和目标域名..."
    unset CF_Key CF_Email domain # 清空旧值

    # 优先使用环境变量进行认证 (Key 和 Email)
    local cf_key_source="文件"
    local cf_email_source="文件"

    if [ -n "${CF_Key:-}" ]; then
        log_info "检测到环境变量 CF_Key，将优先使用它进行认证。"
        cf_key_source="环境变量"
    fi
    if [ -n "${CF_Email:-}" ]; then
         log_info "检测到环境变量 CF_Email，将优先使用它进行认证。"
         cf_email_source="环境变量"
    fi

    # 检查凭证文件是否存在以加载 domain (以及 Key/Email 如果环境变量不存在)
    if [ -f "${CRED_FILE}" ]; then
        log_info "从文件 ${CRED_FILE} 加载变量..."
        set +u
        # shellcheck source=/dev/null
        source "${CRED_FILE}"
        set -u

        # 如果环境变量没有设置 Key/Email, 则从文件导出
        if [ "$cf_key_source" == "文件" ]; then
            export CF_Key="${CF_Key:-}"
        fi
         if [ "$cf_email_source" == "文件" ]; then
            export CF_Email="${CF_Email:-}"
        fi
        # 始终导出文件中的 domain，并检查其是否存在
        export domain="${domain:-}"
        if [ -z "${domain}" ]; then
             log_error "错误：凭证文件 ${CRED_FILE} 中未找到或未设置 'domain' 变量。"
             log_error "请确文件格式为 export domain=\"your.domain.com\"。"
             exit 1
        fi
        # 将加载到的 domain 赋值给脚本的目标域名变量
        TARGET_DOMAIN="${domain}"
        log_info "从文件加载的目标域名: ${TARGET_DOMAIN}"

    elif [ -z "${domain:-}" ]; then
        # 文件不存在，且环境变量也没有提供 domain (标准环境变量里也没有 domain)
         log_error "错误：找不到凭证文件 ${CRED_FILE}，无法确定目标域名。"
         exit 1
    fi

    # 最终检查认证所需的 Key 和 Email 是否就绪
    if [ -z "${CF_Key:-}" ] || [ -z "${CF_Email:-}" ]; then
        log_error "错误：无法加载 Cloudflare 认证凭证 (CF_Key 和/或 CF_Email)。"
        log_error "请检查环境变量或凭证文件 ${CRED_FILE}。"
        exit 1
    fi

    # 检查 TARGET_DOMAIN 是否最终被赋值
    if [ -z "${TARGET_DOMAIN}" ]; then
         log_error "严重错误：未能确定要操作的目标域名。"
         exit 1
    fi

    log_info "Cloudflare 认证凭证 (CF_Key from ${cf_key_source}, CF_Email from ${cf_email_source}) 已准备好。"
    log_info "将要操作的目标域名: ${TARGET_DOMAIN}"
}

setup_acme() {
    log_info "正在配置 acme.sh..."
    if [ ! -x "${ACME_CMD}" ]; then log_error "命令不存在: ${ACME_CMD}"; exit 1; fi
    "${ACME_CMD}" --upgrade
    "${ACME_CMD}" --set-default-ca --server letsencrypt
    if [ -n "${LE_ACCOUNT_EMAIL}" ]; then
        log_info "注册/更新 Let's Encrypt 账户邮箱: ${LE_ACCOUNT_EMAIL}"
        if ! "${ACME_CMD}" --register-account -m "${LE_ACCOUNT_EMAIL}"; then
            log_error "注册 Let's Encrypt 账户失败 (邮箱: ${LE_ACCOUNT_EMAIL})。请检查日志。"
        fi
    else
        log_info "未提供 Let's Encrypt 账户邮箱。"
    fi
}

issue_and_install_cert() {
    # 使用从凭证文件中加载的 TARGET_DOMAIN
    log_info "正在为域名 ${TARGET_DOMAIN} 签发证书 (使用 dns_cf 方式)..."
    mkdir -p "${CERT_DIR}" || { log_error "创建目录失败: ${CERT_DIR}"; exit 1; }

    log_info "执行签发命令: ${ACME_CMD} --issue --dns dns_cf -d ${TARGET_DOMAIN}"
    # acme.sh 会使用导出的 CF_Key 和 CF_Email 环境变量
    if ! "${ACME_CMD}" --issue --dns dns_cf -d "${TARGET_DOMAIN}"; then
        log_error "为 ${TARGET_DOMAIN} 签发证书失败。"
        log_error "使用的 Email: ${CF_Email:-?}, 请检查 Cloudflare API 权限和 DNS 传播。"
        log_error "检查日志: ${ACME_HOME}/acme.sh.log"
        exit 1
    fi
    log_info "证书签发成功 for ${TARGET_DOMAIN}."

    log_info "正在将证书安装到 ${CERT_DIR}..."
    # 使用 TARGET_DOMAIN 构建文件名
    local key_file="${CERT_DIR}/${TARGET_DOMAIN}.key"
    local fullchain_file="${CERT_DIR}/${TARGET_DOMAIN}.crt"

    local install_args=(
        "--install-cert"
        "-d" "${TARGET_DOMAIN}" # 指定要安装证书的域名
        "--key-file" "${key_file}"
        "--fullchain-file" "${fullchain_file}"
    )
    if [ -n "${RELOAD_CMD}" ]; then
        install_args+=("--reloadcmd" "${RELOAD_CMD}")
    fi

    log_info "执行安装命令: ${ACME_CMD} ${install_args[*]}"
    if ! "${ACME_CMD}" "${install_args[@]}"; then
        log_error "为 ${TARGET_DOMAIN} 安装证书失败。"
        exit 1
    fi

    log_info "证书已成功安装到 ${CERT_DIR} for ${TARGET_DOMAIN}."
    if [ -n "${RELOAD_CMD}" ]; then
      log_info "已执行重载命令: ${RELOAD_CMD}"
    fi
}

setup_cron() {
    log_info "正在检查 acme.sh 的 cron 任务..."
     if [ ! -x "${ACME_CMD}" ]; then log_error "命令不存在，无法检查/安装 cron: ${ACME_CMD}"; return 1; fi
    if ! "${ACME_CMD}" --list | grep -q 'Auto upgrade'; then
       log_info "未找到 cron 任务。正在安装/更新 cron 任务..."
       if ! "${ACME_CMD}" --install-cronjob; then
           log_error "安装 acme.sh cron 任务失败。可能需要手动设置。"
       else
           log_info "acme.sh cron 任务已成功安装/更新。"
       fi
    else
       log_info "acme.sh cron 任务看起来已安装。"
    fi
}

# --- 主程序执行 ---

# 解析命令行参数 (移除了 -d / --domain)
ARGS=$(getopt -o c:m:r:h --long credentials:,email:,cert-dir:,reloadcmd:,acme-home:,help -n "$(basename "$0")" -- "$@")
if [ $? -ne 0 ]; then
    usage
    exit 1
fi
eval set -- "$ARGS"

while true; do
    case "$1" in
        -c|--credentials) CRED_FILE="$2"; shift 2 ;;
        -m|--email) LE_ACCOUNT_EMAIL="$2"; shift 2 ;;
        --cert-dir) CERT_DIR="$2"; shift 2 ;;
        -r|--reloadcmd) RELOAD_CMD="$2"; shift 2 ;;
        --acme-home) ACME_HOME="$2"; shift 2 ;;
        -h|--help) usage ;;
        --) shift; break ;;
        *) echo "内部错误！参数解析失败。" ; exit 1 ;;
    esac
done

# -d 参数不再是必需的，目标域名来自凭证文件

# --- 开始执行主要逻辑 ---
# 日志信息将在 load_credentials 后输出，因为那时才知道 TARGET_DOMAIN

check_root
install_acme
ensure_credentials_file      # 确保凭证文件存在且包含 CF_Key, CF_Email, domain
load_credentials             # 加载凭证 (优先环境变量 Key/Email) 并设置 TARGET_DOMAIN

# 现在 TARGET_DOMAIN 应该有值了，可以开始主要流程
log_info "开始为凭证文件中定义的域名 ${TARGET_DOMAIN} 进行 SSL 证书自动化处理"

setup_acme
issue_and_install_cert       # 使用 TARGET_DOMAIN 签发和安装证书
setup_cron

log_info "域名 ${TARGET_DOMAIN} 的 SSL 证书设置已成功完成。"

exit 0
