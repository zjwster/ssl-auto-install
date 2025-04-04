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
DOMAIN=""                               # 需要申请证书的域名 (必需, 通过 -d 参数传入)
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
# export domain="" # 从凭证文件中加载的域名, 注意与脚本参数 -d 的区别

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
  -d, --domain <域名>      要为其颁发证书的域名。此参数指定的域名将用于证书申请。

选项:
  -c, --credentials <文件路径>  Cloudflare 凭证文件路径。
                              (默认: ${DEFAULT_CRED_FILE})
                              此文件需要包含 export CF_Key、export CF_Email 和 export domain。
                              如果文件不存在或内容不全，脚本将提示输入。
                              注意：文件中的 domain 主要用于记录，脚本实际操作的域名由 -d 参数指定。
                              也可以通过环境变量 CF_Key 和 CF_Email 设置 (优先级更高)。
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
        mkdir -p "$(dirname "${ACME_HOME}")"
        local install_script="get-acme.sh"
        if curl -fsS https://get.acme.sh -o "${install_script}"; then
            log_info "已下载 acme.sh 安装脚本。"
            eval sh "'${install_script}'" --home "'${ACME_HOME}'" ${LE_ACCOUNT_EMAIL:+"--accountemail"} ${LE_ACCOUNT_EMAIL:+"'${LE_ACCOUNT_EMAIL}'"}
            rm -f "${install_script}"
            log_info "acme.sh 已成功安装到 ${ACME_HOME}。"
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

# --- 更新：检查并可能创建/更新包含三个变量的凭证文件 ---
ensure_credentials_file() {
    log_info "正在检查 Cloudflare 凭证文件: ${CRED_FILE}"
    local needs_update=0
    local current_cf_key=""
    local current_cf_email=""
    local current_domain="" # 新增：用于检查文件中的 domain

    # 确保证书目录存在，以便可以写入文件
    mkdir -p "$(dirname "${CRED_FILE}")"

    if [ -f "${CRED_FILE}" ]; then
        log_info "找到凭证文件。正在检查内容..."
        # 尝试加载现有值，临时禁用 set -u
        set +u
        # 清空变量以确保是从文件中加载的
        CF_Key=""
        CF_Email=""
        domain=""
        # shellcheck source=/dev/null
        source "${CRED_FILE}"
        current_cf_key="${CF_Key:-}"
        current_cf_email="${CF_Email:-}"
        current_domain="${domain:-}" # 加载文件中的 domain
        set -u

        if [ -z "${current_cf_key}" ]; then
            log_info "文件 ${CRED_FILE} 中缺少 CF_Key。"
            needs_update=1
        fi
        if [ -z "${current_cf_email}" ]; then
            log_info "文件 ${CRED_FILE} 中缺少 CF_Email。"
            needs_update=1
        fi
        if [ -z "${current_domain}" ]; then # 新增：检查 domain
            log_info "文件 ${CRED_FILE} 中缺少 domain。"
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
        log_info "需要获取 Cloudflare API 凭证和关联域名。"
        local input_email=""
        local input_key=""
        local input_domain="" # 新增：用于用户输入

        # 如果文件存在且部分值有效，则预填这些值
        local default_email="${current_cf_email:-}"
        local default_domain="${current_domain:-}"
        # API Key 不预填，总是要求重新输入以策安全

        log_info "请输入以下信息："
        # 提示输入 Email, 提供默认值
        while [ -z "$input_email" ]; do
            read -rp "Cloudflare 账户邮箱 (CF_Email) [${default_email}]: " input_email
            # 如果用户直接回车，则使用默认值（如果存在）
            input_email="${input_email:-${default_email}}"
            if [ -z "$input_email" ]; then
                 echo "[警告] 邮箱不能为空，请重新输入。" >&2
            fi
        done

        # 提示输入 API Key (隐藏输入)
        while [ -z "$input_key" ]; do
            read -rsp "Cloudflare Global API Key (CF_Key) (必须输入): " input_key
            echo # 换行
            if [ -z "$input_key" ]; then
                 echo "[警告] API Key 不能为空，请重新输入。" >&2
            fi
        done

        # 提示输入域名, 提供默认值
        while [ -z "$input_domain" ]; do
            read -rp "与此凭证关联的主域名 (用于记录) [${default_domain}]: " input_domain
            # 如果用户直接回车，则使用默认值（如果存在）
            input_domain="${input_domain:-${default_domain}}"
            if [ -z "$input_domain" ]; then
                 echo "[警告] 域名不能为空，请重新输入。" >&2
            fi
        done

        log_info "正在将凭证写入文件: ${CRED_FILE}"
        # 使用 printf 更安全地写入，并确保包含 export 关键字
        if printf "export CF_Key=\"%s\"\nexport CF_Email=\"%s\"\nexport domain=\"%s\"\n" "${input_key}" "${input_email}" "${input_domain}" > "${CRED_FILE}"; then
           # 设置文件权限，只允许所有者读写
           chmod 600 "${CRED_FILE}"
           log_info "凭证已成功写入 ${CRED_FILE} 并设置权限为 600。"
        else
            log_error "写入凭证文件 ${CRED_FILE} 失败。"
            exit 1
        fi
    fi
}
# --- 更新结束 ---


# 从文件或环境变量加载 Cloudflare 凭证
load_credentials() {
    log_info "正在加载 Cloudflare 凭证..."
    # 先清空可能存在的旧值
    unset CF_Key CF_Email domain

    # 优先使用环境变量 (注意：这里只处理了 Key 和 Email，没有处理 domain 的环境变量)
    # 如果用户通过其他方式设置了 CF_Key 和 CF_Email 环境变量，则使用它们
    # 注意：没有 CF_Domain 环境变量的标准约定，所以不处理
    if [ -n "${CF_Key:-}" ] && [ -n "${CF_Email:-}" ]; then
        log_info "检测到环境变量 CF_Key 和 CF_Email，将优先使用它们进行认证。"
        # 不需要重新 export，因为它们已经是环境变量了
    # 如果环境变量不完整，则尝试从文件加载
    elif [ -f "${CRED_FILE}" ]; then
        log_info "从文件 ${CRED_FILE} 加载凭证 (CF_Key, CF_Email, domain)..."
        # 临时禁用未设置变量检查以便 source 文件
        set +u
        # shellcheck source=/dev/null
        source "${CRED_FILE}"
        set -u # 重新启用未设置变量检查

        # 检查从文件加载后关键变量是否已设置
        if [ -z "${CF_Key:-}" ] || [ -z "${CF_Email:-}" ]; then
             log_error "从文件 ${CRED_FILE} 加载后，CF_Key 或 CF_Email 仍然不完整。请检查文件内容或手动设置环境变量。"
             exit 1
        fi
        # 导出从文件加载的变量供 acme.sh 子进程使用
        # 注意：acme.sh dns_cf 主要使用 CF_Key 和 CF_Email
        export CF_Key
        export CF_Email
        # 也导出 domain，虽然 acme.sh 可能不直接用，但保持一致性
        export domain
        log_info "从文件加载的域名记录为: ${domain:-未设置}"
    else
        # 文件不存在，且环境变量也没设置
        log_error "Cloudflare 凭证 (CF_Key 和 CF_Email) 既未在环境变量中设置，也找不到有效的凭证文件 ${CRED_FILE}。"
        log_error "请运行脚本让其提示输入，或手动创建 ${CRED_FILE}，或设置 CF_Key 和 CF_Email 环境变量。"
        exit 1
    fi

    # 最终检查认证所需的变量是否已成功设置
    if [ -z "${CF_Key:-}" ] || [ -z "${CF_Email:-}" ]; then
        log_error "无法加载 Cloudflare 认证凭证 (CF_Key 和 CF_Email)。"
        exit 1
    fi

    log_info "Cloudflare 认证凭证 (CF_Key, CF_Email) 已准备好。"
}

# 更新 acme.sh, 设置默认 CA, 如果提供了邮箱则注册账户
setup_acme() {
    log_info "正在配置 acme.sh..."
    if [ ! -x "${ACME_CMD}" ]; then
        log_error "找不到 acme.sh 命令或没有执行权限: ${ACME_CMD}"
        exit 1
    fi

    "${ACME_CMD}" --upgrade
    "${ACME_CMD}" --set-default-ca --server letsencrypt

    if [ -n "${LE_ACCOUNT_EMAIL}" ]; then
        log_info "正在注册/更新 Let's Encrypt 账户邮箱: ${LE_ACCOUNT_EMAIL}"
        if ! "${ACME_CMD}" --register-account -m "${LE_ACCOUNT_EMAIL}"; then
            log_error "使用邮箱 ${LE_ACCOUNT_EMAIL} 注册 Let's Encrypt 账户失败。请检查 acme.sh 日志。"
            # exit 1 # 通常不致命
        fi
    else
        log_info "未提供用于注册/更新的 Let's Encrypt 账户邮箱。"
    fi
}

# 使用 DNS 验证颁发证书并安装
issue_and_install_cert() {
    # 注意：这里的 ${DOMAIN} 是通过 -d 参数传入的，不是凭证文件里的 domain
    log_info "正在为域名 ${DOMAIN} (由 -d 参数指定) 签发证书 (使用 dns_cf 方式)..."
    mkdir -p "${CERT_DIR}"
    if [ ! -d "${CERT_DIR}" ]; then
        log_error "创建证书目录失败: ${CERT_DIR}"
        exit 1
    fi

    # 签发证书，确保 CF_Key 和 CF_Email 被传递给 acme.sh
    # 使用加载好的环境变量 CF_Key 和 CF_Email
    log_info "执行签发命令: ${ACME_CMD} --issue --dns dns_cf -d ${DOMAIN}"
    # acme.sh 会自动读取导出的 CF_Key 和 CF_Email 环境变量
    if ! "${ACME_CMD}" --issue --dns dns_cf -d "${DOMAIN}"; then
        log_error "为 ${DOMAIN} 签发证书失败。请检查 Cloudflare API 设置和 DNS 记录是否正确传播。"
        log_error "凭证使用的 Email: ${CF_Email:-未设置}"
        log_error "请检查 acme.sh 日志文件: ${ACME_HOME}/acme.sh.log"
        exit 1
    fi
    log_info "证书签发成功 for ${DOMAIN}."

    log_info "正在将证书安装到 ${CERT_DIR}..."
    local key_file="${CERT_DIR}/${DOMAIN}.key"
    local fullchain_file="${CERT_DIR}/${DOMAIN}.crt"

    local install_args=(
        "--install-cert"
        "-d" "${DOMAIN}"
        "--key-file" "${key_file}"
        "--fullchain-file" "${fullchain_file}"
    )
    if [ -n "${RELOAD_CMD}" ]; then
        install_args+=("--reloadcmd" "${RELOAD_CMD}")
    fi

    log_info "执行安装命令: ${ACME_CMD} ${install_args[*]}"
    if ! "${ACME_CMD}" "${install_args[@]}"; then
        log_error "为 ${DOMAIN} 安装证书失败。"
        exit 1
    fi

    log_info "证书已成功安装到 ${CERT_DIR} for ${DOMAIN}."
    if [ -n "${RELOAD_CMD}" ]; then
      log_info "已执行重载命令: ${RELOAD_CMD}"
    fi
}

# 确保 acme.sh 的 cron 任务已安装
setup_cron() {
    log_info "正在检查 acme.sh 的 cron 任务..."
     if [ ! -x "${ACME_CMD}" ]; then
        log_error "找不到 acme.sh 命令或没有执行权限，无法检查/安装 cron 任务: ${ACME_CMD}"
        return 1
    fi
    if ! "${ACME_CMD}" --list | grep -q 'Auto upgrade'; then
       log_info "未找到 cron 任务或自动升级被禁用。正在安装/更新 cron 任务..."
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

# 解析命令行参数
# 移除了 --cf-key-env 和 --cf-email-env，因为 load_credentials 现在直接检查环境变量
ARGS=$(getopt -o d:c:m:r:h --long domain:,credentials:,email:,cert-dir:,reloadcmd:,acme-home:,help -n "$(basename "$0")" -- "$@")
if [ $? -ne 0 ]; then
    usage
    exit 1
fi
eval set -- "$ARGS"

while true; do
    case "$1" in
        -d|--domain) DOMAIN="$2"; shift 2 ;;          # 脚本操作的目标域名
        -c|--credentials) CRED_FILE="$2"; shift 2 ;;  # 凭证文件路径
        -m|--email) LE_ACCOUNT_EMAIL="$2"; shift 2 ;; # Let's Encrypt 邮箱
        --cert-dir) CERT_DIR="$2"; shift 2 ;;         # 证书目录
        -r|--reloadcmd) RELOAD_CMD="$2"; shift 2 ;;   # 重载命令
        --acme-home) ACME_HOME="$2"; shift 2 ;;       # acme.sh 主目录
        -h|--help) usage ;;                           # 帮助
        --) shift; break ;;
        *) echo "内部错误！参数解析失败。" ; exit 1 ;;
    esac
done

# 验证必需的参数 (-d)
if [ -z "${DOMAIN}" ]; then
    log_error "必须提供要操作的域名 (-d 或 --domain)。"
    usage
    exit 1
fi

# --- 开始执行主要逻辑 ---
log_info "开始为域名 ${DOMAIN} (由 -d 参数指定) 进行 SSL 证书自动化处理"

check_root
install_acme
ensure_credentials_file      # 确保凭证文件存在且包含 CF_Key, CF_Email, domain
load_credentials             # 加载凭证 (优先环境变量 Key/Email, 其次文件)
setup_acme
issue_and_install_cert       # 使用 -d 指定的 DOMAIN 签发和安装证书
setup_cron

log_info "域名 ${DOMAIN} 的 SSL 证书设置已成功完成。"

exit 0
