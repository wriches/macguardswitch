#!/bin/bash
# Fallback launcher (Terminal). The polished version is "Disconnect VPN.app".
# Double-click to disconnect WireGuard and disarm the kill-switch.
# You'll be asked for your Mac password (that's sudo, needed to manage the firewall).
cd "$(dirname "$0")" || exit 1
bash ./macguardswitch-vpn.sh disconnect
echo
read -r -p "Done — you can close this window (⌘W), then press Return here. " _ || true
