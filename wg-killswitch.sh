#!/bin/bash
#
# WireGuard kill-switch for macOS — fail-closed, via pf.
# Single-owner pf script: do NOT run alongside Internet Sharing or other
# software that manages pf at runtime; use an anchor-based version for that.
#
# Subcommands:
#   arm     Enable pf and block ALL outbound traffic except: loopback, DHCP,
#           the encrypted transport to your server, and tunnelled traffic.
#           Flushes existing pf states so connections established before
#           arming can't keep leaking. Then watches for the tunnel's utun
#           interface (whose number can change) and re-allows it.
#           Ctrl-C leaves the rules IN PLACE (fail-closed) — use 'disarm'.
#   disarm  Reload the stock /etc/pf.conf and, if pf appeared disabled before
#           arming, disable it again. Fails loudly if the reload fails. Does
#           NOT restore arbitrary runtime pf rules another tool may have loaded.
#   status  Show pf status and whether the tunnel is up.
#
# ---- Fill these in from your WireGuard config ([Interface] + [Peer]) ----
SERVER="vpn.example.com"   # Peer "Endpoint" host. An IP is best; a hostname is
                           #   resolved ONCE, BEFORE the kill-switch arms (so that
                           #   one lookup is NOT protected), and the result pinned
                           #   — a later DNS change needs a re-arm. IPv4 only.
SERVER_PORT="51820"        # Peer "Endpoint" port
TUNNEL_IP="10.7.0.2"       # your [Interface] "Address", WITHOUT the /NN suffix
# -------------------------------------------------------------------------

set -euo pipefail
[ "$(id -u)" -eq 0 ] || { echo "Run me with sudo." >&2; exit 1; }
umask 077                  # files we drop in /etc and /var/run stay 600

# Strict IPv4 check: dotted-quad shape AND every octet in 0–255.
valid_ipv4() {
  local ip="$1" o o1 o2 o3 o4
  [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
  IFS=. read -r o1 o2 o3 o4 <<< "$ip"
  for o in "$o1" "$o2" "$o3" "$o4"; do
    [ "$o" -ge 0 ] && [ "$o" -le 255 ] || return 1
  done
}

# Catch typos before they become opaque pf parse errors.
{ [[ "$SERVER_PORT" =~ ^[0-9]+$ ]] && [ "$SERVER_PORT" -ge 1 ] && [ "$SERVER_PORT" -le 65535 ]; } \
  || { echo "Invalid SERVER_PORT: $SERVER_PORT" >&2; exit 1; }
valid_ipv4 "$TUNNEL_IP" \
  || { echo "Invalid TUNNEL_IP: $TUNNEL_IP" >&2; exit 1; }

RULES="/etc/pf-wg-killswitch.conf"
STATE="/var/run/wg-killswitch.state"   # remembers pf's pre-arm on/off state
IPS=""                                 # set by arm(), read by load()

# --- helpers --------------------------------------------------------------

# Echo the utun interface currently holding the tunnel IP (empty if down).
# Exact field match — no substring/spacing surprises.
vpn_if() {
  local i
  for i in $(ifconfig -l | tr ' ' '\n' | grep '^utun'); do
    if ifconfig "$i" 2>/dev/null | awk '/inet /{print $2}' | grep -Fxq "$TUNNEL_IP"; then
      echo "$i"; return 0
    fi
  done
  return 0
}

# Resolve SERVER to one or more valid IPv4 addresses (passes an IP through).
# Queries both resolvers and de-duplicates. IPv4 only by design.
server_ips() {
  if valid_ipv4 "$SERVER"; then
    echo "$SERVER"
  else
    {
      dig +short A "$SERVER" 2>/dev/null
      dscacheutil -q host -a name "$SERVER" 2>/dev/null | awk '/^ip_address:/{print $2}'
    } | while IFS= read -r ip; do
          if valid_ipv4 "$ip"; then printf '%s\n' "$ip"; fi
        done | sort -u || true
  fi
}

# Build, VALIDATE, then atomically load the ruleset ("" dev = tunnel down).
load() {
  local dev="$1" ip
  {
    echo "set block-policy drop"
    echo "set skip on lo0"
    echo "block out all"
    for ip in $IPS; do
      echo "pass out quick proto udp to ${ip} port ${SERVER_PORT}"
    done
    # Intentionally interface-agnostic: hardcoding en0/en1 breaks USB-Ethernet,
    # tethering, and Thunderbolt bridges. Broad enough that any process can send
    # UDP 68->67 off-tunnel; accepted as a roaming trade-off.
    echo "pass out quick proto udp from any port 68 to any port 67"
    [ -n "$dev" ] && echo "pass out quick on ${dev} all"
  } > "$RULES"
  pfctl -nf "$RULES"        # dry-run: bail before applying if syntax is bad
  pfctl -f  "$RULES"
}

# --- subcommands ----------------------------------------------------------

arm() {
  IPS="$(server_ips)"
  [ -n "$IPS" ] || { echo "Could not resolve ${SERVER}. Fix DNS or use an IP." >&2; exit 1; }

  # Remember whether pf was already enabled, so disarm can restore it.
  if pfctl -s info 2>/dev/null | grep -q '^Status: Enabled'; then
    echo enabled  > "$STATE"
  else
    echo disabled > "$STATE"
  fi

  pfctl -E 2>/dev/null || true
  load "$(vpn_if)"      # default-deny is in effect from here
  pfctl -F states       # drop pre-armed flows so they can't bypass via state
  echo "Armed. Allowed out: tunnel + ${SERVER}:${SERVER_PORT} (${IPS//$'\n'/, }) + DHCP."
  echo "Ctrl-C leaves the kill-switch ON. Run '$0 disarm' to lift it."

  local cur="__init__" dev
  while true; do
    dev="$(vpn_if)"
    if [ "$dev" != "$cur" ]; then
      # No state flush here on purpose: the ruleset is already default-deny, so
      # a utun change can't have created off-tunnel leak states. Flushing would
      # only disrupt in-tunnel traffic on every reconnect for no safety gain.
      load "$dev"
      if [ -n "$dev" ]; then
        echo "Tunnel up on ${dev} — traffic allowed through it."
      else
        echo "Tunnel down — only reconnect + DHCP allowed."
      fi
      cur="$dev"
    fi
    sleep 2
  done
}

disarm() {
  if ! pfctl -f /etc/pf.conf; then
    echo "Failed to reload /etc/pf.conf — kill-switch rules may still be active." >&2
    echo "Not disabling pf. Fix /etc/pf.conf or reload a known-good ruleset manually." >&2
    exit 1
  fi
  pfctl -F states 2>/dev/null || true             # match state table to restored ruleset
  if [ -f "$STATE" ] && [ "$(cat "$STATE")" = disabled ]; then
    pfctl -d 2>/dev/null || true                  # pf was off before arming
  fi
  rm -f "$RULES" "$STATE"
  echo "Disarmed. Default pf config reloaded."
}

status() {
  pfctl -s info 2>/dev/null | grep '^Status:' || true
  local dev; dev="$(vpn_if)"
  if [ -n "$dev" ]; then echo "Tunnel: up (${dev}, ${TUNNEL_IP})"; else echo "Tunnel: down"; fi
  # Inspect the ACTIVE ruleset, not just the file. block-policy drop makes
  # pfctl render "block out all" as "block drop out all"; anchor the match.
  if [ -f "$RULES" ] && pfctl -s rules 2>/dev/null | grep -qE '^block( drop)? out all'; then
    echo "Kill-switch rules: appear active"
  else
    echo "Kill-switch rules: not detected in active pf rules"
  fi
}

case "${1:-}" in
  arm)    arm ;;
  disarm) disarm ;;
  status) status ;;
  *) echo "Usage: sudo $0 {arm|disarm|status}" >&2; exit 1 ;;
esac
