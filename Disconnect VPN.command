#!/bin/bash
# Double-click to disconnect WireGuard and disarm the kill-switch.
# You'll be asked for your Mac password (that's sudo, needed to manage the firewall).
cd "$(dirname "$0")" || exit 1
./macguard-vpn.sh disconnect
echo
read -r -p "Press Return to close this window… " _ || true
