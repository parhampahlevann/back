#!/bin/bash

# Backhaul Tunnel Manager (Iran <-> Kharej) — v7.3 (Fixed Syntax & UDP)
# Official Musixal/Backhaul release binary — encrypted reverse port forwarding with full UDP support.

set -e

REPO="Musixal/Backhaul"
INSTALL_DIR="/root/backhaul-core"
STATE_FILE="$INSTALL_DIR/state.env"
FIXED_TOKEN="123"

if [ "$EUID" -ne 0 ]; then
    echo "Please run as root (sudo)."
    exit 1
fi

mkdir -p "$INSTALL_DIR"

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

ensure_backhaul_local() {
    mkdir -p "$INSTALL_DIR"
    if [ -x "$INSTALL_DIR/backhaul" ]; then
        return
    fi
    echo "Fetching latest official Backhaul release from GitHub..."
    local arch asset_arch url attempt
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
        url="https://github.com/Musixal/Backhaul/releases/download/v0.7.2/backhaul_linux_${asset_arch}.tar.gz"
    fi

    rm -f "$INSTALL_DIR/backhaul.tar.gz"
    attempt=0
    until curl -fSL --retry 3 --retry-delay 2 -o "$INSTALL_DIR/backhaul.tar.gz" "$url"; do
        attempt=$((attempt + 1))
        if [ "$attempt" -ge 3 ]; then
            echo "Download failed. Check network access."
            exit 1
        fi
        sleep 2
    done

    tar -xzf "$INSTALL_DIR/backhaul.tar.gz" -C "$INSTALL_DIR"
    rm -f "$INSTALL_DIR/backhaul.tar.gz"
    chmod +x "$INSTALL_DIR/backhaul"
    echo "Backhaul binary installed."
}

ensure_tls_cert_local() {
    if [ -f "$INSTALL_DIR/server.crt" ] && [ -f "$INSTALL_DIR/server.key" ]; then
        return
    fi
    echo "Generating self-signed TLS certificate..."
    openssl req -x509 -newkey rsa:2048 -nodes \
        -keyout "$INSTALL_DIR/server.key" -out "$INSTALL_DIR/server.crt" \
        -days 3650 -subj "/CN=backhaul" >/dev/null 2>&1
}

gen_port() {
    echo $(( (RANDOM % 40000) + 20000 ))
}

ensure_mtu() {
    local iface
    iface=$(detect_default_iface)
    ip link set dev "$iface" mtu 1400 2>/dev/null || true
    cat > /etc/systemd/system/backhaul-mtu.service << EOF
[Unit]
Description=Pin MTU 1400 for Backhaul
After=network-online.target
[Service]
Type=oneshot
ExecStart=/sbin/ip link set dev ${iface} mtu 1400
RemainAfterExit=yes
[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable --now backhaul-mtu.service >/dev/null 2>&1
}

optimize_system() {
    echo "Applying system optimizations (BBR, buffers, ulimits)..."
    sysctl -w net.core.default_qdisc=fq > /dev/null 2>&1
    sysctl -w net.ipv4.tcp_congestion_control=bbr > /dev/null 2>&1
    sysctl -w net.core.somaxconn=65535 > /dev/null 2>&1
    sysctl -w net.core.netdev_max_backlog=250000 > /dev/null 2>&1
    sysctl -w net.ipv4.ip_forward=1 > /dev/null 2>&1
    
    cat > /etc/sysctl.d/99-backhaul-tunnel.conf << EOF
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
net.core.somaxconn=65535
net.core.netdev_max_backlog=250000
net.ipv4.ip_forward=1
EOF
    sysctl --system > /dev/null 2>&1
    ensure_mtu
    echo "Optimization complete."
}

show_status() {
    echo "=== Backhaul Services Status ==="
    systemctl list-units --all 'backhaul-*.service' --no-legend
}

install_flow() {
    echo "Are you setting up the Iran server or the Kharej server?"
    select LOCAL_ROLE in "Iran" "Kharej"; do
        case $LOCAL_ROLE in
            Iran|Kharej) break;;
            *) echo "Invalid selection.";;
        esac
    done

    LOCAL_PUBLIC_IP_GUESS=$(detect_public_ip)
    read -p "This server's public IP [${LOCAL_PUBLIC_IP_GUESS}]: " LOCAL_PUBLIC_IP
    LOCAL_PUBLIC_IP=${LOCAL_PUBLIC_IP:-$LOCAL_PUBLIC_IP_GUESS}

    read -p "The OTHER server's public IP: " PEER_PUBLIC_IP

    echo "Choose transport (Recommended: wssmux for shadowsocks/proxy stability):"
    echo "  1) wss"
    echo "  2) wssmux (Best for 1080/Shadowsocks)"
    echo "  3) tcp"
    echo "  4) tcpmux"
    read -p "Enter choice [1-4] (default 2): " TRANSPORT_CHOICE
    case "$TRANSPORT_CHOICE" in
        1) TRANSPORT="wss" ;;
        3) TRANSPORT="tcp" ;;
        4) TRANSPORT="tcpmux" ;;
        *) TRANSPORT="wssmux" ;;
    esac

    TOKEN="$FIXED_TOKEN"

    if [ "$LOCAL_ROLE" = "Iran" ]; then
        TUNNEL_PORT_DEFAULT=$(gen_port)
        read -p "Tunnel port [${TUNNEL_PORT_DEFAULT}]: " TUNNEL_PORT
        TUNNEL_PORT=${TUNNEL_PORT:-$TUNNEL_PORT_DEFAULT}
        read -p "Inbound ports on Iran server (e.g. 1080,443): " INBOUND_PORTS
        IRAN_IP="$LOCAL_PUBLIC_IP"; KHAREJ_IP="$PEER_PUBLIC_IP"
        echo ">>> Tunnel Port: $TUNNEL_PORT (Use this exact port on Kharej server)"
    else
        read -p "Enter the tunnel port used on the Iran server: " TUNNEL_PORT
        KHAREJ_IP="$LOCAL_PUBLIC_IP"; IRAN_IP="$PEER_PUBLIC_IP"
    fi

    ensure_backhaul_local
    if [ "$TRANSPORT" = "wss" ] || [ "$TRANSPORT" = "wssmux" ]; then
        [ "$LOCAL_ROLE" = "Iran" ] && ensure_tls_cert_local
    fi

    if [ "$LOCAL_ROLE" = "Iran" ]; then
        TOML_FILE="$INSTALL_DIR/iran${TUNNEL_PORT}.toml"
        {
            echo "[server]"
            echo "bind_addr = \"0.0.0.0:${TUNNEL_PORT}\""
            echo "transport = \"${TRANSPORT}\""
            echo "accept_udp = true"
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
After=network.target

[Service]
Type=simple
User=root
ExecStart=${INSTALL_DIR}/backhaul -c ${TOML_FILE}
Restart=always
RestartSec=1
LimitNOFILE=1048576
OOMScoreAdjust=-1000

[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload
        systemctl enable --now "backhaul-iran${TUNNEL_PORT}.service"
        echo "Iran Backhaul started with UDP support on port ${TUNNEL_PORT}."
    else
        TOML_FILE="$INSTALL_DIR/kharej${TUNNEL_PORT}.toml"
        cat > "$TOML_FILE" << EOF
[client]
remote_addr = "${IRAN_IP}:${TUNNEL_PORT}"
transport = "${TRANSPORT}"
accept_udp = true
token = "${TOKEN}"
connection_pool = 8
aggressive_pool = true
keepalive_period = 20
nodelay = true
retry_interval = 1
sniffer = false
web_port = 0
log_level = "warn"
EOF
        SERVICE_FILE="/etc/systemd/system/backhaul-kharej${TUNNEL_PORT}.service"
        cat > "$SERVICE_FILE" << EOF
[Unit]
Description=Backhaul Kharej Client Port ${TUNNEL_PORT}
After=network.target

[Service]
Type=simple
User=root
ExecStart=${INSTALL_DIR}/backhaul -c ${TOML_FILE}
Restart=always
RestartSec=1
LimitNOFILE=1048576
OOMScoreAdjust=-1000

[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload
        systemctl enable --now "backhaul-kharej${TUNNEL_PORT}.service"
        echo "Kharej Backhaul client started with UDP support."
    fi

    optimize_system
    echo "=== Setup Completed Successfully! ==="
}

while true; do
    echo ""
    echo "==== Backhaul Tunnel Manager (v7.3) ===="
    echo "1) Install / Setup tunnel"
    echo "2) Show tunnel status"
    echo "3) Exit"
    read -p "Select option [1-3]: " CHOICE
    case "$CHOICE" in
        1) install_flow ;;
        2) show_status ;;
        3) exit 0 ;;
        *) echo "Invalid option." ;;
    esac
done
