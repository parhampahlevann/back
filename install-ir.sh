#!/usr/bin/env bash

set -e

ZIP_URL="https://raw.githubusercontent.com/parhampahlevann/back/main/backhaul-core.zip"

WORKDIR="$(pwd)"

echo "Installing Backhaul IR in $WORKDIR"

rm -rf "$WORKDIR/backhaul-core"
rm -f "$WORKDIR/backhaul-core.zip"

curl -fsSL "$ZIP_URL" -o "$WORKDIR/backhaul-core.zip"

command -v unzip >/dev/null 2>&1 || {
    apt-get update
    apt-get install -y unzip
}

unzip -o "$WORKDIR/backhaul-core.zip" -d "$WORKDIR"

cd "$WORKDIR/backhaul-core"

chmod +x backhaul.sh backhaul_premium


cat > config.toml <<'EOF'
[transport]
type = "tun"
heartbeat_interval = 10
heartbeat_timeout = 25

[tun]
encapsulation = "ipx"
name = "backhaul"
local_addr = "10.10.1.1/24"
remote_addr = "10.10.1.2/24"
health_port = 1234
mtu = 1320

[ipx]
mode = "server"
profile = "icmp"
listen_ip = "iran ip"
dst_ip = "kharej ip"
spoof_dst_ip = "ip white1"
spoof_src_ip = "ip white2"
custom_packet = true
interface = "ens161"

[security]
enable_encryption = false

[tuning]
auto_tuning = true
tuning_profile = "balanced"
workers = 0
channel_size = 10000
so_sndbuf = 0
batch_size = 2048

[logging]
log_level = "debug"

[ports]
forwarder = "iptables"
mapping = [
    "9090=9090",
]
EOF


echo "Starting Backhaul IR..."
./backhaul.sh
