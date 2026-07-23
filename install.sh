#!/bin/bash

# DaggerConnect Tunnel Manager — Full Edition
# Combined DaggerConnect and Backhaul features

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

BINARY="/usr/local/bin/DaggerConnect"
GITHUB_REPO="itsFLoKi/daggerConnect"
LATEST_RELEASE_API="https://api.github.com/repos/${GITHUB_REPO}/releases/latest"
CONFIG_DIR="/etc/DaggerConnect"
STATE_FILE="/etc/DaggerConnect/state.env"
WATCHDOG_SCRIPT="/etc/DaggerConnect/watchdog.sh"
WATCHDOG_LOG="/etc/DaggerConnect/watchdog.log"
WATCHDOG_STATE_DIR="/etc/DaggerConnect/watchdog-state"
WATCHDOG_IDLE_THRESHOLD=30

# Global variables
CONFIG=""
CONFIG_FMT=""
SERVICE_NAME=""
SERVICE_FILE=""
TRANSPORT=""
SSL_MODE=""
DOMAIN=""
CERT_FILE=""
KEY_FILE=""
TLS_INSECURE="false"
SOCKS5_ENABLED="false"
SOCKS5_BIND=""
PORTS=()
PSK=""
CLIENT_CONN_POOL="8"
FIXED_TOKEN="123"

# TUN variables
TUN_ENCAP=""
TUN_PROFILE=""
TUN_LOCAL_IP=""
TUN_PEER_IP=""
TUN_LOCAL_ADDR=""
TUN_REMOTE_ADDR=""
TUN_IFACE=""
TUN_NAME=""
TUN_HEARTBEAT_SEC=""
TUN_IDLE_TIMEOUT_SEC=""
TUN_SPOOF_SRC=""
TUN_SPOOF_DST=""
TUN_DCPI=""
QM_MTU=""
QM_BLOCK=""
WS_PATH=""
HTTP_DOMAIN=""
HTTP_PATH=""

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
    local var="$1" prompt="$2" default="$3"
    if [ -n "$default" ]; then
        echo -ne "${YELLOW}?${NC} $prompt [${default}]: "
    else
        echo -ne "${YELLOW}?${NC} $prompt: "
    fi
    read -r input
    [ -z "$input" ] && [ -n "$default" ] && input="$default"
    eval "$var=\"$input\""
}

ask_required() {
    local var="$1" prompt="$2"
    while true; do
        ask "$var" "$prompt" ""
        eval "local val=\$$var"
        [ -n "$val" ] && break
        warn "This field cannot be empty."
    done
}

validate_label() {
    echo "$1" | grep -qE '^[A-Za-z0-9_-]+$'
}

detect_public_ip() {
    curl -fsSL -4 https://ifconfig.me 2>/dev/null || \
    curl -fsSL -4 https://api.ipify.org 2>/dev/null || \
    echo ""
}

detect_default_iface() {
    local iface
    iface=$(ip -o -4 route show to default | awk '{print $5}' | head -n1)
    [ -z "$iface" ] && iface=$(ip link show | grep "state UP" | head -1 | awk '{print $2}' | cut -d: -f1)
    [ -z "$iface" ] && iface="eth0"
    echo "$iface"
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
    sysctl -w net.core.default_qdisc=fq >/dev/null 2>&1 || true
    sysctl -w net.ipv4.tcp_congestion_control=bbr >/dev/null 2>&1 && ok "BBR enabled." || warn "BBR not available."

    step "Tuning network buffers..."
    sysctl -w net.core.somaxconn=65535 >/dev/null 2>&1 || true
    sysctl -w net.core.netdev_max_backlog=250000 >/dev/null 2>&1 || true
    sysctl -w net.ipv4.ip_local_port_range="1024 65535" >/dev/null 2>&1 || true
    sysctl -w net.core.rmem_max=134217728 >/dev/null 2>&1 || true
    sysctl -w net.core.wmem_max=134217728 >/dev/null 2>&1 || true
    sysctl -w net.ipv4.tcp_rmem="4096 87380 134217728" >/dev/null 2>&1 || true
    sysctl -w net.ipv4.tcp_wmem="4096 65536 134217728" >/dev/null 2>&1 || true

    step "Tuning TCP timeouts..."
    sysctl -w net.ipv4.tcp_keepalive_time=60 >/dev/null 2>&1 || true
    sysctl -w net.ipv4.tcp_keepalive_intvl=10 >/dev/null 2>&1 || true
    sysctl -w net.ipv4.tcp_keepalive_probes=6 >/dev/null 2>&1 || true
    sysctl -w net.ipv4.tcp_user_timeout=30000 >/dev/null 2>&1 || true
    sysctl -w net.ipv4.tcp_fin_timeout=15 >/dev/null 2>&1 || true
    sysctl -w net.ipv4.tcp_mtu_probing=1 >/dev/null 2>&1 || true
    sysctl -w net.ipv4.tcp_fastopen=3 >/dev/null 2>&1 || true
    sysctl -w net.ipv4.tcp_low_latency=1 >/dev/null 2>&1 || true
    sysctl -w net.ipv4.tcp_slow_start_after_idle=0 >/dev/null 2>&1 || true
    sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1 || true

    cat > /etc/sysctl.d/99-daggerconnect-tunnel.conf << 'EOF'
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
    
    cat > /etc/systemd/system/daggerconnect-mtu.service << EOF
[Unit]
Description=Pin MTU 1400 on ${INTERFACE} for DaggerConnect tunnel
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
    systemctl enable --now daggerconnect-mtu.service >/dev/null 2>&1 || true
    ok "MTU 1400 applied and persisted"

    step "Setting DNS to 1.1.1.1 / 1.0.0.1 / 8.8.8.8..."
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
    if ! grep -q "^fs.file-max" /etc/sysctl.d/99-daggerconnect-tunnel.conf 2>/dev/null; then
        echo "fs.file-max=2097152" >> /etc/sysctl.d/99-daggerconnect-tunnel.conf
    fi
    sysctl -w fs.file-max=2097152 >/dev/null 2>&1 || true

    if ! grep -q "daggerconnect limits" /etc/security/limits.conf 2>/dev/null; then
        cat >> /etc/security/limits.conf << 'EOF'

# daggerconnect limits
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
# DaggerConnect Watchdog

INSTALL_DIR="/etc/DaggerConnect"
STATE_DIR="$INSTALL_DIR/watchdog-state"
LOG_FILE="$INSTALL_DIR/watchdog.log"
IDLE_THRESHOLD=30

mkdir -p "$STATE_DIR"

for unit in $(systemctl list-units --all '*.service' --no-legend 2>/dev/null | awk '{print $1}' | grep -E '^[a-zA-Z0-9_-]+\.service$'); do
    case "$unit" in
        daggerconnect-mtu.service|daggerconnect-watchdog.service|systemd-*|dbus-*|*@*) continue ;;
    esac
    
    svc_name="${unit%.service}"
    if [ ! -f "/etc/DaggerConnect/${svc_name}.json" ] && [ ! -f "/etc/DaggerConnect/${svc_name}.yaml" ]; then
        continue
    fi

    if ! systemctl is-active --quiet "$unit"; then
        systemctl restart "$unit" 2>/dev/null
        echo "$(date '+%F %T') restarted $unit (service was inactive)" >> "$LOG_FILE"
        rm -f "${STATE_DIR}/${unit}.last_ok"
        continue
    fi

    config_file=""
    [ -f "/etc/DaggerConnect/${svc_name}.json" ] && config_file="/etc/DaggerConnect/${svc_name}.json"
    [ -f "/etc/DaggerConnect/${svc_name}.yaml" ] && config_file="/etc/DaggerConnect/${svc_name}.yaml"
    [ -z "$config_file" ] && continue

    port=""
    if [[ "$config_file" == *.json ]]; then
        port=$(grep -oE '"addr": "0\.0\.0\.0:[0-9]+"' "$config_file" 2>/dev/null | grep -oE '[0-9]+$' | head -1)
    else
        port=$(grep -oE 'addr: "0\.0\.0\.0:[0-9]+"' "$config_file" 2>/dev/null | grep -oE '[0-9]+$' | head -1)
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

    cat > /etc/systemd/system/daggerconnect-watchdog.service << 'EOF'
[Unit]
Description=DaggerConnect Watchdog (health check / auto-restart)

[Service]
Type=oneshot
ExecStart=/etc/DaggerConnect/watchdog.sh
EOF

    cat > /etc/systemd/system/daggerconnect-watchdog.timer << 'EOF'
[Unit]
Description=Run DaggerConnect Watchdog every 10 seconds

[Timer]
OnBootSec=20
OnUnitActiveSec=10
AccuracySec=1
Unit=daggerconnect-watchdog.service

[Install]
WantedBy=timers.target
EOF

    systemctl daemon-reload
    systemctl enable --now daggerconnect-watchdog.timer >/dev/null 2>&1 || true
    ok "Watchdog installed - checks every 10s, restarts after ${WATCHDOG_IDLE_THRESHOLD}s idle"
    info "Log: $WATCHDOG_LOG"
}

# ============================================================
# Core DaggerConnect Functions
# ============================================================

download_binary() {
    echo ""
    step "Checking for the latest DaggerConnect release ..."

    LATEST_VERSION=$(curl -fsSL "$LATEST_RELEASE_API" 2>/dev/null | grep '"tag_name":' | head -1 | sed -E 's/.*"([^"]+)".*/\1/')

    if [ -z "$LATEST_VERSION" ]; then
        warn "Could not reach GitHub to check the latest version."
        if [ -f "$BINARY" ]; then
            chmod +x "$BINARY"
            ok "Using existing local binary: ${BINARY}"
            return 0
        fi
        error "No local binary found and GitHub is unreachable. Cannot continue."
    fi

    info "Latest release: ${LATEST_VERSION}"

    CURRENT_VERSION=""
    if [ -f "$BINARY" ]; then
        chmod +x "$BINARY"
        CURRENT_VERSION=$("$BINARY" -v 2>&1 | grep -oE 'v?[0-9]+\.[0-9]+(\.[0-9]+)?' | head -1)
    fi

    if [ -n "$CURRENT_VERSION" ] && [ "$CURRENT_VERSION" = "$LATEST_VERSION" ]; then
        ok "Already on the latest version (${CURRENT_VERSION})."
        return 0
    fi

    if [ -n "$CURRENT_VERSION" ]; then
        step "Updating DaggerConnect: ${CURRENT_VERSION} -> ${LATEST_VERSION} ..."
    else
        step "Downloading DaggerConnect ${LATEST_VERSION} ..."
    fi

    BINARY_URL="https://github.com/${GITHUB_REPO}/releases/download/${LATEST_VERSION}/DaggerConnect"
    mkdir -p "$(dirname "$BINARY")"

    [ -f "$BINARY" ] && cp "$BINARY" "${BINARY}.backup"

    if curl -fL --progress-bar "$BINARY_URL" -o "${BINARY}.new"; then
        chmod +x "${BINARY}.new"
        if "${BINARY}.new" -v >/dev/null 2>&1; then
            mv -f "${BINARY}.new" "$BINARY"
            rm -f "${BINARY}.backup"
            ok "DaggerConnect updated to ${LATEST_VERSION}."

            mapfile -t SERVICES < <(list_services)
            if [ ${#SERVICES[@]} -gt 0 ]; then
                echo ""
                warn "Running services are still using the old binary in memory until restarted."
                ask RESTART_CHOICE "Restart all DaggerConnect services now? (y/n)" "y"
                if [ "$RESTART_CHOICE" = "y" ] || [ "$RESTART_CHOICE" = "Y" ]; then
                    for svc in "${SERVICES[@]}"; do
                        systemctl restart "$svc" && ok "Restarted: ${svc}" || warn "Failed to restart: ${svc}"
                    done
                fi
            fi
        else
            rm -f "${BINARY}.new"
            warn "Downloaded binary failed to run -- keeping the previous version."
            [ -f "${BINARY}.backup" ] && mv -f "${BINARY}.backup" "$BINARY"
        fi
    else
        rm -f "${BINARY}.new"
        warn "Download failed."
        if [ -f "${BINARY}.backup" ]; then
            mv -f "${BINARY}.backup" "$BINARY"
            warn "Keeping existing binary."
        elif [ -f "$BINARY" ]; then
            ok "Using existing binary: ${BINARY}"
        else
            error "No binary available and download failed. Cannot continue."
        fi
    fi
}

ensure_binary() {
    if [ -f "$BINARY" ]; then
        chmod +x "$BINARY"
        return 0
    fi

    echo ""
    warn "No DaggerConnect binary found at ${BINARY}."
    ask DOWNLOAD_CHOICE "Download the latest release now? (y/n)" "y"
    if [ "$DOWNLOAD_CHOICE" != "y" ] && [ "$DOWNLOAD_CHOICE" != "Y" ]; then
        error "Cannot continue without a binary."
    fi

    download_binary
}

ask_service_name() {
    local svc_name svc_file

    while true; do
        ask LABEL "Service Name    (e.g. iran1, client-home, relay01)" ""
        if [ -z "$LABEL" ]; then
            warn "Service Name cannot be empty."
            continue
        fi
        if ! validate_label "$LABEL"; then
            warn "Only letters, numbers, - and _ are allowed."
            continue
        fi

        svc_name="${LABEL}"
        svc_file="/etc/systemd/system/${svc_name}.service"

        if [ -f "$svc_file" ] || \
           [ -f "${CONFIG_DIR}/${svc_name}.json" ] || \
           [ -f "${CONFIG_DIR}/${svc_name}.yaml" ]; then
            echo ""
            warn "Already exists: ${svc_name}"
            ask OVERWRITE "Overwrite? (y/n)" "n"
            if [ "$OVERWRITE" = "y" ] || [ "$OVERWRITE" = "Y" ]; then
                break
            fi
            info "Enter a different service name."
            echo ""
            continue
        fi

        break
    done

    while true; do
        ask FMT "Config Format   (json/yaml)" "json"
        case "$FMT" in
            json|yaml) break ;;
            *) warn "Please enter json or yaml." ;;
        esac
    done

    CONFIG_FMT="$FMT"
    SERVICE_NAME="${LABEL}"
    SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
    CONFIG="${CONFIG_DIR}/${SERVICE_NAME}.${CONFIG_FMT}"

    echo ""
    info "Service Name : ${SERVICE_NAME}"
    info "Config File  : ${CONFIG}"
}

ask_transport() {
    echo ""
    echo -e "  ${BOLD}Available Transports:${NC}"
    echo "    1)  tcp     - Raw TCP tunnel"
    echo "    2)  ws      - WebSocket tunnel"
    echo "    3)  wss     - WebSocket Secure (TLS) tunnel"
    echo "    4)  http    - HTTP Mimicry tunnel"
    echo "    5)  https   - HTTP Mimicry Secure (TLS) tunnel"
    echo "    6)  quantum - Raw-packet tunnel (KCP over forged TCP)"
    echo "    7)  tun     - TUN kernel interface tunnel"
    echo ""
    while true; do
        ask T_CHOICE "Transport" "1"
        case "$T_CHOICE" in
            1|tcp)     TRANSPORT="tcp";     break ;;
            2|ws)      TRANSPORT="ws";      break ;;
            3|wss)     TRANSPORT="wss";     break ;;
            4|http)    TRANSPORT="http";    break ;;
            5|https)   TRANSPORT="https";   break ;;
            6|quantum) TRANSPORT="quantum"; break ;;
            7|tun)     TRANSPORT="tun";     break ;;
            *) warn "Please enter 1-7 or transport name." ;;
        esac
    done
    info "Transport : ${TRANSPORT}"
}

ask_ports() {
    echo ""
    echo -e "  Ports to forward. One per line, or comma-separated. Empty line when done."
    echo -e "        Example : 22                   (bind :22 -> target :22)"
    echo -e "        Example : 2222=22              (bind :2222 -> target :22)"
    echo -e "        Example : 800,3005,4155,6550   (multiple at once)"
    PORTS=()
    while true; do
        ask P "Port" ""
        [ -z "$P" ] && break
        IFS="," read -ra _parts <<< "$P"
        for _p in "${_parts[@]}"; do
            _p="${_p// /}"
            [ -n "$_p" ] && PORTS+=("$_p")
        done
    done
    if [ ${#PORTS[@]} -eq 0 ]; then
        warn "No ports defined. Adding default 2222=22."
        PORTS=("2222=22")
    fi
}

build_ports_json() {
    local first=1
    for p in "$@"; do
        if [ "$first" = "1" ]; then
            printf '    "%s"' "$p"
            first=0
        else
            printf ',
    "%s"' "$p"
        fi
    done
    echo ""
}

build_ports_yaml() {
    for p in "$@"; do
        printf '      - "%s"\n' "$p"
    done
}

build_socks5_json() {
    printf '  "socks5": {
    "enabled": %s,
    "bind": "%s"
  },\n' "$SOCKS5_ENABLED" "$SOCKS5_BIND"
}

build_socks5_yaml() {
    printf "socks5:
  enabled: %s
  bind: \"%s\"\n\n" "$SOCKS5_ENABLED" "$SOCKS5_BIND"
}

# ============================================================
# SSL Functions
# ============================================================

install_certbot() {
    if command -v certbot >/dev/null 2>&1; then
        ok "certbot already installed."
        return
    fi
    info "Installing certbot..."
    if command -v apt-get >/dev/null 2>&1; then
        apt-get update -qq
        apt-get install -y -qq certbot
    elif command -v yum >/dev/null 2>&1; then
        yum install -y -q certbot
    elif command -v dnf >/dev/null 2>&1; then
        dnf install -y -q certbot
    else
        error "Cannot install certbot - package manager not found."
    fi
    ok "certbot installed."
}

obtain_cert_auto() {
    local domain="$1"
    local cert_dir="/etc/letsencrypt/live/${domain}"

    install_certbot

    if ss -tlnp 2>/dev/null | grep -q ':80 '; then
        warn "Port 80 is in use. Trying standalone anyway."
    fi

    info "Obtaining SSL certificate for: ${domain}"
    if certbot certonly \
        --standalone \
        --non-interactive \
        --agree-tos \
        --register-unsafely-without-email \
        -d "$domain" \
        --http-01-port 80 2>&1 | grep -E "Congratulations|Certificate|error|Error|failed|Failed"; then
        ok "Certificate obtained successfully."
    else
        error "certbot failed. Make sure port 80 is open and domain points to this server."
    fi

    CERT_FILE="${cert_dir}/fullchain.pem"
    KEY_FILE="${cert_dir}/privkey.pem"

    if [ ! -f "$CERT_FILE" ] || [ ! -f "$KEY_FILE" ]; then
        error "Certificate files not found at ${cert_dir}"
    fi

    ok "Cert : ${CERT_FILE}"
    ok "Key  : ${KEY_FILE}"

    local hook_dir="/etc/letsencrypt/renewal-hooks/deploy"
    mkdir -p "$hook_dir"
    cat > "${hook_dir}/daggerconnect-${SERVICE_NAME}.sh" << EOF
#!/bin/bash
systemctl restart ${SERVICE_NAME} 2>/dev/null || true
EOF
    chmod +x "${hook_dir}/daggerconnect-${SERVICE_NAME}.sh"
    ok "Auto-renew hook installed."
}

ask_ssl_server() {
    echo ""
    echo -e "  ${BOLD}SSL Mode:${NC}"
    echo "    1)  Automatic SSL  - Let's Encrypt (certbot)"
    echo "    2)  Custom SSL     - Provide your own cert/key paths"
    echo ""
    while true; do
        ask SSL_CHOICE "SSL Mode" "1"
        case "$SSL_CHOICE" in
            1|auto)   SSL_MODE="auto";   break ;;
            2|custom) SSL_MODE="custom"; break ;;
            *) warn "Please enter 1 (auto) or 2 (custom)." ;;
        esac
    done

    case "$SSL_MODE" in
        auto)
            echo ""
            ask_required DOMAIN "Domain name  (e.g. tunnel.example.com)"
            echo ""
            obtain_cert_auto "$DOMAIN"
            ;;
        custom)
            echo ""
            while true; do
                ask_required CERT_FILE "Certificate file path"
                [ -f "$CERT_FILE" ] && break
                warn "File not found: ${CERT_FILE}"
            done
            while true; do
                ask_required KEY_FILE "Private key file path"
                [ -f "$KEY_FILE" ] && break
                warn "File not found: ${KEY_FILE}"
            done
            echo ""
            ok "Cert : ${CERT_FILE}"
            ok "Key  : ${KEY_FILE}"
            ;;
    esac
}

ask_ssl_client() {
    echo ""
    echo -e "  ${BOLD}Server Certificate Verification:${NC}"
    echo "    1)  Verify  - Recommended (server has valid cert)"
    echo "    2)  Skip    - Skip TLS verification (self-signed)"
    echo ""
    while true; do
        ask TLS_CHOICE "TLS Verify" "1"
        case "$TLS_CHOICE" in
            1|verify) TLS_INSECURE="false"; break ;;
            2|skip)   TLS_INSECURE="true";  break ;;
            *) warn "Please enter 1 (verify) or 2 (skip)." ;;
        esac
    done
}

ask_socks5() {
    echo ""
    echo -e "  ${BOLD}Standalone SOCKS5 Proxy:${NC}"
    echo -e "        Independent of the transport and port maps above - opens a local"
    echo -e "        SOCKS5 proxy on this server whose traffic is tunneled to the client."
    echo ""
    ask SOCKS5_CHOICE "Enable SOCKS5 proxy? (y/n)" "n"
    if [ "$SOCKS5_CHOICE" = "y" ] || [ "$SOCKS5_CHOICE" = "Y" ]; then
        SOCKS5_ENABLED="true"
        ask SOCKS5_BIND "SOCKS5 bind address  (keep on 127.0.0.1 unless you add auth)" "127.0.0.1:6060"
    else
        SOCKS5_ENABLED="false"
        SOCKS5_BIND=""
    fi
}

# ============================================================
# Config Writer Functions
# ============================================================

write_server_config_tcp() {
    local port="$1" psk="$2"
    shift 2
    local ports_json
    ports_json=$(build_ports_json "$@")
    local ports_yaml
    ports_yaml=$(build_ports_yaml "$@")
    mkdir -p "$CONFIG_DIR"
    if [ "$CONFIG_FMT" = "json" ]; then
        cat > "$CONFIG" <<-EOF
{
  "mode": "server",
  "transport": "tcp",
  "psk": "${psk}",
  "log_level": "info",
  "listeners": [
    {
      "addr": "0.0.0.0:${port}",
      "transport": "tcp",
      "ports": [
${ports_json}
      ]
    }
  ],
$(build_socks5_json)
  "advanced": {
    "tcp_nodelay": true,
    "tcp_keepalive": 1,
    "connection_timeout": 30,
    "session_timeout": 60,
    "cleanup_interval": 3
  }
}
EOF
    else
        cat > "$CONFIG" <<-EOF
mode: server
transport: tcp
psk: "${psk}"
log_level: info
listeners:
  - addr: "0.0.0.0:${port}"
    transport: tcp
    ports:
${ports_yaml}
$(build_socks5_yaml)
advanced:
  tcp_nodelay: true
  tcp_keepalive: 1
  connection_timeout: 30
  session_timeout: 60
  cleanup_interval: 3
EOF
    fi
}

write_client_config_tcp() {
    local server_ip="$1" server_port="$2" psk="$3"
    mkdir -p "$CONFIG_DIR"
    if [ "$CONFIG_FMT" = "json" ]; then
        cat > "$CONFIG" <<-EOF
{
  "mode": "client",
  "transport": "tcp",
  "psk": "${psk}",
  "log_level": "info",
  "paths": [
    {
      "transport": "tcp",
      "addr": "${server_ip}:${server_port}",
      "connection_pool": ${CLIENT_CONN_POOL},
      "retry_interval": 3,
      "dial_timeout": 10
    }
  ],
  "advanced": {
    "tcp_nodelay": true,
    "tcp_keepalive": 1,
    "connection_timeout": 30,
    "session_timeout": 60,
    "cleanup_interval": 3
  }
}
EOF
    else
        cat > "$CONFIG" <<-EOF
mode: client
transport: tcp
psk: "${psk}"
log_level: info
paths:
  - transport: tcp
    addr: "${server_ip}:${server_port}"
    connection_pool: ${CLIENT_CONN_POOL}
    retry_interval: 3
    dial_timeout: 10

advanced:
  tcp_nodelay: true
  tcp_keepalive: 1
  connection_timeout: 30
  session_timeout: 60
  cleanup_interval: 3
EOF
    fi
}

write_server_config_ws() {
    local port="$1" psk="$2" ws_path="$3"
    shift 3
    local ports_json
    ports_json=$(build_ports_json "$@")
    local ports_yaml
    ports_yaml=$(build_ports_yaml "$@")
    mkdir -p "$CONFIG_DIR"
    if [ "$CONFIG_FMT" = "json" ]; then
        cat > "$CONFIG" <<-EOF
{
  "mode": "server",
  "transport": "ws",
  "psk": "${psk}",
  "log_level": "info",
  "listeners": [
    {
      "addr": "0.0.0.0:${port}",
      "transport": "ws",
      "ports": [
${ports_json}
      ]
    }
  ],
  "ws_settings": {
    "path": "${ws_path}"
  },
$(build_socks5_json)
  "advanced": {
    "tcp_nodelay": true,
    "tcp_keepalive": 1,
    "connection_timeout": 30,
    "session_timeout": 60,
    "cleanup_interval": 3
  }
}
EOF
    else
        cat > "$CONFIG" <<-EOF
mode: server
transport: ws
psk: "${psk}"
log_level: info
listeners:
  - addr: "0.0.0.0:${port}"
    transport: ws
    ports:
${ports_yaml}
ws_settings:
  path: "${ws_path}"
$(build_socks5_yaml)
advanced:
  tcp_nodelay: true
  tcp_keepalive: 1
  connection_timeout: 30
  session_timeout: 60
  cleanup_interval: 3
EOF
    fi
}

write_client_config_ws() {
    local server_ip="$1" server_port="$2" psk="$3" ws_path="$4"
    mkdir -p "$CONFIG_DIR"
    if [ "$CONFIG_FMT" = "json" ]; then
        cat > "$CONFIG" <<-EOF
{
  "mode": "client",
  "transport": "ws",
  "psk": "${psk}",
  "log_level": "info",
  "paths": [
    {
      "transport": "ws",
      "addr": "${server_ip}:${server_port}",
      "connection_pool": ${CLIENT_CONN_POOL},
      "retry_interval": 3,
      "dial_timeout": 10
    }
  ],
  "ws_settings": {
    "path": "${ws_path}"
  },
  "advanced": {
    "tcp_nodelay": true,
    "tcp_keepalive": 1,
    "connection_timeout": 30,
    "session_timeout": 60,
    "cleanup_interval": 3
  }
}
EOF
    else
        cat > "$CONFIG" <<-EOF
mode: client
transport: ws
psk: "${psk}"
log_level: info
paths:
  - transport: ws
    addr: "${server_ip}:${server_port}"
    connection_pool: ${CLIENT_CONN_POOL}
    retry_interval: 3
    dial_timeout: 10

ws_settings:
  path: "${ws_path}"

advanced:
  tcp_nodelay: true
  tcp_keepalive: 1
  connection_timeout: 30
  session_timeout: 60
  cleanup_interval: 3
EOF
    fi
}

write_server_config_wss() {
    local port="$1" psk="$2" ws_path="$3" cert="$4" key="$5"
    shift 5
    local ports_json
    ports_json=$(build_ports_json "$@")
    local ports_yaml
    ports_yaml=$(build_ports_yaml "$@")
    mkdir -p "$CONFIG_DIR"
    if [ "$CONFIG_FMT" = "json" ]; then
        cat > "$CONFIG" <<-EOF
{
  "mode": "server",
  "transport": "wss",
  "psk": "${psk}",
  "log_level": "info",
  "listeners": [
    {
      "addr": "0.0.0.0:${port}",
      "transport": "wss",
      "cert_file": "${cert}",
      "key_file": "${key}",
      "ports": [
${ports_json}
      ]
    }
  ],
  "ws_settings": {
    "path": "${ws_path}"
  },
$(build_socks5_json)
  "advanced": {
    "tcp_nodelay": true,
    "tcp_keepalive": 1,
    "connection_timeout": 30,
    "session_timeout": 60,
    "cleanup_interval": 3
  }
}
EOF
    else
        cat > "$CONFIG" <<-EOF
mode: server
transport: wss
psk: "${psk}"
log_level: info
listeners:
  - addr: "0.0.0.0:${port}"
    transport: wss
    cert_file: "${cert}"
    key_file: "${key}"
    ports:
${ports_yaml}
ws_settings:
  path: "${ws_path}"
$(build_socks5_yaml)
advanced:
  tcp_nodelay: true
  tcp_keepalive: 1
  connection_timeout: 30
  session_timeout: 60
  cleanup_interval: 3
EOF
    fi
}

write_client_config_wss() {
    local server_ip="$1" server_port="$2" psk="$3" ws_path="$4" tls_insecure="$5"
    mkdir -p "$CONFIG_DIR"
    if [ "$CONFIG_FMT" = "json" ]; then
        cat > "$CONFIG" <<-EOF
{
  "mode": "client",
  "transport": "wss",
  "psk": "${psk}",
  "log_level": "info",
  "paths": [
    {
      "transport": "wss",
      "addr": "${server_ip}:${server_port}",
      "connection_pool": ${CLIENT_CONN_POOL},
      "retry_interval": 3,
      "dial_timeout": 10
    }
  ],
  "ws_settings": {
    "path": "${ws_path}"
  },
  "tls_insecure": ${tls_insecure},
  "advanced": {
    "tcp_nodelay": true,
    "tcp_keepalive": 1,
    "connection_timeout": 30,
    "session_timeout": 60,
    "cleanup_interval": 3
  }
}
EOF
    else
        cat > "$CONFIG" <<-EOF
mode: client
transport: wss
psk: "${psk}"
log_level: info
paths:
  - transport: wss
    addr: "${server_ip}:${server_port}"
    connection_pool: ${CLIENT_CONN_POOL}
    retry_interval: 3
    dial_timeout: 10

ws_settings:
  path: "${ws_path}"

tls_insecure: ${tls_insecure}

advanced:
  tcp_nodelay: true
  tcp_keepalive: 1
  connection_timeout: 30
  session_timeout: 60
  cleanup_interval: 3
EOF
    fi
}

write_server_config_http() {
    local port="$1" psk="$2" http_domain="$3" http_path="$4"
    shift 4
    local ports_json
    ports_json=$(build_ports_json "$@")
    local ports_yaml
    ports_yaml=$(build_ports_yaml "$@")
    mkdir -p "$CONFIG_DIR"
    if [ "$CONFIG_FMT" = "json" ]; then
        cat > "$CONFIG" <<-EOF
{
  "mode": "server",
  "transport": "http",
  "psk": "${psk}",
  "log_level": "info",
  "listeners": [
    {
      "addr": "0.0.0.0:${port}",
      "transport": "http",
      "ports": [
${ports_json}
      ]
    }
  ],
  "http_settings": {
    "fake_domain": "${http_domain}",
    "path": "${http_path}"
  },
$(build_socks5_json)
  "advanced": {
    "tcp_nodelay": true,
    "tcp_keepalive": 1,
    "connection_timeout": 30,
    "session_timeout": 60,
    "cleanup_interval": 3
  }
}
EOF
    else
        cat > "$CONFIG" <<-EOF
mode: server
transport: http
psk: "${psk}"
log_level: info
listeners:
  - addr: "0.0.0.0:${port}"
    transport: http
    ports:
${ports_yaml}
http_settings:
  fake_domain: "${http_domain}"
  path: "${http_path}"
$(build_socks5_yaml)
advanced:
  tcp_nodelay: true
  tcp_keepalive: 1
  connection_timeout: 30
  session_timeout: 60
  cleanup_interval: 3
EOF
    fi
}

write_client_config_http() {
    local server_ip="$1" server_port="$2" psk="$3" http_domain="$4" http_path="$5"
    mkdir -p "$CONFIG_DIR"
    if [ "$CONFIG_FMT" = "json" ]; then
        cat > "$CONFIG" <<-EOF
{
  "mode": "client",
  "transport": "http",
  "psk": "${psk}",
  "log_level": "info",
  "paths": [
    {
      "transport": "http",
      "addr": "${server_ip}:${server_port}",
      "connection_pool": ${CLIENT_CONN_POOL},
      "retry_interval": 3,
      "dial_timeout": 10
    }
  ],
  "http_settings": {
    "fake_domain": "${http_domain}",
    "path": "${http_path}"
  },
  "advanced": {
    "tcp_nodelay": true,
    "tcp_keepalive": 1,
    "connection_timeout": 30,
    "session_timeout": 60,
    "cleanup_interval": 3
  }
}
EOF
    else
        cat > "$CONFIG" <<-EOF
mode: client
transport: http
psk: "${psk}"
log_level: info
paths:
  - transport: http
    addr: "${server_ip}:${server_port}"
    connection_pool: ${CLIENT_CONN_POOL}
    retry_interval: 3
    dial_timeout: 10

http_settings:
  fake_domain: "${http_domain}"
  path: "${http_path}"

advanced:
  tcp_nodelay: true
  tcp_keepalive: 1
  connection_timeout: 30
  session_timeout: 60
  cleanup_interval: 3
EOF
    fi
}

write_server_config_https() {
    local port="$1" psk="$2" http_domain="$3" http_path="$4" cert="$5" key="$6"
    shift 6
    local ports_json
    ports_json=$(build_ports_json "$@")
    local ports_yaml
    ports_yaml=$(build_ports_yaml "$@")
    mkdir -p "$CONFIG_DIR"
    if [ "$CONFIG_FMT" = "json" ]; then
        cat > "$CONFIG" <<-EOF
{
  "mode": "server",
  "transport": "https",
  "psk": "${psk}",
  "log_level": "info",
  "listeners": [
    {
      "addr": "0.0.0.0:${port}",
      "transport": "https",
      "cert_file": "${cert}",
      "key_file": "${key}",
      "ports": [
${ports_json}
      ]
    }
  ],
  "http_settings": {
    "fake_domain": "${http_domain}",
    "path": "${http_path}"
  },
$(build_socks5_json)
  "advanced": {
    "tcp_nodelay": true,
    "tcp_keepalive": 1,
    "connection_timeout": 30,
    "session_timeout": 60,
    "cleanup_interval": 3
  }
}
EOF
    else
        cat > "$CONFIG" <<-EOF
mode: server
transport: https
psk: "${psk}"
log_level: info
listeners:
  - addr: "0.0.0.0:${port}"
    transport: https
    cert_file: "${cert}"
    key_file: "${key}"
    ports:
${ports_yaml}
http_settings:
  fake_domain: "${http_domain}"
  path: "${http_path}"
$(build_socks5_yaml)
advanced:
  tcp_nodelay: true
  tcp_keepalive: 1
  connection_timeout: 30
  session_timeout: 60
  cleanup_interval: 3
EOF
    fi
}

write_client_config_https() {
    local server_ip="$1" server_port="$2" psk="$3" http_domain="$4" http_path="$5" tls_insecure="$6"
    mkdir -p "$CONFIG_DIR"
    if [ "$CONFIG_FMT" = "json" ]; then
        cat > "$CONFIG" <<-EOF
{
  "mode": "client",
  "transport": "https",
  "psk": "${psk}",
  "log_level": "info",
  "paths": [
    {
      "transport": "https",
      "addr": "${server_ip}:${server_port}",
      "connection_pool": ${CLIENT_CONN_POOL},
      "retry_interval": 3,
      "dial_timeout": 10
    }
  ],
  "http_settings": {
    "fake_domain": "${http_domain}",
    "path": "${http_path}"
  },
  "tls_insecure": ${tls_insecure},
  "advanced": {
    "tcp_nodelay": true,
    "tcp_keepalive": 1,
    "connection_timeout": 30,
    "session_timeout": 60,
    "cleanup_interval": 3
  }
}
EOF
    else
        cat > "$CONFIG" <<-EOF
mode: client
transport: https
psk: "${psk}"
log_level: info
paths:
  - transport: https
    addr: "${server_ip}:${server_port}"
    connection_pool: ${CLIENT_CONN_POOL}
    retry_interval: 3
    dial_timeout: 10

http_settings:
  fake_domain: "${http_domain}"
  path: "${http_path}"

tls_insecure: ${tls_insecure}

advanced:
  tcp_nodelay: true
  tcp_keepalive: 1
  connection_timeout: 30
  session_timeout: 60
  cleanup_interval: 3
EOF
    fi
}

write_server_config_quantum() {
    local port="$1" psk="$2" mtu="$3" block="$4"
    shift 4
    local ports_json
    ports_json=$(build_ports_json "$@")
    local ports_yaml
    ports_yaml=$(build_ports_yaml "$@")
    mkdir -p "$CONFIG_DIR"
    if [ "$CONFIG_FMT" = "json" ]; then
        cat > "$CONFIG" <<-EOF
{
  "mode": "server",
  "transport": "quantum",
  "psk": "${psk}",
  "log_level": "info",
  "listeners": [
    {
      "addr": "0.0.0.0:${port}",
      "transport": "quantum",
      "ports": [
${ports_json}
      ]
    }
  ],
  "quantum": {
    "mtu": ${mtu},
    "block": "${block}"
  },
$(build_socks5_json)
  "advanced": {
    "tcp_nodelay": true,
    "tcp_keepalive": 1,
    "connection_timeout": 30,
    "session_timeout": 60,
    "cleanup_interval": 3
  }
}
EOF
    else
        cat > "$CONFIG" <<-EOF
mode: server
transport: quantum
psk: "${psk}"
log_level: info
listeners:
  - addr: "0.0.0.0:${port}"
    transport: quantum
    ports:
${ports_yaml}
quantum:
  mtu: ${mtu}
  block: "${block}"
$(build_socks5_yaml)
advanced:
  tcp_nodelay: true
  tcp_keepalive: 1
  connection_timeout: 30
  session_timeout: 60
  cleanup_interval: 3
EOF
    fi
}

write_client_config_quantum() {
    local server_ip="$1" server_port="$2" psk="$3" mtu="$4" block="$5"
    mkdir -p "$CONFIG_DIR"
    if [ "$CONFIG_FMT" = "json" ]; then
        cat > "$CONFIG" <<-EOF
{
  "mode": "client",
  "transport": "quantum",
  "psk": "${psk}",
  "log_level": "info",
  "paths": [
    {
      "transport": "quantum",
      "addr": "${server_ip}:${server_port}",
      "connection_pool": ${CLIENT_CONN_POOL},
      "retry_interval": 3,
      "dial_timeout": 10
    }
  ],
  "quantum": {
    "mtu": ${mtu},
    "block": "${block}"
  },
  "advanced": {
    "tcp_nodelay": true,
    "tcp_keepalive": 1,
    "connection_timeout": 30,
    "session_timeout": 60,
    "cleanup_interval": 3
  }
}
EOF
    else
        cat > "$CONFIG" <<-EOF
mode: client
transport: quantum
psk: "${psk}"
log_level: info
paths:
  - transport: quantum
    addr: "${server_ip}:${server_port}"
    connection_pool: ${CLIENT_CONN_POOL}
    retry_interval: 3
    dial_timeout: 10

quantum:
  mtu: ${mtu}
  block: "${block}"

advanced:
  tcp_nodelay: true
  tcp_keepalive: 1
  connection_timeout: 30
  session_timeout: 60
  cleanup_interval: 3
EOF
    fi
}

write_server_config_tun() {
    local port="$1" psk="$2" listen_ip="$3" dst_ip="$4" local_addr="$5" remote_addr="$6"
    local encap="$7" profile="$8" iface="$9" spoof_src="${10}" spoof_dst="${11}" dcpi="${12}" tun_name="${13}"
    local heartbeat_sec="${14}" idle_timeout_sec="${15}"
    shift 15
    local ports_json
    ports_json=$(build_ports_json "$@")
    local ports_yaml
    ports_yaml=$(build_ports_yaml "$@")
    [ -z "$tun_name" ] && tun_name="dagger0"
    mkdir -p "$CONFIG_DIR"
    
    if [ "$CONFIG_FMT" = "json" ]; then
        cat > "$CONFIG" <<-EOF
{
  "mode": "server",
  "transport": "tun",
  "psk": "${psk}",
  "log_level": "info",
  "listeners": [
    {
      "addr": "0.0.0.0:${port}",
      "transport": "tun",
      "ports": [
${ports_json}
      ]
    }
  ],
  "tun": {
    "encapsulation": "${encap}",
    "name": "${tun_name}",
    "local_addr": "${local_addr}",
    "remote_addr": "${remote_addr}",
    "mtu": 1420,
    "heartbeat_sec": ${heartbeat_sec},
    "idle_timeout_sec": ${idle_timeout_sec}
  },
  "ipx": {
    "mode": "server",
    "profile": "${profile}",
    "listen_ip": "${listen_ip}",
    "dst_ip": "${dst_ip}"
  },
$(build_socks5_json)
  "advanced": {
    "tcp_nodelay": true,
    "tcp_keepalive": 1,
    "connection_timeout": 30,
    "session_timeout": 60,
    "cleanup_interval": 3
  }
}
EOF
    else
        cat > "$CONFIG" <<-EOF
mode: server
transport: tun
psk: "${psk}"
log_level: info
listeners:
  - addr: "0.0.0.0:${port}"
    transport: tun
    ports:
${ports_yaml}
tun:
  encapsulation: "${encap}"
  name: "${tun_name}"
  local_addr: "${local_addr}"
  remote_addr: "${remote_addr}"
  mtu: 1420
  heartbeat_sec: ${heartbeat_sec}
  idle_timeout_sec: ${idle_timeout_sec}
ipx:
  mode: server
  profile: "${profile}"
  listen_ip: "${listen_ip}"
  dst_ip: "${dst_ip}"
$(build_socks5_yaml)
advanced:
  tcp_nodelay: true
  tcp_keepalive: 1
  connection_timeout: 30
  session_timeout: 60
  cleanup_interval: 3
EOF
    fi
}

write_client_config_tun() {
    local server_port="$1" psk="$2" listen_ip="$3" dst_ip="$4" local_addr="$5" remote_addr="$6"
    local encap="$7" profile="$8" iface="$9" spoof_src="${10}" spoof_dst="${11}" dcpi="${12}" tun_name="${13}"
    local heartbeat_sec="${14}" idle_timeout_sec="${15}"
    [ -z "$tun_name" ] && tun_name="dagger0"
    mkdir -p "$CONFIG_DIR"
    
    if [ "$CONFIG_FMT" = "json" ]; then
        cat > "$CONFIG" <<-EOF
{
  "mode": "client",
  "transport": "tun",
  "psk": "${psk}",
  "log_level": "info",
  "paths": [
    {
      "transport": "tun",
      "addr": "${dst_ip}:${server_port}",
      "retry_interval": 3,
      "dial_timeout": 30
    }
  ],
  "tun": {
    "encapsulation": "${encap}",
    "name": "${tun_name}",
    "local_addr": "${local_addr}",
    "remote_addr": "${remote_addr}",
    "mtu": 1420,
    "heartbeat_sec": ${heartbeat_sec},
    "idle_timeout_sec": ${idle_timeout_sec}
  },
  "ipx": {
    "mode": "client",
    "profile": "${profile}",
    "listen_ip": "${listen_ip}",
    "dst_ip": "${dst_ip}"
  },
  "advanced": {
    "tcp_nodelay": true,
    "tcp_keepalive": 1,
    "connection_timeout": 30,
    "session_timeout": 60,
    "cleanup_interval": 3
  }
}
EOF
    else
        cat > "$CONFIG" <<-EOF
mode: client
transport: tun
psk: "${psk}"
log_level: info
paths:
  - transport: tun
    addr: "${dst_ip}:${server_port}"
    retry_interval: 3
    dial_timeout: 30

tun:
  encapsulation: "${encap}"
  name: "${tun_name}"
  local_addr: "${local_addr}"
  remote_addr: "${remote_addr}"
  mtu: 1420
  heartbeat_sec: ${heartbeat_sec}
  idle_timeout_sec: ${idle_timeout_sec}
ipx:
  mode: client
  profile: "${profile}"
  listen_ip: "${listen_ip}"
  dst_ip: "${dst_ip}"

advanced:
  tcp_nodelay: true
  tcp_keepalive: 1
  connection_timeout: 30
  session_timeout: 60
  cleanup_interval: 3
EOF
    fi
}

# ============================================================
# Installation and Management Functions
# ============================================================

install_service_hardened() {
    cat > "$SERVICE_FILE" <<-EOF
[Unit]
Description=DaggerConnect Tunnel (${SERVICE_NAME})
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
SyslogIdentifier=DaggerConnect

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable "$SERVICE_NAME" > /dev/null 2>&1 || true
    ok "Service installed: ${SERVICE_NAME}"
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

list_services() {
    local found=()
    for cfg in "${CONFIG_DIR}"/*.json "${CONFIG_DIR}"/*.yaml; do
        [ -f "$cfg" ] || continue
        local name
        name=$(basename "$cfg")
        name="${name%.*}"
        [ -f "/etc/systemd/system/${name}.service" ] && found+=("${name}.service")
    done
    [ ${#found[@]} -eq 0 ] && return 0
    printf '%s\n' "${found[@]}" | sort -u
}

ask_watchdog_and_optimizer() {
    echo ""
    ask RUN_OPT "Run system optimizer now (BBR, buffers, MTU, DNS, ulimits)? (y/n)" "y"
    if [ "$RUN_OPT" = "y" ] || [ "$RUN_OPT" = "Y" ]; then
        optimize_system
    fi
    
    echo ""
    ask RUN_WD "Install the watchdog (auto-restart on dead/idle tunnel)? (y/n)" "y"
    if [ "$RUN_WD" = "y" ] || [ "$RUN_WD" = "Y" ]; then
        setup_watchdog
    fi
}

# ============================================================
# Server and Client Installation
# ============================================================

install_server() {
    hr "Install Server"
    ensure_binary
    echo ""

    ask_service_name
    echo ""

    ask_transport
    echo ""

    ask PORT "Listen port" "8443"
    echo ""

    ask PSK "PSK  (must match client)" ""
    [ -z "$PSK" ] && PSK="$FIXED_TOKEN" && warn "Using default token: $PSK"
    echo ""

    case "$TRANSPORT" in
        ws|wss)
            ask WS_PATH "WebSocket path" "/ws"
            echo ""
            ;;
        http|https)
            ask HTTP_DOMAIN "Fake domain  (e.g. www.google.com)" "www.google.com"
            ask HTTP_PATH   "Fake path    (e.g. /search)" "/search"
            echo ""
            ;;
        quantum)
            echo ""
            echo -e "  ${DIM}Quantum auto-detects network interface, source IP, and gateway MAC${NC}"
            echo ""
            ask QM_MTU   "MTU" "1350"
            ask QM_BLOCK "KCP header cipher  (aes/salsa20/none)" "aes"
            echo ""
            ;;
        tun)
            echo ""
            echo -e "  ${BOLD}TUN Encapsulation:${NC}"
            echo "    1)  tcp   - plain TCP over TUN"
            echo "    2)  ipx   - raw IP encapsulation"
            echo ""
            ask TUN_ENCAP_CHOICE "Encapsulation" "1"
            case "$TUN_ENCAP_CHOICE" in
                2|ipx) TUN_ENCAP="ipx" ;;
                *)     TUN_ENCAP="tcp" ;;
            esac

            if [ "$TUN_ENCAP" = "ipx" ]; then
                echo ""
                echo -e "  ${BOLD}IPX Profile:${NC}"
                echo "    1)  icmp  - ICMP encapsulation"
                echo "    2)  gre   - GRE (proto 47)"
                echo "    3)  ipip  - IP-in-IP (proto 4)"
                echo "    4)  bip   - BIP/ICMP custom"
                echo ""
                ask TUN_PROFILE_CHOICE "Profile" "1"
                case "$TUN_PROFILE_CHOICE" in
                    2|gre)  TUN_PROFILE="gre"  ;;
                    3|ipip) TUN_PROFILE="ipip" ;;
                    4|bip)  TUN_PROFILE="bip"  ;;
                    *)      TUN_PROFILE="icmp" ;;
                esac
            else
                TUN_PROFILE="icmp"
            fi
            echo ""
            info "TUN : encapsulation=${TUN_ENCAP}  profile=${TUN_PROFILE}"
            echo ""
            _DEFAULT_IP=$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}' | head -1)
            ask TUN_LOCAL_IP "Server real IP" "${_DEFAULT_IP}"
            ask_required TUN_PEER_IP "Client real IP"
            echo ""
            ask_required TUN_LOCAL_ADDR  "TUN local IP   (server side, e.g. 10.0.0.1)"
            ask_required TUN_REMOTE_ADDR "TUN remote IP  (client side, e.g. 10.0.0.2)"
            TUN_LOCAL_ADDR="$(echo "$TUN_LOCAL_ADDR" | cut -d/ -f1)"
            TUN_REMOTE_ADDR="$(echo "$TUN_REMOTE_ADDR" | cut -d/ -f1)"
            echo ""
            ask TUN_IFACE "Network interface  (leave empty for auto-detect)" ""
            ask TUN_NAME  "TUN device name" "dagger0"
            echo ""
            ask TUN_HEARTBEAT_SEC    "Heartbeat interval (sec)" "5"
            ask TUN_IDLE_TIMEOUT_SEC "Idle timeout (sec)" "40"
            echo ""
            ask TUN_SPOOF_CHOICE "Enable IP Spoof (y/n)" "n"
            if [ "$TUN_SPOOF_CHOICE" = "y" ] || [ "$TUN_SPOOF_CHOICE" = "Y" ]; then
                ask TUN_SPOOF_SRC "Spoof Source IP" ""
                ask TUN_SPOOF_DST "Spoof Dest IP  " ""
            else
                TUN_SPOOF_SRC="" TUN_SPOOF_DST=""
            fi
            echo ""
            ask TUN_DCPI_CHOICE "Enable DCPI Mode (y/n)" "n"
            if [ "$TUN_DCPI_CHOICE" = "y" ] || [ "$TUN_DCPI_CHOICE" = "Y" ]; then
                TUN_DCPI="yes"
            else
                TUN_DCPI="no"
            fi
            echo ""
            ;;
    esac

    if [ "$TRANSPORT" = "wss" ] || [ "$TRANSPORT" = "https" ]; then
        ask_ssl_server
        echo ""
    fi

    ask_ports
    echo ""

    ask_socks5
    echo ""

    mkdir -p "$CONFIG_DIR"

    case "$TRANSPORT" in
        tcp)
            write_server_config_tcp "$PORT" "$PSK" "${PORTS[@]}"
            ;;
        ws)
            write_server_config_ws "$PORT" "$PSK" "$WS_PATH" "${PORTS[@]}"
            ;;
        wss)
            write_server_config_wss "$PORT" "$PSK" "$WS_PATH" "$CERT_FILE" "$KEY_FILE" "${PORTS[@]}"
            ;;
        http)
            write_server_config_http "$PORT" "$PSK" "$HTTP_DOMAIN" "$HTTP_PATH" "${PORTS[@]}"
            ;;
        https)
            write_server_config_https "$PORT" "$PSK" "$HTTP_DOMAIN" "$HTTP_PATH" "$CERT_FILE" "$KEY_FILE" "${PORTS[@]}"
            ;;
        quantum)
            write_server_config_quantum "$PORT" "$PSK" "$QM_MTU" "$QM_BLOCK" "${PORTS[@]}"
            ;;
        tun)
            write_server_config_tun "$PORT" "$PSK" "$TUN_LOCAL_IP" "$TUN_PEER_IP" "$TUN_LOCAL_ADDR" "$TUN_REMOTE_ADDR" "$TUN_ENCAP" "$TUN_PROFILE" "$TUN_IFACE" "$TUN_SPOOF_SRC" "$TUN_SPOOF_DST" "$TUN_DCPI" "$TUN_NAME" "$TUN_HEARTBEAT_SEC" "$TUN_IDLE_TIMEOUT_SEC" "${PORTS[@]}"
            ;;
    esac
    ok "Config written: ${CONFIG}"

    install_service_hardened
    start_service

    cat > "$STATE_FILE" <<-EOF
MODE=server
SERVICE_NAME=${SERVICE_NAME}
TRANSPORT=${TRANSPORT}
PORT=${PORT}
PSK=${PSK}
CONFIG=${CONFIG}
EOF

    echo ""
    echo -e "${GREEN}${BOLD}  Server installed successfully.${NC}"
    echo ""
    echo -e "  Service   : ${BOLD}${SERVICE_NAME}${NC}"
    echo -e "  Transport : ${BOLD}${TRANSPORT}${NC}"
    echo -e "  Port      : ${BOLD}${PORT}${NC}"
    echo -e "  PSK       : ${BOLD}${PSK}${NC}"
    echo ""
    echo -e "  Logs      : journalctl -u ${SERVICE_NAME} -f"
    echo ""
    
    ask_watchdog_and_optimizer
}

install_client() {
    hr "Install Client"
    ensure_binary
    echo ""

    ask_service_name
    echo ""

    ask_transport
    echo ""

    if [ "$TRANSPORT" != "tun" ]; then
        ask CLIENT_CONN_POOL "Connections per path" "8"
    fi

    while true; do
        echo -e "        Example : 1.1.1.1:8443"
        ask SERVER_ADDR "Server IP And Port" ""
        SERVER_IP="${SERVER_ADDR%%:*}"
        SERVER_PORT="${SERVER_ADDR##*:}"
        if [ -z "$SERVER_IP" ] || [ -z "$SERVER_PORT" ] || [ "$SERVER_IP" = "$SERVER_PORT" ]; then
            warn "Invalid format. Use IP:PORT (e.g. 1.1.1.1:8443)"
        else
            break
        fi
    done
    echo ""

    ask PSK "PSK  (must match server)" ""
    [ -z "$PSK" ] && PSK="$FIXED_TOKEN" && warn "Using default token: $PSK"
    echo ""

    case "$TRANSPORT" in
        ws|wss)
            ask WS_PATH "WebSocket path  (must match server)" "/ws"
            echo ""
            ;;
        http|https)
            ask HTTP_DOMAIN "Fake domain  (must match server)" "www.google.com"
            ask HTTP_PATH   "Fake path    (must match server)" "/search"
            echo ""
            ;;
        quantum)
            echo ""
            echo -e "  ${DIM}Quantum auto-detects network interface, source IP, and gateway MAC${NC}"
            echo ""
            ask QM_MTU   "MTU" "1350"
            ask QM_BLOCK "KCP header cipher  (must match server, aes/salsa20/none)" "aes"
            echo ""
            ;;
        tun)
            echo ""
            echo -e "  ${BOLD}TUN Encapsulation (must match server):${NC}"
            echo "    1)  tcp   - plain TCP over TUN"
            echo "    2)  ipx   - raw IP encapsulation"
            echo ""
            ask TUN_ENCAP_CHOICE "Encapsulation" "1"
            case "$TUN_ENCAP_CHOICE" in
                2|ipx) TUN_ENCAP="ipx" ;;
                *)     TUN_ENCAP="tcp" ;;
            esac
            if [ "$TUN_ENCAP" = "ipx" ]; then
                echo ""
                echo -e "  ${BOLD}IPX Profile (must match server):${NC}"
                echo "    1)  icmp  2)  gre  3)  ipip  4)  bip"
                echo ""
                ask TUN_PROFILE_CHOICE "Profile" "1"
                case "$TUN_PROFILE_CHOICE" in
                    2|gre)  TUN_PROFILE="gre"  ;;
                    3|ipip) TUN_PROFILE="ipip" ;;
                    4|bip)  TUN_PROFILE="bip"  ;;
                    *)      TUN_PROFILE="icmp" ;;
                esac
            else
                TUN_PROFILE="icmp"
            fi
            echo ""
            _DEFAULT_IP=$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}' | head -1)
            ask TUN_LOCAL_IP "Client real IP" "${_DEFAULT_IP}"
            ask_required TUN_PEER_IP "Server real IP"
            echo ""
            ask_required TUN_LOCAL_ADDR  "TUN local IP   (client side, e.g. 10.0.0.2)"
            ask_required TUN_REMOTE_ADDR "TUN remote IP  (server side, e.g. 10.0.0.1)"
            TUN_LOCAL_ADDR="$(echo "$TUN_LOCAL_ADDR" | cut -d/ -f1)"
            TUN_REMOTE_ADDR="$(echo "$TUN_REMOTE_ADDR" | cut -d/ -f1)"
            echo ""
            ask TUN_IFACE "Network interface  (leave empty for auto-detect)" ""
            ask TUN_NAME  "TUN device name" "dagger0"
            echo ""
            ask TUN_HEARTBEAT_SEC    "Heartbeat interval (sec)" "5"
            ask TUN_IDLE_TIMEOUT_SEC "Idle timeout (sec)" "40"
            echo ""
            ask TUN_SPOOF_CHOICE "Enable IP Spoof (y/n)" "n"
            if [ "$TUN_SPOOF_CHOICE" = "y" ] || [ "$TUN_SPOOF_CHOICE" = "Y" ]; then
                ask TUN_SPOOF_SRC "Spoof Source IP" ""
                ask TUN_SPOOF_DST "Spoof Dest IP  " ""
            else
                TUN_SPOOF_SRC="" TUN_SPOOF_DST=""
            fi
            echo ""
            ask TUN_DCPI_CHOICE "Enable DCPI Mode (y/n)" "n"
            if [ "$TUN_DCPI_CHOICE" = "y" ] || [ "$TUN_DCPI_CHOICE" = "Y" ]; then
                TUN_DCPI="yes"
            else
                TUN_DCPI="no"
            fi
            echo ""
            ;;
    esac

    if [ "$TRANSPORT" = "wss" ] || [ "$TRANSPORT" = "https" ]; then
        ask_ssl_client
        echo ""
    fi

    mkdir -p "$CONFIG_DIR"

    case "$TRANSPORT" in
        tcp)
            write_client_config_tcp "$SERVER_IP" "$SERVER_PORT" "$PSK"
            ;;
        ws)
            write_client_config_ws "$SERVER_IP" "$SERVER_PORT" "$PSK" "$WS_PATH"
            ;;
        wss)
            write_client_config_wss "$SERVER_IP" "$SERVER_PORT" "$PSK" "$WS_PATH" "$TLS_INSECURE"
            ;;
        http)
            write_client_config_http "$SERVER_IP" "$SERVER_PORT" "$PSK" "$HTTP_DOMAIN" "$HTTP_PATH"
            ;;
        https)
            write_client_config_https "$SERVER_IP" "$SERVER_PORT" "$PSK" "$HTTP_DOMAIN" "$HTTP_PATH" "$TLS_INSECURE"
            ;;
        quantum)
            write_client_config_quantum "$SERVER_IP" "$SERVER_PORT" "$PSK" "$QM_MTU" "$QM_BLOCK"
            ;;
        tun)
            write_client_config_tun "$SERVER_PORT" "$PSK" "$TUN_LOCAL_IP" "$TUN_PEER_IP" "$TUN_LOCAL_ADDR" "$TUN_REMOTE_ADDR" "$TUN_ENCAP" "$TUN_PROFILE" "$TUN_IFACE" "$TUN_SPOOF_SRC" "$TUN_SPOOF_DST" "$TUN_DCPI" "$TUN_NAME" "$TUN_HEARTBEAT_SEC" "$TUN_IDLE_TIMEOUT_SEC"
            ;;
    esac
    ok "Config written: ${CONFIG}"

    install_service_hardened
    start_service

    cat > "$STATE_FILE" <<-EOF
MODE=client
SERVICE_NAME=${SERVICE_NAME}
TRANSPORT=${TRANSPORT}
SERVER=${SERVER_IP}:${SERVER_PORT}
PSK=${PSK}
CONFIG=${CONFIG}
EOF

    echo ""
    echo -e "${GREEN}${BOLD}  Client installed successfully.${NC}"
    echo ""
    echo -e "  Service   : ${BOLD}${SERVICE_NAME}${NC}"
    echo -e "  Transport : ${BOLD}${TRANSPORT}${NC}"
    echo -e "  Server    : ${BOLD}${SERVER_IP}:${SERVER_PORT}${NC}"
    echo -e "  PSK       : ${BOLD}${PSK}${NC}"
    echo ""
    echo -e "  Logs      : journalctl -u ${SERVICE_NAME} -f"
    echo ""
    
    ask_watchdog_and_optimizer
}

# ============================================================
# Management Functions
# ============================================================

show_status() {
    hr "Service Status"
    echo ""

    mapfile -t SERVICES < <(list_services)

    if [ ${#SERVICES[@]} -eq 0 ]; then
        warn "No DaggerConnect services found."
        return
    fi

    echo "=== DaggerConnect Services ==="
    for svc in "${SERVICES[@]}"; do
        echo "--- $svc ---"
        systemctl status "$svc" --no-pager -l 2>/dev/null | head -n 6
        echo ""
    done

    echo "=== Recent warnings / errors ==="
    local found_warn=0
    for svc in "${SERVICES[@]}"; do
        local warn_log
        warn_log=$(journalctl -u "$svc" -n 20 --no-pager 2>/dev/null | grep -iE "error|failed|panic" | tail -n 3)
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
        warn "No DaggerConnect services found."
        return 1
    fi

    if [ ${#SERVICES[@]} -eq 1 ]; then
        PICKED_SVC="${SERVICES[0]}"
        return 0
    fi

    echo -e "  ${BOLD}Available services:${NC}"
    for i in "${!SERVICES[@]}"; do
        local st="stopped"
        systemctl is-active --quiet "${SERVICES[$i]}" && st="${GREEN}running${NC}" || st="${RED}stopped${NC}"
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
    systemctl is-active --quiet "$svc" && st="${GREEN}running${NC}" || st="${RED}stopped${NC}"
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
    local cfg=""
    [ -f "${CONFIG_DIR}/${svc_name}.json" ] && cfg="${CONFIG_DIR}/${svc_name}.json"
    [ -f "${CONFIG_DIR}/${svc_name}.yaml" ] && cfg="${CONFIG_DIR}/${svc_name}.yaml"

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
            if [ -n "$cfg" ]; then
                cat "$cfg"
            else
                warn "Config not found."
            fi
            ;;
        8)
            if [ -n "$cfg" ]; then
                local ed="${EDITOR:-nano}"
                cp "$cfg" "${cfg}.bak" 2>/dev/null && info "Backup saved: ${cfg}.bak"
                info "Opening ${cfg} in ${ed} ..."
                "$ed" "$cfg"
                echo ""
                ask DORESTART "Restart the service to apply changes? (y/n)" "y"
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
            ask CONFIRM "Confirm? (yes/no)" "no"
            if [ "$CONFIRM" != "yes" ]; then
                info "Cancelled."
                return
            fi
            systemctl disable --now "$svc" >/dev/null 2>&1 || true
            rm -f "/etc/systemd/system/${svc}"
            if [ -n "$cfg" ]; then
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
        warn "No DaggerConnect services found."
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
        warn "No DaggerConnect services found."
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

    local cfg=""
    [ -f "${CONFIG_DIR}/${svc}.json" ] && cfg="${CONFIG_DIR}/${svc}.json"
    [ -f "${CONFIG_DIR}/${svc}.yaml" ] && cfg="${CONFIG_DIR}/${svc}.yaml"
    if [ -z "$cfg" ]; then
        warn "No config file found for ${svc}."
        return 0
    fi

    local ed="${EDITOR:-nano}"
    cp "$cfg" "${cfg}.bak" 2>/dev/null && info "Backup saved: ${cfg}.bak"
    info "Opening ${cfg} in ${ed} ..."
    "$ed" "$cfg"

    echo ""
    ask DORESTART "Restart the service to apply changes? (y/n)" "y"
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
        warn "No DaggerConnect services found."
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
    ask CONFIRM "Confirm? (yes/no)" "no"
    if [ "$CONFIRM" != "yes" ]; then
        info "Cancelled."
        return
    fi

    for svc in "${TARGETS[@]}"; do
        svc_name="${svc%.service}"
        systemctl stop    "$svc_name" 2>/dev/null || true
        systemctl disable "$svc_name" 2>/dev/null || true
        rm -f "/etc/systemd/system/${svc_name}.service"
        cfg_json="${CONFIG_DIR}/${svc_name}.json"
        cfg_yaml="${CONFIG_DIR}/${svc_name}.yaml"
        if [ -f "$cfg_json" ]; then
            rm -f "$cfg_json"
            ok "Removed config: ${cfg_json}"
        fi
        if [ -f "$cfg_yaml" ]; then
            rm -f "$cfg_yaml"
            ok "Removed config: ${cfg_yaml}"
        fi
        rm -f "/etc/letsencrypt/renewal-hooks/deploy/daggerconnect-${svc_name}.sh" 2>/dev/null || true
        ok "Removed service: ${svc_name}"
    done

    systemctl daemon-reload
    
    # Cleanup watchdog if no services left
    local remaining
    remaining=$(list_services | wc -l)
    if [ "$remaining" -eq 0 ]; then
        systemctl disable --now daggerconnect-watchdog.timer 2>/dev/null || true
        rm -f /etc/systemd/system/daggerconnect-watchdog.{service,timer}
        rm -f "$WATCHDOG_SCRIPT"
        systemctl daemon-reload
        ok "Watchdog removed."
    fi
    
    if [ -d "$CONFIG_DIR" ] && [ -z "$(ls -A "$CONFIG_DIR" 2>/dev/null)" ]; then
        rmdir "$CONFIG_DIR"
    fi
    
    ok "Done."
}

# ============================================================
# Main Menu
# ============================================================

show_banner() {
    echo ""
    echo -e "  ${CYAN}${BOLD}DaggerConnect Installer - Full Edition${NC}"
    echo -e "  ${DIM}Combined DaggerConnect and Backhaul features${NC}"
    echo ""
}

show_menu() {
    echo -e "${BOLD}  Select an option:${NC}"
    echo ""
    echo -e "  ${BOLD}Install${NC}"
    echo "    1)  Install Server"
    echo "    2)  Install Client"
    echo ""
    echo -e "  ${BOLD}Manage${NC}"
    echo "    3)  Service Status"
    echo "    4)  Service Control  (restart/stop/start/edit/delete)"
    echo "    5)  Edit Config"
    echo ""
    echo -e "  ${BOLD}Logs${NC}"
    echo "    6)  View Logs        (last 80 lines)"
    echo "    7)  Live Logs        (follow)"
    echo ""
    echo -e "  ${BOLD}System${NC}"
    echo "    8)  System Optimizer (BBR + buffers + MTU + DNS + ulimits)"
    echo "    9)  Watchdog         (auto-restart on dead/idle tunnel)"
    echo ""
    echo -e "  ${BOLD}Other${NC}"
    echo "   10)  Remove"
    echo "   11)  Update Core (Binary)"
    echo "    0)  Exit"
    echo ""
    ask CHOICE "Choice" ""
}

run_action() {
    ( "$@" )
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

mkdir -p "$CONFIG_DIR"

while true; do
    clear 2>/dev/null || true
    show_banner
    show_menu

    case "$CHOICE" in
        1) run_action install_server ;;
        2) run_action install_client ;;
        3) run_action show_status ;;
        4) run_action service_control ;;
        5) run_action edit_config ;;
        6) run_action show_logs ;;
        7) run_action show_logs_live ;;
        8) run_action optimize_system ;;
        9) run_action setup_watchdog ;;
        10) run_action uninstall ;;
        11) run_action download_binary ;;
        0) echo -e "\n  ${CYAN}Bye.${NC}\n"; exit 0 ;;
        *) warn "Invalid choice: ${CHOICE}" ;;
    esac

    pause
done
