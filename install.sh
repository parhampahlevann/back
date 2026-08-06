#!/bin/bash
#
# Gost Ip6 Script v2.4.0 (hardened/optimized fork)
# Original by Masoud Gb - Special Thanks Hamid Router
#
# Changes in v2.4.0 (this revision):
#  - REMOVED ws / wss / mwss: unreliable in real-world use with this
#    script's direct-forwarder model; dropped instead of half-fixed.
#  - grpc kept, but the script now FORCES Gost 3.x for grpc and quic,
#    because Gost 2.11.5's grpc/quic implementations are old and are the
#    most likely cause of the "traffic doesn't pass / packet loss"
#    symptom. 2.11.5 is still offered, but only for tcp/udp.
#  - Added quic protocol (UDP + TLS1.3, lowest latency of the wrapped
#    options). NOTE: some networks throttle or block UDP/QUIC traffic
#    specifically because it's a well-known circumvention vector - if
#    quic "doesn't work" on a specific network, that is very likely
#    network-level UDP filtering, not a script bug. Test tcp as a
#    control before assuming quic itself is broken.
#  - systemd units: added StartLimitIntervalSec=0. Without this,
#    systemd's default burst limiter (5 restarts / 10s) permanently
#    stops restarting a unit that keeps crashing - this is a common,
#    silent cause of tunnels that "just stop working" until manual
#    intervention. This alone can fix a lot of the disconnect reports.
#  - Added a real Watchdog (menu item) that probes the actual listening
#    port and restarts only the specific unit that's unhealthy, instead
#    of blindly restarting everything on a timer.
#  - Kernel tuning extended with UDP-receive-path tunables
#    (netdev_max_backlog, udp_rmem_min/udp_wmem_min, rmem/wmem default)
#    which matter for udp/quic under load and were missing before -
#    a common source of silent UDP packet loss under load.
#  - Everything else from v2.3.0 (input validation, MSS clamp, single
#    case-statement menu dispatch, sysctl.d/limits.d instead of
#    rc.local, self-install to /etc/gost/install.sh) is unchanged.
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

# ---------- helpers ----------
require_root() {
    if [ "$EUID" -ne 0 ]; then
        echo -e "${C_GREEN}Please run with root privileges.${C_RESET}"
        exit 1
    fi
}

is_number() { [[ "$1" =~ ^[0-9]+$ ]]; }

read_choice() {
    # $1 = prompt, $2 = min, $3 = max -> echoes validated integer
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
    echo -e "${C_MAGENTA}Gost Ip6 Script v2.4.0 (hardened)${C_RESET}"
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

# ---------- kernel / TCP+UDP tuning for speed + stability ----------
apply_kernel_tuning() {
    echo -e "${C_GREEN}Applying kernel/TCP/UDP tuning for throughput and stability...${C_RESET}"

    local kernel_major kernel_minor bbr_ok=1
    kernel_major=$(uname -r | cut -d. -f1)
    kernel_minor=$(uname -r | cut -d. -f2)
    if [ "$kernel_major" -lt 4 ] || { [ "$kernel_major" -eq 4 ] && [ "$kernel_minor" -lt 9 ]; }; then
        bbr_ok=0
        echo -e "${C_YELLOW}Kernel < 4.9, BBR not available - skipping congestion control change.${C_RESET}"
    fi
    # Note: BBR is a TCP-only congestion control. It has zero effect on
    # udp/quic traffic - quic's congestion control lives inside gost's
    # quic-go library, not the kernel. Don't expect BBR to help quic.

    {
        echo "net.ipv4.ip_local_port_range = 1024 65535"
        echo "net.core.rmem_max = 67108864"
        echo "net.core.wmem_max = 67108864"
        echo "net.core.rmem_default = 1048576"
        echo "net.core.wmem_default = 1048576"
        echo "net.ipv4.tcp_rmem = 4096 87380 67108864"
        echo "net.ipv4.tcp_wmem = 4096 65536 67108864"
        echo "net.ipv4.udp_rmem_min = 131072"
        echo "net.ipv4.udp_wmem_min = 131072"
        # Raises the kernel's receive backlog queue so bursts of udp/quic
        # packets aren't dropped before the app (gost) reads them - the
        # default (1000) is too low for a busy udp/quic relay and is a
        # common silent cause of "packet loss" that never shows up in
        # gost's own logs because the kernel drops the packet first.
        echo "net.core.netdev_max_backlog = 250000"
        echo "net.core.somaxconn = 65535"
        echo "net.ipv4.tcp_max_syn_backlog = 65535"
        echo "net.ipv4.tcp_syncookies = 1"
        echo "net.ipv4.tcp_fin_timeout = 15"
        echo "net.ipv4.tcp_tw_reuse = 1"
        echo "net.ipv4.tcp_slow_start_after_idle = 0"
        # keepalive: detect and recover dead tunnel connections fast
        echo "net.ipv4.tcp_keepalive_time = 60"
        echo "net.ipv4.tcp_keepalive_intvl = 10"
        echo "net.ipv4.tcp_keepalive_probes = 6"
        echo "net.ipv4.tcp_mtu_probing = 1"
        echo "fs.file-max = 2097152"
        if [ "$bbr_ok" -eq 1 ]; then
            echo "net.core.default_qdisc = fq"
            echo "net.ipv4.tcp_congestion_control = bbr"
        fi
        # A relay box juggling thousands of forwarded connections can
        # silently exhaust the default conntrack table (65536 on most
        # distros) - once full, new connections get dropped with no
        # error in gost's own logs, which just looks like "sometimes it
        # doesn't work". Only written if the module is actually present.
        if modprobe nf_conntrack 2>/dev/null || [ -e /proc/sys/net/netfilter/nf_conntrack_max ]; then
            echo "net.netfilter.nf_conntrack_max = 1048576"
            echo "net.netfilter.nf_conntrack_tcp_timeout_established = 3600"
        fi
    } > "$SYSCTL_FILE"

    sysctl --system > /dev/null 2>&1

    if [ -w /sys/module/nf_conntrack/parameters/hashsize ]; then
        echo 262144 > /sys/module/nf_conntrack/parameters/hashsize 2>/dev/null
    fi

    {
        echo "* soft nofile 1048576"
        echo "* hard nofile 1048576"
        echo "* soft nproc 1048576"
        echo "* hard nproc 1048576"
    } > "$LIMITS_FILE"

    echo -e "${C_GREEN}Kernel/TCP/UDP tuning applied.${C_RESET}"
}

# ---------- gost install ----------
# IMPORTANT: if direct GitHub access from this server is blocked/reset
# (not just slow), no amount of retrying the direct URL will help. So we
# fall back through a couple of well-known public GitHub download mirrors.
# These are third-party services, not run by us or Anthropic - use at
# your own judgment. Because of that, every downloaded file is checked
# for a real ELF header before being installed, to catch a mirror
# silently returning an HTML error page instead of the binary.
WGET_OPTS="--timeout=20 --tries=2 --waitretry=2"
CURL_OPTS="--connect-timeout 10 --max-time 25 --retry 2 --retry-delay 2 -s"
GH_MIRRORS=("" "https://gh-proxy.com/" "https://mirror.ghproxy.com/")
# Used only if the GitHub API itself can't be reached to discover the
# true latest version - update this occasionally so it doesn't go too stale.
GOST3_PINNED_VERSION="3.2.6"

is_elf_binary() { [ -f "$1" ] && [ "$(head -c4 "$1" 2>/dev/null | od -An -tx1 | tr -d ' \n')" = "7f454c46" ]; }

# fetch_with_mirrors <url-without-scheme-prefix-issue> <output-path>
# Tries the URL directly, then through each mirror prefix, in order.
fetch_with_mirrors() {
    local url="$1" out="$2" m label
    for m in "${GH_MIRRORS[@]}"; do
        label="direct GitHub"; [ -n "$m" ] && label="mirror $m"
        echo -e "${C_GREEN}Trying ${label}...${C_RESET}"
        rm -f "$out"
        if wget $WGET_OPTS -q -O "$out" "${m}${url}" && [ -s "$out" ]; then
            return 0
        fi
    done
    return 1
}

install_gost() {
    local version_choice="$1"
    apt-get update -qq && apt-get install -y -qq wget nano tar curl > /dev/null

    if [ "$version_choice" -eq 1 ]; then
        if ! fetch_with_mirrors "https://github.com/ginuerzh/gost/releases/download/v2.11.5/gost-linux-amd64-2.11.5.gz" /tmp/gost.gz; then
            echo -e "${C_RED}Download failed on direct GitHub and both mirrors. Your server likely has no usable path to GitHub at all right now.${C_RESET}"
            echo -e "${C_YELLOW}If you have a working proxy, export it and re-run: export https_proxy=http://IP:PORT; export http_proxy=http://IP:PORT${C_RESET}"
            return 1
        fi
        gunzip -f /tmp/gost.gz
        mv -f /tmp/gost /usr/local/bin/gost
        chmod +x /usr/local/bin/gost
    else
        echo -e "${C_GREEN}Resolving latest Gost 3.x version via GitHub API...${C_RESET}"
        local download_url
        download_url=$(curl $CURL_OPTS https://api.github.com/repos/go-gost/gost/releases | \
                        grep -oP '"browser_download_url":\s*"\K[^"]+linux_amd64\.tar\.gz' | \
                        grep -v amd64v3 | head -n 1)
        if [ -z "$download_url" ]; then
            echo -e "${C_YELLOW}GitHub API unreachable/rate-limited - falling back to pinned version ${GOST3_PINNED_VERSION}.${C_RESET}"
            download_url="https://github.com/go-gost/gost/releases/download/v${GOST3_PINNED_VERSION}/gost_${GOST3_PINNED_VERSION}_linux_amd64.tar.gz"
        fi
        if ! fetch_with_mirrors "$download_url" /tmp/gost.tar.gz; then
            echo -e "${C_RED}Download failed on direct GitHub and both mirrors. Your server likely has no usable path to GitHub at all right now.${C_RESET}"
            echo -e "${C_YELLOW}If you have a working proxy, export it and re-run: export https_proxy=http://IP:PORT; export http_proxy=http://IP:PORT${C_RESET}"
            return 1
        fi
        tar -xzf /tmp/gost.tar.gz -C /usr/local/bin/ gost 2>/dev/null
        chmod +x /usr/local/bin/gost 2>/dev/null
    fi

    if ! is_elf_binary /usr/local/bin/gost; then
        echo -e "${C_RED}The downloaded file isn't a valid binary (likely an error page from a mirror, or a bad archive). Aborting install.${C_RESET}"
        rm -f /usr/local/bin/gost
        return 1
    fi
    echo -e "${C_GREEN}Gost installed successfully.${C_RESET}"
}

# grpc and quic need Gost 3.x - 2.11.5's implementation of both is old
# and is the most likely reason they misbehave (dropped traffic / total
# failure). tcp/udp work fine on either version, so we only force the
# version when it actually matters.
ensure_gost_for_protocol() {
    local protocol="$1"

    if [ ! -x /usr/local/bin/gost ]; then
        if [ "$protocol" == "grpc" ] || [ "$protocol" == "quic" ]; then
            echo -e "${C_YELLOW}${protocol} requires Gost 3.x - installing the latest 3.x automatically.${C_RESET}"
            install_gost 2
            return $?
        fi
        echo -e "${C_GREEN}Gost is not installed yet.${C_RESET}"
        echo -e "${C_CYAN}1. ${C_RESET}Gost 2.11.5 (official, stable, tcp/udp)"
        echo -e "${C_CYAN}2. ${C_RESET}Gost 3.x (latest, required for grpc/quic)"
        local v; v=$(read_choice $'\e[97mYour choice: \e[0m' 1 2)
        install_gost "$v"
        return $?
    fi

    if [ "$protocol" == "grpc" ] || [ "$protocol" == "quic" ]; then
        # best-effort version probe - if it fails we just proceed, we don't
        # want a fragile version-string parse to block a working setup
        local ver_line
        ver_line=$(/usr/local/bin/gost -V 2>&1 | head -1)
        if echo "$ver_line" | grep -qE '(^| )gost( |v)?2\.'; then
            echo -e "${C_YELLOW}Installed Gost looks like a 2.x build - ${protocol} needs 3.x. Reinstalling latest 3.x...${C_RESET}"
            install_gost 2
            return $?
        fi
    fi
    return 0
}

# ---------- build/refresh a tunnel systemd unit ----------
# args: unit_name  destination_ip  ports_csv  protocol
build_tunnel_service() {
    local unit_name="$1" destination_ip="$2" ports_csv="$3" protocol="$4"

    # Reliability query params appended to every -L listener. tcp needs
    # nothing extra. udp/quic default to tearing a "connection" down
    # after ~5s of silence, which reads as a random disconnect for any
    # session that goes briefly idle - keepAlive+ttl fixes that.
    local suffix=""
    case "$protocol" in
        udp)  suffix="?keepAlive=true&ttl=10s" ;;
        quic) suffix="?keepalive=true&ttl=10s" ;;
        kcp)  suffix="?kcp.mode=fast" ;;
    esac

    IFS=',' read -ra port_array <<< "$ports_csv"
    local port_count=${#port_array[@]}
    local max_ports_per_unit=4000   # keep ExecStart lines sane and startup fast
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
After=network-online.target
Wants=network-online.target
StartLimitIntervalSec=0

[Service]
Type=simple
Environment="GOST_LOGGER_LEVEL=fatal"
${exec_start}
Restart=always
RestartSec=2
TimeoutStopSec=5
LimitNOFILE=1048576
LimitNPROC=1048576

[Install]
WantedBy=multi-user.target
EOF
        systemctl enable "${this_unit}.service" > /dev/null 2>&1
        systemctl daemon-reload
        systemctl restart "${this_unit}.service"
    done

    apply_mss_clamp

    echo -e "${C_GREEN}Tunnel configuration applied (${file_count} service unit(s)).${C_RESET}"
    if [ "$protocol" == "quic" ]; then
        echo -e "${C_YELLOW}Note: quic runs over UDP. If it never connects at all (not just slow/packet loss), that is almost always the network path blocking/throttling UDP, not this script. Try tcp as a control to confirm.${C_RESET}"
    fi
}

# TLS/gRPC framing adds bytes on top of the real payload; if a packet then
# exceeds path MTU it gets fragmented or silently dropped by routers that
# block fragments - a common cause of "works but unstable/slow" over grpc.
# Clamping MSS to the actual path MTU avoids this without needing to know
# the exact MTU in advance. NOTE: this only helps TCP-based protocols
# (tcp, grpc) - it does nothing for udp/quic, which don't use MSS.
apply_mss_clamp() {
    command -v iptables &>/dev/null || return 0
    if ! iptables -t mangle -C POSTROUTING -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null; then
        iptables -t mangle -A POSTROUTING -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null
        echo -e "${C_GREEN}MSS clamping enabled (reduces fragmentation-related packet loss on tcp/grpc).${C_RESET}"
    fi
}

prompt_protocol() {
    echo -e "${C_GREEN}Select the protocol:${C_RESET}" >&2
    echo -e "${C_CYAN}1. ${C_RESET}tcp   plain TCP relay - fastest when the path is clean, but on a lossy/long-haul link TCP's own congestion control will make it feel slow" >&2
    echo -e "${C_CYAN}2. ${C_RESET}udp   plain UDP relay" >&2
    echo -e "${C_CYAN}3. ${C_RESET}grpc  HTTP/2 + TLS wrapped (forces Gost 3.x)" >&2
    echo -e "${C_CYAN}4. ${C_RESET}quic  UDP + TLS1.3, lowest latency of the wrapped options (forces Gost 3.x - some networks throttle/block UDP-based QUIC, test tcp first if unsure)" >&2
    echo -e "${C_CYAN}5. ${C_RESET}kcp   UDP-based with forward-error-correction/aggressive retransmit - built specifically for lossy international links where plain tcp feels slow but doesn't drop" >&2
    local opt
    opt=$(read_choice $'\e[97mYour choice: \e[0m' 1 5)
    case "$opt" in
        1) echo "tcp" ;;
        2) echo "udp" ;;
        3) echo "grpc" ;;
        4) echo "quic" ;;
        5) echo "kcp" ;;
    esac
}

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

action_create_tunnel() {
    local ip_version="$1" destination_ip ports protocol
    read -rp $'\e[97mEnter destination (Kharej) IP: \e[0m' destination_ip
    [ -z "$destination_ip" ] && { echo -e "${C_RED}IP cannot be empty.${C_RESET}"; return; }

    ports=$(prompt_ports) || return
    protocol=$(prompt_protocol)

    echo -e "${C_WHITE}Destination:${C_RESET} $destination_ip  ${C_WHITE}Protocol:${C_RESET} $protocol  ${C_WHITE}Ports:${C_RESET} $(echo "$ports" | cut -c1-40)..."

    ensure_gost_for_protocol "$protocol" || return

    local unit_name="gost_$(echo "$destination_ip" | tr -c 'a-zA-Z0-9' '_')"
    build_tunnel_service "$unit_name" "$destination_ip" "$ports" "$protocol"
    apply_kernel_tuning
}

action_status() {
    if ! command -v gost &>/dev/null; then
        echo -e "${C_YELLOW}Gost is not installed.${C_RESET}"
        return
    fi
    local found=0
    for svc in /etc/systemd/system/gost_*.service; do
        [ -e "$svc" ] || continue
        found=1
        local active dest proto ports
        active=$(systemctl is-active "$(basename "$svc")" 2>/dev/null)
        dest=$(grep -oP 'ExecStart=.*?-L=\S+://:\d+/\[\K[^\]]+' "$svc" | head -1)
        proto=$(grep -oP 'ExecStart=.*?-L=\K[a-z]+(?=://)' "$svc" | head -1)
        ports=$(grep -oP -- '-L=\S+?://:\K[0-9]+' "$svc" | wc -l)
        echo -e "${C_WHITE}Unit:${C_RESET} $(basename "$svc")  ${C_WHITE}State:${C_RESET} $active  ${C_WHITE}IP:${C_RESET} $dest  ${C_WHITE}Proto:${C_RESET} $proto  ${C_WHITE}Ports:${C_RESET} $ports"
    done
    [ "$found" -eq 0 ] && echo -e "${C_YELLOW}No tunnel services configured.${C_RESET}"
}

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
    echo -e "${C_CYAN}1. ${C_RESET}Gost 2.11.5"
    echo -e "${C_CYAN}2. ${C_RESET}Gost 3.x (latest)"
    local v; v=$(read_choice $'\e[97mYour choice: \e[0m' 1 2)
    install_gost "$v"
    systemctl restart gost_*.service 2>/dev/null
}

action_auto_restart() {
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

# ---------- watchdog: probes the actual port instead of blind restarts ----------
generate_watchdog_script() {
    cat > "$WATCHDOG_SCRIPT" <<'WDEOF'
#!/bin/bash
# Restarts only the gost unit(s) whose listening port has actually stopped
# responding, instead of blindly restarting everything on a timer.
for unit in /etc/systemd/system/gost_*.service; do
    [ -e "$unit" ] || continue
    name="$(basename "$unit" .service)"

    if ! systemctl is-active --quiet "$name"; then
        systemctl restart "$name"
        continue
    fi

    port="$(grep -oP -- '-L=\S+?://:\K[0-9]+' "$unit" | head -1)"
    proto="$(grep -oP 'ExecStart=.*?-L=\K[a-z]+(?=://)' "$unit" | head -1)"
    [ -z "$port" ] && continue

    if [ "$proto" = "udp" ] || [ "$proto" = "quic" ]; then
        # UDP/QUIC are connectionless - a real end-to-end probe isn't
        # reliable here, so this only confirms the socket is still bound.
        ss -uln 2>/dev/null | grep -q ":${port} " || systemctl restart "$name"
    else
        timeout 3 bash -c "echo > /dev/tcp/127.0.0.1/${port}" 2>/dev/null || systemctl restart "$name"
    fi
done
WDEOF
    chmod +x "$WATCHDOG_SCRIPT"
}

action_watchdog() {
    echo -e "${C_GREEN}This checks every 2 minutes whether each tunnel's port is actually${C_RESET}"
    echo -e "${C_GREEN}alive and restarts only the ones that aren't - independent of the${C_RESET}"
    echo -e "${C_GREEN}blind timed restart in option 6.${C_RESET}"
    echo -e "${C_CYAN}1. ${C_RESET}Enable"
    echo -e "${C_CYAN}2. ${C_RESET}Disable"
    local opt; opt=$(read_choice $'\e[97mYour choice: \e[0m' 1 2)
    if [ "$opt" -eq 1 ]; then
        generate_watchdog_script
        (crontab -l 2>/dev/null | grep -v gost_watchdog.sh; echo "*/2 * * * * $WATCHDOG_SCRIPT") | crontab -
        echo -e "${C_GREEN}Watchdog enabled.${C_RESET}"
    else
        rm -f "$WATCHDOG_SCRIPT"
        (crontab -l 2>/dev/null | grep -v gost_watchdog.sh) | crontab - 2>/dev/null
        echo -e "${C_GREEN}Watchdog disabled.${C_RESET}"
    fi
}

action_auto_clear_cache() {
    echo -e "${C_YELLOW}Note: dropping page cache does not speed up an already-running tunnel and can briefly hurt performance right after it runs; only useful on memory-starved boxes.${C_RESET}"
    echo -e "${C_CYAN}1. ${C_RESET}Enable"
    echo -e "${C_CYAN}2. ${C_RESET}Disable"
    local opt; opt=$(read_choice $'\e[97mYour choice: \e[0m' 1 2)
    if [ "$opt" -eq 1 ]; then
        local days; read -rp $'\e[97mInterval in days: \e[0m' days
        is_number "$days" || { echo -e "${C_RED}Invalid number.${C_RESET}"; return; }
        (crontab -l 2>/dev/null | grep -v drop_caches; echo "0 0 */$days * * sync; echo 3 > /proc/sys/vm/drop_caches") | crontab -
        echo -e "${C_GREEN}Scheduled.${C_RESET}"
    else
        (crontab -l 2>/dev/null | grep -v drop_caches) | crontab - 2>/dev/null
        echo -e "${C_GREEN}Disabled.${C_RESET}"
    fi
}

action_install_bbr() {
    apply_kernel_tuning
    echo -e "${C_CYAN}Optional: also run teddysun/across bbr.sh for alternate congestion-control algorithms (bbrplus/etc)? (y/n)${C_RESET}"
    read -rp "> " ans
    if [ "$ans" == "y" ]; then
        wget -qN --no-check-certificate https://github.com/teddysun/across/raw/master/bbr.sh && chmod +x bbr.sh && bash bbr.sh
    fi
}

action_uninstall() {
    read -rp $'\e[91mWarning\e[33m: this removes Gost and all tunnel data. Continue? (y/n): \e[0m' ans
    [ "$ans" != "y" ] && { echo "Canceled."; return; }
    rm -f /usr/bin/gost_auto_restart.sh "$WATCHDOG_SCRIPT"
    (crontab -l 2>/dev/null | grep -v gost_auto_restart.sh | grep -v drop_caches | grep -v gost_watchdog.sh) | crontab - 2>/dev/null
    systemctl stop gost_*.service 2>/dev/null
    systemctl disable gost_*.service 2>/dev/null
    rm -f /etc/systemd/system/gost_*.service
    rm -f /usr/local/bin/gost
    rm -rf "$GOST_DIR"
    rm -f "$SYSCTL_FILE" "$LIMITS_FILE"
    systemctl daemon-reload
    echo -e "${C_GREEN}Gost uninstalled.${C_RESET}"
}

main_menu() {
    banner
    echo -e "${C_CYAN}1. ${C_RESET}Gost Tunnel By IP4"
    echo -e "${C_CYAN}2. ${C_RESET}Gost Tunnel By IP6"
    echo -e "${C_CYAN}3. ${C_RESET}Gost Status"
    echo -e "${C_CYAN}4. ${C_RESET}Update Script"
    echo -e "${C_CYAN}5. ${C_RESET}Change Gost Version"
    echo -e "${C_CYAN}6. ${C_RESET}Auto Restart Gost (timed, blind)"
    echo -e "${C_CYAN}7. ${C_RESET}Connection Watchdog (auto-heal, checks port health)"
    echo -e "${C_CYAN}8. ${C_RESET}Auto Clear Cache"
    echo -e "${C_CYAN}9. ${C_RESET}Apply Speed/Stability Tuning (BBR + TCP/UDP tuning)"
    echo -e "${C_CYAN}10. ${C_RESET}Uninstall"
    echo -e "${C_CYAN}11. ${C_RESET}Exit"

    local choice; choice=$(read_choice $'\e[97mYour choice: \e[0m' 1 11)
    case "$choice" in
        1) action_create_tunnel 4 ;;
        2) action_create_tunnel 6 ;;
        3) action_status ;;
        4) action_update_script ;;
        5) action_change_version ;;
        6) action_auto_restart ;;
        7) action_watchdog ;;
        8) action_auto_clear_cache ;;
        9) action_install_bbr ;;
        10) action_uninstall ;;
        11) echo -e "${C_GREEN}Bye.${C_RESET}"; exit 0 ;;
    esac
}

# ---------- entry point ----------
require_root
ensure_self_installed
main_menu
