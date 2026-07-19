#!/bin/bash

# Backhaul Tunnel Manager (Iran <-> Kharej)
# Official Musixal/Backhaul release binary — encrypted reverse port forwarding (wss/wssmux).
# Run this SEPARATELY on each server (Iran and Kharej). No SSH auto-sync — keep it simple.
# Run as root on Ubuntu.

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

# ============================================================
# Helpers
# ============================================================

detect_public_ip() {
    curl -fsSL -4 https://ifconfig.me 2>/dev/null || curl -fsSL -4 https://api.ipify.org 2>/dev/null || echo ""
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
        echo "Could not resolve a release asset automatically."
        read -p "Paste the correct .tar.gz download URL: " url
    fi

    rm -f "$INSTALL_DIR/backhaul.tar.gz"
    attempt=0
    until curl -fSL --retry 3 --retry-delay 2 -o "$INSTALL_DIR/backhaul.tar.gz" "$url"; do
        attempt=$((attempt + 1))
        if [ "$attempt" -ge 3 ]; then
            echo "Download failed after multiple attempts."
            echo "Check disk space (df -h) and network access, then try again."
            exit 1
        fi
        echo "Retrying download..."
        sleep 2
    done

    if [ ! -s "$INSTALL_DIR/backhaul.tar.gz" ]; then
        echo "Downloaded file is empty — aborting."
        exit 1
    fi

    if ! tar -tzf "$INSTALL_DIR/backhaul.tar.gz" >/dev/null 2>&1; then
        echo "Downloaded file is not a valid archive — aborting. Try re-running."
        rm -f "$INSTALL_DIR/backhaul.tar.gz"
        exit 1
    fi

    tar -xzf "$INSTALL_DIR/backhaul.tar.gz" -C "$INSTALL_DIR"
    rm -f "$INSTALL_DIR/backhaul.tar.gz"
    chmod +x "$INSTALL_DIR/backhaul"
    echo "Backhaul binary installed."
}

ensure_tls_cert_local() {
    # wss/wssmux require tls_cert/tls_key on the server side.
    if [ -f "$INSTALL_DIR/server.crt" ] && [ -f "$INSTALL_DIR/server.key" ]; then
        return
    fi
    echo "Generating self-signed TLS certificate for wss/wssmux..."
    openssl req -x509 -newkey rsa:2048 -nodes \
        -keyout "$INSTALL_DIR/server.key" -out "$INSTALL_DIR/server.crt" \
        -days 3650 -subj "/CN=backhaul" >/dev/null 2>&1
}

gen_port() {
    echo $(( (RANDOM % 40000) + 20000 ))
}

# ============================================================
# Status
# ============================================================

show_status() {
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

    echo "=== Recent warnings (token mismatch / connection issues) ==="
    local found_warning=0
    for u in $units; do
        local warn
        warn=$(journalctl -u "$u" -n 20 --no-pager 2>/dev/null | grep -iE "invalid security token|error|failed" | tail -n 3)
        if [ -n "$warn" ]; then
            found_warning=1
            echo "--- $u ---"
            echo "$warn"
        fi
    done
    if [ "$found_warning" = "0" ]; then
        echo "None found in the last 20 log lines of each service."
    else
        echo ""
        echo "If you see 'invalid security token', the token in the .toml files on the"
        echo "two servers does not match — check with: grep token ${INSTALL_DIR}/*.toml"
    fi
}

# ============================================================
# Manage inbound ports (Iran server side only)
# ============================================================

manage_ports() {
    local tomls
    tomls=$(ls "$INSTALL_DIR"/iran*.toml 2>/dev/null || true)
    if [ -z "$tomls" ]; then
        echo "No Iran server config found on this machine. Run this on the Iran server."
        return
    fi

    echo "Found config(s):"
    select TOML_FILE in $tomls; do
        [ -n "$TOML_FILE" ] && break
        echo "Invalid selection."
    done

    echo ""
    echo "Current ports:"
    sed -n '/ports = \[/,/\]/p' "$TOML_FILE"

    echo ""
    echo "1) Add a port"
    echo "2) Remove a port"
    read -p "Choice [1-2]: " PCHOICE

    PORT_NUM=$(basename "$TOML_FILE" | grep -oE '[0-9]+' | head -n1)
    SERVICE_NAME="backhaul-iran${PORT_NUM}.service"

    if [ "$PCHOICE" = "1" ]; then
        read -p "Port to add: " NEWPORT
        sed -i "s/\]/    \"${NEWPORT}\"\n]/" "$TOML_FILE"
        # normalize: ensure previous last line got a trailing comma
        python3 - "$TOML_FILE" << 'PYEOF' 2>/dev/null || true
import sys, re
path = sys.argv[1]
with open(path) as f:
    content = f.read()
lines = content.split("\n")
out = []
in_ports = False
port_lines_idx = []
for i, l in enumerate(lines):
    if 'ports = [' in l:
        in_ports = True
    if in_ports and l.strip().startswith('"'):
        port_lines_idx.append(i)
    if in_ports and l.strip() == ']':
        in_ports = False
for idx_pos, i in enumerate(port_lines_idx):
    l = lines[i].rstrip(',').rstrip()
    if idx_pos != len(port_lines_idx) - 1:
        lines[i] = l + ","
    else:
        lines[i] = l
with open(path, "w") as f:
    f.write("\n".join(lines))
PYEOF
        echo "Added port ${NEWPORT}."
    else
        read -p "Port to remove: " OLDPORT
        sed -i "/\"${OLDPORT}\"/d" "$TOML_FILE"
        echo "Removed port ${OLDPORT}."
    fi

    systemctl restart "$SERVICE_NAME"
    echo "Restarted $SERVICE_NAME."
}

# ============================================================
# Uninstall
# ============================================================

uninstall_all() {
    read -p "This will remove ALL Backhaul services on THIS server. Continue? (y/n): " CONFIRM
    if [ "$CONFIRM" != "y" ]; then
        echo "Cancelled."
        return
    fi

    local units
    units=$(systemctl list-units --all 'backhaul-*.service' --no-legend 2>/dev/null | awk '{print $1}')
    for u in $units; do
        systemctl disable --now "$u" >/dev/null 2>&1 || true
        rm -f "/etc/systemd/system/$u"
    done

    systemctl daemon-reload
    rm -rf "$INSTALL_DIR"
    echo "Uninstalled."
}

# ============================================================
# Install
# ============================================================

install_flow() {
    mkdir -p "$INSTALL_DIR"
    echo ""
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

    # Token is fixed (as requested) — same on both servers, no prompt needed.
    # NOTE: this is much weaker than a random token. Anyone who guesses/knows
    # "123" can authenticate to your tunnel. Fine for quick testing, but
    # consider a random token (openssl rand -hex 24) for anything real.
    TOKEN="$FIXED_TOKEN"

    # Tunnel port still has to match on both sides. Iran picks/generates it;
    # Kharej must type in EXACTLY the same port Iran is using.
    if [ "$LOCAL_ROLE" = "Iran" ]; then
        TUNNEL_PORT_DEFAULT=$(gen_port)
        read -p "Tunnel port [${TUNNEL_PORT_DEFAULT}]: " TUNNEL_PORT
        TUNNEL_PORT=${TUNNEL_PORT:-$TUNNEL_PORT_DEFAULT}
        read -p "Inbound ports on the Iran server (comma separated, e.g. 2050,2023): " INBOUND_PORTS
        IRAN_IP="$LOCAL_PUBLIC_IP"; KHAREJ_IP="$PEER_PUBLIC_IP"
        echo ""
        echo ">>> Tunnel port: $TUNNEL_PORT   (token is fixed: $TOKEN)"
        echo ">>> Enter this EXACT port when you run this script on the Kharej server."
    else
        echo ""
        echo "This MUST exactly match the port shown on the Iran server."
        read -p "Enter the tunnel port used on the Iran server: " TUNNEL_PORT
        KHAREJ_IP="$LOCAL_PUBLIC_IP"; IRAN_IP="$PEER_PUBLIC_IP"
    fi

    ensure_backhaul_local
    if [ "$TRANSPORT" = "wss" ] || [ "$TRANSPORT" = "wssmux" ]; then
        if [ "$LOCAL_ROLE" = "Iran" ]; then
            ensure_tls_cert_local
        fi
    fi

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
            if [ "$TRANSPORT" = "wss" ] || [ "$TRANSPORT" = "wssmux" ]; then
                echo "tls_cert = \"${INSTALL_DIR}/server.crt\""
                echo "tls_key = \"${INSTALL_DIR}/server.key\""
            fi
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
After=network.target

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
After=network.target

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

    echo ""
    echo "=== Setup Completed! ==="
    echo "Tunnel port: $TUNNEL_PORT"
    echo "Token: $TOKEN"
    echo "Check: systemctl status 'backhaul-*'"
    if [ "$TOKEN" = "123" ]; then
        echo "(Reminder: token is the fixed value '123' — fine for testing, weak for production.)"
    fi
}

# ============================================================
# Menu
# ============================================================

while true; do
    echo ""
    echo "==== Backhaul Tunnel Manager ===="
    echo "1) Install / Setup tunnel"
    echo "2) Show tunnel status"
    echo "3) Manage inbound ports (Iran side)"
    echo "4) Uninstall tunnel"
    echo "5) Exit"
    read -p "Select an option [1-5]: " CHOICE
    case "$CHOICE" in
        1) install_flow ;;
        2) show_status ;;
        3) manage_ports ;;
        4) uninstall_all ;;
        5) exit 0 ;;
        *) echo "Invalid option." ;;
    esac
done
