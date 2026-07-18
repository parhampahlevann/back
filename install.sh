#!/usr/bin/env bash

set -e

ZIP_URL="https://raw.githubusercontent.com/parhampahlevann/back/main/backhaul-core.zip"

cd /root

echo "Downloading backhaul-core..."

rm -rf backhaul-core
rm -f backhaul-core.zip

if command -v curl >/dev/null 2>&1; then
    curl -fsSL "$ZIP_URL" -o backhaul-core.zip
elif command -v wget >/dev/null 2>&1; then
    wget -qO backhaul-core.zip "$ZIP_URL"
else
    apt-get update
    apt-get install -y curl
    curl -fsSL "$ZIP_URL" -o backhaul-core.zip
fi

if ! command -v unzip >/dev/null 2>&1; then
    apt-get update
    apt-get install -y unzip
fi

echo "Extracting..."
unzip -o backhaul-core.zip

cd backhaul-core

chmod +x backhaul.sh
chmod +x backhaul_premium

exec ./backhaul.sh
