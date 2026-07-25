#!/bin/bash

# Backhaul Tunnel Manager — v8
# Official Musixal/Backhaul release binary — encrypted reverse port forwarding.
#
# v8 changes vs v7 (UX/architecture ported over from a DaggerConnect-style installer):
#   - Named, multi-service model: install as many server/client tunnels on one
#     box as you like, each with its own label, config, and systemd unit
#     (instead of one fixed "iranPORT"/"kharejPORT" naming scheme).
#   - Colored, timestamped logging (info/ok/warn/step/error) + a service
#     picker used everywhere (status/control/edit/logs/remove).
#   - Smart binary installer/updater: checks the latest GitHub tag, compares
#     against the installed version, backs up before replacing, rolls back on
#     a broken download, and offers to restart running tunnels after an update.
#   - TLS for wss/wssmux now has 3 modes: self-signed (quick test), automatic
#     Let's Encrypt via certbot (with an auto-renew restart hook), or custom
#     cert/key paths -- each service gets its own cert.
#   - Advanced tuning profiles (auto/stable/aggressive/low_latency/
#     low_hardware/custom) mapped onto Backhaul's real tunable fields
#     (keepalive_period, heartbeat, channel_size, mux_con, connection_pool,
#     aggressive_pool, retry_interval, log_level).
#   - Config editor with automatic backup + revert-on-failed-restart.
#   - Live log following and last-N-lines log viewing, per service.
#   - Everything from v7 kept: system optimizer (BBR/buffers/MTU/DNS/ulimits)
#     and the idle-connection watchdog, both updated for the new multi-service
#     layout.
#
# NOT ported from the other installer, and why: that script targets a
# different binary (DaggerConnect) with its own config schema. Its quantum /
# tun / http-https-mimicry transports and SOCKS5 proxy option are features of
# THAT binary, not of Backhaul -- Backhaul's real transports are only
# tcp / tcpmux / ws / wsmux / wss / wssmux, and its TOML schema has no SOCKS5
# block. Inventing those fields here would just produce a config Backhaul
# can't parse, so they're intentionally left out.
#
# Run this SEPARATELY on each server (Iran and Kharej). No SSH auto-sync.

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
CONFIG_DIR="${INSTALL_DIR}/configs"
CERTS_DIR="${INSTALL_DIR}/certs"
WATCHDOG_SCRIPT="${INSTALL_DIR}/watchdog.sh"
WATCHDOG_LOG="${INSTALL_DIR}/watchdog.log"
WATCHDOG_STATE_DIR="${INSTALL_DIR}/watchdog-state"
WATCHDOG_IDLE_THRESHOLD=30
FIXED_TOKEN="123"

SERVICE_NAME=""
SERVICE_FILE=""
CONFIG=""
TRANSPORT=""
SSL_MODE=""
DOMAIN=""
CERT_FILE=""
KEY_FILE=""

# ============================================================
# Logging helpers
# ============================================================

_ts()   { date '+%H:%M:%S'; }
info()  { echo -e "${DIM}$(_ts)${NC} ${CYAN}[INFO]${NC}  $*"; }
ok()    { echo -e "${DIM}$(_ts)${NC} ${GREEN}[ OK ]${NC}  $*"; }
warn()  { echo -e "${DIM}$(_ts)${NC} ${YELLOW}[WARN]${NC}  $*"; }
step()  { echo -e "${DIM}$(_ts)${NC} ${MAGENTA}[STEP]${NC}  $*"; }
error() { echo -e "${DIM}$(_ts)${NC} ${RED}[ERR ]${NC}  $*"; }
hr()    { echo -e "\n${BOLD}${CYAN}== $* ==${NC}"; }

ask() {
    local var="$1" prompt="$2" default="$3"
    if [ -n "$default" ]; then
        echo -ne "${YELLOW}?${NC} $prompt [${default}]: "
    else
        echo -ne "${YELLOW}?${NC} $prompt: "
    fi
    read -r input
    [ -z "$input" ] && [ -n "$default" ] && input="$default"
    eval "$var=\"\$input\""
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

if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}[ERR ]${NC}  Please run as root (sudo)."
    exit 1
fi

mkdir -p "$INSTALL_DIR" "$CONFIG_DIR" "$CERTS_DIR"

# ============================================================
# Basic helpers
# ============================================================

detect_public_ip() {
    curl -fsSL -4 https://ifconfig.me 2>/dev/null || curl -fsSL -4 https://api.ipify.org 2>/dev/null || echo ""
}

detect_default_iface() {
    local iface
    iface=$(ip -o -4 route show to default | awk '{print $5}' | head -n1)
    [ -z "$iface" ] && iface=$(ip link show | grep "state UP" | head -1 | awk '{print $2}' | cut -d: -f1)
    [ -z "$iface" ] && iface="eth0"
    echo "$iface"
}

gen_port() {
    echo $(( (RANDOM % 40000) + 20000 ))
}

# ============================================================
# Binary install / smart update
# ============================================================

download_backhaul() {
    step "Checking for the latest Backhaul release ..."
    local LATEST_VERSION
    LATEST_VERSION=$(curl -fsSL "https://api.github.com/repos/${REPO}/releases/latest" 2>/dev/null | grep '"tag_name":' | head -1 | sed -E 's/.*"([^"]+)".*/\1/')

    if [ -z "$LATEST_VERSION" ]; then
        warn "Could not reach GitHub to check the latest version."
        if [ -x "$BINARY" ]; then
            ok "Using existing local binary: ${BINARY}"
            return 0
        fi
        error "No local binary and GitHub is unreachable. Cannot continue."
        return 1
    fi
    info "Latest release: ${LATEST_VERSION}"

    local CURRENT_VERSION=""
    if [ -x "$BINARY" ]; then
        CURRENT_VERSION=$("$BINARY" -v 2>&1 | grep -oE 'v?[0-9]+\.[0-9]+(\.[0-9]+)?' | head -1)
    fi
    if [ -n "$CURRENT_VERSION" ] && [ "$CURRENT_VERSION" = "$LATEST_VERSION" ]; then
        ok "Already on the latest version (${CURRENT_VERSION})."
        return 0
    fi

    local arch asset_arch url
    arch=$(uname -m)
    case "$arch" in
        x86_64) asset_arch="amd64" ;;
        aarch64) asset_arch="arm64" ;;
        *) error "Unsupported architecture: $arch"; return 1 ;;
    esac
    url=$(curl -fsSL "https://api.github.com/repos/${REPO}/releases/latest" \
        | grep "browser_download_url" | grep "linux_${asset_arch}" | grep -v ".sha256" \
        | head -n1 | cut -d '"' -f4)
    if [ -z "$url" ]; then
        warn "Could not auto-resolve a release asset URL."
        ask url "Paste the correct .tar.gz download URL" ""
    fi

    [ -x "$BINARY" ] && cp "$BINARY" "${BINARY}.backup"

    if [ -n "$CURRENT_VERSION" ]; then
        step "Updating Backhaul: ${CURRENT_VERSION} -> ${LATEST_VERSION} ..."
    else
        step "Downloading Backhaul ${LATEST_VERSION} ..."
    fi

    rm -f "${INSTALL_DIR}/backhaul.tar.gz"
    local attempt=0
    until curl -fSL --retry 3 --retry-delay 2 -o "${INSTALL_DIR}/backhaul.tar.gz" "$url"; do
        attempt=$((attempt + 1))
        if [ "$attempt" -ge 3 ]; then
            warn "Download failed after multiple attempts."
            [ -f "${BINARY}.backup" ] && mv -f "${BINARY}.backup" "$BINARY" && warn "Keeping previous binary."
            return 1
        fi
        echo "Retrying download..."
        sleep 2
    done

    if [ ! -s "${INSTALL_DIR}/backhaul.tar.gz" ] || ! tar -tzf "${INSTALL_DIR}/backhaul.tar.gz" >/dev/null 2>&1; then
        warn "Downloaded archive is empty or invalid."
        rm -f "${INSTALL_DIR}/backhaul.tar.gz"
        [ -f "${BINARY}.backup" ] && mv -f "${BINARY}.backup" "$BINARY" && warn "Keeping previous binary."
        return 1
    fi

    tar -xzf "${INSTALL_DIR}/backhaul.tar.gz" -C "$INSTALL_DIR"
    rm -f "${INSTALL_DIR}/backhaul.tar.gz" "${BINARY}.backup"
    chmod +x "$BINARY"
    ok "Backhaul is up to date (${LATEST_VERSION})."

    mapfile -t SERVICES < <(list_services)
    if [ ${#SERVICES[@]} -gt 0 ]; then
        echo ""
        warn "Running tunnels are still using the old binary in memory until restarted."
        ask RESTART_CHOICE "Restart all Backhaul services now? (y/n)" "y"
        if [ "$RESTART_CHOICE" = "y" ] || [ "$RESTART_CHOICE" = "Y" ]; then
            for svc in "${SERVICES[@]}"; do
                systemctl restart "$svc" && ok "Restarted: ${svc}" || warn "Failed to restart: ${svc}"
            done
        fi
    fi
}

ensure_binary() {
    if [ -x "$BINARY" ]; then
        return 0
    fi
    echo ""
    warn "No Backhaul binary found at ${BINARY}."
    ask DOWNLOAD_CHOICE "Download the latest release now? (y/n)" "y"
    if [ "$DOWNLOAD_CHOICE" != "y" ] && [ "$DOWNLOAD_CHOICE" != "Y" ]; then
        error "Cannot continue without a binary."
        return 1
    fi
    download_backhaul
}

# ============================================================
# TLS certificates (self-signed / Let's Encrypt / custom)
# ============================================================

install_certbot() {
    if command -v certbot &>/dev/null; then
        ok "certbot already installed."
        return
    fi
    info "Installing certbot..."
    if command -v apt-get &>/dev/null; then
        apt-get update -qq
        apt-get install -y -qq certbot
    elif command -v yum &>/dev/null; then
        yum install -y -q certbot
    elif command -v dnf &>/dev/null; then
        dnf install -y -q certbot
    else
        error "Cannot install certbot — package manager not found. Install it manually."
        return 1
    fi
    ok "certbot installed."
}

obtain_cert_auto() {
    local domain="$1"
    local cert_dir="/etc/letsencrypt/live/${domain}"

    install_certbot || return 1

    if ss -tlnp 2>/dev/null | grep -q ':80 '; then
        warn "Port 80 is in use. Standalone certbot will likely fail unless it's freed."
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
        error "certbot failed. Make sure port 80 is open and the domain points to this server."
        return 1
    fi

    CERT_FILE="${cert_dir}/fullchain.pem"
    KEY_FILE="${cert_dir}/privkey.pem"

    if [ ! -f "$CERT_FILE" ] || [ ! -f "$KEY_FILE" ]; then
        error "Certificate files not found at ${cert_dir}"
        return 1
    fi

    ok "Cert : ${CERT_FILE}"
    ok "Key  : ${KEY_FILE}"

    local hook_dir="/etc/letsencrypt/renewal-hooks/deploy"
    mkdir -p "$hook_dir"
    cat > "${hook_dir}/backhaul-${SERVICE_NAME}.sh" << EOF
#!/bin/bash
systemctl restart ${SERVICE_NAME} 2>/dev/null || true
EOF
    chmod +x "${hook_dir}/backhaul-${SERVICE_NAME}.sh"
    ok "Auto-renew hook installed."
}

ask_ssl_server() {
    echo ""
    echo -e "  ${BOLD}TLS Certificate:${NC}"
    echo "    1)  Self-signed   — quick, works immediately (fine for testing)"
    echo "    2)  Automatic SSL — Let's Encrypt via certbot (needs a real domain + port 80)"
    echo "    3)  Custom SSL    — provide your own cert/key paths"
    echo ""
    while true; do
        ask SSL_CHOICE "TLS Mode" "1"
        case "$SSL_CHOICE" in
            1|self|selfsigned) SSL_MODE="self";   break ;;
            2|auto)             SSL_MODE="auto";   break ;;
            3|custom)           SSL_MODE="custom"; break ;;
            *) warn "Please enter 1, 2 or 3." ;;
        esac
    done

    case "$SSL_MODE" in
        self)
            CERT_FILE="${CERTS_DIR}/${SERVICE_NAME}.crt"
            KEY_FILE="${CERTS_DIR}/${SERVICE_NAME}.key"
            if [ ! -f "$CERT_FILE" ] || [ ! -f "$KEY_FILE" ]; then
                info "Generating self-signed certificate..."
                openssl req -x509 -newkey rsa:2048 -nodes \
                    -keyout "$KEY_FILE" -out "$CERT_FILE" \
                    -days 3650 -subj "/CN=backhaul" >/dev/null 2>&1
            fi
            ok "Cert : ${CERT_FILE}"
            ok "Key  : ${KEY_FILE}"
            warn "Self-signed certs may be rejected by strict TLS clients. If the client"
            warn "side fails to connect, switch to Automatic or Custom SSL instead."
            ;;
        auto)
            echo ""
            ask_required DOMAIN "Domain name  (e.g. tunnel.example.com)"
            echo ""
            obtain_cert_auto "$DOMAIN"
            ;;
        custom)
            echo ""
            while true; do
                ask_required CERT_FILE "Certificate file path  (e.g. /etc/ssl/certs/cert.pem)"
                [ -f "$CERT_FILE" ] && break
                warn "File not found: ${CERT_FILE}"
            done
            while true; do
                ask_required KEY_FILE "Private key file path  (e.g. /etc/ssl/private/key.pem)"
                [ -f "$KEY_FILE" ] && break
                warn "File not found: ${KEY_FILE}"
            done
            ok "Cert : ${CERT_FILE}"
            ok "Key  : ${KEY_FILE}"
            ;;
    esac
}

# ============================================================
# Service naming / transport selection
# ============================================================

ask_service_name() {
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

        local svc_file="/etc/systemd/system/${LABEL}.service"
        local cfg_file="${CONFIG_DIR}/${LABEL}.toml"

        if [ -f "$svc_file" ] || [ -f "$cfg_file" ]; then
            echo ""
            warn "Already exists: ${LABEL}"
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

    SERVICE_NAME="${LABEL}"
    SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
    CONFIG="${CONFIG_DIR}/${SERVICE_NAME}.toml"

    echo ""
    info "Service Name : ${SERVICE_NAME}"
    info "Config File  : ${CONFIG}"
}

ask_transport() {
    echo ""
    echo -e "  ${BOLD}Available Transports:${NC}"
    echo "    1)  tcp     — Raw TCP tunnel"
    echo "    2)  tcpmux  — TCP + multiplexing (many concurrent connections)"
    echo "    3)  ws      — WebSocket tunnel"
    echo "    4)  wsmux   — WebSocket + multiplexing"
    echo "    5)  wss     — WebSocket Secure (TLS), looks like HTTPS (recommended)"
    echo "    6)  wssmux  — WebSocket Secure + multiplexing"
    echo ""
    while true; do
        ask T_CHOICE "Transport" "5"
        case "$T_CHOICE" in
            1|tcp)    TRANSPORT="tcp";    break ;;
            2|tcpmux) TRANSPORT="tcpmux"; break ;;
            3|ws)     TRANSPORT="ws";     break ;;
            4|wsmux)  TRANSPORT="wsmux";  break ;;
            5|wss)    TRANSPORT="wss";    break ;;
            6|wssmux) TRANSPORT="wssmux"; break ;;
            *) warn "Please enter 1-6 or a transport name." ;;
        esac
    done
    info "Transport : ${TRANSPORT}"
}

# ============================================================
# Ports
# ============================================================

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

build_ports_toml() {
    local first=1
    for p in "$@"; do
        if [ "$first" = "1" ]; then
            printf '    "%s"' "$p"
            first=0
        else
            printf ',\n    "%s"' "$p"
        fi
    done
    echo ""
}

# ============================================================
# Advanced tuning profiles
# ============================================================

ADV_PROFILE="auto"
ADV_KEEPALIVE="20"
ADV_HEARTBEAT="15"
ADV_CHANNEL_SIZE="16384"
ADV_MUX_CON="8"
ADV_CONN_POOL="8"
ADV_AGGRESSIVE_POOL="true"
ADV_RETRY_INTERVAL="1"
ADV_LOG_LEVEL="warn"

apply_profile() {
    local p="$1"
    ADV_PROFILE="$p"
    case "$p" in
        auto)
            ADV_KEEPALIVE=20  ADV_HEARTBEAT=15 ADV_CHANNEL_SIZE=16384 ADV_MUX_CON=8
            ADV_CONN_POOL=8   ADV_AGGRESSIVE_POOL=true  ADV_RETRY_INTERVAL=1 ADV_LOG_LEVEL="warn"
            ;;
        stable)
            ADV_KEEPALIVE=30  ADV_HEARTBEAT=20 ADV_CHANNEL_SIZE=4096  ADV_MUX_CON=8
            ADV_CONN_POOL=8   ADV_AGGRESSIVE_POOL=false ADV_RETRY_INTERVAL=3 ADV_LOG_LEVEL="info"
            ;;
        aggressive)
            ADV_KEEPALIVE=10  ADV_HEARTBEAT=8  ADV_CHANNEL_SIZE=32768 ADV_MUX_CON=16
            ADV_CONN_POOL=16  ADV_AGGRESSIVE_POOL=true  ADV_RETRY_INTERVAL=1 ADV_LOG_LEVEL="warn"
            ;;
        low_latency)
            ADV_KEEPALIVE=10  ADV_HEARTBEAT=5  ADV_CHANNEL_SIZE=2048  ADV_MUX_CON=4
            ADV_CONN_POOL=4   ADV_AGGRESSIVE_POOL=false ADV_RETRY_INTERVAL=1 ADV_LOG_LEVEL="info"
            ;;
        low_hardware)
            ADV_KEEPALIVE=60  ADV_HEARTBEAT=30 ADV_CHANNEL_SIZE=1024  ADV_MUX_CON=2
            ADV_CONN_POOL=2   ADV_AGGRESSIVE_POOL=false ADV_RETRY_INTERVAL=5 ADV_LOG_LEVEL="info"
            ;;
    esac
}

ask_advanced() {
    echo ""
    echo -e "  ${BOLD}Tuner Profile:${NC}"
    echo "    1)  auto         — Recommended low-latency defaults"
    echo "    2)  stable       — Balanced, conservative for most setups"
    echo "    3)  aggressive   — Max throughput, higher memory usage"
    echo "    4)  low_latency  — Minimum delay, small buffers"
    echo "    5)  low_hardware — Weak VPS / low RAM"
    echo "    6)  custom       — Set every value manually"
    echo ""
    ask ADV_CHOICE "Tuner Profile" "1"
    echo ""
    case "$ADV_CHOICE" in
        1|auto)         apply_profile "auto" ;;
        2|stable)       apply_profile "stable" ;;
        3|aggressive)   apply_profile "aggressive" ;;
        4|low_latency)  apply_profile "low_latency" ;;
        5|low_hardware) apply_profile "low_hardware" ;;
        6|custom)
            ADV_PROFILE="custom"
            ask ADV_KEEPALIVE       "keepalive_period    (sec)"   "20"
            ask ADV_HEARTBEAT       "heartbeat           (sec)"   "15"
            ask ADV_CHANNEL_SIZE    "channel_size        (count)" "16384"
            ask ADV_MUX_CON         "mux_con             (count)" "8"
            ask ADV_CONN_POOL       "connection_pool     (client only)" "8"
            ask ADV_AGGRESSIVE_POOL "aggressive_pool     (true/false, client only)" "true"
            ask ADV_RETRY_INTERVAL  "retry_interval      (sec, client only)" "1"
            ask ADV_LOG_LEVEL       "log_level           (info/warn/error)" "warn"
            ;;
        *) apply_profile "auto" ;;
    esac
    info "Tuner Profile : ${ADV_PROFILE}"
}

# ============================================================
# Config writers
# ============================================================

write_server_config() {
    local cfg="$1" port="$2" token="$3" transport="$4" cert="$5" key="$6"
    shift 6
    local ports_toml
    ports_toml=$(build_ports_toml "$@")
    {
        echo "[server]"
        echo "bind_addr = \"0.0.0.0:${port}\""
        echo "transport = \"${transport}\""
        echo "token = \"${token}\""
        echo "keepalive_period = ${ADV_KEEPALIVE}"
        echo "nodelay = true"
        echo "channel_size = ${ADV_CHANNEL_SIZE}"
        echo "heartbeat = ${ADV_HEARTBEAT}"
        echo "mux_con = ${ADV_MUX_CON}"
        if [ "$transport" = "wss" ] || [ "$transport" = "wssmux" ]; then
            echo "tls_cert = \"${cert}\""
            echo "tls_key = \"${key}\""
        fi
        echo "sniffer = false"
        echo "web_port = 0"
        echo "log_level = \"${ADV_LOG_LEVEL}\""
        echo ""
        echo "ports = ["
        echo "$ports_toml"
        echo "]"
    } > "$cfg"
}

write_client_config() {
    local cfg="$1" server_ip="$2" server_port="$3" token="$4" transport="$5"
    {
        echo "[client]"
        echo "remote_addr = \"${server_ip}:${server_port}\""
        echo "transport = \"${transport}\""
        echo "token = \"${token}\""
        echo "connection_pool = ${ADV_CONN_POOL}"
        echo "aggressive_pool = ${ADV_AGGRESSIVE_POOL}"
        echo "keepalive_period = ${ADV_KEEPALIVE}"
        echo "nodelay = true"
        echo "retry_interval = ${ADV_RETRY_INTERVAL}"
        echo "sniffer = false"
        echo "web_port = 0"
        echo "log_level = \"${ADV_LOG_LEVEL}\""
    } > "$cfg"
}

# ============================================================
# systemd service management
# ============================================================

install_service() {
    cat > "$SERVICE_FILE" << EOF
[Unit]
Description=Backhaul Tunnel (${SERVICE_NAME})
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
SyslogIdentifier=backhaul-${SERVICE_NAME}

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable "${SERVICE_NAME}.service" > /dev/null 2>&1
    ok "Service installed: ${SERVICE_NAME}"
}

start_service() {
    systemctl restart "${SERVICE_NAME}.service"
    sleep 2
    if systemctl is-active --quiet "${SERVICE_NAME}.service"; then
        ok "Service is running."
    else
        warn "Service failed to start. Logs:"
        journalctl -u "${SERVICE_NAME}.service" -n 20 --no-pager
    fi
}

list_services() {
    local found=()
    for cfg in "${CONFIG_DIR}"/*.toml; do
        [ -f "$cfg" ] || continue
        local name
        name=$(basename "$cfg" .toml)
        [ -f "/etc/systemd/system/${name}.service" ] && found+=("${name}.service")
    done
    [ ${#found[@]} -eq 0 ] && return 0
    printf '%s\n' "${found[@]}" | sort -u
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
        local st
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

# ============================================================
# Install flows
# ============================================================

install_server() {
    hr "Install Server"
    ensure_binary || return
    echo ""

    ask_service_name
    echo ""

    ask_transport
    echo ""

    local PORT_DEFAULT
    PORT_DEFAULT=$(gen_port)
    ask PORT "Listen port" "$PORT_DEFAULT"
    echo ""

    ask TOKEN "Token / PSK  (must match the client)" "$FIXED_TOKEN"
    echo ""

    CERT_FILE="" KEY_FILE=""
    if [ "$TRANSPORT" = "wss" ] || [ "$TRANSPORT" = "wssmux" ]; then
        ask_ssl_server
        echo ""
    fi

    ask_ports
    echo ""

    ask_advanced
    echo ""

    write_server_config "$CONFIG" "$PORT" "$TOKEN" "$TRANSPORT" "$CERT_FILE" "$KEY_FILE" "${PORTS[@]}"
    ok "Config written: ${CONFIG}"

    install_service
    start_service

    echo ""
    echo -e "${GREEN}${BOLD}  Server installed successfully.${NC}"
    echo ""
    echo -e "  Service   : ${BOLD}${SERVICE_NAME}${NC}"
    echo -e "  Transport : ${BOLD}${TRANSPORT}${NC}"
    echo -e "  Port      : ${BOLD}${PORT}${NC}"
    echo -e "  Token     : ${BOLD}${TOKEN}${NC}"
    [ -n "$CERT_FILE" ] && echo -e "  Cert      : ${BOLD}${CERT_FILE}${NC}"
    echo -e "  Config    : ${BOLD}${CONFIG}${NC}"
    echo -e "  Logs      : journalctl -u ${SERVICE_NAME} -f"
    if [ "$TOKEN" = "$FIXED_TOKEN" ]; then
        echo -e "  ${DIM}(Reminder: token is the default '${FIXED_TOKEN}' — fine for testing, weak for production.)${NC}"
    fi
    echo ""

    ask RUNOPT "Run system optimizer now (BBR, buffers, MTU, DNS, ulimits)? (y/n)" "n"
    [ "$RUNOPT" = "y" ] || [ "$RUNOPT" = "Y" ] && optimize_system

    ask RUNWD "Install/refresh the watchdog (auto-restart on dead/idle tunnel)? (y/n)" "y"
    [ "$RUNWD" = "y" ] || [ "$RUNWD" = "Y" ] && setup_watchdog
}

install_client() {
    hr "Install Client"
    ensure_binary || return
    echo ""

    ask_service_name
    echo ""

    ask_transport
    echo ""

    local SERVER_IP SERVER_PORT
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

    ask TOKEN "Token / PSK  (must match the server)" "$FIXED_TOKEN"
    echo ""

    if [ "$TRANSPORT" = "wss" ] || [ "$TRANSPORT" = "wssmux" ]; then
        warn "This client connects over TLS. If the server uses a self-signed"
        warn "certificate, the handshake may be rejected — use Automatic or"
        warn "Custom SSL on the server side if the client fails to connect."
        echo ""
    fi

    ask_advanced
    echo ""

    write_client_config "$CONFIG" "$SERVER_IP" "$SERVER_PORT" "$TOKEN" "$TRANSPORT"
    ok "Config written: ${CONFIG}"

    install_service
    start_service

    echo ""
    echo -e "${GREEN}${BOLD}  Client installed successfully.${NC}"
    echo ""
    echo -e "  Service   : ${BOLD}${SERVICE_NAME}${NC}"
    echo -e "  Transport : ${BOLD}${TRANSPORT}${NC}"
    echo -e "  Server    : ${BOLD}${SERVER_IP}:${SERVER_PORT}${NC}"
    echo -e "  Token     : ${BOLD}${TOKEN}${NC}"
    echo -e "  Config    : ${BOLD}${CONFIG}${NC}"
    echo -e "  Logs      : journalctl -u ${SERVICE_NAME} -f"
    echo ""

    ask RUNOPT "Run system optimizer now (BBR, buffers, MTU, DNS, ulimits)? (y/n)" "n"
    [ "$RUNOPT" = "y" ] || [ "$RUNOPT" = "Y" ] && optimize_system

    ask RUNWD "Install/refresh the watchdog (auto-restart on dead/idle tunnel)? (y/n)" "y"
    [ "$RUNWD" = "y" ] || [ "$RUNWD" = "Y" ] && setup_watchdog
}

# ============================================================
# Status / logs / control / edit
# ============================================================

show_status() {
    hr "Service Status"
    echo ""
    mapfile -t SERVICES < <(list_services)
    if [ ${#SERVICES[@]} -eq 0 ]; then
        warn "No Backhaul services found."
        return
    fi
    for svc in "${SERVICES[@]}"; do
        echo -e "${BOLD}${svc}${NC}"
        systemctl status "$svc" --no-pager --lines=5 2>/dev/null || true
        echo ""
    done

    echo "=== Recent warnings (token mismatch / connection issues) ==="
    local found_warning=0
    for svc in "${SERVICES[@]}"; do
        local warntxt
        warntxt=$(journalctl -u "$svc" -n 20 --no-pager 2>/dev/null | grep -iE "invalid security token|error|failed" | tail -n 3)
        if [ -n "$warntxt" ]; then
            found_warning=1
            echo "--- $svc ---"
            echo "$warntxt"
        fi
    done
    [ "$found_warning" = "0" ] && echo "None found in the last 20 log lines of each service."

    if [ -f "$WATCHDOG_LOG" ]; then
        echo ""
        echo "=== Last 10 watchdog restarts ==="
        tail -n 10 "$WATCHDOG_LOG"
    fi
}

show_logs() {
    hr "Logs"
    echo ""
    pick_service "View logs for" || return 0
    journalctl -u "$PICKED_SVC" -n 80 --no-pager
}

show_logs_live() {
    hr "Live Logs"
    echo ""
    pick_service "Follow logs for" || return 0
    info "Following ${PICKED_SVC} — press Ctrl+C to return to the menu."
    echo ""
    trap ' ' INT
    journalctl -u "$PICKED_SVC" -n 40 -f --no-pager
    trap - INT
    echo ""
    ok "Stopped following logs."
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
    echo "  0)  Back"
    echo ""
    ask ACT "Action" "1"

    case "$ACT" in
        1) step "Restarting ${svc} ..."; systemctl restart "$svc"; sleep 2
           systemctl is-active --quiet "$svc" && ok "Running." || warn "Failed to start — see logs." ;;
        2) step "Stopping ${svc} ..."; systemctl stop "$svc" && ok "Stopped." || warn "Could not stop." ;;
        3) step "Starting ${svc} ..."; systemctl start "$svc"; sleep 2
           systemctl is-active --quiet "$svc" && ok "Running." || warn "Failed to start — see logs." ;;
        4) systemctl status "$svc" --no-pager --lines=10 2>/dev/null || true ;;
        5) systemctl enable "$svc" && ok "Enabled." ;;
        6) systemctl disable "$svc" && ok "Disabled." ;;
        0|"") return 0 ;;
        *) warn "Invalid action." ;;
    esac
}

edit_config() {
    hr "Edit Config"
    echo ""
    pick_service "Edit config for" || return 0
    local label="${PICKED_SVC%.service}"
    local cfg="${CONFIG_DIR}/${label}.toml"
    if [ ! -f "$cfg" ]; then
        warn "No config file found for ${label}."
        return 0
    fi

    local ed="${EDITOR:-}"
    if [ -z "$ed" ]; then
        for cand in nano vim vi; do
            command -v "$cand" >/dev/null 2>&1 && { ed="$cand"; break; }
        done
    fi
    if [ -z "$ed" ]; then
        warn "No editor found (nano/vim/vi). Install one: apt install nano"
        return 0
    fi

    cp "$cfg" "${cfg}.bak" 2>/dev/null && info "Backup saved: ${cfg}.bak"
    info "Opening ${cfg} in ${ed} ..."
    "$ed" "$cfg"

    echo ""
    ask DORESTART "Restart the service to apply changes? (y/n)" "y"
    if [ "$DORESTART" = "y" ] || [ "$DORESTART" = "Y" ]; then
        step "Restarting ${label} ..."
        systemctl restart "${label}"
        sleep 2
        if systemctl is-active --quiet "${label}"; then
            ok "Running with new config."
        else
            warn "Service failed to start — config may be invalid."
            ask REVERT "Restore backup and restart? (y/n)" "y"
            if [ "$REVERT" = "y" ] || [ "$REVERT" = "Y" ]; then
                cp "${cfg}.bak" "$cfg" && systemctl restart "${label}" && ok "Reverted to previous config."
            fi
        fi
    fi
}

# ============================================================
# Manage inbound ports (server-role services)
# ============================================================

manage_ports() {
    hr "Manage Inbound Ports"
    echo ""
    mapfile -t ALL < <(list_services)
    local SERVER_SVCS=()
    for s in "${ALL[@]}"; do
        local cfg="${CONFIG_DIR}/${s%.service}.toml"
        grep -q '^\[server\]' "$cfg" 2>/dev/null && SERVER_SVCS+=("$s")
    done
    if [ ${#SERVER_SVCS[@]} -eq 0 ]; then
        warn "No server-role services on this machine."
        return
    fi

    echo "Server-role services:"
    for i in "${!SERVER_SVCS[@]}"; do echo "  $((i+1)))  ${SERVER_SVCS[$i]}"; done
    ask IDX "Select number" "1"
    if ! [[ "$IDX" =~ ^[0-9]+$ ]] || [ "$IDX" -lt 1 ] || [ "$IDX" -gt ${#SERVER_SVCS[@]} ]; then
        warn "Invalid selection."
        return
    fi
    local SVC="${SERVER_SVCS[$((IDX-1))]}"
    local cfg="${CONFIG_DIR}/${SVC%.service}.toml"

    echo ""
    echo "Current ports:"
    sed -n '/ports = \[/,/\]/p' "$cfg"
    echo ""
    echo "1) Add a port"
    echo "2) Remove a port"
    ask PCHOICE "Choice" "1"

    mapfile -t CURPORTS < <(sed -n '/ports = \[/,/\]/p' "$cfg" | grep -oE '"[^"]+"' | tr -d '"')

    if [ "$PCHOICE" = "1" ]; then
        ask NEWPORT "Port to add  (e.g. 2050 or 2222=22)" ""
        [ -n "$NEWPORT" ] && CURPORTS+=("$NEWPORT")
    else
        ask OLDPORT "Port to remove" ""
        local tmp=()
        for p in "${CURPORTS[@]}"; do [ "$p" != "$OLDPORT" ] && tmp+=("$p"); done
        CURPORTS=("${tmp[@]}")
    fi

    local ports_toml
    ports_toml=$(build_ports_toml "${CURPORTS[@]}")

    python3 - "$cfg" "$ports_toml" << 'PYEOF' 2>/dev/null || true
import sys, re
path, ports_block = sys.argv[1], sys.argv[2]
with open(path) as f:
    content = f.read()
content = re.sub(r'ports = \[.*?\]', 'ports = [\n' + ports_block + '\n]', content, flags=re.S)
with open(path, 'w') as f:
    f.write(content)
PYEOF

    ok "Ports updated."
    systemctl restart "$SVC"
    ok "Restarted ${SVC}."
}

# ============================================================
# MTU / DNS / ulimits / system optimizer  (from v7)
# ============================================================

ensure_mtu() {
    echo ""
    echo "=== Setting MTU to 1400 ==="
    local iface
    iface=$(detect_default_iface)
    echo "Interface: $iface"

    ip link set dev "$iface" mtu 1400 2>/dev/null || echo "Could not set MTU live (will still persist for next boot)."

    cat > /etc/systemd/system/backhaul-mtu.service << EOF
[Unit]
Description=Pin MTU 1400 on ${iface} for Backhaul tunnel
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/sbin/ip link set dev ${iface} mtu 1400
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable --now backhaul-mtu.service >/dev/null 2>&1
    echo "MTU 1400 applied and will persist after reboot (backhaul-mtu.service)."
}

ensure_dns() {
    echo ""
    echo "=== Setting DNS to 1.1.1.1 / 1.0.0.1 / 8.8.8.8 ==="
    if [ -L /etc/resolv.conf ]; then
        rm -f /etc/resolv.conf
    fi
    cat > /etc/resolv.conf << EOF
nameserver 1.1.1.1
nameserver 1.0.0.1
nameserver 8.8.8.8
EOF
    chattr +i /etc/resolv.conf 2>/dev/null || true
    echo "DNS set. (If this server uses systemd-resolved/NetworkManager, this file is now static/locked with chattr +i.)"
}

ensure_ulimits() {
    echo ""
    echo "=== Raising file descriptor limits ==="
    if ! grep -q "^fs.file-max" /etc/sysctl.d/99-backhaul-tunnel.conf 2>/dev/null; then
        echo "fs.file-max=2097152" >> /etc/sysctl.d/99-backhaul-tunnel.conf
    fi
    sysctl -w fs.file-max=2097152 > /dev/null 2>&1

    if ! grep -q "backhaul-tunnel limits" /etc/security/limits.conf 2>/dev/null; then
        cat >> /etc/security/limits.conf << EOF

# backhaul-tunnel limits
root soft nofile 1048576
root hard nofile 1048576
* soft nofile 1048576
* hard nofile 1048576
EOF
    fi
    ulimit -n 1048576 2>/dev/null || true
    echo "File descriptor limits raised (takes full effect for new sessions/services)."
}

optimize_system() {
    echo ""
    echo "=== System Optimization ==="
    local INTERFACE
    INTERFACE=$(detect_default_iface)
    echo "Interface: $INTERFACE"

    sysctl -w net.core.default_qdisc=fq > /dev/null 2>&1
    sysctl -w net.ipv4.tcp_congestion_control=bbr > /dev/null 2>&1 && echo "BBR congestion control enabled." \
        || echo "BBR module not available on this kernel — staying on the default (usually CUBIC)."

    sysctl -w net.core.somaxconn=65535 > /dev/null 2>&1
    sysctl -w net.core.netdev_max_backlog=250000 > /dev/null 2>&1
    sysctl -w net.ipv4.ip_local_port_range="1024 65535" > /dev/null 2>&1

    sysctl -w net.core.rmem_max=134217728 > /dev/null 2>&1
    sysctl -w net.core.wmem_max=134217728 > /dev/null 2>&1
    sysctl -w net.ipv4.tcp_rmem="4096 87380 134217728" > /dev/null 2>&1
    sysctl -w net.ipv4.tcp_wmem="4096 65536 134217728" > /dev/null 2>&1

    sysctl -w net.ipv4.tcp_keepalive_time=60 > /dev/null 2>&1
    sysctl -w net.ipv4.tcp_keepalive_intvl=10 > /dev/null 2>&1
    sysctl -w net.ipv4.tcp_keepalive_probes=6 > /dev/null 2>&1
    sysctl -w net.ipv4.tcp_user_timeout=30000 > /dev/null 2>&1

    sysctl -w net.ipv4.tcp_fin_timeout=15 > /dev/null 2>&1
    sysctl -w net.ipv4.tcp_mtu_probing=1 > /dev/null 2>&1

    sysctl -w net.ipv4.tcp_window_scaling=1 > /dev/null 2>&1
    sysctl -w net.ipv4.tcp_timestamps=1 > /dev/null 2>&1
    sysctl -w net.ipv4.tcp_sack=1 > /dev/null 2>&1
    sysctl -w net.ipv4.tcp_retries2=6 > /dev/null 2>&1
    sysctl -w net.ipv4.tcp_syn_retries=2 > /dev/null 2>&1
    sysctl -w net.ipv4.tcp_fastopen=3 > /dev/null 2>&1
    sysctl -w net.ipv4.tcp_low_latency=1 > /dev/null 2>&1
    sysctl -w net.ipv4.tcp_slow_start_after_idle=0 > /dev/null 2>&1
    sysctl -w net.ipv4.tcp_no_metrics_save=1 > /dev/null 2>&1
    sysctl -w net.ipv4.ip_forward=1 > /dev/null 2>&1

    # Deliberately NOT set (can backfire on newer kernels / behind NAT-CGNAT):
    #   net.ipv4.tcp_tw_recycle   (removed in modern kernels)
    #   net.ipv4.tcp_tw_reuse=1   (can break behind NAT/CGNAT)

    cat > /etc/sysctl.d/99-backhaul-tunnel.conf << EOF
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
    echo "Saved to /etc/sysctl.d/99-backhaul-tunnel.conf (persists across reboots)."

    ensure_ulimits
    ensure_mtu
    ensure_dns

    echo ""
    echo "Optimization complete."
}

# ============================================================
# Watchdog (health check + auto-restart)  — updated for multi-service layout
# ============================================================

setup_watchdog() {
    echo ""
    echo "=== Installing Watchdog ==="
    mkdir -p "$WATCHDOG_STATE_DIR"

    cat > "$WATCHDOG_SCRIPT" << WDEOF
#!/bin/bash
INSTALL_DIR="${INSTALL_DIR}"
CONFIG_DIR="${CONFIG_DIR}"
STATE_DIR="${WATCHDOG_STATE_DIR}"
LOG_FILE="${WATCHDOG_LOG}"
IDLE_THRESHOLD=${WATCHDOG_IDLE_THRESHOLD}
mkdir -p "\$STATE_DIR"

for cfg in "\$CONFIG_DIR"/*.toml; do
    [ -f "\$cfg" ] || continue
    label=\$(basename "\$cfg" .toml)
    unit="\${label}.service"
    [ -f "/etc/systemd/system/\${unit}" ] || continue

    if ! systemctl is-active --quiet "\$unit"; then
        systemctl restart "\$unit" 2>/dev/null
        echo "\$(date '+%F %T') restarted \$unit (service was inactive)" >> "\$LOG_FILE"
        rm -f "\${STATE_DIR}/\${unit}.last_ok"
        continue
    fi

    port=""
    if grep -q '^\[server\]' "\$cfg"; then
        port=\$(grep -oE 'bind_addr = "0\.0\.0\.0:[0-9]+"' "\$cfg" | grep -oE '[0-9]+\$')
    else
        port=\$(grep -oE 'remote_addr = "[^:"]+:[0-9]+"' "\$cfg" | grep -oE '[0-9]+\$')
    fi
    [ -z "\$port" ] && continue

    active_conns=\$(ss -H -tn state established "( sport = :\${port} or dport = :\${port} )" 2>/dev/null | grep -c .)
    now=\$(date +%s)
    state_file="\${STATE_DIR}/\${unit}.last_ok"

    if [ "\${active_conns:-0}" -gt 0 ]; then
        echo "\$now" > "\$state_file"
    else
        last_ok=\$(cat "\$state_file" 2>/dev/null || echo "\$now")
        idle=\$(( now - last_ok ))
        if [ "\$idle" -ge "\$IDLE_THRESHOLD" ]; then
            systemctl restart "\$unit" 2>/dev/null
            echo "\$now" > "\$state_file"
            echo "\$(date '+%F %T') restarted \$unit (idle \${idle}s, no established connections on port \${port})" >> "\$LOG_FILE"
        fi
    fi
done
WDEOF
    chmod +x "$WATCHDOG_SCRIPT"

    cat > /etc/systemd/system/backhaul-watchdog.service << EOF
[Unit]
Description=Backhaul Watchdog (health check / auto-restart)

[Service]
Type=oneshot
ExecStart=${WATCHDOG_SCRIPT}
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
    systemctl enable --now backhaul-watchdog.timer >/dev/null 2>&1
    echo "Watchdog installed — checks every 10s, restarts a tunnel after ${WATCHDOG_IDLE_THRESHOLD}s with no active connections."
    echo "Log: $WATCHDOG_LOG"
}

# ============================================================
# Remove / uninstall
# ============================================================

uninstall_one_or_more() {
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

    local TARGETS=()
    if [ "$IDX" = "a" ]; then
        TARGETS=("${SERVICES[@]}")
    else
        if ! [[ "$IDX" =~ ^[0-9]+$ ]] || [ "$IDX" -lt 1 ] || [ "$IDX" -gt ${#SERVICES[@]} ]; then
            warn "Invalid selection."
            return
        fi
        TARGETS=("${SERVICES[$((IDX-1))]}")
    fi

    echo ""
    warn "Will stop and remove: ${TARGETS[*]}"
    ask CONFIRM "Confirm? (yes/no)" "no"
    [ "$CONFIRM" != "yes" ] && { info "Cancelled."; return; }

    for svc in "${TARGETS[@]}"; do
        local label="${svc%.service}"
        systemctl stop "$label" 2>/dev/null || true
        systemctl disable "$label" 2>/dev/null || true
        rm -f "/etc/systemd/system/${label}.service"
        rm -f "${CONFIG_DIR}/${label}.toml" "${CONFIG_DIR}/${label}.toml.bak"
        rm -f "${CERTS_DIR}/${label}.crt" "${CERTS_DIR}/${label}.key"
        rm -f "/etc/letsencrypt/renewal-hooks/deploy/backhaul-${label}.sh" 2>/dev/null || true
        ok "Removed: ${label}"
    done

    systemctl daemon-reload
    ok "Done."
}

uninstall_everything() {
    hr "Full Uninstall"
    echo ""
    read -p "This will remove ALL Backhaul services, the watchdog, and the MTU unit on THIS server. Continue? (y/n): " CONFIRM
    if [ "$CONFIRM" != "y" ]; then
        info "Cancelled."
        return
    fi

    mapfile -t SERVICES < <(list_services)
    for svc in "${SERVICES[@]}"; do
        local label="${svc%.service}"
        systemctl disable --now "$label" >/dev/null 2>&1 || true
        rm -f "/etc/systemd/system/${label}.service"
    done
    systemctl disable --now backhaul-watchdog.timer >/dev/null 2>&1 || true
    rm -f /etc/systemd/system/backhaul-watchdog.timer /etc/systemd/system/backhaul-watchdog.service
    systemctl disable --now backhaul-mtu.service >/dev/null 2>&1 || true
    rm -f /etc/systemd/system/backhaul-mtu.service

    systemctl daemon-reload
    rm -rf "$INSTALL_DIR"
    ok "Uninstalled. (Note: MTU/DNS/sysctl system tuning was left in place — revert manually if needed.)"
}

# ============================================================
# Menu
# ============================================================

show_banner() {
    echo ""
    echo -e "  ${CYAN}${BOLD}Backhaul Tunnel Manager${NC}  -  v8"
    echo ""
}

show_menu() {
    echo -e "${BOLD}  Select an option:${NC}"
    echo ""
    echo -e "  ${BOLD}Install${NC}"
    echo "    1)  Install Server (Iran side)"
    echo "    2)  Install Client (Kharej side)"
    echo ""
    echo -e "  ${BOLD}Manage${NC}"
    echo "    3)  Service Status"
    echo "    4)  Service Control  (restart/stop/start)"
    echo "    5)  Edit Config"
    echo "    6)  Manage Inbound Ports (server side)"
    echo ""
    echo -e "  ${BOLD}Logs${NC}"
    echo "    7)  View Logs        (last 80 lines)"
    echo "    8)  Live Logs        (follow)"
    echo ""
    echo -e "  ${BOLD}System${NC}"
    echo "    9)  System Optimizer (BBR + buffers + MTU + DNS + ulimits)"
    echo "   10)  Install/repair Watchdog"
    echo ""
    echo -e "  ${BOLD}Other${NC}"
    echo "   11)  Remove a service"
    echo "   12)  Full uninstall (everything)"
    echo "   13)  Update Core (Binary)"
    echo "    0)  Exit"
    echo ""
    ask CHOICE "Choice" ""
}

pause() {
    echo ""
    echo -ne "${YELLOW}?${NC} Press Enter to return to the menu: "
    read -r _
}

while true; do
    clear 2>/dev/null || true
    show_banner
    show_menu

    case "$CHOICE" in
        1)  install_server ;;
        2)  install_client ;;
        3)  show_status ;;
        4)  service_control ;;
        5)  edit_config ;;
        6)  manage_ports ;;
        7)  show_logs ;;
        8)  show_logs_live ;;
        9)  optimize_system ;;
        10) setup_watchdog ;;
        11) uninstall_one_or_more ;;
        12) uninstall_everything ;;
        13) download_backhaul ;;
        0)  echo -e "\n  ${CYAN}Bye.${NC}\n"; exit 0 ;;
        *)  warn "Invalid choice: ${CHOICE}" ;;
    esac

    pause
done
