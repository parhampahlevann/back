#!/bin/bash

# Backhaul Tunnel Manager - Full Edition
# Based on Musixal/Backhaul - No license required
# Open Source - Free to use

set -e

# ============================================================
# Color and Base Settings
# ============================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
DIM='\033[2m'
BOLD='\033[1m'
NC='\033[0m'

REPO="Musixal/Backhaul"
INSTALL_DIR="/root/backhaul-core"
BINARY="${INSTALL_DIR}/backhaul"
CONFIG_DIR="${INSTALL_DIR}"
STATE_FILE="${INSTALL_DIR}/state.env"
WATCHDOG_SCRIPT="${INSTALL_DIR}/watchdog.sh"
WATCHDOG_LOG="${INSTALL_DIR}/watchdog.log"
WATCHDOG_STATE_DIR="${INSTALL_DIR}/watchdog-state"
WATCHDOG_IDLE_THRESHOLD=30

# Global variables
CONFIG=""
SERVICE_NAME=""
SERVICE_FILE=""
TRANSPORT=""
TOKEN=""
FIXED_TOKEN="123"
LOCAL_ROLE=""
TUNNEL_PORT=""
INBOUND_PORTS=""
IRAN_IP=""
KHAREJ_IP=""
PEER_IP=""
LOCAL_PUBLIC_IP=""

# ============================================================
# Helper Functions
# ============================================================

_ts() { date '+%H:%M:%S'; }
info() { echo -e "${DIM}$(_ts)${NC} ${CYAN}[INFO]${NC}  $*"; }
ok() { echo -e "${DIM}$(_ts)${NC} ${GREEN}[ OK ]${NC}  $*"; }
warn() { echo -e "${DIM}$(_ts)${NC} ${YELLOW}[WARN]${NC}  $*"; }
step() { echo -e "${DIM}$(_ts)${NC} ${MAGENTA}[STEP]${NC}  $*"; }
error() { echo -e "${DIM}$(_ts)${NC} ${RED}[ERR ]${NC}  $*"; exit 1; }
hr() { echo -e "\n${BOLD}${CYAN}══ $* ══${NC}"; }

ask() {
    local var="$1"
    local prompt="$2"
    local default="$3"
    local input
    
    if [ -n "$default" ]; then
        echo -ne "${YELLOW}?${NC} $prompt [${default}]: "
    else
        echo -ne "${YELLOW}?${NC} $prompt: "
    fi
    read -r input
    if [ -z "$input" ] && [ -n "$default" ]; then
        input="$default"
    fi
    eval "$var=\"$input\""
}

ask_required() {
    local var="$1"
    local prompt="$2"
    local val
    
    while true; do
        ask "$var" "$prompt" ""
        eval "val=\$$var"
        if [ -n "$val" ]; then
            break
        fi
        warn "This field cannot be empty."
    done
}

validate_label() {
    echo "$1" | grep -qE '^[A-Za-z0-9_-]+$'
}

detect_public_ip() {
    local ip
    ip=$(curl -fsSL -4 https://ifconfig.me 2>/dev/null)
    if [ -z "$ip" ]; then
        ip=$(curl -fsSL -4 https://api.ipify.org 2>/dev/null)
    fi
    if [ -z "$ip" ]; then
        ip=""
    fi
    echo "$ip"
}

detect_default_iface() {
    local iface
    iface=$(ip -o -4 route show to default 2>/dev/null | awk '{print $5}' | head -n1)
    if [ -z "$iface" ]; then
        iface=$(ip link show 2>/dev/null | grep "state UP" | head -1 | awk '{print $2}' | cut -d: -f1)
    fi
    if [ -z "$iface" ]; then
        iface="eth0"
    fi
    echo "$iface"
}

gen_port() {
    echo $(( (RANDOM % 40000) + 20000 ))
}

# ============================================================
# System Optimization
# ============================================================

optimize_system() {
    hr "System Optimization"
    echo ""
    
    local INTERFACE
    INTERFACE=$(detect_default_iface)
    info "Interface: $INTERFACE"

    step "Enabling BBR congestion control..."
    sysctl -w net.core.default_qdisc=fq 2>/dev/null || true
    sysctl -w net.ipv4.tcp_congestion_control=bbr 2>/dev/null && ok "BBR enabled." || warn "BBR not available."

    step "Tuning network buffers..."
    sysctl -w net.core.somaxconn=65535 2>/dev/null || true
    sysctl -w net.core.netdev_max_backlog=250000 2>/dev/null || true
    sysctl -w net.ipv4.ip_local_port_range="1024 65535" 2>/dev/null || true
    sysctl -w net.core.rmem_max=134217728 2>/dev/null || true
    sysctl -w net.core.wmem_max=134217728 2>/dev/null || true
    sysctl -w net.ipv4.tcp_rmem="4096 87380 134217728" 2>/dev/null || true
    sysctl -w net.ipv4.tcp_wmem="4096 65536 134217728" 2>/dev/null || true

    step "Tuning TCP timeouts..."
    sysctl -w net.ipv4.tcp_keepalive_time=60 2>/dev/null || true
    sysctl -w net.ipv4.tcp_keepalive_intvl=10 2>/dev/null || true
    sysctl -w net.ipv4.tcp_keepalive_probes=6 2>/dev/null || true
    sysctl -w net.ipv4.tcp_user_timeout=30000 2>/dev/null || true
    sysctl -w net.ipv4.tcp_fin_timeout=15 2>/dev/null || true
    sysctl -w net.ipv4.tcp_mtu_probing=1 2>/dev/null || true
    sysctl -w net.ipv4.tcp_fastopen=3 2>/dev/null || true
    sysctl -w net.ipv4.tcp_low_latency=1 2>/dev/null || true
    sysctl -w net.ipv4.tcp_slow_start_after_idle=0 2>/dev/null || true
    sysctl -w net.ipv4.ip_forward=1 2>/dev/null || true

    cat > /etc/sysctl.d/99-backhaul-tunnel.conf << 'EOF'
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
net.ipv4.tcp_user_timeout=30000
net.ipv4.tcp_fin_timeout=15
net.ipv4.tcp_mtu_probing=1
net.ipv4.tcp_window_scaling=1
net.ipv4.tcp_timestamps=1
net.ipv4.tcp_sack=1
net.ipv4.tcp_retries2=6
net.ipv4.tcp_syn_retries=2
net.ipv4.tcp_fastopen=3
net.ipv4.tcp_low_latency=1
net.ipv4.tcp_slow_start_after_idle=0
net.ipv4.tcp_no_metrics_save=1
net.ipv4.ip_forward=1
EOF
    ok "Sysctl config saved"

    step "Setting MTU to 1400..."
    ip link set dev "$INTERFACE" mtu 1400 2>/dev/null || warn "Could not set MTU live"
    
    cat > /etc/systemd/system/backhaul-mtu.service << EOF
[Unit]
Description=Pin MTU 1400 on ${INTERFACE} for Backhaul tunnel
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/sbin/ip link set dev ${INTERFACE} mtu 1400
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable --now backhaul-mtu.service 2>/dev/null || true
    ok "MTU 1400 applied and persisted"

    step "Setting DNS to 1.1.1.1 / 1.0.0.1 / 8.8.8.8..."
    
    if [ -f /etc/resolv.conf ]; then
        chattr -i /etc/resolv.conf 2>/dev/null || true
    fi
    
    if [ -L /etc/resolv.conf ]; then
        rm -f /etc/resolv.conf
    fi
    
    cat > /etc/resolv.conf << 'EOF'
nameserver 1.1.1.1
nameserver 1.0.0.1
nameserver 8.8.8.8
EOF
    
    chattr +i /etc/resolv.conf 2>/dev/null || true
    ok "DNS set and locked"

    step "Raising file descriptor limits..."
    if ! grep -q "^fs.file-max" /etc/sysctl.d/99-backhaul-tunnel.conf 2>/dev/null; then
        echo "fs.file-max=2097152" >> /etc/sysctl.d/99-backhaul-tunnel.conf
    fi
    sysctl -w fs.file-max=2097152 2>/dev/null || true

    if ! grep -q "backhaul limits" /etc/security/limits.conf 2>/dev/null; then
        cat >> /etc/security/limits.conf << 'EOF'

# backhaul limits
root soft nofile 1048576
root hard nofile 1048576
* soft nofile 1048576
* hard nofile 1048576
EOF
    fi
    ulimit -n 1048576 2>/dev/null || true
    ok "File descriptor limits raised"

    echo ""
    ok "System optimization complete!"
}

# ============================================================
# Watchdog
# ============================================================

setup_watchdog() {
    hr "Install Watchdog"
    echo ""
    
    mkdir -p "$WATCHDOG_STATE_DIR"

    cat > "$WATCHDOG_SCRIPT" << 'WDEOF'
#!/bin/bash
# Backhaul Watchdog

INSTALL_DIR="/root/backhaul-core"
STATE_DIR="$INSTALL_DIR/watchdog-state"
LOG_FILE="$INSTALL_DIR/watchdog.log"
IDLE_THRESHOLD=30

mkdir -p "$STATE_DIR"

for unit in $(systemctl list-units --all 'backhaul-*.service' --no-legend 2>/dev/null | awk '{print $1}'); do
    case "$unit" in
        backhaul-mtu.service|backhaul-watchdog.service) continue ;;
    esac

    if ! systemctl is-active --quiet "$unit"; then
        systemctl restart "$unit" 2>/dev/null
        echo "$(date '+%F %T') restarted $unit (service was inactive)" >> "$LOG_FILE"
        rm -f "${STATE_DIR}/${unit}.last_ok"
        continue
    fi

    unit_file="/etc/systemd/system/${unit}"
    toml=$(grep -oE '/root/backhaul-core/[a-zA-Z0-9_.-]+\.toml' "$unit_file" 2>/dev/null | head -n1)
    [ -z "$toml" ] || [ ! -f "$toml" ] && continue

    port=""
    if grep -q '^\[server\]' "$toml" 2>/dev/null; then
        port=$(grep -oE 'bind_addr = "0\.0\.0\.0:[0-9]+"' "$toml" | grep -oE '[0-9]+$')
    else
        port=$(grep -oE 'remote_addr = "[^:"]+:[0-9]+"' "$toml" | grep -oE '[0-9]+$')
    fi
    [ -z "$port" ] && continue

    active_conns=$(ss -H -tn state established "( sport = :${port} or dport = :${port} )" 2>/dev/null | grep -c .)
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
            echo "$(date '+%F %T') restarted $unit (idle ${idle}s, no established connections on port ${port})" >> "$LOG_FILE"
        fi
    fi
done
WDEOF

    chmod +x "$WATCHDOG_SCRIPT"

    cat > /etc/systemd/system/backhaul-watchdog.service << 'EOF'
[Unit]
Description=Backhaul Watchdog (health check / auto-restart)

[Service]
Type=oneshot
ExecStart=/root/backhaul-core/watchdog.sh
EOF

    cat > /etc/systemd/system/backhaul-watchdog.timer << 'EOF'
[Unit]
Description=Run Backhaul Watchdog every 10 seconds

[Timer]
OnBootSec=20
OnUnitActiveSec=10
AccuracySec=1
Unit=backhaul-watchdog.service

[Install]
WantedBy=timers.target
EOF

    systemctl daemon-reload
    systemctl enable --now backhaul-watchdog.timer 2>/dev/null || true
    ok "Watchdog installed - checks every 10s, restarts after ${WATCHDOG_IDLE_THRESHOLD}s idle"
    info "Log: $WATCHDOG_LOG"
}

# ============================================================
# Backhaul Binary Download
# ============================================================

ensure_backhaul_binary() {
    mkdir -p "$INSTALL_DIR"
    
    if [ -x "$BINARY" ]; then
        ok "Backhaul binary already exists: $BINARY"
        return 0
    fi
    
    info "Fetching latest official Backhaul release from GitHub..."
    local arch asset_arch url
    
    arch=$(uname -m)
    case "$arch" in
        x86_64) asset_arch="amd64" ;;
        aarch64) asset_arch="arm64" ;;
        *) error "Unsupported architecture: $arch" ;;
    esac
    
    url=$(curl -fsSL "https://api.github.com/repos/${REPO}/releases/latest" 2>/dev/null \
        | grep "browser_download_url" | grep "linux_${asset_arch}" | grep -v ".sha256" \
        | head -n1 | cut -d '"' -f4)
    
    if [ -z "$url" ]; then
        warn "Could not resolve release asset automatically."
        ask url "Paste the correct .tar.gz download URL" ""
        if [ -z "$url" ]; then
            error "No URL provided."
        fi
    fi

    rm -f "$INSTALL_DIR/backhaul.tar.gz"
    
    info "Downloading from: $url"
    if ! curl -fSL --retry 3 --retry-delay 2 -o "$INSTALL_DIR/backhaul.tar.gz" "$url" 2>/dev/null; then
        error "Download failed after multiple attempts."
    fi

    if [ ! -s "$INSTALL_DIR/backhaul.tar.gz" ]; then
        error "Downloaded file is empty."
    fi

    if ! tar -tzf "$INSTALL_DIR/backhaul.tar.gz" 2>/dev/null; then
        error "Downloaded file is not a valid archive."
    fi

    tar -xzf "$INSTALL_DIR/backhaul.tar.gz" -C "$INSTALL_DIR" 2>/dev/null
    rm -f "$INSTALL_DIR/backhaul.tar.gz"
    chmod +x "$BINARY"
    
    ok "Backhaul binary installed: $BINARY"
}

ensure_tls_cert() {
    if [ -f "$INSTALL_DIR/server.crt" ] && [ -f "$INSTALL_DIR/server.key" ]; then
        return
    fi
    info "Generating self-signed TLS certificate for wss/wssmux..."
    openssl req -x509 -newkey rsa:2048 -nodes \
        -keyout "$INSTALL_DIR/server.key" -out "$INSTALL_DIR/server.crt" \
        -days 3650 -subj "/CN=backhaul" 2>/dev/null
    ok "TLS certificate generated."
}

# ============================================================
# Install Functions
# ============================================================

install_tunnel() {
    hr "Install Tunnel"
    
    ensure_backhaul_binary
    
    echo ""
    echo "Are you setting up the Iran server or the Kharej server?"
    echo "  1) Iran"
    echo "  2) Kharej"
    ask ROLE_CHOICE "Select role" "1"
    
    case "$ROLE_CHOICE" in
        1) LOCAL_ROLE="Iran" ;;
        2) LOCAL_ROLE="Kharej" ;;
        *) error "Invalid selection" ;;
    esac

    LOCAL_PUBLIC_IP_GUESS=$(detect_public_ip)
    ask LOCAL_PUBLIC_IP "This server's public IP" "${LOCAL_PUBLIC_IP_GUESS}"
    if [ -z "$LOCAL_PUBLIC_IP" ]; then
        LOCAL_PUBLIC_IP="$LOCAL_PUBLIC_IP_GUESS"
    fi

    ask_required PEER_IP "The OTHER server's public IP"

    echo ""
    echo "Choose transport:"
    echo "  1) wss     - TLS encrypted, looks like HTTPS (recommended)"
    echo "  2) wssmux  - wss + multiplexing, best for many connections"
    echo "  3) tcp     - plain TCP, fastest but not encrypted"
    echo "  4) tcpmux  - tcp + multiplexing"
    ask TRANSPORT_CHOICE "Enter choice [1-4]" "1"
    
    case "$TRANSPORT_CHOICE" in
        2) TRANSPORT="wssmux" ;;
        3) TRANSPORT="tcp" ;;
        4) TRANSPORT="tcpmux" ;;
        *) TRANSPORT="wss" ;;
    esac

    TOKEN="$FIXED_TOKEN"
    info "Using token: $TOKEN"

    if [ "$LOCAL_ROLE" = "Iran" ]; then
        TUNNEL_PORT_DEFAULT=$(gen_port)
        ask TUNNEL_PORT "Tunnel port" "${TUNNEL_PORT_DEFAULT}"
        if [ -z "$TUNNEL_PORT" ]; then
            TUNNEL_PORT="$TUNNEL_PORT_DEFAULT"
        fi
        
        ask_required INBOUND_PORTS "Inbound ports on Iran server (comma separated, e.g. 2050,2023)"
        IRAN_IP="$LOCAL_PUBLIC_IP"
        KHAREJ_IP="$PEER_IP"
        
        echo ""
        echo ">>> Tunnel port: $TUNNEL_PORT   (token: $TOKEN)"
        echo ">>> Enter this EXACT port on the Kharej server."
    else
        echo ""
        echo "This MUST exactly match the port shown on the Iran server."
        ask_required TUNNEL_PORT "Enter the tunnel port used on the Iran server"
        KHAREJ_IP="$LOCAL_PUBLIC_IP"
        IRAN_IP="$PEER_IP"
    fi

    if [ "$TRANSPORT" = "wss" ] || [ "$TRANSPORT" = "wssmux" ]; then
        if [ "$LOCAL_ROLE" = "Iran" ]; then
            ensure_tls_cert
        fi
    fi

    if [ "$LOCAL_ROLE" = "Iran" ]; then
        write_server_config
    else
        write_client_config
    fi

    install_service
    start_service

    cat > "$STATE_FILE" << EOF
LOCAL_ROLE=${LOCAL_ROLE}
TUNNEL_PORT=${TUNNEL_PORT}
IRAN_IP=${IRAN_IP}
KHAREJ_IP=${KHAREJ_IP}
TRANSPORT=${TRANSPORT}
TOKEN=${TOKEN}
EOF

    echo ""
    echo -e "${GREEN}${BOLD}  Installation completed successfully!${NC}"
    echo ""
    echo -e "  Role      : ${BOLD}${LOCAL_ROLE}${NC}"
    echo -e "  Transport : ${BOLD}${TRANSPORT}${NC}"
    echo -e "  Port      : ${BOLD}${TUNNEL_PORT}${NC}"
    echo -e "  Token     : ${BOLD}${TOKEN}${NC}"
    echo ""
    echo -e "  Logs      : journalctl -u backhaul-${LOCAL_ROLE,,}${TUNNEL_PORT} -f"
    echo ""
    
    ask_watchdog_and_optimizer
}

write_server_config() {
    local TOML_FILE="${INSTALL_DIR}/${LOCAL_ROLE,,}${TUNNEL_PORT}.toml"
    CONFIG="$TOML_FILE"
    
    {
        echo "[server]"
        echo "bind_addr = \"0.0.0.0:${TUNNEL_PORT}\""
        echo "transport = \"${TRANSPORT}\""
        echo "token = \"${TOKEN}\""
        echo "keepalive_period = 20"
        echo "nodelay = true"
        echo "channel_size = 16384"
        echo "heartbeat = 15"
        echo "mux_con = 8"
        
        if [ "$TRANSPORT" = "wss" ] || [ "$TRANSPORT" = "wssmux" ]; then
            echo "tls_cert = \"${INSTALL_DIR}/server.crt\""
            echo "tls_key = \"${INSTALL_DIR}/server.key\""
        fi
        
        echo "sniffer = false"
        echo "web_port = 0"
        echo "log_level = \"warn\""
        echo ""
        echo "ports = ["
        
        IFS=',' read -ra PORT_ARRAY <<< "$INBOUND_PORTS"
        for i in "${!PORT_ARRAY[@]}"; do
            port=$(echo "${PORT_ARRAY[i]}" | xargs)
            if [ $((i+1)) -eq ${#PORT_ARRAY[@]} ]; then
                echo "    \"${port}\""
            else
                echo "    \"${port}\","
            fi
        done
        echo "]"
    } > "$TOML_FILE"
    
    SERVICE_NAME="backhaul-${LOCAL_ROLE,,}${TUNNEL_PORT}"
    SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
    CONFIG="$TOML_FILE"
    
    ok "Server config written: $TOML_FILE"
}

write_client_config() {
    local TOML_FILE="${INSTALL_DIR}/${LOCAL_ROLE,,}${TUNNEL_PORT}.toml"
    CONFIG="$TOML_FILE"
    
    {
        echo "[client]"
        echo "remote_addr = \"${IRAN_IP}:${TUNNEL_PORT}\""
        echo "transport = \"${TRANSPORT}\""
        echo "token = \"${TOKEN}\""
        echo "connection_pool = 8"
        echo "aggressive_pool = true"
        echo "keepalive_period = 20"
        echo "nodelay = true"
        echo "retry_interval = 1"
        echo "sniffer = false"
        echo "web_port = 0"
        echo "log_level = \"warn\""
    } > "$TOML_FILE"
    
    SERVICE_NAME="backhaul-${LOCAL_ROLE,,}${TUNNEL_PORT}"
    SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
    CONFIG="$TOML_FILE"
    
    ok "Client config written: $TOML_FILE"
}

install_service() {
    cat > "$SERVICE_FILE" << EOF
[Unit]
Description=Backhaul ${LOCAL_ROLE} Tunnel Port ${TUNNEL_PORT}
After=network.target
Wants=network-online.target

[Service]
Type=simple
User=root
ExecStart=${BINARY} -c ${CONFIG}
Restart=always
RestartSec=1
StartLimitIntervalSec=0
LimitNOFILE=1048576
TasksMax=infinity
LimitMEMLOCK=infinity
OOMScoreAdjust=-1000
StandardOutput=journal
StandardError=journal
SyslogIdentifier=Backhaul

[Install]
WantedBy=multi-user.target
EOF
    
    systemctl daemon-reload
    systemctl enable "$SERVICE_NAME" 2>/dev/null || true
    ok "Service installed: $SERVICE_NAME"
}

start_service() {
    systemctl restart "$SERVICE_NAME"
    sleep 2
    if systemctl is-active --quiet "$SERVICE_NAME"; then
        ok "Service is running."
    else
        warn "Service failed to start. Logs:"
        journalctl -u "$SERVICE_NAME" -n 20 --no-pager
    fi
}

ask_watchdog_and_optimizer() {
    echo ""
    ask RUN_OPT "Run system optimizer now (BBR, buffers, MTU, DNS, ulimits)" "y"
    if [ "$RUN_OPT" = "y" ] || [ "$RUN_OPT" = "Y" ]; then
        optimize_system
    fi
    
    echo ""
    ask RUN_WD "Install the watchdog (auto-restart on dead/idle tunnel)" "y"
    if [ "$RUN_WD" = "y" ] || [ "$RUN_WD" = "Y" ]; then
        setup_watchdog
    fi
}

# ============================================================
# Management Functions
# ============================================================

list_services() {
    local found=()
    for cfg in "${INSTALL_DIR}"/*.toml; do
        if [ -f "$cfg" ]; then
            local name
            name=$(basename "$cfg" .toml)
            if [ -f "/etc/systemd/system/backhaul-${name}.service" ]; then
                found+=("backhaul-${name}.service")
            fi
        fi
    done
    if [ ${#found[@]} -eq 0 ]; then
        return 0
    fi
    printf '%s\n' "${found[@]}" | sort -u
}

show_status() {
    hr "Service Status"
    echo ""

    mapfile -t SERVICES < <(list_services)

    if [ ${#SERVICES[@]} -eq 0 ]; then
        warn "No Backhaul services found."
        return
    fi

    echo "=== Backhaul Services ==="
    for svc in "${SERVICES[@]}"; do
        echo "--- $svc ---"
        systemctl status "$svc" --no-pager -l 2>/dev/null | head -n 6
        echo ""
    done

    echo "=== Recent warnings / errors ==="
    local found_warn=0
    for svc in "${SERVICES[@]}"; do
        local warn_log
        warn_log=$(journalctl -u "$svc" -n 20 --no-pager 2>/dev/null | grep -iE "error|failed|panic|invalid" | tail -n 3)
        if [ -n "$warn_log" ]; then
            found_warn=1
            echo "--- $svc ---"
            echo "$warn_log"
        fi
    done
    if [ "$found_warn" -eq 0 ]; then
        echo "None found in the last 20 log lines."
    fi

    if [ -f "$WATCHDOG_LOG" ]; then
        echo ""
        echo "=== Last 10 watchdog restarts ==="
        tail -n 10 "$WATCHDOG_LOG"
    fi
}

PICKED_SVC=""
pick_service() {
    PICKED_SVC=""
    local prompt="${1:-Select service}"
    mapfile -t SERVICES < <(list_services)

    if [ ${#SERVICES[@]} -eq 0 ]; then
        warn "No Backhaul services found."
        return 1
    fi

    if [ ${#SERVICES[@]} -eq 1 ]; then
        PICKED_SVC="${SERVICES[0]}"
        return 0
    fi

    echo -e "  ${BOLD}Available services:${NC}"
    for i in "${!SERVICES[@]}"; do
        local st="stopped"
        if systemctl is-active --quiet "${SERVICES[$i]}"; then
            st="${GREEN}running${NC}"
        else
            st="${RED}stopped${NC}"
        fi
        echo -e "    $((i+1)))  ${SERVICES[$i]}   [${st}]"
    done
    echo ""
    ask IDX "$prompt (number)" "1"
    if ! [[ "$IDX" =~ ^[0-9]+$ ]] || [ "$IDX" -lt 1 ] || [ "$IDX" -gt ${#SERVICES[@]} ]; then
        warn "Invalid selection."
        return 1
    fi
    PICKED_SVC="${SERVICES[$((IDX-1))]}"
    return 0
}

service_control() {
    hr "Service Control"
    echo ""
    pick_service "Manage" || return 0
    local svc="$PICKED_SVC"

    echo ""
    local st
    if systemctl is-active --quiet "$svc"; then
        st="${GREEN}running${NC}"
    else
        st="${RED}stopped${NC}"
    fi
    echo -e "  Selected : ${BOLD}${svc}${NC}   [${st}]"
    echo ""
    echo "  1)  Restart"
    echo "  2)  Stop"
    echo "  3)  Start"
    echo "  4)  Status"
    echo "  5)  Enable auto-start"
    echo "  6)  Disable auto-start"
    echo "  7)  View config"
    echo "  8)  Edit config"
    echo "  9)  Delete this service"
    echo "  0)  Back"
    echo ""
    ask ACT "Action" "1"

    local svc_name="${svc%.service}"
    local cfg="${INSTALL_DIR}/${svc_name#backhaul-}.toml"

    case "$ACT" in
        1)
            step "Restarting ${svc} ..."
            systemctl restart "$svc"
            sleep 2
            if systemctl is-active --quiet "$svc"; then
                ok "Running."
            else
                warn "Failed to start - see logs."
            fi
            ;;
        2)
            step "Stopping ${svc} ..."
            systemctl stop "$svc" && ok "Stopped." || warn "Could not stop."
            ;;
        3)
            step "Starting ${svc} ..."
            systemctl start "$svc"
            sleep 2
            if systemctl is-active --quiet "$svc"; then
                ok "Running."
            else
                warn "Failed to start - see logs."
            fi
            ;;
        4)
            systemctl status "$svc" --no-pager --lines=10 2>/dev/null || true
            ;;
        5)
            systemctl enable "$svc" && ok "Auto-start enabled."
            ;;
        6)
            systemctl disable "$svc" && ok "Auto-start disabled."
            ;;
        7)
            if [ -f "$cfg" ]; then
                cat "$cfg"
            else
                warn "Config not found."
            fi
            ;;
        8)
            if [ -f "$cfg" ]; then
                local ed="${EDITOR:-nano}"
                cp "$cfg" "${cfg}.bak" 2>/dev/null && info "Backup saved: ${cfg}.bak"
                info "Opening ${cfg} in ${ed} ..."
                "$ed" "$cfg"
                echo ""
                ask DORESTART "Restart the service to apply changes" "y"
                if [ "$DORESTART" = "y" ] || [ "$DORESTART" = "Y" ]; then
                    systemctl restart "${svc}" && ok "Restarted with new config."
                fi
            else
                warn "Config not found."
            fi
            ;;
        9)
            echo ""
            warn "Will delete: ${svc}"
            ask CONFIRM "Confirm (yes/no)" "no"
            if [ "$CONFIRM" != "yes" ]; then
                info "Cancelled."
                return
            fi
            systemctl disable --now "$svc" 2>/dev/null || true
            rm -f "/etc/systemd/system/${svc}"
            if [ -f "$cfg" ]; then
                rm -f "$cfg"
            fi
            systemctl daemon-reload
            ok "Deleted."
            ;;
        0|"")
            return 0
            ;;
        *)
            warn "Invalid action."
            ;;
    esac
}

show_logs() {
    hr "Logs"
    echo ""

    mapfile -t SERVICES < <(list_services)

    if [ ${#SERVICES[@]} -eq 0 ]; then
        warn "No Backhaul services found."
        return
    fi

    if [ ${#SERVICES[@]} -eq 1 ]; then
        TARGET="${SERVICES[0]}"
    else
        echo "Available services:"
        for i in "${!SERVICES[@]}"; do
            echo "  $((i+1)))  ${SERVICES[$i]}"
        done
        echo ""
        ask IDX "Select number" "1"
        TARGET="${SERVICES[$((IDX-1))]}"
    fi

    journalctl -u "$TARGET" -n 80 --no-pager
}

show_logs_live() {
    hr "Live Logs"
    echo ""
    
    mapfile -t SERVICES < <(list_services)
    if [ ${#SERVICES[@]} -eq 0 ]; then
        warn "No Backhaul services found."
        return
    fi
    
    pick_service "Follow logs for" || return 0
    info "Following ${PICKED_SVC} - press Ctrl+C to return."
    echo ""
    trap ' ' INT
    journalctl -u "$PICKED_SVC" -n 40 -f --no-pager
    trap - INT
    echo ""
    ok "Stopped following logs."
}

edit_config() {
    hr "Edit Config"
    echo ""
    pick_service "Edit config for" || return 0
    local svc="${PICKED_SVC%.service}"

    local cfg="${INSTALL_DIR}/${svc#backhaul-}.toml"
    if [ ! -f "$cfg" ]; then
        warn "No config file found for ${svc}."
        return 0
    fi

    local ed="${EDITOR:-nano}"
    cp "$cfg" "${cfg}.bak" 2>/dev/null && info "Backup saved: ${cfg}.bak"
    info "Opening ${cfg} in ${ed} ..."
    "$ed" "$cfg"

    echo ""
    ask DORESTART "Restart the service to apply changes" "y"
    if [ "$DORESTART" = "y" ] || [ "$DORESTART" = "Y" ]; then
        step "Restarting ${svc} ..."
        systemctl restart "${svc}"
        sleep 2
        if systemctl is-active --quiet "${svc}"; then
            ok "Running with new config."
        else
            warn "Service failed to start - config may be invalid."
        fi
    fi
}

uninstall() {
    hr "Remove"
    echo ""

    mapfile -t SERVICES < <(list_services)

    if [ ${#SERVICES[@]} -eq 0 ]; then
        warn "No Backhaul services found."
        return
    fi

    echo "Installed services:"
    for i in "${!SERVICES[@]}"; do
        echo "  $((i+1)))  ${SERVICES[$i]}"
    done
    echo "  a)  Remove ALL"
    echo ""
    ask IDX "Select number (or a)" ""

    if [ "$IDX" = "a" ]; then
        TARGETS=("${SERVICES[@]}")
    else
        TARGETS=("${SERVICES[$((IDX-1))]}")
    fi

    echo ""
    warn "Will stop and remove: ${TARGETS[*]}"
    ask CONFIRM "Confirm (yes/no)" "no"
    if [ "$CONFIRM" != "yes" ]; then
        info "Cancelled."
        return
    fi

    for svc in "${TARGETS[@]}"; do
        svc_name="${svc%.service}"
        systemctl stop    "$svc_name" 2>/dev/null || true
        systemctl disable "$svc_name" 2>/dev/null || true
        rm -f "/etc/systemd/system/${svc_name}.service"
        
        local cfg_name="${svc_name#backhaul-}"
        local cfg="${INSTALL_DIR}/${cfg_name}.toml"
        if [ -f "$cfg" ]; then
            rm -f "$cfg"
            ok "Removed config: $cfg"
        fi
        
        ok "Removed service: $svc_name"
    done

    systemctl daemon-reload
    
    local remaining
    remaining=$(list_services | wc -l)
    if [ "$remaining" -eq 0 ]; then
        systemctl disable --now backhaul-watchdog.timer 2>/dev/null || true
        rm -f /etc/systemd/system/backhaul-watchdog.{service,timer}
        rm -f "$WATCHDOG_SCRIPT"
        systemctl daemon-reload
        ok "Watchdog removed."
    fi
    
    ok "Done."
}

# ============================================================
# Main Menu
# ============================================================

show_banner() {
    echo ""
    echo -e "  ${CYAN}${BOLD}Backhaul Tunnel Manager - Full Edition${NC}"
    echo -e "  ${DIM}Based on Musixal/Backhaul - No license required${NC}"
    echo -e "  ${DIM}Open Source - Free to use${NC}"
    echo ""
}

show_menu() {
    echo -e "${BOLD}  Select an option:${NC}"
    echo ""
    echo -e "  ${BOLD}Install${NC}"
    echo "    1)  Install Tunnel (Iran / Kharej)"
    echo ""
    echo -e "  ${BOLD}Manage${NC}"
    echo "    2)  Service Status"
    echo "    3)  Service Control  (restart/stop/start/edit/delete)"
    echo "    4)  Edit Config"
    echo ""
    echo -e "  ${BOLD}Logs${NC}"
    echo "    5)  View Logs        (last 80 lines)"
    echo "    6)  Live Logs        (follow)"
    echo ""
    echo -e "  ${BOLD}System${NC}"
    echo "    7)  System Optimizer (BBR + buffers + MTU + DNS + ulimits)"
    echo "    8)  Watchdog         (auto-restart on dead/idle tunnel)"
    echo ""
    echo -e "  ${BOLD}Other${NC}"
    echo "    9)  Remove"
    echo "   10)  Update Core (Binary)"
    echo "    0)  Exit"
    echo ""
    ask CHOICE "Choice" ""
}

run_action() {
    "$@"
    return 0
}

pause() {
    echo ""
    echo -ne "${YELLOW}?${NC} Press Enter to return to the menu: "
    read -r _
}

# ============================================================
# Program Start
# ============================================================

if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}[ERR ]${NC}  Run as root: sudo bash install.sh"
    exit 1
fi

# Fix hostname resolution issue
if ! hostname -f 2>/dev/null >/dev/null; then
    echo "127.0.0.1 $(hostname)" >> /etc/hosts 2>/dev/null || true
fi

mkdir -p "$INSTALL_DIR"

while true; do
    clear 2>/dev/null || true
    show_banner
    show_menu

    case "$CHOICE" in
        1) run_action install_tunnel ;;
        2) run_action show_status ;;
        3) run_action service_control ;;
        4) run_action edit_config ;;
        5) run_action show_logs ;;
        6) run_action show_logs_live ;;
        7) run_action optimize_system ;;
        8) run_action setup_watchdog ;;
        9) run_action uninstall ;;
        10) run_action ensure_backhaul_binary ;;
        0) echo -e "\n  ${CYAN}Bye.${NC}\n"; exit 0 ;;
        *) warn "Invalid choice: ${CHOICE}" ;;
    esac

    pause
done
