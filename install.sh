#!/usr/bin/env bash

set -e

echo "=============================="
echo " Backhaul Installer"
echo "=============================="
echo
echo "1) Install OUT Server (Client)"
echo "2) Install IR Server (Server)"
echo

read -p "Choose option [1-2]: " choice

case $choice in

1)
    echo "Starting OUT installation..."
    bash <(curl -fsSL https://raw.githubusercontent.com/parhampahlevann/back/main/install-out.sh)
    ;;

2)
    echo "Starting IR installation..."
    bash <(curl -fsSL https://raw.githubusercontent.com/parhampahlevann/back/main/install-ir.sh)
    ;;

*)
    echo "Invalid option!"
    exit 1
    ;;

esac
