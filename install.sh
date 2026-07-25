#!/bin/bash

# ============================================================
# Backhaul Tunnel Manager — v15 (Fully Fixed)
# 
# Default ports:
#   - Server listen port: 8443 (client connects here)
#   - Tunnel port: 2020 (forwards to target, e.g., 2020=22)
# ============================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
PURPLE='\033[0;35m'
BLUE='\033[0;34m'
WHITE='\033[1;37m'
DIM='\033[2m'
BOLD='\033[1m'
BLINK='\033[5m'
REVERSE='\033[7m'
NC='\033[0m'

REPO="Musixal/Backhaul"
INSTALL_DIR="/root/backhaul-core"
BINARY="${INSTALL_DIR}/backhaul"
CONFIG_DIR="${INSTALL_DIR}/configs"
CERTS_DIR="${INSTALL_DIR}/certs"
WATCHDOG_SCRIPT="${INSTALL_DIR}/watchdog.sh"
WATCHDOG_LOG="${INSTALL_DIR}/watchdog.log"
WATCHDOG_STATE_DIR="${INSTALL_DIR}/watchdog-state"
WATCHDOG_IDLE_THRESHOLD=30
DEFAULT_TOKEN="Backhaul2024Secure"

# ============================================================
# Logging Helpers
# ============================================================

_ts() { date '+%H:%M:%S'; }
info() { echo -e "${DIM}$(_ts)${NC} ${CYAN}[INFO]${NC}  $*"; }
ok() { echo -e "${DIM}$(_ts)${NC} ${GREEN}[ OK ]${NC}  $*"; }
warn() { echo -e "${DIM}$(_ts)${NC} ${YELLOW}[WARN]${NC}  $*"; }
step() { echo -e "${DIM}$(_ts)${NC} ${MAGENTA}[STEP]${NC}  $*"; }
error() { echo -e "${DIM}$(_ts)${NC} ${RED}[ERR ]${NC}  $*"; }
success() { echo -e "\n${GREEN}${BOLD}✓ $*${NC}"; }
hr() { echo -e "\n${BOLD}${CYAN}═══════════════════════════════════════════════════════════${NC}"; echo -e "${BOLD}${CYAN}  $*${NC}"; echo -e "${BOLD}${CYAN}═══════════════════════════════════════════════════════════${NC}"; }

ask() {
    local var="$1" 
    local prompt="$2" 
    local default="$3"
    local input
    if [ -n "$default" ]; then
        echo -ne "${YELLOW}➜${NC} $prompt ${DIM}[${default}]${NC}: "
    else
        echo -ne "${YELLOW}➜${NC} $prompt: "
    fi
    read -r input
    [ -z "$input" ] && [ -n "$default" ] && input="$default"
    eval "$var=\"\$input\""
}

confirm() {
    local prompt="$1"
    local default="${2:-n}"
    local input
    echo -ne "${YELLOW}❓${NC} $prompt ${DIM}[${default}]${NC}: "
    read -r input
    [ -z "$input" ] && input="$default"
    [[ "$input" =~ ^[Yy]$ ]]
}

ask_required() {
    local var="$1" 
    local prompt="$2"
    while true; do
        ask "$var" "$prompt" ""
        eval "local val=\$$var"
        [ -n "$val" ] && break
        warn "This field is required."
    done
}

if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}╔══════════════════════════════════════════════════════════╗${NC}"
    echo -e "${RED}║  ❌ ERROR: Please run as root (sudo)                    ║${NC}"
    echo -e "${RED}╚══════════════════════════════════════════════════════════╝${NC}"
    exit 1
fi

mkdir -p "$INSTALL_DIR" "$CONFIG_DIR" "$CERTS_DIR"

# ============================================================
# Core Functions
# ============================================================

detect_interface() {
    ip -o -4 route show to default | awk '{print $5}' | head -n1 || echo "eth0"
}

generate_port() {
    echo $(( (RANDOM % 30000) + 20000 ))
}

ensure_dirs() {
    mkdir -p "$INSTALL_DIR" "$CONFIG_DIR" "$CERTS_DIR"
}

# ============================================================
# Binary Management
# ============================================================

download_backhaul() {
    ensure_dirs
    step "Checking latest Backhaul release..."
    
    local LATEST_VERSION
    LATEST_VERSION=$(curl -fsSL "https://api.github.com/repos/${REPO}/releases/latest" 2>/dev/null | grep '"tag_name":' | head -1 | sed -E 's/.*"([^"]+)".*/\1/')
    
    if [ -z "$LATEST_VERSION" ]; then
        warn "Cannot reach GitHub. Using existing binary if available."
        [ -x "$BINARY" ] && return 0
        error "No binary available. Please check internet connection."
        return 1
    fi
    
    info "Latest version: ${LATEST_VERSION}"
    
    local CURRENT_VERSION=""
    [ -x "$BINARY" ] && CURRENT_VERSION=$("$BINARY" -v 2>&1 | grep -oE 'v?[0-9]+\.[0-9]+(\.[0-9]+)?' | head -1)
    
    if [ -n "$CURRENT_VERSION" ] && [ "$CURRENT_VERSION" = "$LATEST_VERSION" ]; then
        ok "Already latest version (${CURRENT_VERSION})"
        return 0
    fi
    
    local arch
    case $(uname -m) in
        x86_64)  arch="amd64" ;;
        aarch64) arch="arm64" ;;
        *) error "Unsupported architecture: $(uname -m)"; return 1 ;;
    esac
    
    local URL
    URL=$(curl -fsSL "https://api.github.com/repos/${REPO}/releases/latest" | \
          grep "browser_download_url" | grep "linux_${arch}" | grep -v ".sha256" | \
          head -n1 | cut -d '"' -f4)
    
    if [ -z "$URL" ]; then
        error "Could not find download URL"
        return 1
    fi
    
    [ -x "$BINARY" ] && cp "$BINARY" "${BINARY}.backup"
    
    step "Downloading Backhaul ${LATEST_VERSION}..."
    if curl -fSL --retry 3 --retry-delay 2 -o "${INSTALL_DIR}/backhaul.tar.gz" "$URL"; then
        if tar -xzf "${INSTALL_DIR}/backhaul.tar.gz" -C "$INSTALL_DIR" 2>/dev/null; then
            rm -f "${INSTALL_DIR}/backhaul.tar.gz" "${BINARY}.backup"
            chmod +x "$BINARY"
            ok "Binary updated to ${LATEST_VERSION}"
            return 0
        fi
    fi
    
    warn "Download/installation failed"
    [ -f "${BINARY}.backup" ] && mv -f "${BINARY}.backup" "$BINARY"
    return 1
}

ensure_binary() {
    if [ -x "$BINARY" ]; then
        return 0
    fi
    
    warn "Backhaul binary not found."
    if confirm "Download latest release now?" "y"; then
        download_backhaul
        return $?
    fi
    return 1
}

# ============================================================
# SSL Certificate Management
# ============================================================

generate_self_signed_cert() {
    local name="$1"
    local cert_file="${CERTS_DIR}/${name}.crt"
    local key_file="${CERTS_DIR}/${name}.key"
    
    if [ ! -f "$cert_file" ] || [ ! -f "$key_file" ]; then
        info "Generating self-signed certificate for ${name}..."
        openssl req -x509 -newkey rsa:2048 -nodes \
            -keyout "$key_file" -out "$cert_file" \
            -days 3650 -subj "/CN=backhaul-${name}" 2>/dev/null
        chmod 600 "$key_file"
        chmod 644 "$cert_file"
    fi
    
    echo "$cert_file|$key_file"
}

setup_ssl() {
    local service_name="$1"
    local transport="$2"
    
    if [[ "$transport" != "wss" && "$transport" != "wssmux" ]]; then
        echo ""
        return 0
    fi
    
    echo ""
    echo -e "  ${BOLD}🔐 TLS Certificate Options:${NC}"
    echo -e "    ${GREEN}1)${NC}  Self-signed ${DIM}(quick test)${NC}"
    echo -e "    ${GREEN}2)${NC}  Let's Encrypt ${DIM}(requires domain)${NC}"
    echo -e "    ${GREEN}3)${NC}  Custom certificate"
    echo ""
    
    local choice
    ask choice "Select option" "1"
    
    case "$choice" in
        1|"self")
            local cert_info
            cert_info=$(generate_self_signed_cert "$service_name")
            echo "$cert_info"
            return 0
            ;;
        2|"letsencrypt")
            local domain
            ask_required domain "Domain name (e.g., tunnel.example.com)"
            
            if command -v certbot &>/dev/null || apt-get install -y certbot 2>/dev/null || yum install -y certbot 2>/dev/null; then
                if certbot certonly --standalone --non-interactive --agree-tos \
                    --register-unsafely-without-email -d "$domain" 2>/dev/null; then
                    echo "/etc/letsencrypt/live/${domain}/fullchain.pem|/etc/letsencrypt/live/${domain}/privkey.pem"
                    return 0
                fi
            fi
            error "Let's Encrypt failed. Using self-signed..."
            local cert_info
            cert_info=$(generate_self_signed_cert "$service_name")
            echo "$cert_info"
            return 0
            ;;
        3|"custom")
            local cert_file
            local key_file
            ask cert_file "Certificate file path"
            ask key_file "Private key file path"
            if [ -f "$cert_file" ] && [ -f "$key_file" ]; then
                echo "$cert_file|$key_file"
                return 0
            fi
            error "Certificate files not found. Using self-signed..."
            local cert_info
            cert_info=$(generate_self_signed_cert "$service_name")
            echo "$cert_info"
            return 0
            ;;
        *)
            local cert_info
            cert_info=$(generate_self_signed_cert "$service_name")
            echo "$cert_info"
            return 0
            ;;
    esac
}

# ============================================================
# Configuration Generation
# ============================================================

declare -A PROFILE_VALUES
init_profiles() {
    PROFILE_VALUES["auto_keepalive"]=20
    PROFILE_VALUES["auto_heartbeat"]=15
    PROFILE_VALUES["auto_channel_size"]=16384
    PROFILE_VALUES["auto_mux_con"]=8
    PROFILE_VALUES["auto_conn_pool"]=8
    PROFILE_VALUES["auto_aggressive"]=true
    PROFILE_VALUES["auto_retry"]=1
    PROFILE_VALUES["auto_log_level"]="warn"
    
    PROFILE_VALUES["stable_keepalive"]=30
    PROFILE_VALUES["stable_heartbeat"]=20
    PROFILE_VALUES["stable_channel_size"]=4096
    PROFILE_VALUES["stable_mux_con"]=8
    PROFILE_VALUES["stable_conn_pool"]=8
    PROFILE_VALUES["stable_aggressive"]=false
    PROFILE_VALUES["stable_retry"]=3
    PROFILE_VALUES["stable_log_level"]="info"
    
    PROFILE_VALUES["aggressive_keepalive"]=10
    PROFILE_VALUES["aggressive_heartbeat"]=8
    PROFILE_VALUES["aggressive_channel_size"]=32768
    PROFILE_VALUES["aggressive_mux_con"]=16
    PROFILE_VALUES["aggressive_conn_pool"]=16
    PROFILE_VALUES["aggressive_aggressive"]=true
    PROFILE_VALUES["aggressive_retry"]=1
    PROFILE_VALUES["aggressive_log_level"]="warn"
    
    PROFILE_VALUES["low_latency_keepalive"]=10
    PROFILE_VALUES["low_latency_heartbeat"]=5
    PROFILE_VALUES["low_latency_channel_size"]=2048
    PROFILE_VALUES["low_latency_mux_con"]=4
    PROFILE_VALUES["low_latency_conn_pool"]=4
    PROFILE_VALUES["low_latency_aggressive"]=false
    PROFILE_VALUES["low_latency_retry"]=1
    PROFILE_VALUES["low_latency_log_level"]="info"
    
    PROFILE_VALUES["low_hardware_keepalive"]=60
    PROFILE_VALUES["low_hardware_heartbeat"]=30
    PROFILE_VALUES["low_hardware_channel_size"]=1024
    PROFILE_VALUES["low_hardware_mux_con"]=2
    PROFILE_VALUES["low_hardware_conn_pool"]=2
    PROFILE_VALUES["low_hardware_aggressive"]=false
    PROFILE_VALUES["low_hardware_retry"]=5
    PROFILE_VALUES["low_hardware_log_level"]="info"
}

select_profile() {
    init_profiles
    echo ""
    echo -e "  ${BOLD}⚡ Tuning Profile:${NC}"
    echo -e "    ${GREEN}1)${NC}  auto          ${DIM}— Balanced, recommended default${NC}"
    echo -e "    ${GREEN}2)${NC}  stable        ${DIM}— Conservative, stable connections${NC}"
    echo -e "    ${GREEN}3)${NC}  aggressive    ${DIM}— Maximum throughput${NC}"
    echo -e "    ${GREEN}4)${NC}  low_latency   ${DIM}— Minimum delay${NC}"
    echo -e "    ${GREEN}5)${NC}  low_hardware  ${DIM}— For weak VPS${NC}"
    echo -e "    ${GREEN}6)${NC}  custom        ${DIM}— Manual configuration${NC}"
    echo ""
    
    local choice
    ask choice "Select profile" "1"
    
    local profile="auto"
    case "$choice" in
        2|stable) profile="stable" ;;
        3|aggressive) profile="aggressive" ;;
        4|low_latency) profile="low_latency" ;;
        5|low_hardware) profile="low_hardware" ;;
        6|custom) profile="custom" ;;
        *) profile="auto" ;;
    esac
    
    if [ "$profile" = "custom" ]; then
        ask KEEPALIVE "keepalive_period (sec)" "20"
        ask HEARTBEAT "heartbeat (sec)" "15"
        ask CHANNEL_SIZE "channel_size" "16384"
        ask MUX_CON "mux_con" "8"
        ask CONN_POOL "connection_pool (client)" "8"
        ask AGGRESSIVE "aggressive_pool (true/false)" "true"
        ask RETRY_INTERVAL "retry_interval (client, sec)" "1"
        ask LOG_LEVEL "log_level (info/warn/error)" "warn"
    else
        KEEPALIVE="${PROFILE_VALUES["${profile}_keepalive"]}"
        HEARTBEAT="${PROFILE_VALUES["${profile}_heartbeat"]}"
        CHANNEL_SIZE="${PROFILE_VALUES["${profile}_channel_size"]}"
        MUX_CON="${PROFILE_VALUES["${profile}_mux_con"]}"
        CONN_POOL="${PROFILE_VALUES["${profile}_conn_pool"]}"
        AGGRESSIVE="${PROFILE_VALUES["${profile}_aggressive"]}"
        RETRY_INTERVAL="${PROFILE_VALUES["${profile}_retry"]}"
        LOG_LEVEL="${PROFILE_VALUES["${profile}_log_level"]}"
    fi
    
    ok "Profile: ${profile} applied"
}

# ============================================================
# Install Server
# ============================================================

install_server() {
    hr "🚀 Install Server (Iran Side)"
    ensure_dirs
    ensure_binary || return 1
    
    # Service name
    local service_name
    while true; do
        ask service_name "Service name (e.g., iran1, server-main)" "iran1"
        if [ -n "$service_name" ] && [[ "$service_name" =~ ^[A-Za-z0-9_-]+$ ]]; then
            break
        fi
        warn "Use only letters, numbers, - and _"
    done
    
    # Transport
    echo ""
    echo -e "  ${BOLD}🌐 Transports:${NC}"
    echo -e "    ${GREEN}1)${NC}  tcp"
    echo -e "    ${GREEN}2)${NC}  tcpmux"
    echo -e "    ${GREEN}3)${NC}  ws"
    echo -e "    ${GREEN}4)${NC}  wsmux"
    echo -e "    ${GREEN}5)${NC}  wss     ${DIM}(recommended)${NC}"
    echo -e "    ${GREEN}6)${NC}  wssmux  ${DIM}(recommended for many connections)${NC}"
    echo ""
    local transport_choice
    ask transport_choice "Select transport" "5"
    
    local transport
    case "$transport_choice" in
        1|tcp) transport="tcp" ;;
        2|tcpmux) transport="tcpmux" ;;
        3|ws) transport="ws" ;;
        4|wsmux) transport="wsmux" ;;
        5|wss) transport="wss" ;;
        6|wssmux) transport="wssmux" ;;
        *) transport="wss" ;;
    esac
    
    # Listen port (where client connects)
    local listen_port
    echo ""
    echo -e "${DIM}  This is the port clients connect to.${NC}"
    ask listen_port "Server listen port" "8443"
    warn "⚠️  Make sure port ${listen_port} is open in firewall"
    
    # Token
    local token
    echo ""
    ask token "Token/PSK (must match client)" "$DEFAULT_TOKEN"
    
    # SSL for WSS
    local cert_file=""
    local key_file=""
    if [[ "$transport" =~ ^wss ]]; then
        local cert_info
        cert_info=$(setup_ssl "$service_name" "$transport")
        if [ -n "$cert_info" ] && [ "$cert_info" != "" ]; then
            cert_file="${cert_info%|*}"
            key_file="${cert_info#*|}"
        fi
    fi
    
    # Ports to forward (DEFAULT TUNNEL PORT: 2020)
    echo ""
    echo -e "${BOLD}🔀 Port Forwarding Rules:${NC}"
    echo -e "  ${DIM}Format: local_port=target_port (e.g., 2020=22)${NC}"
    echo -e "  ${DIM}Or just: local_port (same as target)${NC}"
    echo -e "  ${DIM}Default tunnel port is ${GREEN}2020${NC}${DIM} → forwards to 22${NC}"
    echo ""
    
    local ports=()
    local port_input
    ask port_input "Port to forward" "2020=22"
    if [ -n "$port_input" ]; then
        IFS=',' read -ra _parts <<< "$port_input"
        for _p in "${_parts[@]}"; do
            _p="${_p// /}"
            [ -n "$_p" ] && ports+=("$_p")
        done
    fi
    [ ${#ports[@]} -eq 0 ] && ports=("2020=22")
    
    # Show what will be forwarded
    echo ""
    for p in "${ports[@]}"; do
        if [[ "$p" == *"="* ]]; then
            local local_p="${p%%=*}"
            local target_p="${p##*=}"
            echo -e "  ${GREEN}→${NC} Port ${local_p} ${DIM}→${NC} target ${target_p}"
        else
            echo -e "  ${GREEN}→${NC} Port ${p} ${DIM}→${NC} target ${p}"
        fi
    done
    
    # Tuning profile
    select_profile
    
    # Build config
    local config_file="${CONFIG_DIR}/${service_name}.toml"
    
    # Build ports TOML
    local ports_toml=""
    local i
    for i in "${!ports[@]}"; do
        if [ $i -eq 0 ]; then
            ports_toml="    \"${ports[$i]}\""
        else
            ports_toml="${ports_toml},\n    \"${ports[$i]}\""
        fi
    done
    
    cat > "$config_file" << EOF
[server]
bind_addr = "0.0.0.0:${listen_port}"
transport = "${transport}"
token = "${token}"
keepalive_period = ${KEEPALIVE}
nodelay = true
channel_size = ${CHANNEL_SIZE}
heartbeat = ${HEARTBEAT}
mux_con = ${MUX_CON}
sniffer = false
web_port = 0
log_level = "${LOG_LEVEL}"
EOF

    if [[ "$transport" =~ ^wss ]] && [ -n "$cert_file" ] && [ -n "$key_file" ]; then
        cat >> "$config_file" << EOF
tls_cert = "${cert_file}"
tls_key = "${key_file}"
EOF
    fi

    cat >> "$config_file" << EOF

ports = [
${ports_toml}
]
EOF

    ok "Config created: ${config_file}"
    
    # Debug: show config
    info "Config content:"
    cat "$config_file"
    
    # Install systemd service
    local service_file="/etc/systemd/system/${service_name}.service"
    cat > "$service_file" << EOF
[Unit]
Description=Backhaul Server (${service_name})
After=network.target
Wants=network-online.target
StartLimitIntervalSec=0
StartLimitBurst=0

[Service]
Type=simple
User=root
ExecStart=${BINARY} -c ${config_file}
Restart=always
RestartSec=1
LimitNOFILE=1048576
TasksMax=infinity
OOMScoreAdjust=-1000
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable "${service_name}" 2>/dev/null
    systemctl restart "${service_name}"
    sleep 2
    
    if systemctl is-active --quiet "${service_name}"; then
        success "Service started successfully"
    else
        warn "⚠️  Service failed to start. Check logs:"
        journalctl -u "${service_name}" -n 20 --no-pager
        echo ""
        warn "Trying to run binary directly to see error:"
        ${BINARY} -c "${config_file}" 2>&1 | head -20
    fi
    
    # Display summary
    echo ""
    echo -e "${GREEN}${BOLD}╔══════════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}${BOLD}║  ✅  SERVER INSTALLED SUCCESSFULLY!                    ║${NC}"
    echo -e "${GREEN}${BOLD}╚══════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "  ${BOLD}📋 Summary:${NC}"
    echo -e "    ${CYAN}●${NC} Service:      ${WHITE}${service_name}${NC}"
    echo -e "    ${CYAN}●${NC} Transport:    ${WHITE}${transport}${NC}"
    echo -e "    ${CYAN}●${NC} Listen Port:  ${WHITE}${listen_port}${NC}  ${DIM}(client connects here)${NC}"
    echo -e "    ${CYAN}●${NC} Tunnel Ports: ${WHITE}${ports[*]}${NC}  ${DIM}(forwarded to target)${NC}"
    echo -e "    ${CYAN}●${NC} Token:        ${WHITE}${token}${NC}"
    echo ""
    echo -e "  ${BOLD}📂 Files:${NC}"
    echo -e "    ${CYAN}●${NC} Config: ${DIM}${config_file}${NC}"
    echo -e "    ${CYAN}●${NC} Logs:   ${DIM}journalctl -u ${service_name} -f${NC}"
    echo ""
    echo -e "  ${YELLOW}💡 Client should connect to: ${WHITE}YOUR_SERVER_IP:${listen_port}${NC}"
    echo -e "  ${YELLOW}💡 Then access: ${WHITE}YOUR_SERVER_IP:2020${NC} ${DIM}→ forwarded to target${NC}"
    echo ""
    
    if confirm "Install watchdog for auto-restart?" "y"; then
        setup_watchdog
    fi
    
    if confirm "Run system optimizer (BBR, buffers, etc.)?" "n"; then
        optimize_system
    fi
}

# ============================================================
# Install Client
# ============================================================

install_client() {
    hr "🚀 Install Client (Kharej Side)"
    ensure_dirs
    ensure_binary || return 1
    
    # Service name
    local service_name
    while true; do
        ask service_name "Service name (e.g., kharej1, client-home)" "kharej1"
        if [ -n "$service_name" ] && [[ "$service_name" =~ ^[A-Za-z0-9_-]+$ ]]; then
            break
        fi
        warn "Use only letters, numbers, - and _"
    done
    
    # Transport (MUST match server)
    echo ""
    echo -e "  ${BOLD}🌐 Transport (must match server):${NC}"
    echo -e "    ${GREEN}1)${NC}  tcp"
    echo -e "    ${GREEN}2)${NC}  tcpmux"
    echo -e "    ${GREEN}3)${NC}  ws"
    echo -e "    ${GREEN}4)${NC}  wsmux"
    echo -e "    ${GREEN}5)${NC}  wss"
    echo -e "    ${GREEN}6)${NC}  wssmux"
    echo ""
    local transport_choice
    ask transport_choice "Select transport" "5"
    
    local transport
    case "$transport_choice" in
        1|tcp) transport="tcp" ;;
        2|tcpmux) transport="tcpmux" ;;
        3|ws) transport="ws" ;;
        4|wsmux) transport="wsmux" ;;
        5|wss) transport="wss" ;;
        6|wssmux) transport="wssmux" ;;
        *) transport="wss" ;;
    esac
    
    # Server address
    local server_ip server_port
    while true; do
        local server_addr
        echo ""
        echo -e "${DIM}  Server IP and port where the Backhaul server is listening${NC}"
        ask server_addr "Server IP:PORT" "1.2.3.4:8443"
        server_ip="${server_addr%%:*}"
        server_port="${server_addr##*:}"
        if [ -n "$server_ip" ] && [ -n "$server_port" ] && [ "$server_ip" != "$server_port" ]; then
            break
        fi
        warn "Invalid format. Use IP:PORT (e.g., 1.2.3.4:8443)"
    done
    
    # Token (MUST match server)
    echo ""
    local token
    ask token "Token/PSK (must match server)" "$DEFAULT_TOKEN"
    warn "⚠️  Token must be EXACTLY the same as on server"
    
    # Tuning profile
    select_profile
    
    # Build config
    local config_file="${CONFIG_DIR}/${service_name}.toml"
    
    cat > "$config_file" << EOF
[client]
remote_addr = "${server_ip}:${server_port}"
transport = "${transport}"
token = "${token}"
connection_pool = ${CONN_POOL}
EOF

    if [[ "$AGGRESSIVE" == "true" ]]; then
        echo "aggressive_pool = true" >> "$config_file"
    else
        echo "aggressive_pool = false" >> "$config_file"
    fi

    cat >> "$config_file" << EOF
keepalive_period = ${KEEPALIVE}
channel_size = ${CHANNEL_SIZE}
mux_con = ${MUX_CON}
heartbeat = ${HEARTBEAT}
retry_interval = ${RETRY_INTERVAL}
sniffer = false
web_port = 0
log_level = "${LOG_LEVEL}"
EOF

    if [[ "$transport" =~ ^wss ]]; then
        echo "insecure_skip_verify = true" >> "$config_file"
    fi

    ok "Config created: ${config_file}"
    
    # Install systemd service
    local service_file="/etc/systemd/system/${service_name}.service"
    cat > "$service_file" << EOF
[Unit]
Description=Backhaul Client (${service_name})
After=network.target
Wants=network-online.target
StartLimitIntervalSec=0
StartLimitBurst=0

[Service]
Type=simple
User=root
ExecStart=${BINARY} -c ${config_file}
Restart=always
RestartSec=1
LimitNOFILE=1048576
TasksMax=infinity
OOMScoreAdjust=-1000
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable "${service_name}" 2>/dev/null
    systemctl restart "${service_name}"
    sleep 2
    
    if systemctl is-active --quiet "${service_name}"; then
        success "Service started successfully"
    else
        warn "⚠️  Service failed to start. Check logs:"
        journalctl -u "${service_name}" -n 20 --no-pager
    fi
    
    # Display summary
    echo ""
    echo -e "${GREEN}${BOLD}╔══════════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}${BOLD}║  ✅  CLIENT INSTALLED SUCCESSFULLY!                    ║${NC}"
    echo -e "${GREEN}${BOLD}╚══════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "  ${BOLD}📋 Summary:${NC}"
    echo -e "    ${CYAN}●${NC} Service:   ${WHITE}${service_name}${NC}"
    echo -e "    ${CYAN}●${NC} Transport: ${WHITE}${transport}${NC}"
    echo -e "    ${CYAN}●${NC} Server:    ${WHITE}${server_ip}:${server_port}${NC}"
    echo -e "    ${CYAN}●${NC} Token:     ${WHITE}${token}${NC}"
    echo ""
    echo -e "  ${BOLD}📂 Files:${NC}"
    echo -e "    ${CYAN}●${NC} Config: ${DIM}${config_file}${NC}"
    echo -e "    ${CYAN}●${NC} Logs:   ${DIM}journalctl -u ${service_name} -f${NC}"
    echo ""
    
    if confirm "Install watchdog for auto-restart?" "y"; then
        setup_watchdog
    fi
    
    if confirm "Run system optimizer (BBR, buffers, etc.)?" "n"; then
        optimize_system
    fi
}

# ============================================================
# Watchdog
# ============================================================

setup_watchdog() {
    hr "🛡️ Installing Watchdog"
    ensure_dirs
    mkdir -p "$WATCHDOG_STATE_DIR"
    
    cat > "$WATCHDOG_SCRIPT" << 'EOF'
#!/bin/bash
CONFIG_DIR="/root/backhaul-core/configs"
STATE_DIR="/root/backhaul-core/watchdog-state"
LOG_FILE="/root/backhaul-core/watchdog.log"
IDLE_THRESHOLD=30

mkdir -p "$STATE_DIR"

for cfg in "$CONFIG_DIR"/*.toml; do
    [ -f "$cfg" ] || continue
    label=$(basename "$cfg" .toml)
    unit="${label}.service"
    [ -f "/etc/systemd/system/${unit}" ] || continue
    
    if ! systemctl is-active --quiet "$unit"; then
        systemctl restart "$unit" 2>/dev/null
        echo "$(date '+%F %T') restarted $unit (was inactive)" >> "$LOG_FILE"
        rm -f "${STATE_DIR}/${unit}.last_ok"
        continue
    fi
    
    port=""
    if grep -q '^\[server\]' "$cfg"; then
        port=$(grep -oE 'bind_addr = "0\.0\.0\.0:[0-9]+"' "$cfg" | grep -oE '[0-9]+$')
    else
        port=$(grep -oE 'remote_addr = "[^:"]+:[0-9]+"' "$cfg" | grep -oE '[0-9]+$')
    fi
    [ -z "$port" ] && continue
    
    active_conns=$(ss -H -tn state established "( sport = :${port} or dport = :${port} )" 2>/dev/null | wc -l)
    now=$(date +%s)
    state_file="${STATE_DIR}/${unit}.last_ok"
    
    if [ "${active_conns:-0}" -gt 0 ]; then
        echo "$now" > "$state_file"
    else
        last_ok=$(cat "$state_file" 2>/dev/null || echo "$now")
        idle=$(( now - last_ok ))
        if [ "$idle" -ge "$IDLE_THRESHOLD" ]; then
            systemctl restart "$unit" 2>/dev/null
            echo "$now" > "$state_file"
            echo "$(date '+%F %T') restarted $unit (idle ${idle}s)" >> "$LOG_FILE"
        fi
    fi
done
EOF

    chmod +x "$WATCHDOG_SCRIPT"
    
    cat > /etc/systemd/system/backhaul-watchdog.service << EOF
[Unit]
Description=Backhaul Watchdog
[Service]
Type=oneshot
ExecStart=${WATCHDOG_SCRIPT}
EOF

    cat > /etc/systemd/system/backhaul-watchdog.timer << EOF
[Unit]
Description=Backhaul Watchdog Timer
[Timer]
OnBootSec=20
OnUnitActiveSec=10
AccuracySec=1
Unit=backhaul-watchdog.service
[Install]
WantedBy=timers.target
EOF

    systemctl daemon-reload
    systemctl enable --now backhaul-watchdog.timer 2>/dev/null
    
    ok "Watchdog installed (checks every 10s)"
}

# ============================================================
# System Optimization
# ============================================================

optimize_system() {
    hr "⚡ System Optimization"
    
    local iface
    iface=$(detect_interface)
    info "Interface: ${iface}"
    
    sysctl -w net.core.default_qdisc=fq >/dev/null 2>&1
    if sysctl -w net.ipv4.tcp_congestion_control=bbr >/dev/null 2>&1; then
        ok "BBR enabled"
    else
        warn "BBR not available"
    fi
    
    sysctl -w net.core.somaxconn=65535 >/dev/null 2>&1
    sysctl -w net.core.netdev_max_backlog=250000 >/dev/null 2>&1
    sysctl -w net.ipv4.ip_local_port_range="1024 65535" >/dev/null 2>&1
    sysctl -w net.core.rmem_max=134217728 >/dev/null 2>&1
    sysctl -w net.core.wmem_max=134217728 >/dev/null 2>&1
    sysctl -w net.ipv4.tcp_rmem="4096 87380 134217728" >/dev/null 2>&1
    sysctl -w net.ipv4.tcp_wmem="4096 65536 134217728" >/dev/null 2>&1
    ok "Network buffers optimized"
    
    sysctl -w net.ipv4.tcp_keepalive_time=60 >/dev/null 2>&1
    sysctl -w net.ipv4.tcp_keepalive_intvl=10 >/dev/null 2>&1
    sysctl -w net.ipv4.tcp_keepalive_probes=6 >/dev/null 2>&1
    sysctl -w net.ipv4.tcp_fin_timeout=15 >/dev/null 2>&1
    sysctl -w net.ipv4.tcp_mtu_probing=1 >/dev/null 2>&1
    sysctl -w net.ipv4.tcp_fastopen=3 >/dev/null 2>&1
    sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1
    ok "TCP optimized"
    
    ip link set dev "$iface" mtu 1400 2>/dev/null
    ok "MTU set to 1400"
    
    ulimit -n 1048576 2>/dev/null
    echo "fs.file-max=2097152" >> /etc/sysctl.d/99-backhaul.conf 2>/dev/null
    ok "File descriptor limits raised"
    
    cat > /etc/sysctl.d/99-backhaul.conf << EOF
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
net.core.somaxconn=65535
net.core.netdev_max_backlog=250000
net.ipv4.ip_local_port_range=1024 65535
net.core.rmem_max=134217728
net.core.wmem_max=134217728
net.ipv4.tcp_rmem=4096 87380 134217728
net.ipv4.tcp_wmem=4096 65536 134217728
net.ipv4.tcp_keepalive_time=60
net.ipv4.tcp_keepalive_intvl=10
net.ipv4.tcp_keepalive_probes=6
net.ipv4.tcp_fin_timeout=15
net.ipv4.tcp_mtu_probing=1
net.ipv4.tcp_fastopen=3
net.ipv4.ip_forward=1
EOF
    
    success "Optimization complete"
}

# ============================================================
# Management Functions
# ============================================================

list_services() {
    local services=()
    local cfg
    for cfg in "$CONFIG_DIR"/*.toml; do
        [ -f "$cfg" ] || continue
        local name
        name=$(basename "$cfg" .toml)
        [ -f "/etc/systemd/system/${name}.service" ] && services+=("$name")
    done
    printf '%s\n' "${services[@]}" | sort -u
}

pick_service() {
    local services
    services=($(list_services))
    if [ ${#services[@]} -eq 0 ]; then
        warn "No services found"
        return 1
    fi
    
    if [ ${#services[@]} -eq 1 ]; then
        SELECTED_SERVICE="${services[0]}"
        return 0
    fi
    
    echo ""
    echo -e "  ${BOLD}📋 Services:${NC}"
    local i
    for i in "${!services[@]}"; do
        local status
        status=$(systemctl is-active "${services[$i]}" 2>/dev/null)
        if [ "$status" = "active" ]; then
            echo -e "    ${GREEN}$((i+1))${NC})  ${services[$i]}  ${GREEN}● running${NC}"
        else
            echo -e "    ${RED}$((i+1))${NC})  ${services[$i]}  ${RED}○ stopped${NC}"
        fi
    done
    echo ""
    
    local choice
    ask choice "Select service" "1"
    if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le ${#services[@]} ]; then
        SELECTED_SERVICE="${services[$((choice-1))]}"
        return 0
    fi
    return 1
}

show_status() {
    hr "📊 Service Status"
    local services
    services=($(list_services))
    if [ ${#services[@]} -eq 0 ]; then
        warn "No services installed"
        return
    fi
    
    local svc
    for svc in "${services[@]}"; do
        echo ""
        echo -e "${BOLD}${CYAN}━━━ ${svc} ━━━${NC}"
        systemctl status "$svc" --no-pager --lines=5 2>/dev/null || true
        echo ""
    done
}

service_control() {
    hr "🎮 Service Control"
    if ! pick_service; then
        return
    fi
    
    local svc="$SELECTED_SERVICE"
    echo ""
    echo -e "  Selected: ${BOLD}${WHITE}${svc}${NC}"
    echo ""
    echo -e "    ${GREEN}1${NC})  Restart"
    echo -e "    ${YELLOW}2${NC})  Stop"
    echo -e "    ${GREEN}3${NC})  Start"
    echo -e "    ${BLUE}4${NC})  Status"
    echo -e "    ${CYAN}5${NC})  View logs"
    echo -e "    ${CYAN}6${NC})  Follow logs"
    echo -e "    ${RED}0${NC})  Back"
    echo ""
    
    local action
    ask action "Action" "1"
    
    case "$action" in
        1) systemctl restart "$svc" && ok "Restarted" || error "Failed" ;;
        2) systemctl stop "$svc" && ok "Stopped" || error "Failed" ;;
        3) systemctl start "$svc" && ok "Started" || error "Failed" ;;
        4) systemctl status "$svc" --no-pager ;;
        5) journalctl -u "$svc" -n 50 --no-pager ;;
        6) journalctl -u "$svc" -f ;;
        0|"") return ;;
    esac
}

edit_config() {
    hr "✏️ Edit Config"
    if ! pick_service; then
        return
    fi
    
    local config="${CONFIG_DIR}/${SELECTED_SERVICE}.toml"
    if [ ! -f "$config" ]; then
        warn "Config not found: $config"
        return
    fi
    
    local editor="${EDITOR:-}"
    [ -z "$editor" ] && command -v nano >/dev/null && editor="nano"
    [ -z "$editor" ] && command -v vim >/dev/null && editor="vim"
    [ -z "$editor" ] && command -v vi >/dev/null && editor="vi"
    
    if [ -z "$editor" ]; then
        warn "No editor found. Install nano: apt install nano"
        return
    fi
    
    cp "$config" "${config}.bak"
    info "Editing: $config"
    "$editor" "$config"
    
    if confirm "Restart service to apply changes?" "y"; then
        systemctl restart "$SELECTED_SERVICE"
        if systemctl is-active --quiet "$SELECTED_SERVICE"; then
            ok "Service running with new config"
        else
            warn "Service failed to start"
            if confirm "Revert to backup?" "y"; then
                cp "${config}.bak" "$config"
                systemctl restart "$SELECTED_SERVICE"
                ok "Reverted to backup"
            fi
        fi
    fi
}

remove_service() {
    hr "🗑️ Remove Service"
    if ! pick_service; then
        return
    fi
    
    local svc="$SELECTED_SERVICE"
    if ! confirm "Remove ${svc}?" "n"; then
        return
    fi
    
    systemctl stop "$svc" 2>/dev/null
    systemctl disable "$svc" 2>/dev/null
    rm -f "/etc/systemd/system/${svc}.service"
    rm -f "${CONFIG_DIR}/${svc}.toml"
    rm -f "${CONFIG_DIR}/${svc}.toml.bak"
    rm -f "${CERTS_DIR}/${svc}.crt" "${CERTS_DIR}/${svc}.key"
    systemctl daemon-reload
    
    ok "Removed: $svc"
}

update_binary() {
    hr "🔄 Update Binary"
    download_backhaul
}

uninstall_all() {
    hr "💀 Full Uninstall"
    if ! confirm "Remove ALL Backhaul services and files?" "n"; then
        return
    fi
    
    local services
    services=($(list_services))
    local svc
    for svc in "${services[@]}"; do
        systemctl stop "$svc" 2>/dev/null
        systemctl disable "$svc" 2>/dev/null
        rm -f "/etc/systemd/system/${svc}.service"
    done
    
    systemctl stop backhaul-watchdog.timer 2>/dev/null
    systemctl disable backhaul-watchdog.timer 2>/dev/null
    rm -f /etc/systemd/system/backhaul-watchdog.{service,timer}
    
    systemctl daemon-reload
    rm -rf "$INSTALL_DIR"
    
    success "All Backhaul files removed"
}

# ============================================================
# Main Menu
# ============================================================

show_banner() {
    clear 2>/dev/null || true
    echo ""
    echo -e "${CYAN}${BOLD}╔══════════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}${BOLD}║                                                          ║${NC}"
    echo -e "${CYAN}${BOLD}║       🚀  BACKHAUL TUNNEL MANAGER  v15                 ║${NC}"
    echo -e "${CYAN}${BOLD}║                                                          ║${NC}"
    echo -e "${CYAN}${BOLD}║       ${WHITE}Secure Reverse Port Forwarding Tool${CYAN}           ║${NC}"
    echo -e "${CYAN}${BOLD}║                                                          ║${NC}"
    echo -e "${CYAN}${BOLD}╚══════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "  ${DIM}Default tunnel port: ${GREEN}2020${NC}${DIM} → forwards to 22${NC}"
    echo -e "  ${DIM}Server listen port:  ${GREEN}8443${NC}${DIM}  (client connects here)${NC}"
    echo ""
}

show_menu() {
    echo -e "${BOLD}  ─── 📦 Installation ───${NC}"
    echo -e "    ${GREEN}1${NC})  Install Server ${DIM}(Iran side)${NC}"
    echo -e "    ${GREEN}2${NC})  Install Client ${DIM}(Kharej side)${NC}"
    echo ""
    echo -e "${BOLD}  ─── ⚙️  Management ───${NC}"
    echo -e "    ${BLUE}3${NC})  Service Status"
    echo -e "    ${BLUE}4${NC})  Service Control ${DIM}(start/stop/restart)${NC}"
    echo -e "    ${BLUE}5${NC})  Edit Config"
    echo -e "    ${BLUE}6${NC})  Remove Service"
    echo ""
    echo -e "${BOLD}  ─── 🛠️  System ───${NC}"
    echo -e "    ${MAGENTA}7${NC})  System Optimizer ${DIM}(BBR, buffers, MTU)${NC}"
    echo -e "    ${MAGENTA}8${NC})  Watchdog ${DIM}(auto-restart)${NC}"
    echo -e "    ${MAGENTA}9${NC})  Update Binary"
    echo -e "    ${RED}10${NC})  Full Uninstall"
    echo ""
    echo -e "${BOLD}  ─── 🚪 Exit ───${NC}"
    echo -e "    ${RED}0${NC})  Exit"
    echo ""
}

pause_menu() {
    echo ""
    echo -ne "${DIM}Press Enter to continue...${NC}"
    read -r _
}

# ============================================================
# Main Loop
# ============================================================

while true; do
    show_banner
    show_menu
    
    local choice
    ask choice "Select option" "0"
    
    case "$choice" in
        1) install_server ;;
        2) install_client ;;
        3) show_status ;;
        4) service_control ;;
        5) edit_config ;;
        6) remove_service ;;
        7) optimize_system ;;
        8) setup_watchdog ;;
        9) update_binary ;;
        10) uninstall_all ;;
        0) 
            echo ""
            echo -e "  ${GREEN}${BOLD}╔══════════════════════════════════════════════════════════╗${NC}"
            echo -e "  ${GREEN}${BOLD}║  👋  Goodbye!  Thanks for using Backhaul Tunnel Manager  ║${NC}"
            echo -e "  ${GREEN}${BOLD}╚══════════════════════════════════════════════════════════╝${NC}"
            echo ""
            exit 0 
            ;;
        *) 
            warn "Invalid option: $choice" 
            ;;
    esac
    
    pause_menu
done
