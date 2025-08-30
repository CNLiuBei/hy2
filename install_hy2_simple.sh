#!/bin/bash
# Hysteria2 一键安装脚本
# 基于 lvhy.sh 精简优化
# 适用于 Linux 服务器环境，支持 systemd 的发行版
# 脚本特点：一键安装、自动配置、彩色输出、客户端配置生成、systemd 服务管理
# GitHub: https://github.com/YOUR_USERNAME/YOUR_REPOSITORY

# --- 颜色定义 ---#
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
MAGENTA='\033[0;35m'
CYAN='\033[0;36m'
BOLD='\033[1m'
UNDERLINE='\033[4m'
NC='\033[0m' # 无颜色

# --- 配置参数 ---#
HY2_INSTALL_PATH="/usr/bin"
HY2_CONFIG_PATH="/etc/hysteria2"
HY2_CERT_DIR="/etc/hysteria2/certs"
HY2_SERVICE_FILE="/etc/systemd/system/hysteria2.service"
HY2_VERSION="v2.6.1"
DEFAULT_HY2_PORT="8443"
DEFAULT_HY2_MASQUERADE_CN="bing.com"

# --- 辅助函数 ---#
info() { echo -e "${BLUE}[INFO]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; }
success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }

# 检查root权限
check_root() {
    if [ "$(id -u)" -ne 0 ]; then
        error "此脚本需要以 root 权限运行。请使用 'sudo bash $0'"
        exit 1
    fi
}

# 检查并安装依赖
check_dependencies() {
    info "检查核心依赖..."
    local core_deps=()
    local install_deps=()
    
    # 检查必要命令
    if ! command -v curl &>/dev/null; then install_deps+=("curl"); fi
    if ! command -v openssl &>/dev/null; then install_deps+=("openssl"); fi
    if ! command -v systemctl &>/dev/null; then 
        error "未找到 systemd，此脚本需要 systemd 来管理服务"
        info "请在支持 systemd 的 Linux 发行版上运行此脚本（如 Ubuntu 16.04+, Debian 8+, CentOS 7+ 等）"
        exit 1
    fi
    
    # 安装缺失的依赖
    if [ ${#install_deps[@]} -gt 0 ]; then
        info "正在安装缺失的依赖: ${install_deps[*]}"
        if command -v apt-get &>/dev/null; then
            apt-get update -y && apt-get install -y "${install_deps[@]}"
        elif command -v yum &>/dev/null; then
            yum install -y "${install_deps[@]}"
        elif command -v dnf &>/dev/null; then
            dnf install -y "${install_deps[@]}"
        else
            error "未找到已知的包管理器 (apt, yum, dnf)。请手动安装依赖: ${install_deps[*]}"
            exit 1
        fi
    fi
    success "核心依赖检查通过。"
}

# 检查系统架构
check_arch() {
    case $(uname -m) in
        x86_64) ARCH="amd64" ;;
        aarch64) ARCH="arm64" ;;
        armv7l) ARCH="armv7" ;;
        *) 
            error "不支持的系统架构: $(uname -m)"
            exit 1 
            ;;
    esac
    info "检测到系统架构: $(uname -m) -> ${ARCH}"
}

# 获取服务器IP
get_server_ip() {
    # 尝试多个IP获取服务，增加可靠性
    local ip_services=(
        "curl -s --max-time 5 ip.sb"
        "curl -s --max-time 5 https://api.ipify.org"
        "curl -s --max-time 5 https://checkip.amazonaws.com"
        "curl -s --max-time 5 https://icanhazip.com"
        "curl -s --max-time 5 https://ipinfo.io/ip"
    )
    
    for service in "${ip_services[@]}"; do
        SERVER_IP=$($service 2>/dev/null)
        if [ -n "$SERVER_IP" ]; then
            # 确保获取的是有效的IP地址
            if [[ "$SERVER_IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
                break
            fi
        fi
        SERVER_IP=""
    done
    
    if [ -z "$SERVER_IP" ]; then
        warn "无法自动获取服务器公网 IP"
        read -p "请输入你的服务器公网 IP: " MANUAL_SERVER_IP
        if [ -z "$MANUAL_SERVER_IP" ]; then
            error "未提供服务器IP，无法继续"
            exit 1
        fi
        SERVER_IP="$MANUAL_SERVER_IP"
    fi
    
    # 检查是否为私有IP
    if [[ "$SERVER_IP" =~ ^10\. || "$SERVER_IP" =~ ^172\.(1[6-9]|2[0-9]|3[0-1])\. || "$SERVER_IP" =~ ^192\.168\. ]]; then
        warn "检测到的 IP (${SERVER_IP}) 是私有IP。如果这是公网服务器，请确保输入正确的公网IP。"
    fi
    info "服务器 IP: ${SERVER_IP}"
}

# 生成随机密码
generate_random_password() {
    openssl rand -base64 24 | tr -dc 'A-Za-z0-9' | head -c 16
}

# 下载并安装Hysteria2
download_and_install_hy2() {
    info "正在下载 Hysteria2 ${HY2_VERSION}..."
    
    # 创建临时目录
    TMP_DIR=$(mktemp -d)
    cd "$TMP_DIR" || exit 1
    
    # 下载Hysteria2二进制文件
    DOWNLOAD_URL="https://github.com/apernet/hysteria/releases/download/${HY2_VERSION}/hysteria-linux-${ARCH}"
    if ! curl -L -o hysteria "$DOWNLOAD_URL"; then
        error "下载失败，请检查网络连接或版本是否正确"
        exit 1
    fi
    
    # 安装二进制文件
    chmod +x hysteria
    mv hysteria "${HY2_INSTALL_PATH}/hysteria"
    
    # 检查安装是否成功
    if [ -f "${HY2_INSTALL_PATH}/hysteria" ]; then
        success "Hysteria2 已成功安装到 ${HY2_INSTALL_PATH}/hysteria"
        ${HY2_INSTALL_PATH}/hysteria version
    else
        error "安装失败，请检查权限"
        exit 1
    fi
    
    # 清理临时目录
    rm -rf "$TMP_DIR"
}

# 生成自签名证书
generate_self_signed_cert() {
    local domain_cn="$1"
    
    info "正在为 Hysteria2 生成自签名证书 (CN=${domain_cn})..."
    mkdir -p "$HY2_CERT_DIR"
    
    # 生成私钥和证书
    openssl ecparam -genkey -name prime256v1 -out "${HY2_CERT_DIR}/server.key"
    openssl req -new -x509 -days 36500 -key "${HY2_CERT_DIR}/server.key" -out "${HY2_CERT_DIR}/server.crt" -subj "/CN=${domain_cn}"
    
    if [ $? -eq 0 ]; then
        success "自签名证书生成成功"
        info "证书: ${HY2_CERT_DIR}/server.crt"
        info "私钥: ${HY2_CERT_DIR}/server.key"
    else
        error "自签名证书生成失败"
        exit 1
    fi
}

# 创建配置文件
create_config_file() {
    local port="$1"
    local password="$2"
    local sni="$3"
    
    info "正在创建 Hysteria2 配置文件..."
    mkdir -p "$HY2_CONFIG_PATH"
    
    cat > "${HY2_CONFIG_PATH}/config.yaml" << EOF
# Hysteria2 服务端配置
listen: :$port

tls:
  cert: ${HY2_CERT_DIR}/server.crt
  key: ${HY2_CERT_DIR}/server.key
  server_name: $sni

auth:
  type: password
  password: $password

# 流量控制配置
quic:
  initStreamReceiveWindow: 16777216
  maxStreamReceiveWindow: 67108864
  initConnectionReceiveWindow: 33554432
  maxConnectionReceiveWindow: 134217728
  disablePathMTUDiscovery: false

# 带宽配置
bandwidth:
  up: 100 mbps
  down: 500 mbps

# 日志配置
log:
  level: info
  format: text
EOF
    
    success "配置文件已创建: ${HY2_CONFIG_PATH}/config.yaml"
}

# 创建系统服务
create_systemd_service() {
    info "创建 Hysteria2 systemd 服务..."
    
    cat > "$HY2_SERVICE_FILE" << EOF
[Unit]
Description=Hysteria2 - A powerful, lightning fast and censorship resistant proxy
After=network.target nss-lookup.target

[Service]
Type=simple
ExecStart=${HY2_INSTALL_PATH}/hysteria server --config ${HY2_CONFIG_PATH}/config.yaml
Restart=on-failure
RestartSec=5s
LimitNPROC=10000
LimitNOFILE=1000000

[Install]
WantedBy=multi-user.target
EOF
    
    # 启用并启动服务
    systemctl daemon-reload
    systemctl enable hysteria2
    systemctl start hysteria2
    
    # 检查服务状态
    sleep 2
    if systemctl is-active --quiet hysteria2; then
        success "Hysteria2 服务已成功启动"
    else
        error "Hysteria2 服务启动失败"
        systemctl status hysteria2 --no-pager
        warn "请使用 'journalctl -u hysteria2 -e' 查看详细日志"
        exit 1
    fi
}

# 显示客户端配置信息
display_client_config() {
    local server_ip="$1"
    local port="$2"
    local password="$3"
    local sni="$4"
    
    echo -e "\n${CYAN}${BOLD}==== 客户端配置信息 ====${NC}\n"
    echo -e "${GREEN}服务器地址:${NC} ${server_ip}"
    echo -e "${GREEN}端口:${NC} ${port}"
    echo -e "${GREEN}密码:${NC} ${password}"
    echo -e "${GREEN}SNI/主机名:${NC} ${sni}"
    echo -e "${GREEN}ALPN:${NC} h3"
    echo -e "${GREEN}允许不安全连接 (自签证书):${NC} 是/True"
    
    # 生成客户端链接
    local client_link="hy2://${password}@${server_ip}:${port}?sni=${sni}&alpn=h3&insecure=1#Hysteria2-Server"
    echo -e "\n${CYAN}客户端导入链接:${NC}"
    echo -e "${GREEN}${client_link}${NC}\n"
    
    # 显示客户端配置文件示例
    echo -e "${CYAN}客户端配置文件示例:${NC}"
    cat << EOF
# 保存为 config.yaml
server: "$server_ip:$port"

tls:
  sni: $sni
  insecure: true

auth: $password

quic:
  initStreamReceiveWindow: 16777216
  maxStreamReceiveWindow: 67108864
  initConnectionReceiveWindow: 33554432
  maxConnectionReceiveWindow: 134217728
  disablePathMTUDiscovery: false

bandwidth:
  up: 10 mbps
  down: 50 mbps

outbounds:
  - type: direct
EOF
    
    echo -e "\n${YELLOW}注意: 请妥善保存以上信息，客户端连接时需要使用${NC}"
    echo -e "${YELLOW}提示: 生产环境建议使用正式的SSL证书替换自签名证书${NC}\n"
}

# 显示安装完成信息
display_completion_info() {
    echo -e "${MAGENTA}${BOLD}================================================${NC}"
    echo -e "${GREEN}${BOLD} Hysteria2 一键安装完成！${NC}"
    echo -e "${MAGENTA}${BOLD}================================================${NC}\n"
    
    echo -e "${BLUE}管理命令:${NC}"
    echo -e "  启动服务: systemctl start hysteria2"
    echo -e "  停止服务: systemctl stop hysteria2"
    echo -e "  重启服务: systemctl restart hysteria2"
    echo -e "  查看状态: systemctl status hysteria2"
    echo -e "  查看日志: journalctl -u hysteria2 -f"
    echo -e "\n"
    echo -e "${BLUE}配置文件路径:${NC} ${HY2_CONFIG_PATH}/config.yaml"
    echo -e "${BLUE}修改配置后需要重启服务使配置生效${NC}\n"
    
    # 添加防火墙规则提示
    echo -e "${YELLOW}防火墙设置提示:${NC}"
    if command -v ufw &>/dev/null; then
        echo -e "  Ubuntu/Debian 系统: sudo ufw allow $hy2_port/tcp && sudo ufw allow $hy2_port/udp"
    elif command -v firewall-cmd &>/dev/null; then
        echo -e "  CentOS/RHEL 系统: sudo firewall-cmd --permanent --add-port=$hy2_port/tcp && sudo firewall-cmd --permanent --add-port=$hy2_port/udp && sudo firewall-cmd --reload"
    else
        echo -e "  请确保您的防火墙已开放端口 $hy2_port (TCP/UDP)"
    fi
    echo -e "\n"
    
    echo -e "${CYAN}脚本来源: https://github.com/YOUR_USERNAME/YOUR_REPOSITORY${NC}\n"}

# 主函数
main() {
    echo -e "${MAGENTA}${BOLD}================================================${NC}"
    echo -e "${CYAN}${BOLD} Hysteria2 一键安装脚本 ${NC}"
    echo -e "${MAGENTA}${BOLD}================================================${NC}\n"
    echo -e "正在安装 Hysteria2 版本: ${HY2_VERSION}\n"
    
    # 检查环境
    check_root
    check_dependencies
    check_arch
    
    # 获取配置信息
    get_server_ip
    read -p "请输入 Hysteria2 监听端口 (默认: ${DEFAULT_HY2_PORT}): " hy2_port
    hy2_port=${hy2_port:-$DEFAULT_HY2_PORT}
    read -p "请输入 伪装域名/SNI (默认: ${DEFAULT_HY2_MASQUERADE_CN}): " hy2_sni
    hy2_sni=${hy2_sni:-$DEFAULT_HY2_MASQUERADE_CN}
    
    # 生成密码
    hy2_password=$(generate_random_password)
    info "生成的随机密码: ${hy2_password}"
    
    # 开始安装
    download_and_install_hy2
    generate_self_signed_cert "$hy2_sni"
    create_config_file "$hy2_port" "$hy2_password" "$hy2_sni"
    create_systemd_service
    
    # 显示客户端配置和完成信息
    display_client_config "$SERVER_IP" "$hy2_port" "$hy2_password" "$hy2_sni"
    display_completion_info
}

# 执行主函数
main