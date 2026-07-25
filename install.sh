#!/bin/bash

# ============================================================
# Backhaul Tunnel Manager — v15.2 (Fixed & Completed)
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

_ts() { date '+%H:%M:%S'; }
info() { echo -e "${DIM}$(_ts)${NC} ${CYAN}[INFO]${NC}  $*"; }
ok() { echo -e "${DIM}$(_ts)${NC} ${GREEN}[ OK ]${NC}  $*"; }
warn() { echo -e "${DIM}$(_ts)${NC} ${YELLOW}[WARN]${NC}  $*"; }
step() { echo -e "${DIM}$(_ts)${NC} ${MAGENTA}[STEP]${NC}  $*"; }
error() { echo -e "${DIM}$(_ts)${NC} ${RED}[ERR ]${NC}  $*"; }
success() { echo -e "\n${GREEN}${BOLD}✓ $*${NC}"; }
hr() { echo -e "\n${BOLD}${CYAN}═══════════════════════════════════════════════════════════${NC}"; echo -e "${BOLD}${CYAN}  $*${NC}"; echo -e "${BOLD}${CYAN}═══════════════════════════════════════════════════════════${NC}"; }

ask() {
    local var="$1" prompt="$2" default="$3" input
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
    local prompt="$1" default="${2:-n}" input
    echo -ne "${YELLOW}❓${NC} $prompt ${DIM}[${default}]${NC}: "
    read -r input
    [ -z "$input" ] && input="$default"
    [[ "$input" =~ ^[Yy]$ ]]
}

ask_required() {
    local var="$1" prompt="$2"
    while true; do
        ask "$var" "$prompt" ""
        eval "local val=\$$var"
        [ -n "$val" ] && break
        warn "This field is required."
    done
}

if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}╔══════════════════════════════════════════════════════════╗${NC}"
    echo -e "${RED}║    ❌ ERROR: Please run as root (sudo)                   ║${NC}"
    echo -e "${RED}╚══════════════════════════════════════════════════════════╝${NC}"
    exit 1
fi

ensure_dirs() {
    mkdir -p "$INSTALL_DIR" "$CONFIG_DIR" "$CERTS_DIR" "$WATCHDOG_STATE_DIR"
}
ensure_dirs

detect_interface() {
    ip -o -4 route show to default | awk '{print $5}' | head -n1 || echo "eth0"
}

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
        armv7l)  arch="armv7" ;;
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
    [ -x "$BINARY" ] && return 0
    warn "Backhaul binary not found."
    if confirm "Download latest release now?" "y"; then
        download_backhaul
        return $?
    fi
    return 1
}

generate_self_signed_cert() {
    local name="$1"
    local cert_file="${CERTS_DIR}/${name}.crt"
    local key_file="${CERTS_DIR}/${name}.key"
    
    if [ ! -f "$cert_file" ] || [ ! -f "$key_file" ]; then
        openssl req -x509 -newkey rsa:2048 -nodes \
            -keyout "$key_file" -out "$cert_file" \
            -days 3650 -subj "/CN=backhaul-${name}" &>/dev/null
        chmod 600 "$key_file"
        chmod 644 "$cert_file"
    fi
    
    RET_CERT_FILE="$cert_file"
    RET_KEY_FILE="$key_file"
}

setup_ssl() {
    local service_name="$1" transport="$2"
    RET_CERT_FILE=""
    RET_KEY_FILE=""

    [[ "$transport" != "wss" && "$transport" != "wssmux" ]] && return 0
    
    echo -e "\n  ${BOLD}🔐 TLS Certificate Options:${NC}"
    echo -e "    ${GREEN}1)${NC}  Self-signed ${DIM}(quick test / automatic)${NC}"
    echo -e "    ${GREEN}2)${NC}  Let's Encrypt ${DIM}(requires domain)${NC}"
    echo -e "    ${GREEN}3)${NC}  Custom certificate\n"
    
    local choice
    ask choice "Select option" "1"
    
    case "$choice" in
        2|"letsencrypt")
            local domain
            ask_required domain "Domain name (e.g., tunnel.example.com)"
            if command -v certbot &>/dev/null || apt-get install -y certbot &>/dev/null || yum install -y certbot &>/dev/null; then
                if certbot certonly --standalone --non-interactive --agree-tos \
                    --register-unsafely-without-email -d "$domain" &>/dev/null; then
                    RET_CERT_FILE="/etc/letsencrypt/live/${domain}/fullchain.pem"
                    RET_KEY_FILE="/etc/letsencrypt/live/${domain}/privkey.pem"
                    return 0
                fi
            fi
            error "Let's Encrypt failed. Falling back to self-signed..."
            generate_self_signed_cert "$service_name"
            ;;
        3|"custom")
            local cert_file key_file
            ask cert_file "Certificate file path"
            ask key_file "Private key file path"
            if [ -f "$cert_file" ] && [ -f "$key_file" ]; then
                RET_CERT_FILE="$cert_file"
                RET_KEY_FILE="$key_file"
                return 0
            fi
            error "Certificate files not found. Falling back to self-signed..."
            generate_self_signed_cert "$service_name"
            ;;
        *)
            generate_self_signed_cert "$service_name"
            ;;
    esac
}

declare -A PROFILE_VALUES
init_profiles() {
    PROFILE_VALUES["auto_keepalive"]=20; PROFILE_VALUES["auto_heartbeat"]=15; PROFILE_VALUES["auto_channel_size"]=16384; PROFILE_VALUES["auto_mux_con"]=8; PROFILE_VALUES["auto_conn_pool"]=8; PROFILE_VALUES["auto_aggressive"]=true; PROFILE_VALUES["auto_retry"]=1; PROFILE_VALUES["auto_log_level"]="warn"
    PROFILE_VALUES["stable_keepalive"]=30; PROFILE_VALUES["stable_heartbeat"]=20; PROFILE_VALUES["stable_channel_size"]=4096; PROFILE_VALUES["stable_mux_con"]=8; PROFILE_VALUES["stable_conn_pool"]=8; PROFILE_VALUES["stable_aggressive"]=false; PROFILE_VALUES["stable_retry"]=3; PROFILE_VALUES["stable_log_level"]="info"
    PROFILE_VALUES["aggressive_keepalive"]=10; PROFILE_VALUES["aggressive_heartbeat"]=8; PROFILE_VALUES["aggressive_channel_size"]=32768; PROFILE_VALUES["aggressive_mux_con"]=16; PROFILE_VALUES["aggressive_conn_pool"]=16; PROFILE_VALUES["aggressive_aggressive"]=true; PROFILE_VALUES["aggressive_retry"]=1; PROFILE_VALUES["aggressive_log_level"]="warn"
    PROFILE_VALUES["low_latency_keepalive"]=10; PROFILE_VALUES["low_latency_heartbeat"]=5; PROFILE_VALUES["low_latency_channel_size"]=2048; PROFILE_VALUES["low_latency_mux_con"]=4; PROFILE_VALUES["low_latency_conn_pool"]=4; PROFILE_VALUES["low_latency_aggressive"]=false; PROFILE_VALUES["low_latency_retry"]=1; PROFILE_VALUES["low_latency_log_level"]="info"
    PROFILE_VALUES["low_hardware_keepalive"]=60; PROFILE_VALUES["low_hardware_heartbeat"]=30; PROFILE_VALUES["low_hardware_channel_size"]=1024; PROFILE_VALUES["low_hardware_mux_con"]=2; PROFILE_VALUES["low_hardware_conn_pool"]=2; PROFILE_VALUES["low_hardware_aggressive"]=false; PROFILE_VALUES["low_hardware_retry"]=5; PROFILE_VALUES["low_hardware_log_level"]="info"
}

select_profile() {
    init_profiles
    echo -e "\n  ${BOLD}⚡ Tuning Profile:${NC}"
    echo -e "    ${GREEN}1)${NC}  auto          ${DIM}— Balanced, recommended default${NC}"
    echo -e "    ${GREEN}2)${NC}  stable        ${DIM}— Conservative, stable connections${NC}"
    echo -e "    ${GREEN}3)${NC}  aggressive    ${DIM}— Maximum throughput${NC}"
    echo -e "    ${GREEN}4)${NC}  low_latency   ${DIM}— Minimum delay${NC}"
    echo -e "    ${GREEN}5)${NC}  low_hardware  ${DIM}— For weak VPS${NC}"
    echo -e "    ${GREEN}6)${NC}  custom        ${DIM}— Manual configuration${NC}\n"
    
    local choice profile="auto"
    ask choice "Select profile" "1"
    
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

install_server() {
    hr "🚀 Install Server (Iran Side)"
    ensure_dirs && ensure_binary || return 1
    
    local service_name
    while true; do
        ask service_name "Service name" "iran1"
        [[ "$service_name" =~ ^[A-Za-z0-9_-]+$ ]] && break
        warn "Use only letters, numbers, - and _"
    done
    
    echo -e "\n  ${BOLD}🌐 Transports:${NC}"
    echo -e "    ${GREEN}1)${NC}  tcp | ${GREEN}2)${NC} tcpmux | ${GREEN}3)${NC} ws | ${GREEN}4)${NC} wsmux | ${GREEN}5)${NC} wss | ${GREEN}6)${NC} wssmux\n"
    local transport_choice transport
    ask transport_choice "Select transport" "5"
    case "$transport_choice" in
        1|tcp) transport="tcp" ;; 2|tcpmux) transport="tcpmux" ;;
        3|ws) transport="ws" ;; 4|wsmux) transport="wsmux" ;;
        5|wss) transport="wss" ;; 6|wssmux) transport="wssmux" ;;
        *) transport="wss" ;;
    esac
    
    local listen_port token
    ask listen_port "Server listen port" "8443"
    ask token "Token/PSK" "$DEFAULT_TOKEN"
    
    local cert_file="" key_file=""
    if [[ "$transport" =~ ^wss ]]; then
        setup_ssl "$service_name" "$transport"
        cert_file="$RET_CERT_FILE"
        key_file="$RET_KEY_FILE"
    fi
    
    local ports=() port_input
    ask port_input "Port to forward (e.g., 2020=2020)" "2020=2020"
    IFS=',' read -ra _parts <<< "$port_input"
    for _p in "${_parts[@]}"; do
        _p="${_p// /}"
        [ -n "$_p" ] && ports+=("$_p")
    done
    [ ${#ports[@]} -eq 0 ] && ports=("2020=2020")
    
    select_profile
    local config_file="${CONFIG_DIR}/${service_name}.toml"
    
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

    if [[ "$transport" =~ ^wss ]] && [ -n "$cert_file" ]; then
        echo "tls_cert = \"${cert_file}\"" >> "$config_file"
        echo "tls_key = \"${key_file}\"" >> "$config_file"
    fi

    echo -e "\nports = [" >> "$config_file"
    for (( i=0; i<${#ports[@]}; i++ )); do
        [ $i -eq $((${#ports[@]} - 1)) ] && echo "  \"${ports[$i]}\"" >> "$config_file" || echo "  \"${ports[$i]}\"," >> "$config_file"
    done
    echo "]" >> "$config_file"

    local service_file="/etc/systemd/system/${service_name}.service"
    cat > "$service_file" << EOF
[Unit]
Description=Backhaul Server (${service_name})
After=network.target Wants=network-online.target

[Service]
Type=simple
User=root
ExecStart=${BINARY} -c ${config_file}
Restart=always
RestartSec=1
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload && systemctl enable --now "${service_name}"
    sleep 1
    systemctl is-active --quiet "${service_name}" && success "Service started successfully" || warn "Service failed to start."
}

install_client() {
    hr "🚀 Install Client (Kharej Side)"
    ensure_dirs && ensure_binary || return 1
    
    local service_name
    while true; do
        ask service_name "Service name" "kharej1"
        [[ "$service_name" =~ ^[A-Za-z0-9_-]+$ ]] && break
        warn "Use only letters, numbers, - and _"
    done
    
    local transport_choice transport
    ask transport_choice "Select transport (1:tcp, 2:tcpmux, 3:ws, 4:wsmux, 5:wss, 6:wssmux)" "5"
    case "$transport_choice" in
        1|tcp) transport="tcp" ;; 2|tcpmux) transport="tcpmux" ;;
        3|ws) transport="ws" ;; 4|wsmux) transport="wsmux" ;;
        5|wss) transport="wss" ;; 6|wssmux) transport="wssmux" ;;
        *) transport="wss" ;;
    esac
    
    local server_addr server_ip server_port token
    ask server_addr "Server IP:PORT" "1.2.3.4:8443"
    server_ip="${server_addr%%:*}"
    server_port="${server_addr##*:}"
    ask token "Token/PSK" "$DEFAULT_TOKEN"
    
    local ports=() port_input
    ask port_input "Target mappings (e.g., 2020=127.0.0.1:2020)" "2020=127.0.0.1:2020"
    IFS=',' read -ra _parts <<< "$port_input"
    for _p in "${_parts[@]}"; do
        _p="${_p// /}"
        [ -n "$_p" ] && ports+=("$_p")
    done
    [ ${#ports[@]} -eq 0 ] && ports=("2020=127.0.0.1:2020")
    
    select_profile
    local config_file="${CONFIG_DIR}/${service_name}.toml"
    
    cat > "$config_file" << EOF
[client]
remote_addr = "${server_ip}:${server_port}"
transport = "${transport}"
token = "${token}"
connection_pool = ${CONN_POOL}
aggressive_pool = ${AGGRESSIVE}
keepalive_period = ${KEEPALIVE}
channel_size = ${CHANNEL_SIZE}
mux_con = ${MUX_CON}
heartbeat = ${HEARTBEAT}
retry_interval = ${RETRY_INTERVAL}
sniffer = false
web_port = 0
log_level = "${LOG_LEVEL}"
EOF

    [[ "$transport" =~ ^wss ]] && echo "noverify = true" >> "$config_file"

    echo -e "\nports = [" >> "$config_file"
    for (( i=0; i<${#ports[@]}; i++ )); do
        [ $i -eq $((${#ports[@]} - 1)) ] && echo "  \"${ports[$i]}\"" >> "$config_file" || echo "  \"${ports[$i]}\"," >> "$config_file"
    done
    echo "]" >> "$config_file"

    local service_file="/etc/systemd/system/${service_name}.service"
    cat > "$service_file" << EOF
[Unit]
Description=Backhaul Client (${service_name})
After=network.target Wants=network-online.target

[Service]
Type=simple
User=root
ExecStart=${BINARY} -c ${config_file}
Restart=always
RestartSec=1
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload && systemctl enable --now "${service_name}"
    sleep 1
    systemctl is-active --quiet "${service_name}" && success "Service started successfully" || warn "Service failed to start."
}

setup_watchdog() {
    hr "🛡️ Installing Watchdog"
    ensure_dirs
    
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

    systemctl daemon-reload && systemctl enable --now backhaul-watchdog.timer 2>/dev/null
    ok "Watchdog installed (checks every 10s)"
}

optimize_system() {
    hr "⚡ System Optimization"
    local iface
    iface=$(detect_interface)
    info "Interface: ${iface}"
    
    sysctl -w net.core.default_qdisc=fq >/dev/null 2>&1
    sysctl -w net.ipv4.tcp_congestion_control=bbr >/dev/null 2>&1
    sysctl -w net.core.somaxconn=65535 >/dev/null 2>&1
    sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1
    
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
    sysctl --system >/dev/null 2>&1
    success "Optimization complete"
}

list_services() {
    local services=()
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
    mapfile -t services < <(list_services)
    if [ ${#services[@]} -eq 0 ]; then
        warn "No services found"
        return 1
    fi
    
    [ ${#services[@]} -eq 1 ] && { SELECTED_SERVICE="${services[0]}"; return 0; }
    
    echo -e "\n  ${BOLD}📋 Services:${NC}"
    for i in "${!services[@]}"; do
        local status
        status=$(systemctl is-active "${services[$i]}" 2>/dev/null)
        if [ "$status" = "active" ]; then
            echo -e "    ${GREEN}$((i+1))${NC})  ${services[$i]}  ${GREEN}● running${NC}"
        else
            echo -e "    ${RED}$((i+1))${NC})  ${services[$i]}  ${RED}○ stopped${NC}"
        fi
    done
    
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
    mapfile -t services < <(list_services)
    [ ${#services[@]} -eq 0 ] && { warn "No services installed"; return; }
    
    for svc in "${services[@]}"; do
        echo -e "\n${BOLD}${CYAN}━━━ ${svc} ━━━${NC}"
        systemctl status "$svc" --no-pager --lines=5 2>/dev/null || true
    done
}

service_control() {
    hr "🎮 Service Control"
    pick_service || return
    local svc="$SELECTED_SERVICE"
    
    echo -e "\n  Action for ${BOLD}${WHITE}${svc}${NC}:"
    echo -e "    ${GREEN}1${NC}) Restart | ${YELLOW}2${NC}) Stop | ${GREEN}3${NC}) Start | ${BLUE}4${NC}) Status | ${CYAN}5${NC}) Logs | ${RED}0${NC}) Back\n"
    
    local action
    ask action "Action" "1"
    case "$action" in
        1) systemctl restart "$svc" && ok "Restarted" ;;
        2) systemctl stop "$svc" && ok "Stopped" ;;
        3) systemctl start "$svc" && ok "Started" ;;
        4) systemctl status "$svc" --no-pager ;;
        5) journalctl -u "$svc" -n 50 --no-pager ;;
        *) return ;;
    esac
}

edit_config() {
    hr "✏️ Edit Config"
    pick_service || return
    local config="${CONFIG_DIR}/${SELECTED_SERVICE}.toml"
    local editor="${EDITOR:-nano}"
    command -v "$editor" &>/dev/null || editor="vim"
    
    "$editor" "$config"
    confirm "Restart ${SELECTED_SERVICE} to apply changes?" "y" && systemctl restart "$SELECTED_SERVICE"
}

uninstall_service() {
    hr "🗑️ Uninstall Service"
    pick_service || return
    local svc="$SELECTED_SERVICE"
    if confirm "Delete service ${svc}?" "n"; then
        systemctl stop "$svc" 2>/dev/null
        systemctl disable "$svc" 2>/dev/null
        rm -f "/etc/systemd/system/${svc}.service" "${CONFIG_DIR}/${svc}.toml"
        systemctl daemon-reload
        success "Service ${svc} removed."
    fi
}

uninstall_all() {
    hr "💥 Complete Uninstall"
    if confirm "Remove all services and files?" "n"; then
        local services
        mapfile -t services < <(list_services)
        for svc in "${services[@]}"; do
            systemctl stop "$svc" 2>/dev/null
            systemctl disable "$svc" 2>/dev/null
            rm -f "/etc/systemd/system/${svc}.service"
        done
        systemctl stop backhaul-watchdog.timer 2>/dev/null
        rm -f /etc/systemd/system/backhaul-watchdog.*
        systemctl daemon-reload
        rm -rf "$INSTALL_DIR"
        success "Backhaul completely removed."
    fi
}

main_menu() {
    while true; do
        clear
        echo -e "${BOLD}${CYAN}"
        echo '  ____ackhaul  _____unnel  __  __anager'
        echo -e "${NC}"
        echo -e "  ${DIM}Backhaul Tunnel Manager — v15.2 (Fixed)${NC}"
        echo -e "${BOLD}${CYAN}═══════════════════════════════════════════════════════════${NC}\n"
        
        local installed_count
        installed_count=$(list_services | wc -l)
        echo -e "  ${BOLD}Status:${NC} ${GREEN}${installed_count} service(s) configured${NC}\n"
        
        echo -e "  ${BOLD}🚀 Installation & Setup${NC}"
        echo -e "    ${GREEN}1${NC}) Install Server ${DIM}(Iran side)${NC}"
        echo -e "    ${GREEN}2${NC}) Install Client ${DIM}(Kharej side)${NC}"
        echo -e "    ${GREEN}3${NC}) Update Backhaul binary"
        echo -e "    ${GREEN}4${NC}) Setup Watchdog"
        echo -e "    ${GREEN}5${NC}) System Optimization\n"
        echo -e "  ${BOLD}⚙️ Management${NC}"
        echo -e "    ${CYAN}6${NC}) Show status"
        echo -e "    ${CYAN}7${NC}) Service control"
        echo -e "    ${CYAN}8${NC}) Edit config"
        echo -e "    ${RED}9${NC}) Uninstall single service"
        echo -e "    ${RED}10${NC}) Uninstall EVERYTHING"
        echo -e "    ${WHITE}0${NC}) Exit\n"
        
        local choice
        ask choice "Select option" "1"
        case "$choice" in
            1) install_server ;;
            2) install_client ;;
            3) download_backhaul ;;
            4) setup_watchdog ;;
            5) optimize_system ;;
            6) show_status ;;
            7) service_control ;;
            8) edit_config ;;
            9) uninstall_service ;;
            10) uninstall_all ;;
            0) exit 0 ;;
            *) warn "Invalid option" ;;
        esac
        echo -ne "\nPress Enter to return to main menu..."
        read -r
    done
}

main_menu
