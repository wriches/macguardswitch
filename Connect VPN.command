#!/bin/bash
# Double-click to connect WireGuard and arm the kill-switch.
# You'll be asked for your Mac password (that's sudo, needed to manage the firewall).
cd "$(dirname "$0")" || exit 1
./macguard-vpn.sh connect
echo
read -r -p "Press Return to close this window… " _ || true
