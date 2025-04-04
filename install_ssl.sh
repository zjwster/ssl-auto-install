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
                              如果文件存在且完整，将询问是否修改。
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
    local ask_modify=0 # Flag to indicate if we should ask the user about modifying
    local current_cf_key=""
    local current_cf_email=""
    local current_domain=""

    # 确保证书目录存在
    mkdir -p "$(dirname "${CRED_FILE}")"

    if [ -f "${CRED_FILE}" ]; then
        log_info "找到凭证文件。正在检查内容..."
        # Temporarily disable 'exit on unset variable' to safely source the file
        set +u
        CF_Key=""
        CF_Email=""
        domain=""
        # shellcheck source=/dev/null
        source "${CRED_FILE}"
        # Capture the values from the file, providing empty defaults if unset
        current_cf_key="${CF_Key:-}"
        current_cf_email="${CF_Email:-}"
        current_domain="${domain:-}"
        # Re-enable 'exit on unset variable'
        set -u

        # Check if all required variables are present and non-empty in the file
        if [ -n "${current_cf_key}" ] && [ -n "${current_cf_email}" ] && [ -n "${current_domain}" ]; then
            log_info "凭证文件包含有效的 CF_Key, CF_Email 和 domain。"
            ask_modify=1 # File is complete, so we can ask the user if they want to modify
        else
            log_info "凭证文件不完整。"
            needs_update=1 # File exists but is incomplete, force update
            if [ -z "${current_cf_key}" ]; then log_info " - 缺少 CF_Key"; fi
            if [ -z "${current_cf_email}" ]; then log_info " - 缺少 CF_Email"; fi
            if [ -z "${current_domain}" ]; then log_info " - 缺少 domain"; fi
        fi

        # *** 新增逻辑: 如果文件完整，询问用户是否修改 ***
        if [ ${needs_update} -eq 0 ] && [ ${ask_modify} -eq 1 ]; then
            local modify_choice=""
            # Use -i 'N' for default value in bash 4+ if available, otherwise rely on user input check
            read -rp "凭证文件 ${CRED_FILE} 已存在且包含有效值。是否要修改 CF_Key, CF_Email 和 domain? (y/N): " modify_choice
            if [[ "${modify_choice}" =~ ^[Yy]$ ]]; then
                log_info "用户选择修改现有凭证和域名。"
                needs_update=1 # Set flag to trigger input prompts below
                # Keep current values as defaults for the prompts
            else
                log_info "用户选择不修改，将使用文件中的现有值。"
                # needs_update remains 0, function will skip the input section
            fi
        fi
        # *** 结束新增逻辑 ***

    else
        log_info "凭证文件 ${CRED_FILE} 不存在。"
        needs_update=1 # File doesn't exist, force update/creation
    fi

    # If needs_update is 1 (either file was missing, incomplete, or user chose to modify)
    if [ ${needs_update} -eq 1 ]; then
        log_info "需要获取或更新 Cloudflare API 凭证和目标域名。"
        local input_email=""
        local input_key=""
        local input_domain=""

        # Use values from file (if it existed) as defaults for prompts
        local default_email="${current_cf_email:-}"
        local default_domain="${current_domain:-}"
        # No default for key as it's sensitive and might be wrong anyway

        log_info "请输入以下信息 (留空并按 Enter 键可使用方括号中的默认值):"

        # Get Email
        while [ -z "$input_email" ]; do
            read -rp "Cloudflare 账户邮箱 (CF_Email) [${default_email}]: " input_email
            input_email="${input_email:-${default_email}}" # Apply default if empty
            if [ -z "$input_email" ]; then
                echo "[警告] 邮箱不能为空。" >&2
            else
                # Requirement 2: Show entered value
                log_info "[确认] 输入的 CF_Email: ${input_email}"
            fi
        done

        # Get Key
        while [ -z "$input_key" ]; do
             # Use -r for raw, -p for prompt. *** REMOVED -s option ***
            read -rp "Cloudflare Global API Key (CF_Key): " input_key
             # Prompt text changed to remove "(输入时隐藏)"
            # echo # Newline after input is handled by user pressing Enter now. Optional echo removed.
            if [ -z "$input_key" ]; then
                echo "[警告] API Key 不能为空。" >&2
            else
                # Requirement 2: Show the entered key AFTER it's read
                # This log confirmation is still useful even if input wasn't hidden.
                log_info "[确认] 输入的 CF_Key: ${input_key}"
            fi
        done

        # Get Domain
        while [ -z "$input_domain" ]; do
            read -rp "要申请证书的域名 (domain) [${default_domain}]: " input_domain
            input_domain="${input_domain:-${default_domain}}" # Apply default if empty
            if [ -z "$input_domain" ]; then
                echo "[警告] 域名不能为空。" >&2
            else
                 # Requirement 2: Show entered value
                log_info "[确认] 输入的 domain: ${input_domain}"
            fi
        done

        log_info "正在将凭证和域名写入文件: ${CRED_FILE}"
        # Overwrite the file with the new/updated values
        if printf "export CF_Key=\"%s\"\nexport CF_Email=\"%s\"\nexport domain=\"%s\"\n" "${input_key}" "${input_email}" "${input_domain}" > "${CRED_FILE}"; then
           chmod 600 "${CRED_FILE}"
           log_info "凭证和域名已成功写入 ${CRED_FILE} 并设置权限为 600。"
        else
            log_error "写入凭证文件 ${CRED_FILE} 失败。"
            exit 1
        fi
    fi
    # If needs_update was 0 initially and user chose not to modify, this function just finishes here.
}


load_credentials() {
    log_info "正在加载 Cloudflare 凭证和目标域名..."
    unset CF_Key CF_Email domain # Clear potentially existing environment variables sourced from elsewhere

    # Check if CRED_FILE exists before attempting to source it
    if [ ! -f "${CRED_FILE}" ]; then
        log_error "错误：凭证文件 ${CRED_FILE} 未找到。请先运行脚本生成或检查路径。"
        # We already ran ensure_credentials_file, so this should theoretically not happen unless file perms changed
        # or ensure_credentials_file failed silently, but it's a good safeguard.
        exit 1
    fi

    # Source the credentials file to load CF_Key, CF_Email, and domain
    log_info "从文件 ${CRED_FILE} 加载变量..."
    set +u # Temporarily disable exit on unset variable
    # shellcheck source=/dev/null
    source "${CRED_FILE}"
    set -u # Re-enable

    # Check if variables were actually loaded from the file
    if [ -z "${CF_Key:-}" ] || [ -z "${CF_Email:-}" ] || [ -z "${domain:-}" ]; then
        log_error "错误：从 ${CRED_FILE} 加载凭证或域名失败。"
        log_error "请确保文件包含格式正确的 'export CF_Key=...', 'export CF_Email=...' 和 'export domain=...' 行。"
        exit 1
    fi

    # Assign the domain from the file to our target variable
    TARGET_DOMAIN="${domain}"
    log_info "从文件加载的目标域名: ${TARGET_DOMAIN}"

    # Export the credentials from the file for acme.sh to use
    # Note: Environment variables set *before* running the script still take precedence
    # if acme.sh checks them directly, but this script primarily relies on sourcing the file.
    # We re-export here to be absolutely sure they are available for the acme.sh child process.
    export CF_Key
    export CF_Email
    # 'domain' variable doesn't need to be exported for acme.sh, TARGET_DOMAIN is used internally.

    log_info "Cloudflare 凭证 (CF_Key, CF_Email) 和目标域名 (${TARGET_DOMAIN}) 已从文件加载。"
    # Removed the "source" logging (env vs file) as it's simpler now: we always source from the file after ensure_credentials_file.
}

setup_acme() {
    log_info "正在配置 acme.sh..."
    if [ ! -x "${ACME_CMD}" ]; then log_error "命令不存在: ${ACME_CMD}"; exit 1; fi
    "${ACME_CMD}" --upgrade --home "${ACME_HOME}" # Ensure upgrade respects the specified home
    "${ACME_CMD}" --set-default-ca --server letsencrypt --home "${ACME_HOME}"
    if [ -n "${LE_ACCOUNT_EMAIL}" ]; then
        log_info "注册/更新 Let's Encrypt 账户邮箱: ${LE_ACCOUNT_EMAIL}"
        # Pass --home to ensure account registration uses the correct directory
        if ! "${ACME_CMD}" --register-account -m "${LE_ACCOUNT_EMAIL}" --home "${ACME_HOME}"; then
            log_error "注册 Let's Encrypt 账户失败 (邮箱: ${LE_ACCOUNT_EMAIL})。请检查日志。"
            # Continue script execution, as account registration failure might not block certificate issuance if already registered.
        fi
    else
        log_info "未提供 Let's Encrypt 账户邮箱 (-m 参数)。"
    fi
}

issue_and_install_cert() {
    # TARGET_DOMAIN is set by load_credentials from the file
    log_info "正在为域名 ${TARGET_DOMAIN} 签发证书 (使用 dns_cf 方式)..."
    mkdir -p "${CERT_DIR}" || { log_error "创建目录失败: ${CERT_DIR}"; exit 1; }

    # CF_Key and CF_Email are exported by load_credentials
    log_info "执行签发命令: ${ACME_CMD} --issue --dns dns_cf -d ${TARGET_DOMAIN} --home ${ACME_HOME}"
    # Pass --home to ensure acme.sh uses the correct config/account/log location
    # Environment variables CF_Key and CF_Email will be used automatically by dns_cf hook
    if ! "${ACME_CMD}" --issue --dns dns_cf -d "${TARGET_DOMAIN}" --home "${ACME_HOME}"; then
        log_error "为 ${TARGET_DOMAIN} 签发证书失败。"
        log_error "使用的 Email (来自文件): ${CF_Email:-?}, 请检查 Cloudflare API 权限和 DNS 传播。"
        log_error "检查日志: ${ACME_HOME}/acme.sh.log"
        exit 1
    fi
    log_info "证书签发成功 for ${TARGET_DOMAIN}."

    log_info "正在将证书安装到 ${CERT_DIR}..."
    local key_file="${CERT_DIR}/${TARGET_DOMAIN}.key"
    local fullchain_file="${CERT_DIR}/${TARGET_DOMAIN}.crt"

    local install_args=(
        "--install-cert"
        "--home" "${ACME_HOME}" # Pass --home here too
        "-d" "${TARGET_DOMAIN}" # Specify the domain for which to install the cert
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
     # Pass --home to list and install-cronjob to ensure it manages the right installation
    if ! "${ACME_CMD}" --list --home "${ACME_HOME}" | grep -q 'Auto upgrade'; then
       log_info "未找到 cron 任务。正在安装/更新 cron 任务..."
       if ! "${ACME_CMD}" --install-cronjob --home "${ACME_HOME}"; then
           log_error "安装 acme.sh cron 任务失败。可能需要手动设置。"
       else
           log_info "acme.sh cron 任务已成功安装/更新。"
       fi
    else
       log_info "acme.sh cron 任务看起来已安装。"
    fi
}

# --- 主程序执行 ---

# Parse command-line arguments
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
        --acme-home) ACME_HOME="$2"; ACME_CMD="${ACME_HOME}/acme.sh"; shift 2 ;; # Update ACME_CMD if home changes
        -h|--help) usage ;;
        --) shift; break ;;
        *) echo "内部错误！参数解析失败。" ; exit 1 ;;
    esac
done

# --- Begin Main Logic ---

check_root
install_acme                 # Install acme.sh if not found
ensure_credentials_file      # Check/create/update credentials file, asks user if modify needed
load_credentials             # Load credentials & domain from file, export Key/Email

# Now TARGET_DOMAIN should have a value loaded from the file
log_info "开始为凭证文件中定义的域名 ${TARGET_DOMAIN} 进行 SSL 证书自动化处理"

# Pass --home to all relevant acme.sh commands
setup_acme                   # Upgrade acme.sh, set default CA, register account
issue_and_install_cert       # Issue and install the certificate using TARGET_DOMAIN
setup_cron                   # Setup auto-renewal cron job

log_info "域名 ${TARGET_DOMAIN} 的 SSL 证书设置已成功完成。"

exit 0
