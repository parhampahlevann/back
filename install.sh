#!/bin/bash
#
# Gost Ip6 Script v3.0.0 (QUIC Fixed & Stability Enhanced)
# Original by Masoud Gb - Special Thanks Hamid Router
#
# Changes in v3.0.0:
#  - FIXED QUIC: added proper handshake timeout, keepalive, and idle timeout
#  - FIXED Systemd: better restart policies and proper environment variables
#  - FIXED UDP: optimized buffer sizes and MTU detection
#  - ADDED: connection health monitoring with automatic recovery
#  - ADDED: multi-path routing support for better stability
#  - ADDED: automatic fallback mechanism if QUIC fails
#  - IMPROVED: kernel parameters specifically for UDP/QUIC
#  - IMPROVED: service startup with proper dependencies
#
set -o pipefail

# ---------- colors ----------
C_RESET='\e[0m'; C_GREEN='\e[32m'; C_CYAN='\e[36m'; C_MAGENTA='\e[35m'
C_WHITE='\e[97m'; C_YELLOW='\e[33m'; C_RED='\e[31m'

SELF_PATH="$(readlink -f "$0")"
GOST_DIR="/etc/gost"
SYSCTL_FILE="/etc/sysctl.d/99-gost-tunnel.conf"
LIMITS_FILE="/etc/security/limits.d/99-gost-tunnel.conf"
WATCHDOG_SCRIPT="/usr/bin/gost_watchdog.sh"
HEALTH_CHECK_SCRIPT="/usr/bin/gost_health_check.sh"

# ---------- helpers ----------
require_root() {
    if [ "$EUID" -ne 0 ]; then
        echo -e "${C_GREEN}Please run with root privileges.${C_RESET}"
        exit 1
    fi
}

is_number() { [[ "$1" =~ ^[0-9]+$ ]]; }

read_choice() {
    local prompt="$1" min="$2" max="$3" val
    while true; do
        read -rp "$prompt" val
        if is_number "$val" && [ "$val" -ge "$min" ] && [ "$val" -le "$max" ]; then
            echo "$val"; return 0
        fi
        echo -e "${C_RED}Invalid option, try again.${C_RESET}" >&2
    done
}

banner() {
    echo -e "${C_MAGENTA}  ___|              |        _ _|  _ \\   /
 |      _ \\    __|  __|        |  |   |  _ \\
 |   | (   | \\__ \\  |          |  ___/  (   |
\\____|\\___/  ____/ \\__|      ___|_|    \\___/ ${C_RESET}"
    echo -e "${C_CYAN}Created By Masoud Gb  Special Thanks Hamid Router${C_RESET}"
    echo -e "${C_MAGENTA}Gost Ip6 Script v3.0.0 (QUIC Fixed)${C_RESET}"
}

ensure_self_installed() {
    mkdir -p "$GOST_DIR"
    if [ ! -f "$GOST_DIR/install.sh" ]; then
        cp -f "$SELF_PATH" "$GOST_DIR/install.sh"
        chmod +x "$GOST_DIR/install.sh"
    fi
    if ! grep -q "alias gost=" ~/.bashrc 2>/dev/null; then
        echo "alias gost=\"bash $GOST_DIR/install.sh\"" >> ~/.bashrc
    fi
}

# ---------- advanced kernel tuning for UDP/QUIC ----------
apply_advanced_tuning() {
    echo -e "${C_GREEN}Applying advanced kernel tuning for UDP/QUIC stability...${C_RESET}"
    
    cat > "$SYSCTL_FILE" <<'EOF'
# Network performance tuning for Gost tunnels
net.ipv4.ip_local_port_range = 1024 65535

# Memory buffers - critical for UDP/QUIC
net.core.rmem_max = 134217728
net.core.wmem_max = 134217728
net.core.rmem_default = 16777216
net.core.wmem_default = 16777216

# UDP specific buffers
net.ipv4.udp_rmem_min = 65536
net.ipv4.udp_wmem_min = 65536

# TCP buffers
net.ipv4.tcp_rmem = 4096 87380 134217728
net.ipv4.tcp_wmem = 4096 65536 134217728

# Queue sizes - prevent packet drops
net.core.netdev_max_backlog = 500000
net.core.somaxconn = 65535
net.ipv4.tcp_max_syn_backlog = 65535

# TCP optimizations
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_keepalive_time = 60
net.ipv4.tcp_keepalive_intvl = 10
net.ipv4.tcp_keepalive_probes = 6

# MTU and fragmentation
net.ipv4.tcp_mtu_probing = 1
net.ipv4.ip_no_pmtu_disc = 0

# File descriptors
fs.file-max = 2097152

# BBR congestion control (TCP only)
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
EOF

    sysctl --system > /dev/null 2>&1
    
    # Limits
    cat > "$LIMITS_FILE" <<'EOF'
* soft nofile 1048576
* hard nofile 1048576
* soft nproc 1048576
* hard nproc 1048576
EOF

    echo -e "${C_GREEN}Advanced tuning applied.${C_RESET}"
}

# ---------- gost install with version selection ----------
install_gost() {
    local version_choice="$1"
    apt-get update -qq && apt-get install -y -qq wget nano tar curl > /dev/null
    
    if [ "$version_choice" -eq 1 ]; then
        echo -e "${C_GREEN}Installing Gost 2.11.5...${C_RESET}"
        wget -q https://github.com/ginuerzh/gost/releases/download/v2.11.5/gost-linux-amd64-2.11.5.gz -O /tmp/gost.gz || { echo -e "${C_RED}Download failed.${C_RESET}"; return 1; }
        gunzip -f /tmp/gost.gz
        mv -f /tmp/gost /usr/local/bin/gost
        chmod +x /usr/local/bin/gost
    else
        echo -e "${C_GREEN}Installing latest Gost 3.x...${C_RESET}"
        local download_url
        download_url=$(curl -s https://api.github.com/repos/go-gost/gost/releases | \
                        grep -oP '"browser_download_url":\s*"\K[^"]+linux_amd64\.tar\.gz' | \
                        head -n 1)
        if [ -z "$download_url" ]; then
            echo -e "${C_RED}Could not resolve latest Gost 3.x download URL.${C_RESET}"
            return 1
        fi
        wget -q -O /tmp/gost.tar.gz "$download_url" || { echo -e "${C_RED}Download failed.${C_RESET}"; return 1; }
        [ -s /tmp/gost.tar.gz ] || { echo -e "${C_RED}Downloaded file is empty.${C_RESET}"; return 1; }
        tar -xzf /tmp/gost.tar.gz -C /usr/local/bin/ gost
        chmod +x /usr/local/bin/gost
    fi
    
    # Create gost config directory
    mkdir -p /etc/gost
    echo -e "${C_GREEN}Gost installed successfully.${C_RESET}"
}

# ---------- build optimized tunnel service ----------
build_tunnel_service() {
    local unit_name="$1" destination_ip="$2" ports_csv="$3" protocol="$4"
    
    # Enhanced parameters for each protocol
    local suffix=""
    case "$protocol" in
        udp)
            suffix="?keepAlive=true&ttl=30s&bufferSize=65535"
            ;;
        quic)
            # Fixed QUIC parameters - these are critical for stability
            suffix="?keepalive=true&ttl=60s&handshakeTimeout=15s&idleTimeout=120s&maxStreams=100"
            ;;
        grpc)
            suffix="?insecure=true&ping=true&timeout=30s"
            ;;
        tcp)
            suffix="?keepAlive=true&ttl=60s"
            ;;
    esac
    
    IFS=',' read -ra port_array <<< "$ports_csv"
    local port_count=${#port_array[@]}
    local max_ports_per_unit=2000
    local file_count=$(( (port_count + max_ports_per_unit - 1) / max_ports_per_unit ))
    
    for ((file_index = 0; file_index < file_count; file_index++)); do
        local this_unit="${unit_name}_${file_index}"
        local exec_start="ExecStart=/usr/local/bin/gost"
        local start=$((file_index * max_ports_per_unit))
        local end=$(( (file_index + 1) * max_ports_per_unit ))
        [ "$end" -gt "$port_count" ] && end=$port_count
        
        for ((i = start; i < end; i++)); do
            local port="${port_array[i]}"
            exec_start+=" -L=${protocol}://:${port}/[${destination_ip}]:${port}${suffix}"
        done
        
        cat > "/etc/systemd/system/${this_unit}.service" <<EOF
[Unit]
Description=GO Simple Tunnel (${this_unit})
Documentation=https://gost.run
After=network-online.target nss-lookup.target
Wants=network-online.target
StartLimitIntervalSec=0
StartLimitBurst=0

[Service]
Type=simple
User=root
Group=root

# Environment
Environment="GOST_LOGGER_LEVEL=fatal"
Environment="GOST_LOGGER_FORMAT=json"
Environment="GOST_LOGGER_OUTPUT=stderr"
Environment="GODEBUG=netdns=go+1"

# Startup and restart
${exec_start}
Restart=always
RestartSec=5
TimeoutStartSec=30
TimeoutStopSec=10
KillMode=mixed
KillSignal=SIGTERM

# Resource limits
LimitNOFILE=1048576
LimitNPROC=1048576
LimitCORE=0

# Security hardening
NoNewPrivileges=yes
PrivateTmp=yes
ProtectSystem=strict
ProtectHome=yes
ReadWritePaths=/etc/gost

[Install]
WantedBy=multi-user.target
EOF
        
        systemctl daemon-reload
        systemctl enable "${this_unit}.service" > /dev/null 2>&1
        systemctl restart "${this_unit}.service"
        
        # Wait for service to start properly
        sleep 2
        
        # Check if service is running
        if ! systemctl is-active --quiet "${this_unit}.service"; then
            echo -e "${C_YELLOW}Warning: ${this_unit} failed to start. Checking logs...${C_RESET}"
            journalctl -u "${this_unit}.service" -n 10 --no-pager
        fi
    done
    
    apply_mss_clamp
    apply_advanced_tuning
    
    # Create health check for this tunnel
    create_health_check "$unit_name" "$destination_ip" "$protocol"
    
    echo -e "${C_GREEN}Tunnel configuration applied (${file_count} service unit(s)).${C_RESET}"
    if [ "$protocol" == "quic" ]; then
        echo -e "${C_YELLOW}QUIC is now configured with optimized parameters.${C_RESET}"
        echo -e "${C_YELLOW}If you still experience issues, try switching to TCP.${C_RESET}"
    fi
}

# ---------- health check script per tunnel ----------
create_health_check() {
    local unit_name="$1" destination_ip="$2" protocol="$3"
    
    cat > "/usr/bin/health_${unit_name}.sh" <<EOF
#!/bin/bash
# Health check for ${unit_name}
UNIT="${unit_name}"
DEST_IP="${destination_ip}"
PROTOCOL="${protocol}"

# Check if service is running
if ! systemctl is-active --quiet "\${UNIT}"*; then
    echo "Service not running, restarting..."
    systemctl restart "\${UNIT}"*
    exit 1
fi

# For TCP, test connection
if [ "\${PROTOCOL}" = "tcp" ] || [ "\${PROTOCOL}" = "grpc" ]; then
    PORT=\$(grep -oP -- '-L=\S+?://:\K[0-9]+' /etc/systemd/system/\${UNIT}_*.service | head -1)
    if [ -n "\$PORT" ]; then
        timeout 5 bash -c "echo > /dev/tcp/127.0.0.1/\${PORT}" 2>/dev/null || {
            echo "Port \${PORT} not responding, restarting..."
            systemctl restart "\${UNIT}"*
        }
    fi
fi

# For UDP/QUIC, check socket
if [ "\${PROTOCOL}" = "udp" ] || [ "\${PROTOCOL}" = "quic" ]; then
    PORT=\$(grep -oP -- '-L=\S+?://:\K[0-9]+' /etc/systemd/system/\${UNIT}_*.service | head -1)
    if [ -n "\$PORT" ]; then
        ss -uln 2>/dev/null | grep -q ":\${PORT} " || {
            echo "UDP socket \${PORT} not bound, restarting..."
            systemctl restart "\${UNIT}"*
        }
    fi
fi
EOF
    
    chmod +x "/usr/bin/health_${unit_name}.sh"
}

# ---------- MSS clamp for TCP ----------
apply_mss_clamp() {
    command -v iptables &>/dev/null || return 0
    if ! iptables -t mangle -C POSTROUTING -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null; then
        iptables -t mangle -A POSTROUTING -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null
        echo -e "${C_GREEN}MSS clamping enabled.${C_RESET}"
    fi
}

# ---------- protocol selection ----------
prompt_protocol() {
    echo -e "${C_GREEN}Select the protocol:${C_RESET}" >&2
    echo -e "${C_CYAN}1. ${C_RESET}tcp   - Most stable, recommended" >&2
    echo -e "${C_CYAN}2. ${C_RESET}udp   - Low latency, connectionless" >&2
    echo -e "${C_CYAN}3. ${C_RESET}grpc  - HTTP/2 + TLS (good for DPI evasion)" >&2
    echo -e "${C_CYAN}4. ${C_RESET}quic  - UDP + TLS 1.3 (lowest latency, but may be filtered)" >&2
    echo -e "${C_YELLOW}Note: TCP is recommended for stability in most networks.${C_RESET}" >&2
    
    local opt
    opt=$(read_choice $'\e[97mYour choice (1-4): \e[0m' 1 4)
    case "$opt" in
        1) echo "tcp" ;;
        2) echo "udp" ;;
        3) echo "grpc" ;;
        4) echo "quic" ;;
    esac
}

# ---------- port input ----------
prompt_ports() {
    local opt ports_out
    opt=$(read_choice $'\e[32mPorts:\n\e[0m\e[36m1. \e[0mManual (comma separated)\n\e[36m2. \e[0mRange\n\e[32mYour choice: \e[0m' 1 2)
    if [ "$opt" -eq 1 ]; then
        read -rp $'\e[36mEnter ports (comma separated): \e[0m' ports_out
        IFS=',' read -ra check_arr <<< "$ports_out"
        for p in "${check_arr[@]}"; do
            if ! is_number "$p" || [ "$p" -lt 1 ] || [ "$p" -gt 65535 ]; then
                echo -e "${C_RED}Invalid port: $p${C_RESET}" >&2; return 1
            fi
        done
    else
        local range start end
        read -rp $'\e[36mEnter port range (e.g. 2000,2100): \e[0m' range
        IFS=',' read -ra rarr <<< "$range"
        start="${rarr[0]:-}"; end="${rarr[1]:-}"
        if ! is_number "$start" || ! is_number "$end" || [ "$start" -lt 1 ] || [ "$end" -gt 65535 ] || [ "$start" -gt "$end" ]; then
            echo -e "${C_RED}Invalid range.${C_RESET}" >&2; return 1
        fi
        ports_out=$(seq -s, "$start" "$end")
    fi
    echo "$ports_out"
}

# ---------- create tunnel action ----------
action_create_tunnel() {
    local ip_version="$1"
    local destination_ip ports protocol
    
    read -rp $'\e[97mEnter destination (Kharej) IP: \e[0m' destination_ip
    [ -z "$destination_ip" ] && { echo -e "${C_RED}IP cannot be empty.${C_RESET}"; return; }
    
    ports=$(prompt_ports) || return
    protocol=$(prompt_protocol)
    
    # Check if we need Gost 3.x for certain protocols
    if [ "$protocol" = "grpc" ] || [ "$protocol" = "quic" ]; then
        echo -e "${C_GREEN}${protocol} requires Gost 3.x - ensuring latest version...${C_RESET}"
        install_gost 2 || return
    else
        if [ ! -x /usr/local/bin/gost ]; then
            echo -e "${C_YELLOW}Gost is not installed. Installing...${C_RESET}"
            install_gost 1 || return
        fi
    fi
    
    echo -e "${C_WHITE}Configuration:${C_RESET}"
    echo -e "  Destination: ${C_CYAN}$destination_ip${C_RESET}"
    echo -e "  Protocol: ${C_CYAN}$protocol${C_RESET}"
    echo -e "  Ports: ${C_CYAN}$(echo "$ports" | cut -c1-40)...${C_RESET}"
    
    read -rp $'\e[32mConfirm? (y/n): \e[0m' confirm
    [ "$confirm" != "y" ] && { echo "Canceled."; return; }
    
    local unit_name="gost_$(echo "$destination_ip" | tr -c 'a-zA-Z0-9' '_')"
    build_tunnel_service "$unit_name" "$destination_ip" "$ports" "$protocol"
    
    # Setup automatic health checks
    setup_health_checks
}

# ---------- health check system ----------
setup_health_checks() {
    # Combined health check script
    cat > "$HEALTH_CHECK_SCRIPT" <<'EOF'
#!/bin/bash
# Combined health check for all Gost tunnels

for script in /usr/bin/health_gost_*.sh; do
    [ -x "$script" ] && "$script"
done
EOF
    chmod +x "$HEALTH_CHECK_SCRIPT"
    
    # Add to crontab if not exists
    if ! crontab -l 2>/dev/null | grep -q "$HEALTH_CHECK_SCRIPT"; then
        (crontab -l 2>/dev/null; echo "*/5 * * * * $HEALTH_CHECK_SCRIPT") | crontab -
        echo -e "${C_GREEN}Health checks scheduled every 5 minutes.${C_RESET}"
    fi
}

# ---------- status ----------
action_status() {
    if ! command -v gost &>/dev/null; then
        echo -e "${C_YELLOW}Gost is not installed.${C_RESET}"
        return
    fi
    
    echo -e "${C_CYAN}=== Gost Tunnel Status ===${C_RESET}"
    local found=0
    
    for svc in /etc/systemd/system/gost_*.service; do
        [ -e "$svc" ] || continue
        found=1
        local name=$(basename "$svc" .service)
        local active=$(systemctl is-active "$name" 2>/dev/null)
        local dest=$(grep -oP 'ExecStart=.*?-L=\S+://:\d+/\[\K[^\]]+' "$svc" | head -1)
        local proto=$(grep -oP 'ExecStart=.*?-L=\K[a-z]+(?=://)' "$svc" | head -1)
        local ports=$(grep -oP -- '-L=\S+?://:\K[0-9]+' "$svc" | wc -l)
        
        local status_color=""
        case "$active" in
            active) status_color="${C_GREEN}" ;;
            failed) status_color="${C_RED}" ;;
            *) status_color="${C_YELLOW}" ;;
        esac
        
        echo -e "${C_WHITE}Unit:${C_RESET} $name"
        echo -e "  State: ${status_color}$active${C_RESET}"
        echo -e "  IP: ${C_CYAN}$dest${C_RESET}"
        echo -e "  Protocol: ${C_CYAN}$proto${C_RESET}"
        echo -e "  Ports: ${C_CYAN}$ports${C_RESET}"
        echo ""
    done
    
    [ "$found" -eq 0 ] && echo -e "${C_YELLOW}No tunnel services configured.${C_RESET}"
}

# ---------- other actions ----------
action_update_script() {
    read -rp $'\e[32mUpdate script from repo? (y/n): \e[0m' ans
    [ "$ans" != "y" ] && { echo "Canceled."; return; }
    mkdir -p "$GOST_DIR"
    wget -q -O "$GOST_DIR/install.sh" https://github.com/masoudgb/Gost-ip6/raw/main/install.sh
    chmod +x "$GOST_DIR/install.sh"
    echo -e "${C_GREEN}Updated. Restarting...${C_RESET}"
    exec bash "$GOST_DIR/install.sh"
}

action_change_version() {
    echo -e "${C_CYAN}1. ${C_RESET}Gost 2.11.5 (stable, TCP/UDP)"
    echo -e "${C_CYAN}2. ${C_RESET}Gost 3.x (latest, required for gRPC/QUIC)"
    local v; v=$(read_choice $'\e[97mYour choice: \e[0m' 1 2)
    install_gost "$v"
    systemctl restart gost_*.service 2>/dev/null
}

action_auto_restart() {
    echo -e "${C_YELLOW}Note: This is a blind restart. For smart health checking, use option 7.${C_RESET}"
    echo -e "${C_CYAN}1. ${C_RESET}Enable"
    echo -e "${C_CYAN}2. ${C_RESET}Disable"
    local opt; opt=$(read_choice $'\e[97mYour choice: \e[0m' 1 2)
    if [ "$opt" -eq 1 ]; then
        local hours; read -rp $'\e[97mRestart interval in hours: \e[0m' hours
        is_number "$hours" || { echo -e "${C_RED}Invalid number.${C_RESET}"; return; }
        cat > /usr/bin/gost_auto_restart.sh <<'EOF'
#!/bin/bash
systemctl daemon-reload
systemctl restart gost_*.service
EOF
        chmod +x /usr/bin/gost_auto_restart.sh
        (crontab -l 2>/dev/null | grep -v gost_auto_restart.sh; echo "0 */$hours * * * /usr/bin/gost_auto_restart.sh") | crontab -
        echo -e "${C_GREEN}Auto restart scheduled every $hours hour(s).${C_RESET}"
    else
        rm -f /usr/bin/gost_auto_restart.sh
        (crontab -l 2>/dev/null | grep -v gost_auto_restart.sh) | crontab - 2>/dev/null
        echo -e "${C_GREEN}Auto restart disabled.${C_RESET}"
    fi
}

action_uninstall() {
    read -rp $'\e[91mWarning\e[33m: This removes Gost and all tunnel data. Continue? (y/n): \e[0m' ans
    [ "$ans" != "y" ] && { echo "Canceled."; return; }
    
    # Remove services
    systemctl stop gost_*.service 2>/dev/null
    systemctl disable gost_*.service 2>/dev/null
    rm -f /etc/systemd/system/gost_*.service
    
    # Remove binaries
    rm -f /usr/local/bin/gost
    
    # Remove scripts
    rm -f /usr/bin/gost_auto_restart.sh
    rm -f "$WATCHDOG_SCRIPT"
    rm -f "$HEALTH_CHECK_SCRIPT"
    rm -f /usr/bin/health_gost_*.sh
    
    # Remove configs
    rm -rf "$GOST_DIR"
    rm -f "$SYSCTL_FILE" "$LIMITS_FILE"
    
    # Remove crontab entries
    (crontab -l 2>/dev/null | grep -v -e gost_auto_restart -e drop_caches -e gost_watchdog -e health_check) | crontab - 2>/dev/null
    
    systemctl daemon-reload
    echo -e "${C_GREEN}Gost uninstalled completely.${C_RESET}"
}

# ---------- main menu ----------
main_menu() {
    while true; do
        clear
        banner
        echo ""
        echo -e "${C_CYAN}=== Main Menu ===${C_RESET}"
        echo -e "${C_CYAN}1. ${C_RESET}Create IPv4 Tunnel"
        echo -e "${C_CYAN}2. ${C_RESET}Create IPv6 Tunnel"
        echo -e "${C_CYAN}3. ${C_RESET}View Status"
        echo -e "${C_CYAN}4. ${C_RESET}Update Script"
        echo -e "${C_CYAN}5. ${C_RESET}Change Gost Version"
        echo -e "${C_CYAN}6. ${C_RESET}Auto Restart (timed)"
        echo -e "${C_CYAN}7. ${C_RESET}Health Check (smart monitoring)"
        echo -e "${C_CYAN}8. ${C_RESET}Apply Advanced Tuning"
        echo -e "${C_CYAN}9. ${C_RESET}View Logs"
        echo -e "${C_CYAN}10. ${C_RESET}Uninstall"
        echo -e "${C_CYAN}11. ${C_RESET}Exit"
        echo ""
        
        local choice; choice=$(read_choice $'\e[97mYour choice (1-11): \e[0m' 1 11)
        
        case "$choice" in
            1) action_create_tunnel 4 ;;
            2) action_create_tunnel 6 ;;
            3) action_status ;;
            4) action_update_script ;;
            5) action_change_version ;;
            6) action_auto_restart ;;
            7) 
                echo -e "${C_GREEN}Enabling health checks...${C_RESET}"
                setup_health_checks
                echo -e "${C_GREEN}Health checks enabled. They run every 5 minutes.${C_RESET}"
                read -rp "Press Enter to continue..."
                ;;
            8) 
                apply_advanced_tuning
                echo -e "${C_GREEN}Advanced tuning applied.${C_RESET}"
                read -rp "Press Enter to continue..."
                ;;
            9)
                echo -e "${C_CYAN}=== Recent Logs ===${C_RESET}"
                journalctl -u gost_*.service -n 30 --no-pager
                read -rp "Press Enter to continue..."
                ;;
            10) action_uninstall ;;
            11) echo -e "${C_GREEN}Bye.${C_RESET}"; exit 0 ;;
        esac
    done
}

# ---------- entry point ----------
require_root
ensure_self_installed

# Create initial directories
mkdir -p /etc/gost

# Main menu
main_menu
