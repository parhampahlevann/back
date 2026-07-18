#!/usr/bin/env bash
set -euo pipefail

ZIP_URL="https://raw.githubusercontent.com/parhampahlevann/back/main/backhaul-core.zip"

cd /root

echo "[1/4] Downloading..."

rm -rf backhaul-core
rm -f backhaul-core.zip

if command -v curl >/dev/null 2>&1; then
    curl -fsSL "$ZIP_URL" -o backhaul-core.zip
elif command -v wget >/dev/null 2>&1; then
    wget -qO backhaul-core.zip "$ZIP_URL"
else
    echo "Please install curl or wget."
    exit 1
fi

if [ ! -f backhaul-core.zip ]; then
    echo "Download failed!"
    exit 1
fi

if ! command -v unzip >/dev/null 2>&1; then
    apt-get update
    apt-get install -y unzip
fi

echo "[2/4] Extracting..."
unzip -oq backhaul-core.zip

echo "[3/4] Setting permissions..."
chmod +x /root/backhaul-core/backhaul.sh
chmod +x /root/backhaul-core/backhaul_premium

echo "[4/4] Starting..."
cd /root/backhaul-core
exec ./backhaul.sh
