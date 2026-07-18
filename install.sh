#!/bin/bash

# Backhaul + WireGuard Tunnel Manager (Iran <-> Kharej)
# - Official Musixal/Backhaul release binary (encrypted reverse port forwarding)
# - WireGuard private tunnel (10.100.200.1 <-> 10.100.200.2)
# - Optional SSH auto-sync: give it SSH access to the other server and it
#   configures BOTH sides automatically (no manual copy/paste of keys/tokens).
# Run as root on Ubuntu.

set -e

REPO="Musixal/Backhaul"
INSTALL_DIR="/root/backhaul-core"
WG_DIR="/etc/wireguard"
WG_IFACE="wg0"
WG_LISTEN_PORT=51820
WG_IRAN_IP="10.100.200.1"
WG_KHAREJ_IP="10.100.200.2"
STATE_FILE="$INSTALL_DIR/state.env"

if [ "$EUID" -ne 0 ]; then
    echo "Please run as root (sudo)."
    exit 1
fi

mkdir -p "$INSTALL_DIR"

# ============================================================
# Helpers
# ============================================================

detect_interface() {
    local ifc
    ifc=$(ip -o -4 route show to default | awk '{print $5}' | head -n1)
    if [ -z "$ifc" ]; then
        ifc=$(ip link show | grep -E 'state UP' | awk -F': ' '{print $2}' | grep -E '^(eth|ens|enp)' | head -n1)
    fi
    echo "$ifc"
}

detect_public_ip() {
    curl -fsSL -4 https://ifconfig.me 2>/dev/null || curl -fsSL -4 https://api.ipify.org 2>/dev/null || echo ""
}

ensure_wireguard_local() {
    if ! command -v wg >/dev/null 2>&1; then
        echo "Installing WireGuard locally..."
        apt-get update -qq
        apt-get install -y -qq wireguard >/dev/null
    fi
}

ensure_wg_keys_local() {
    mkdir -p "$WG_DIR"
    chmod 700 "$WG_DIR"
    if [ ! -f "$WG_DIR/privatekey" ]; then
        umask 077
        wg genkey | tee "$WG_DIR/privatekey" | wg pubkey > "$WG_DIR/publickey"
    fi
}

ensure_backhaul_local() {
    if [ -x "$INSTALL_DIR/backhaul" ]; then
        return
    fi
    echo "Fetching latest official Backhaul release from GitHub..."
    local arch asset_arch url
    arch=$(uname -m)
    case "$arch" in
        x86_64) asset_arch="amd64" ;;
        aarch64) asset_arch="arm64" ;;
        *) echo "Unsupported architecture: $arch"; exit 1 ;;
    esac
    url=$(curl -fsSL "https://api.github.com/repos/${REPO}/releases/latest" \
        | grep "browser_download_url" | grep "linux_${asset_arch}" | grep -v ".sha256" \
        | head -n1 | cut -d '"' -f4)
    if [ -z "$url" ]; then
        echo "Could not resolve a release asset automatically."
        read -p "Paste the correct .tar.gz download URL: " url
    fi
    curl -fsSL -o "$INSTALL_DIR/backhaul.tar.gz" "$url"
    tar -xzf "$INSTALL_DIR/backhaul.tar.gz" -C "$INSTALL_DIR"
    rm -f "$INSTALL_DIR/backhaul.tar.gz"
    chmod +x "$INSTALL_DIR/backhaul"
}

gen_token() {
    if command -v openssl >/dev/null 2>&1; then
        openssl rand -hex 24
    else
        head -c 32 /dev/urandom | md5sum | cut -d' ' -f1
    fi
}

gen_port() {
    echo $(( (RANDOM % 40000) + 20000 ))
}

ssh_run() {
    ssh -o BatchMode=yes -o ConnectTimeout=8 -p "$SSH_PORT" "${SSH_USER}@${SSH_HOST}" "$1"
}

ssh_copy_stdin_to_remote_file() {
    # $1 = remote path, reads content from stdin
    ssh -o BatchMode=yes -o ConnectTimeout=8 -p "$SSH_PORT" "${SSH_USER}@${SSH_HOST}" "cat > $1"
}

# ============================================================
# Status
# ============================================================

show_status() {
    echo ""
    echo "=== WireGuard ==="
    if ip link show "$WG_IFACE" >/dev/null 2>&1; then
        wg show "$WG_IFACE"
    else
        echo "wg0 is not up."
    fi

    echo ""
    echo "=== Backhaul services ==="
    local units
    units=$(systemctl list-units --all 'backhaul-*.service' --no-legend 2>/dev/null | awk '{print $1}')
    if [ -z "$units" ]; then
        echo "No Backhaul services found."
    else
        for u in $units; do
            echo "--- $u ---"
            systemctl status "$u" --no-pager -l | head -n 6
            echo ""
        done
    fi
}

# ============================================================
# Uninstall
# ============================================================

uninstall_all() {
    read -p "This will remove WireGuard tunnel and ALL Backhaul services on THIS server. Continue? (y/n): " CONFIRM
    if [ "$CONFIRM" != "y" ]; then
        echo "Cancelled."
        return
    fi

    systemctl disable --now "wg-quick@${WG_IFACE}" >/dev/null 2>&1 || true
    rm -f "$WG_DIR/${WG_IFACE}.conf"

    local units
    units=$(systemctl list-units --all 'backhaul-*.service' --no-legend 2>/dev/null | awk '{print $1}')
    for u in $units; do
        systemctl disable --now "$u" >/dev/null 2>&1 || true
        rm -f "/etc/systemd/system/$u"
    done

    systemctl daemon-reload
    rm -rf "$INSTALL_DIR"
    echo "Uninstalled. (WireGuard package itself was left installed; run 'apt remove wireguard' if you want it fully gone.)"
}

# ============================================================
# Install
# ============================================================

install_flow() {
    echo ""
    echo "Are you setting up the Iran server or the Kharej server?"
    select LOCAL_ROLE in "Iran" "Kharej"; do
        case $LOCAL_ROLE in
            Iran|Kharej) break;;
            *) echo "Invalid selection.";;
        esac
    done
    [ "$LOCAL_ROLE" = "Iran" ] && REMOTE_ROLE="Kharej" || REMOTE_ROLE="Iran"

    INTERFACE=$(detect_interface)
    echo "Detected local interface: $INTERFACE"

    echo ""
    read -p "Auto-configure the OTHER ($REMOTE_ROLE) server too via SSH from here? (y/n): " AUTO_SSH
    if [ "$AUTO_SSH" = "y" ]; then
        read -p "SSH host/IP of the $REMOTE_ROLE server: " SSH_HOST
        read -p "SSH user (default root): " SSH_USER
        SSH_USER=${SSH_USER:-root}
        read -p "SSH port (default 22): " SSH_PORT
        SSH_PORT=${SSH_PORT:-22}
        echo "Testing SSH connection (key-based auth)..."
        if ! ssh_run "echo ok" >/dev/null 2>&1; then
            echo "Could not connect with key-based SSH auth."
            echo "Set up 'ssh-copy-id -p $SSH_PORT ${SSH_USER}@${SSH_HOST}' first, or continue manually."
            read -p "Continue without auto-sync? (y/n): " FALLBACK
            [ "$FALLBACK" = "y" ] || return
            AUTO_SSH="n"
        else
            echo "SSH connection OK — will configure both servers automatically."
        fi
    fi

    LOCAL_PUBLIC_IP_GUESS=$(detect_public_ip)
    read -p "This server's public IP [${LOCAL_PUBLIC_IP_GUESS}]: " LOCAL_PUBLIC_IP
    LOCAL_PUBLIC_IP=${LOCAL_PUBLIC_IP:-$LOCAL_PUBLIC_IP_GUESS}

    if [ "$AUTO_SSH" = "y" ]; then
        PEER_PUBLIC_IP_DEFAULT="$SSH_HOST"
    else
        PEER_PUBLIC_IP_DEFAULT=""
    fi
    read -p "The OTHER server's public IP [${PEER_PUBLIC_IP_DEFAULT}]: " PEER_PUBLIC_IP
    PEER_PUBLIC_IP=${PEER_PUBLIC_IP:-$PEER_PUBLIC_IP_DEFAULT}

    echo ""
    echo "Choose transport:"
    echo "  1) wss     - TLS encrypted, looks like HTTPS to firewalls (recommended)"
    echo "  2) wssmux  - wss + multiplexing, best for many concurrent connections / high throughput"
    echo "  3) tcp     - plain TCP, fastest but not encrypted or disguised"
    echo "  4) tcpmux  - tcp + multiplexing"
    read -p "Enter choice [1-4] (default 1): " TRANSPORT_CHOICE
    case "$TRANSPORT_CHOICE" in
        2) TRANSPORT="wssmux" ;;
        3) TRANSPORT="tcp" ;;
        4) TRANSPORT="tcpmux" ;;
        *) TRANSPORT="wss" ;;
    esac

    TUNNEL_PORT_DEFAULT=$(gen_port)
    read -p "Tunnel port [${TUNNEL_PORT_DEFAULT}]: " TUNNEL_PORT
    TUNNEL_PORT=${TUNNEL_PORT:-$TUNNEL_PORT_DEFAULT}

    if [ "$LOCAL_ROLE" = "Iran" ] || [ "$AUTO_SSH" = "y" ]; then
        read -p "Inbound ports on the Iran server (comma separated, e.g. 2050,2023): " INBOUND_PORTS
    fi

    if [ "$LOCAL_ROLE" = "Iran" ]; then
        IRAN_IP="$LOCAL_PUBLIC_IP"; KHAREJ_IP="$PEER_PUBLIC_IP"
    else
        KHAREJ_IP="$LOCAL_PUBLIC_IP"; IRAN_IP="$PEER_PUBLIC_IP"
    fi

    TOKEN=$(gen_token)
    echo "Generated Backhaul token automatically."

    # --- local WireGuard ---
    ensure_wireguard_local
    ensure_wg_keys_local
    LOCAL_WG_PRIVKEY=$(cat "$WG_DIR/privatekey")
    LOCAL_WG_PUBKEY=$(cat "$WG_DIR/publickey")
    [ "$LOCAL_ROLE" = "Iran" ] && LOCAL_WG_IP="$WG_IRAN_IP" && PEER_WG_IP="$WG_KHAREJ_IP"
    [ "$LOCAL_ROLE" = "Kharej" ] && LOCAL_WG_IP="$WG_KHAREJ_IP" && PEER_WG_IP="$WG_IRAN_IP"

    # --- get / generate peer WireGuard key ---
    if [ "$AUTO_SSH" = "y" ]; then
        echo "Preparing WireGuard on the remote ($REMOTE_ROLE) server..."
        ssh_run "command -v wg >/dev/null 2>&1 || (apt-get update -qq && apt-get install -y -qq wireguard >/dev/null); mkdir -p $WG_DIR && chmod 700 $WG_DIR; if [ ! -f $WG_DIR/privatekey ]; then umask 077; wg genkey | tee $WG_DIR/privatekey | wg pubkey > $WG_DIR/publickey; fi"
        PEER_WG_PUBKEY=$(ssh_run "cat $WG_DIR/publickey")
    else
        echo "Your WireGuard public key (give this to the $REMOTE_ROLE server operator):"
        echo "  $LOCAL_WG_PUBKEY"
        read -p "Enter the $REMOTE_ROLE server's WireGuard public key: " PEER_WG_PUBKEY
    fi

    # --- write + start local WireGuard ---
    cat > "$WG_DIR/${WG_IFACE}.conf" << EOF
[Interface]
Address = ${LOCAL_WG_IP}/24
PrivateKey = ${LOCAL_WG_PRIVKEY}
ListenPort = ${WG_LISTEN_PORT}

[Peer]
PublicKey = ${PEER_WG_PUBKEY}
Endpoint = ${PEER_PUBLIC_IP}:${WG_LISTEN_PORT}
AllowedIPs = ${PEER_WG_IP}/32
PersistentKeepalive = 25
EOF
    chmod 600 "$WG_DIR/${WG_IFACE}.conf"
    systemctl enable --now "wg-quick@${WG_IFACE}"
    echo "Local WireGuard up: ${LOCAL_WG_IP} <-> ${PEER_WG_IP}"

    # --- local Backhaul ---
    ensure_backhaul_local

    if [ "$LOCAL_ROLE" = "Iran" ]; then
        TOML_FILE="$INSTALL_DIR/iran${TUNNEL_PORT}.toml"
        {
            echo "[server]"
            echo "bind_addr = \"0.0.0.0:${TUNNEL_PORT}\""
            echo "transport = \"${TRANSPORT}\""
            echo "token = \"${TOKEN}\""
            echo "keepalive_period = 75"
            echo "nodelay = true"
            echo "channel_size = 2048"
            echo "heartbeat = 40"
            echo "mux_con = 8"
            echo "sniffer = false"
            echo "web_port = 0"
            echo "log_level = \"info\""
            echo ""
            echo "ports = ["
        } > "$TOML_FILE"
        IFS=',' read -ra PORT_ARRAY <<< "$INBOUND_PORTS"
        for i in "${!PORT_ARRAY[@]}"; do
            port=$(echo "${PORT_ARRAY[i]}" | xargs)
            if [ $((i+1)) -eq ${#PORT_ARRAY[@]} ]; then
                echo "    \"${port}\"" >> "$TOML_FILE"
            else
                echo "    \"${port}\"," >> "$TOML_FILE"
            fi
        done
        echo "]" >> "$TOML_FILE"

        SERVICE_FILE="/etc/systemd/system/backhaul-iran${TUNNEL_PORT}.service"
        cat > "$SERVICE_FILE" << EOF
[Unit]
Description=Backhaul Iran Server Port ${TUNNEL_PORT}
After=network.target wg-quick@${WG_IFACE}.service

[Service]
Type=simple
User=root
ExecStart=${INSTALL_DIR}/backhaul -c ${TOML_FILE}
Restart=always
RestartSec=3
LimitNOFILE=1048576
TasksMax=infinity
LimitMEMLOCK=infinity
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload
        systemctl enable --now "backhaul-iran${TUNNEL_PORT}.service"
        echo "Local Backhaul (Iran server side) started on port ${TUNNEL_PORT}."
    else
        TOML_FILE="$INSTALL_DIR/kharej${TUNNEL_PORT}.toml"
        cat > "$TOML_FILE" << EOF
[client]
remote_addr = "${IRAN_IP}:${TUNNEL_PORT}"
transport = "${TRANSPORT}"
token = "${TOKEN}"
connection_pool = 8
aggressive_pool = false
keepalive_period = 75
nodelay = true
retry_interval = 3
sniffer = false
web_port = 0
log_level = "info"
EOF
        SERVICE_FILE="/etc/systemd/system/backhaul-kharej${TUNNEL_PORT}.service"
        cat > "$SERVICE_FILE" << EOF
[Unit]
Description=Backhaul Kharej Client Port ${TUNNEL_PORT}
After=network.target wg-quick@${WG_IFACE}.service

[Service]
Type=simple
User=root
ExecStart=${INSTALL_DIR}/backhaul -c ${TOML_FILE}
Restart=always
RestartSec=3
LimitNOFILE=1048576
TasksMax=infinity
LimitMEMLOCK=infinity
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload
        systemctl enable --now "backhaul-kharej${TUNNEL_PORT}.service"
        echo "Local Backhaul (Kharej client side) started, connecting to ${IRAN_IP}:${TUNNEL_PORT}."
    fi

    cat > "$STATE_FILE" << EOF
LOCAL_ROLE=${LOCAL_ROLE}
TUNNEL_PORT=${TUNNEL_PORT}
IRAN_IP=${IRAN_IP}
KHAREJ_IP=${KHAREJ_IP}
TRANSPORT=${TRANSPORT}
EOF

    # --- remote side, fully automatic ---
    if [ "$AUTO_SSH" = "y" ]; then
        echo ""
        echo "Configuring the remote ($REMOTE_ROLE) server automatically..."

        REMOTE_SCRIPT=$(cat << REMOTEEOF
set -e
mkdir -p ${INSTALL_DIR}
cat > ${WG_DIR}/${WG_IFACE}.conf << WGEOF
[Interface]
Address = ${PEER_WG_IP}/24
PrivateKey = \$(cat ${WG_DIR}/privatekey)
ListenPort = ${WG_LISTEN_PORT}

[Peer]
PublicKey = ${LOCAL_WG_PUBKEY}
Endpoint = ${LOCAL_PUBLIC_IP}:${WG_LISTEN_PORT}
AllowedIPs = ${LOCAL_WG_IP}/32
PersistentKeepalive = 25
WGEOF
chmod 600 ${WG_DIR}/${WG_IFACE}.conf
systemctl enable --now wg-quick@${WG_IFACE}

if [ ! -x ${INSTALL_DIR}/backhaul ]; then
  ARCH=\$(uname -m)
  case "\$ARCH" in
    x86_64) ASSET_ARCH="amd64" ;;
    aarch64) ASSET_ARCH="arm64" ;;
  esac
  URL=\$(curl -fsSL "https://api.github.com/repos/${REPO}/releases/latest" | grep browser_download_url | grep "linux_\${ASSET_ARCH}" | grep -v .sha256 | head -n1 | cut -d '"' -f4)
  curl -fsSL -o ${INSTALL_DIR}/backhaul.tar.gz "\$URL"
  tar -xzf ${INSTALL_DIR}/backhaul.tar.gz -C ${INSTALL_DIR}
  rm -f ${INSTALL_DIR}/backhaul.tar.gz
  chmod +x ${INSTALL_DIR}/backhaul
fi

REMOTEEOF
)
        if [ "$REMOTE_ROLE" = "Kharej" ]; then
            REMOTE_SCRIPT="$REMOTE_SCRIPT
TOML_FILE=${INSTALL_DIR}/kharej${TUNNEL_PORT}.toml
cat > \$TOML_FILE << TOMLEOF
[client]
remote_addr = \"${IRAN_IP}:${TUNNEL_PORT}\"
transport = \"${TRANSPORT}\"
token = \"${TOKEN}\"
connection_pool = 8
aggressive_pool = false
keepalive_period = 75
nodelay = true
retry_interval = 3
sniffer = false
web_port = 0
log_level = \"info\"
TOMLEOF
SERVICE_FILE=/etc/systemd/system/backhaul-kharej${TUNNEL_PORT}.service
cat > \$SERVICE_FILE << SVCEOF
[Unit]
Description=Backhaul Kharej Client Port ${TUNNEL_PORT}
After=network.target wg-quick@${WG_IFACE}.service

[Service]
Type=simple
User=root
ExecStart=${INSTALL_DIR}/backhaul -c \$TOML_FILE
Restart=always
RestartSec=3
LimitNOFILE=1048576
TasksMax=infinity
LimitMEMLOCK=infinity
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
SVCEOF
systemctl daemon-reload
systemctl enable --now backhaul-kharej${TUNNEL_PORT}.service
"
        else
            REMOTE_SCRIPT="$REMOTE_SCRIPT
TOML_FILE=${INSTALL_DIR}/iran${TUNNEL_PORT}.toml
{
echo '[server]'
echo 'bind_addr = \"0.0.0.0:${TUNNEL_PORT}\"'
echo 'transport = \"${TRANSPORT}\"'
echo 'token = \"${TOKEN}\"'
echo 'keepalive_period = 75'
echo 'nodelay = true'
echo 'channel_size = 2048'
echo 'heartbeat = 40'
echo 'mux_con = 8'
echo 'sniffer = false'
echo 'web_port = 0'
echo 'log_level = \"info\"'
echo ''
echo 'ports = ['
"
            IFS=',' read -ra PORT_ARRAY <<< "$INBOUND_PORTS"
            for i in "${!PORT_ARRAY[@]}"; do
                port=$(echo "${PORT_ARRAY[i]}" | xargs)
                if [ $((i+1)) -eq ${#PORT_ARRAY[@]} ]; then
                    REMOTE_SCRIPT="$REMOTE_SCRIPT
echo '    \"${port}\"'
"
                else
                    REMOTE_SCRIPT="$REMOTE_SCRIPT
echo '    \"${port}\",'
"
                fi
            done
            REMOTE_SCRIPT="$REMOTE_SCRIPT
echo ']'
} > \$TOML_FILE
SERVICE_FILE=/etc/systemd/system/backhaul-iran${TUNNEL_PORT}.service
cat > \$SERVICE_FILE << SVCEOF
[Unit]
Description=Backhaul Iran Server Port ${TUNNEL_PORT}
After=network.target wg-quick@${WG_IFACE}.service

[Service]
Type=simple
User=root
ExecStart=${INSTALL_DIR}/backhaul -c \$TOML_FILE
Restart=always
RestartSec=3
LimitNOFILE=1048576
TasksMax=infinity
LimitMEMLOCK=infinity
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
SVCEOF
systemctl daemon-reload
systemctl enable --now backhaul-iran${TUNNEL_PORT}.service
"
        fi

        echo "$REMOTE_SCRIPT" | ssh -o BatchMode=yes -o ConnectTimeout=8 -p "$SSH_PORT" "${SSH_USER}@${SSH_HOST}" "bash -s"
        echo "Remote ($REMOTE_ROLE) server configured and started."
    fi

    echo ""
    echo "=== Setup Completed! ==="
    echo "Tunnel port: $TUNNEL_PORT"
    echo "Token: $TOKEN"
    echo "WireGuard: wg show ${WG_IFACE}"
    echo "Backhaul:  systemctl status 'backhaul-*'"
}

# ============================================================
# Menu
# ============================================================

while true; do
    echo ""
    echo "==== Backhaul + WireGuard Tunnel Manager ===="
    echo "1) Install / Setup tunnel"
    echo "2) Show tunnel status"
    echo "3) Uninstall tunnel"
    echo "4) Exit"
    read -p "Select an option [1-4]: " CHOICE
    case "$CHOICE" in
        1) install_flow ;;
        2) show_status ;;
        3) uninstall_all ;;
        4) exit 0 ;;
        *) echo "Invalid option." ;;
    esac
done
