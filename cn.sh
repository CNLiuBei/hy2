#!/bin/bash

# Script for Sing-Box Hysteria2 Management

# --- Author Information ---
AUTHOR_NAME="jcnf-那坨"
WEBSITE_URL="https://ybfl.net"
TG_CHANNEL_URL="https://t.me/mffjc"
TG_GROUP_URL="https://t.me/+TDz0jE2WcAvfgmLi"

# --- Configuration ---
SINGBOX_INSTALL_PATH_EXPECTED="/usr/local/bin/sing-box"
SINGBOX_CONFIG_DIR="/usr/local/etc/sing-box"
SINGBOX_CONFIG_FILE="${SINGBOX_CONFIG_DIR}/config.json"
SINGBOX_SERVICE_FILE="/etc/systemd/system/sing-box.service"

HYSTERIA_CERT_DIR="/etc/hysteria" # 针对自签名证书
HYSTERIA_CERT_KEY="${HYSTERIA_CERT_DIR}/private.key"
HYSTERIA_CERT_PEM="${HYSTERIA_CERT_DIR}/cert.pem"

# 用于持久存储上次配置信息的文件
PERSISTENT_INFO_FILE="${SINGBOX_CONFIG_DIR}/.last_singbox_script_info"

# 默认值
DEFAULT_HYSTERIA_PORT="8443"
DEFAULT_HYSTERIA_MASQUERADE_CN="bing.com"

# 全局 SINGBOX_CMD
SINGBOX_CMD=""

# 全局变量，用于存储上次生成的配置信息
LAST_SERVER_IP=""
LAST_HY2_PORT=""
LAST_HY2_PASSWORD=""
LAST_HY2_MASQUERADE_CN=""
LAST_HY2_LINK=""
LAST_INSTALL_MODE="" # "hysteria2" 或 ""

# --- 颜色定义 ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
MAGENTA='\033[0;35m'
CYAN='\033[0;36m'
BOLD='\033[1m'
UNDERLINE='\033[4m'
NC='\033[0m' # 无颜色

# --- 辅助函数 ---
info() { echo -e "${BLUE}[INFO]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; }
success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }

print_author_info() {
    echo -e "${MAGENTA}${BOLD}================================================${NC}"
    echo -e "${CYAN}${BOLD} Sing-Box Hysteria2 管理脚本 ${NC}"
    echo -e "${MAGENTA}${BOLD}================================================${NC}"
    echo -e " ${YELLOW}作者:${NC}      ${GREEN}${AUTHOR_NAME}${NC}"
    echo -e " ${YELLOW}网站:${NC}      ${UNDERLINE}${BLUE}${WEBSITE_URL}${NC}"
    echo -e " ${YELLOW}TG 频道:${NC}   ${UNDERLINE}${BLUE}${TG_CHANNEL_URL}${NC}"
    echo -e " ${YELLOW}TG 交流群:${NC} ${UNDERLINE}${BLUE}${TG_GROUP_URL}${NC}"
    echo -e "${MAGENTA}${BOLD}================================================${NC}"
}

load_persistent_info() {
    if [ -f "$PERSISTENT_INFO_FILE" ]; then
        info "加载上次保存的配置信息从: $PERSISTENT_INFO_FILE"
        source "$PERSISTENT_INFO_FILE"
        success "配置信息加载完成。"
    else
        info "未找到持久化的配置信息文件。"
    fi
}

save_persistent_info() {
    info "正在保存当前配置信息到: $PERSISTENT_INFO_FILE"
    mkdir -p "$(dirname "$PERSISTENT_INFO_FILE")"
    cat > "$PERSISTENT_INFO_FILE" <<EOF
LAST_SERVER_IP="${LAST_SERVER_IP}"
LAST_HY2_PORT="${LAST_HY2_PORT}"
LAST_HY2_PASSWORD="${LAST_HY2_PASSWORD}"
LAST_HY2_MASQUERADE_CN="${LAST_HY2_MASQUERADE_CN}"
LAST_HY2_LINK="${LAST_HY2_LINK}"
LAST_INSTALL_MODE="${LAST_INSTALL_MODE}"
EOF
    if [ $? -eq 0 ]; then
        success "配置信息保存成功。"
    else
        error "配置信息保存失败。"
    fi
}

check_root() {
    if [ "$(id -u)" -ne 0 ]; then
        error "此脚本需要以 root 权限运行。请使用 'sudo bash $0'"
        exit 1
    fi
}

attempt_install_package() {
    local package_name="$1"
    local friendly_name="${2:-$package_name}"

    if command -v "$package_name" &>/dev/null; then
        return 0
    fi

    read -p "依赖 '${friendly_name}' 未安装。是否尝试自动安装? (y/N): " install_confirm
    if [[ ! "$install_confirm" =~ ^[Yy]$ ]]; then
        warn "跳过安装 '${friendly_name}'。某些功能可能因此不可用。"
        return 1
    fi

    info "正在尝试安装 '${friendly_name}'..."
    if command -v apt-get &>/dev/null; then
        apt-get update -y && apt-get install -y "$package_name"
    elif command -v yum &>/dev/null; then
        yum install -y "$package_name"
    elif command -v dnf &>/dev/null; then
        dnf install -y "$package_name"
    else
        error "未找到已知的包管理器。请手动安装 '${friendly_name}'。"
        return 1
    fi

    if command -v "$package_name" &>/dev/null; then
        success "'${friendly_name}' 安装成功。"
        return 0
    else
        error "'${friendly_name}' 安装失败。请手动安装。"
        return 1
    fi
}

check_dependencies() {
    info "检查核心依赖..."
    local core_deps=("curl" "openssl" "jq")
    local all_deps_met=true
    for dep in "${core_deps[@]}"; do
        if ! command -v "$dep" &>/dev/null; then
            if ! attempt_install_package "$dep"; then
                all_deps_met=false
            fi
        fi
    done

    if ! $all_deps_met; then
        error "部分核心依赖未能安装。脚本可能无法正常运行。"
        exit 1
    fi
    success "核心依赖检查通过。"
}

check_and_prepare_qrencode() {
    if ! command -v qrencode &>/dev/null; then
        if attempt_install_package "qrencode" "二维码生成工具(qrencode)"; then
            return 0
        else
            warn "未安装 'qrencode'。将无法生成二维码。"
            return 1
        fi
    fi
    return 0
}

find_and_set_singbox_cmd() {
    if [ -x "$SINGBOX_INSTALL_PATH_EXPECTED" ]; then
        SINGBOX_CMD="$SINGBOX_INSTALL_PATH_EXPECTED"
    elif command -v sing-box &>/dev/null; then
        SINGBOX_CMD=$(command -v sing-box)
    else
        SINGBOX_CMD=""
    fi
    if [ -n "$SINGBOX_CMD" ]; then
        info "Sing-box 命令已设置为: $SINGBOX_CMD"
    else
        warn "初始未找到 Sing-box 命令。"
    fi
}

get_server_ip() {
    SERVER_IP=$(curl -s --max-time 5 ip.sb || curl -s --max-time 5 https://api.ipify.org || curl -s --max-time 5 https://checkip.amazonaws.com)
    if [ -z "$SERVER_IP" ]; then
        warn "无法自动获取服务器公网 IP。"
        read -p "请输入你的服务器公网 IP (留空则尝试从hostname获取): " MANUAL_SERVER_IP
        if [ -n "$MANUAL_SERVER_IP" ]; then
            SERVER_IP="$MANUAL_SERVER_IP"
        else
            SERVER_IP=$(hostname -I | awk '{print $1}')
            if [ -z "$SERVER_IP" ]; then
                warn "无法从hostname获取IP，请确保网络连接正常或手动输入。"
            fi
        fi
    fi

    if [[ "$SERVER_IP" =~ ^10\. || "$SERVER_IP" =~ ^172\.(1[6-9]|2[0-9]|3[0-1])\. || "$SERVER_IP" =~ ^192\.168\. ]]; then
        warn "检测到的 IP (${SERVER_IP}) 似乎是私有IP。"
        read -p "请再次输入你的服务器公网 IP (如果上面的IP不正确): " OVERRIDE_SERVER_IP
        if [ -n "$OVERRIDE_SERVER_IP" ]; then
            SERVER_IP="$OVERRIDE_SERVER_IP"
        fi
    fi
    info "检测到服务器 IP: ${SERVER_IP}"
    LAST_SERVER_IP="$SERVER_IP"
}

generate_random_password() {
    openssl rand -base64 24 | tr -dc 'A-Za-z0-9' | head -c 16
}

install_singbox_core() {
    if [ -f "$SINGBOX_INSTALL_PATH_EXPECTED" ]; then
        info "Sing-box 已检测到在 $SINGBOX_INSTALL_PATH_EXPECTED."
        find_and_set_singbox_cmd
        if [ -n "$SINGBOX_CMD" ]; then
            current_version=$($SINGBOX_CMD version | awk '{print $3}' 2>/dev/null)
            if [ -n "$current_version" ]; then
                info "当前版本: $current_version"
            else
                info "无法确定当前版本。"
            fi
        fi
        read -p "是否重新安装/更新 Sing-box (beta)? (y/N): " reinstall_choice
        if [[ ! "$reinstall_choice" =~ ^[Yy]$ ]]; then
            return 0
        fi
    fi
    info "正在安装/更新 Sing-box (beta)..."
    if bash -c "$(curl -fsSL https://sing-box.vercel.app/)" @ install --beta; then
        success "Sing-box 安装/更新成功。"
        find_and_set_singbox_cmd
        if [ -z "$SINGBOX_CMD" ]; then
            error "安装后仍无法找到 sing-box 命令。"
            return 1
        fi
    else
        error "Sing-box 安装失败。"
        return 1
    fi
    return 0
}

generate_self_signed_cert() {
    local domain_cn="$1"
    if [ -f "$HYSTERIA_CERT_PEM" ] && [ -f "$HYSTERIA_CERT_KEY" ]; then
        info "检测到已存在的证书: ${HYSTERIA_CERT_PEM} 和 ${HYSTERIA_CERT_KEY}"
        existing_cn=$(openssl x509 -in "$HYSTERIA_CERT_PEM" -noout -subject | sed -n 's/.*CN = \([^,]*\).*/\1/p')
        if [ "$existing_cn" == "$domain_cn" ]; then
            info "证书 CN ($existing_cn) 与目标 ($domain_cn) 匹配，跳过重新生成。"
            return 0
        else
            warn "证书 CN ($existing_cn) 与目标 ($domain_cn) 不匹配。"
            read -p "是否使用新的 CN ($domain_cn) 重新生成证书? (y/N): " regen_cert_choice
            if [[ ! "$regen_cert_choice" =~ ^[Yy]$ ]]; then
                info "保留现有证书。"
                return 0
            fi
        fi
    fi

    info "正在为 Hysteria2 生成自签名证书 (CN=${domain_cn})..."
    mkdir -p "$HYSTERIA_CERT_DIR"
    openssl ecparam -genkey -name prime256v1 -out "$HYSTERIA_CERT_KEY"
    openssl req -new -x509 -days 36500 -key "$HYSTERIA_CERT_KEY" -out "$HYSTERIA_CERT_PEM" -subj "/CN=${domain_cn}"
    if [ $? -eq 0 ]; then
        success "自签名证书生成成功。"
        info "证书: ${HYSTERIA_CERT_PEM}"
        info "私钥: ${HYSTERIA_CERT_KEY}"
    else
        error "自签名证书生成失败。"
        return 1
    fi
}

create_config_json() {
    local hy2_port="$1"
    local hy2_password="$2"
    local hy2_masquerade_cn="$3"

    if [ -z "$SINGBOX_CMD" ]; then
        error "Sing-box command 未设置。无法校验配置文件。"
        return 1
    fi

    info "正在创建配置文件: ${SINGBOX_CONFIG_FILE}"
    mkdir -p "$SINGBOX_CONFIG_DIR"

    cat > "$SINGBOX_CONFIG_FILE" <<EOF
{
    "log": {
        "level": "info",
        "timestamp": true
    },
    "inbounds": [
        {
            "type": "hysteria2",
            "tag": "hy2-in",
            "listen": "::",
            "listen_port": ${hy2_port},
            "users": [
                {
                    "password": "${hy2_password}"
                }
            ],
            "masquerade": "https://placeholder.services.mozilla.com",
            "up_mbps": 100,
            "down_mbps": 500,
            "tls": {
                "enabled": true,
                "alpn": [
                    "h3"
                ],
                "certificate_path": "${HYSTERIA_CERT_PEM}",
                "key_path": "${HYSTERIA_CERT_KEY}",
                "server_name": "${hy2_masquerade_cn}"
            }
        }
    ],
    "outbounds": [
        {
            "type": "direct",
            "tag": "direct"
        },
        {
            "type": "block",
            "tag": "block"
        }
    ],
    "route": {
        "rules": [
            {
                "protocol": "dns",
                "outbound": "direct"
            }
        ]
    }
}
EOF

    info "正在校验配置文件..."
    if $SINGBOX_CMD check -c "$SINGBOX_CONFIG_FILE"; then
        success "配置文件语法正确。"
        info "正在格式化配置文件..."
        if $SINGBOX_CMD format -c "$SINGBOX_CONFIG_FILE" -w; then
            success "配置文件格式化成功。"
        else
            warn "配置文件格式化失败，但语法可能仍正确。"
        fi
    else
        error "配置文件语法错误。请检查 ${SINGBOX_CONFIG_FILE}"
        cat "${SINGBOX_CONFIG_FILE}"
        return 1
    fi
}

create_systemd_service() {
    if [ -z "$SINGBOX_CMD" ]; then
        error "Sing-box command 未设置。无法创建 systemd 服务。"
        return 1
    fi
    info "创建/更新 systemd 服务: ${SINGBOX_SERVICE_FILE}"
    cat > "$SINGBOX_SERVICE_FILE" <<EOF
[Unit]
Description=Sing-Box Service
Documentation=https://sing-box.sagernet.org
After=network.target nss-lookup.target

[Service]
User=root
WorkingDirectory=${SINGBOX_CONFIG_DIR}
ExecStart=${SINGBOX_CMD} run -c ${SINGBOX_CONFIG_FILE}
ExecReload=/bin/kill -HUP \$MAINPID
Restart=on-failure
RestartSec=10
LimitNPROC=10000
LimitNOFILE=1000000

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable sing-box
    success "Systemd 服务已创建并设置为开机自启。"
}

start_singbox_service() {
    info "正在启动 Sing-box 服务..."
    systemctl restart sing-box
    sleep 2
    if systemctl is-active --quiet sing-box; then
        success "Sing-box 服务启动成功。"
    else
        error "Sing-box 服务启动失败。"
        journalctl -u sing-box -n 20 --no-pager
        warn "请使用 'systemctl status sing-box' 查看详细日志。"
        return 1
    fi
}

display_and_store_config_info() {
    local mode="hysteria2"
    LAST_INSTALL_MODE="$mode"

    local qrencode_is_ready=false
    if check_and_prepare_qrencode; then
        qrencode_is_ready=true
    fi

    echo -e "----------------------------------------------------"
    echo -e "${CYAN}${BOLD}Hysteria2 配置信息${NC}"
    echo -e "----------------------------------------------------"
    echo -e "服务器 IP: ${GREEN}${LAST_SERVER_IP}${NC}"
    echo -e "端口: ${GREEN}${LAST_HY2_PORT}${NC}"
    echo -e "密码: ${GREEN}${LAST_HY2_PASSWORD}${NC}"
    echo -e "SNI (证书 CN): ${GREEN}${LAST_HY2_MASQUERADE_CN}${NC}"
    
    # 生成 Hysteria2 链接 (自签名证书需要添加 insecure=1)
    LAST_HY2_LINK="hy2://${LAST_HY2_PASSWORD}@${LAST_SERVER_IP}:${LAST_HY2_PORT}?insecure=1&sni=${LAST_HY2_MASQUERADE_CN}#Hysteria2_${LAST_SERVER_IP}"
    echo -e "链接: ${MAGENTA}${LAST_HY2_LINK}${NC}"
    
    # 生成二维码
    if [ "$qrencode_is_ready" = true ]; then
        echo -e "二维码:"
        qrencode -t ANSIUTF8 "${LAST_HY2_LINK}"
    fi
    echo -e "----------------------------------------------------"

    save_persistent_info
}

install_hysteria2() {
    info "开始安装 Hysteria2..."
    
    # 1. 安装 Sing-box 核心
    if ! install_singbox_core; then
        error "Sing-box 核心安装失败，无法继续。"
        return 1
    fi

    # 2. 获取服务器 IP
    get_server_ip

    # 3. 配置 Hysteria2 端口
    read -p "请输入 Hysteria2 端口 (默认: ${DEFAULT_HYSTERIA_PORT}): " input_hy2_port
    LAST_HY2_PORT=${input_hy2_port:-$DEFAULT_HYSTERIA_PORT}

    # 4. 生成或使用密码
    read -p "是否生成随机密码? (Y/n): " gen_pwd_choice
    if [[ "$gen_pwd_choice" =~ ^[Nn]$ ]]; then
        read -p "请输入自定义密码: " input_hy2_password
        if [ -z "$input_hy2_password" ]; then
            error "密码不能为空。"
            return 1
        fi
        LAST_HY2_PASSWORD="$input_hy2_password"
    else
        LAST_HY2_PASSWORD=$(generate_random_password)
        info "生成的随机密码: ${LAST_HY2_PASSWORD}"
    fi

    # 5. 配置 SNI/证书 CN
    read -p "请输入 SNI/证书 CN (默认: ${DEFAULT_HYSTERIA_MASQUERADE_CN}): " input_masquerade_cn
    LAST_HY2_MASQUERADE_CN=${input_masquerade_cn:-$DEFAULT_HYSTERIA_MASQUERADE_CN}

    # 6. 生成自签名证书
    if ! generate_self_signed_cert "$LAST_HY2_MASQUERADE_CN"; then
        error "证书生成失败，无法继续。"
        return 1
    fi

    # 7. 创建配置文件
    if ! create_config_json "$LAST_HY2_PORT" "$LAST_HY2_PASSWORD" "$LAST_HY2_MASQUERADE_CN"; then
        error "配置文件创建失败，无法继续。"
        return 1
    fi

    # 8. 创建 systemd 服务
    if ! create_systemd_service; then
        error "服务创建失败，无法继续。"
        return 1
    fi

    # 9. 启动服务
    if ! start_singbox_service; then
        error "服务启动失败。"
        return 1
    fi

    # 10. 显示配置信息
    display_and_store_config_info

    success "Hysteria2 安装完成！"
}

# 主菜单及其他管理功能可根据需要补充
main() {
    check_root
    check_dependencies
    find_and_set_singbox_cmd
    load_persistent_info
    print_author_info

    # 简化版主菜单，仅保留 Hysteria2 安装选项
    echo -e "\n${BOLD}请选择操作:${NC}"
    echo -e " 1. 安装 Hysteria2"
    echo -e " 0. 退出"
    read -p "请输入选项 [0-1]: " choice

    case $choice in
        1) install_hysteria2 ;;
        0) info "退出脚本。" ; exit 0 ;;
        *) error "无效选项。" ;;
    esac
}

main