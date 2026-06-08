#!/bin/bash
# Fallback launcher (Terminal). The polished version is "Connect VPN.app".
# Double-click to connect WireGuard and arm the kill-switch.
# You'll be asked for your Mac password (that's sudo, needed to manage the firewall).
cd "$(dirname "$0")" || exit 1
./macguardswitch-vpn.sh connect
echo
read -r -p "Done — you can close this window (⌘W), then press Return here. " _ || true
