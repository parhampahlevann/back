#!/bin/bash

# Combined Setup Script for Iran <-> Kharej
#   1) WireGuard  -> private point-to-point tunnel (10.100.200.1 <-> 10.100.200.2)
#   2) Backhaul   -> encrypted reverse port-forwarding (official Musixal/Backhaul release)
#
# Both tools are official, open-source projects. Run as root on Ubuntu.

set -e

REPO="Musixal/Backhaul"
INSTALL_DIR="/root/backhaul-core"
WG_DIR="/etc/wireguard"
WG_IFACE="wg0"
WG_PORT=51820
WG_IRAN_IP="10.100.200.1"
WG_KHAREJ_IP="10.100.200.2"

echo "=== Combined WireGuard + Backhaul Setup ==="
echo "Are you currently on the Iran server or Kharej server?"
select server_type in "Iran" "Kharej"; do
    case $server_type in
        Iran|Kharej) break;;
        *) echo "Invalid selection. Please choose 1 or 2.";;
    esac
done

INTERFACE=$(ip -o -4 route show to default | awk '{print $5}' | head -n1)
if [ -z "$INTERFACE" ]; then
    INTERFACE=$(ip link show | grep -E 'state UP' | awk -F': ' '{print $2}' | grep -E '^(eth|ens|enp)' | head -n1)
fi
if [ -z "$INTERFACE" ]; then
    echo "Could not detect main interface. Please enter it manually:"
    read -r INTERFACE
fi
echo "Detected main interface: $INTERFACE"

# ============================================================
# PART 1: WireGuard — private IP tunnel between the two servers
# ============================================================
echo ""
echo "=== Part 1: WireGuard private tunnel (${WG_IRAN_IP} <-> ${WG_KHAREJ_IP}) ==="

if ! command -v wg >/dev/null 2>&1; then
    echo "Installing WireGuard..."
    apt-get update -qq
    apt-get install -y -qq wireguard >/dev/null
fi

mkdir -p "$WG_DIR"
chmod 700 "$WG_DIR"

if [ ! -f "$WG_DIR/privatekey" ]; then
    umask 077
    wg genkey | tee "$WG_DIR/privatekey" | wg pubkey > "$WG_DIR/publickey"
fi
MY_PRIVATE_KEY=$(cat "$WG_DIR/privatekey")
MY_PUBLIC_KEY=$(cat "$WG_DIR/publickey")

echo ""
echo "Your WireGuard public key (send this to the other server's operator):"
echo "  $MY_PUBLIC_KEY"
echo ""
read -p "Enter the OTHER server's public IP (for the WireGuard endpoint): " PEER_PUBLIC_IP
read -p "Enter the OTHER server's WireGuard public key: " PEER_PUBLIC_KEY

if [ "$server_type" = "Iran" ]; then
    MY_WG_IP="$WG_IRAN_IP"
    PEER_WG_IP="$WG_KHAREJ_IP"
else
    MY_WG_IP="$WG_KHAREJ_IP"
    PEER_WG_IP="$WG_IRAN_IP"
fi

cat > "$WG_DIR/${WG_IFACE}.conf" << EOF
[Interface]
Address = ${MY_WG_IP}/24
PrivateKey = ${MY_PRIVATE_KEY}
ListenPort = ${WG_PORT}

[Peer]
PublicKey = ${PEER_PUBLIC_KEY}
Endpoint = ${PEER_PUBLIC_IP}:${WG_PORT}
AllowedIPs = ${PEER_WG_IP}/32
PersistentKeepalive = 25
EOF

chmod 600 "$WG_DIR/${WG_IFACE}.conf"
echo "Created $WG_DIR/${WG_IFACE}.conf"

systemctl enable --now "wg-quick@${WG_IFACE}"
echo "WireGuard interface ${WG_IFACE} is up: ${MY_WG_IP} <-> ${PEER_WG_IP}"
echo "(Open UDP port ${WG_PORT} on both servers' firewalls if not already open.)"

# ============================================================
# PART 2: Backhaul — encrypted reverse port forwarding
# ============================================================
echo ""
echo "=== Part 2: Backhaul reverse tunnel (encrypted port forwarding) ==="

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
echo "Using transport: $TRANSPORT"

mkdir -p "$INSTALL_DIR"

download_backhaul() {
    echo "Fetching latest official Backhaul release info from GitHub..."
    ARCH=$(uname -m)
    case "$ARCH" in
        x86_64) ASSET_ARCH="amd64" ;;
        aarch64) ASSET_ARCH="arm64" ;;
        *) echo "Unsupported architecture: $ARCH"; exit 1 ;;
    esac

    DOWNLOAD_URL=$(curl -fsSL "https://api.github.com/repos/${REPO}/releases/latest" \
        | grep "browser_download_url" \
        | grep "linux_${ASSET_ARCH}" \
        | grep -v ".sha256" \
        | head -n1 \
        | cut -d '"' -f4)

    if [ -z "$DOWNLOAD_URL" ]; then
        echo "Could not resolve a release asset automatically."
        echo "Check available assets at: https://github.com/${REPO}/releases/latest"
        read -p "Paste the correct .tar.gz download URL: " DOWNLOAD_URL
    fi

    echo "Downloading: $DOWNLOAD_URL"
    curl -fsSL -o "$INSTALL_DIR/backhaul.tar.gz" "$DOWNLOAD_URL"
    tar -xzf "$INSTALL_DIR/backhaul.tar.gz" -C "$INSTALL_DIR"
    rm -f "$INSTALL_DIR/backhaul.tar.gz"
    chmod +x "$INSTALL_DIR/backhaul"
    echo "Backhaul binary installed at $INSTALL_DIR/backhaul"
}

download_backhaul

if command -v openssl >/dev/null 2>&1; then
    TOKEN_DEFAULT=$(openssl rand -hex 24)
else
    TOKEN_DEFAULT=$(head -c 32 /dev/urandom | md5sum | cut -d' ' -f1)
fi

if [ "$server_type" = "Iran" ]; then
    echo "=== Iran Server Setup (Backhaul server side) ==="

    read -p "Enter Iran public IP: " IRAN_IP
    read -p "Enter Tunnel Port (e.g. 3080): " TUNNEL_PORT
    read -p "Enter Inbound Ports (comma separated, e.g. 2050,2023): " INBOUND_PORTS
    TOKEN="$TOKEN_DEFAULT"

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

    echo "Created $TOML_FILE"

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

    echo "Created systemd service: $SERVICE_FILE"

    systemctl daemon-reload
    systemctl enable --now "backhaul-iran${TUNNEL_PORT}.service"

    echo ""
    echo "=== IMPORTANT ==="
    echo "Save this Backhaul token — enter the SAME token on the Kharej server:"
    echo "  $TOKEN"
    echo "Backhaul Iran service started and enabled!"

elif [ "$server_type" = "Kharej" ]; then
    echo "=== Kharej Server Setup (Backhaul client side) ==="

    read -p "Enter Iran public IP: " IRAN_IP
    read -p "Enter Tunnel Port (must match the Iran server): " TUNNEL_PORT
    read -p "Enter the Backhaul token generated on the Iran server: " TOKEN

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

    echo "Created $TOML_FILE"

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

    echo "Created systemd service: $SERVICE_FILE"

    systemctl daemon-reload
    systemctl enable --now "backhaul-kharej${TUNNEL_PORT}.service"
    echo "Backhaul Kharej service started and enabled!"
fi

echo ""
echo "=== Setup Completed! ==="
echo "WireGuard:  wg show ${WG_IFACE}"
echo "Backhaul:   systemctl status backhaul-*${TUNNEL_PORT}"
echo "Logs:       journalctl -u backhaul-*${TUNNEL_PORT} -f"
