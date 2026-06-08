#!/bin/bash
#
# macguardswitch — a fail-closed WireGuard kill-switch for macOS, via pf.
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
# Each may be overridden by an MGS_* environment variable, which is how the
# macguardswitch-vpn.sh wrapper injects values parsed straight from your .conf. Edit
# the defaults here only if you run macguardswitch.sh on its own.
SERVER="${MGS_SERVER:-vpn.example.com}"        # Peer "Endpoint" host. An IP is best; a
                           #   hostname is re-resolved while the tunnel is DOWN (DNS is
                           #   allowed out to the system resolvers then), so a dynamic-DNS
                           #   endpoint is tracked without a re-arm. IPv4 only.
SERVER_PORT="${MGS_SERVER_PORT:-51820}"        # Peer "Endpoint" port
TUNNEL_IP="${MGS_TUNNEL_IP:-10.7.0.2}"         # [Interface] "Address", WITHOUT the /NN suffix
# -------------------------------------------------------------------------

set -euo pipefail
# sudo/launchd give a minimal PATH without Homebrew/MacPorts, so `wg` (used for the
# split-horizon-proof endpoint) may be missing. Append the usual spots — append,
# not prepend, so system binaries keep priority over any Homebrew versions.
export PATH="$PATH:/opt/homebrew/bin:/usr/local/bin:/opt/local/bin"
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

RULES="/etc/pf-macguardswitch.conf"
STATE="/var/run/macguardswitch.state"   # remembers pf's pre-arm on/off state
IPS=""                                 # endpoint IP(s); set by arm()/loop, read by load()
RESOLVERS=""                           # system DNS resolvers; set while tunnel down

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

# Echo the peer endpoint IP(s) WireGuard is ACTUALLY using on $dev (empty if
# none / no wg / no handshake). This is authoritative and immune to split-horizon
# DNS, which hands back the server's *internal* address once the tunnel — and the
# VPN's own resolver — are up. IPv4 only; IPv6/(none) endpoints are filtered out.
wg_endpoint_ips() {
  local dev="$1"
  [ -n "$dev" ] || return 0
  command -v wg >/dev/null 2>&1 || return 0
  wg show "$dev" endpoints 2>/dev/null \
    | awk '{print $NF}' | sed -E 's/:[0-9]+$//' \
    | while IFS= read -r ip; do
        if valid_ipv4 "$ip"; then printf '%s\n' "$ip"; fi
      done | sort -u || true
}

# The endpoint IP(s) to pin for the off-tunnel transport rule. When a tunnel is
# up, trust WireGuard (split-horizon-proof) and NEVER fall back to DNS — a lookup
# then could return the internal address. When down, resolve SERVER via local DNS
# (which gives the public answer). Order matters; see CLAUDE.md.
endpoint_ips() {
  local dev="$1"
  if [ -n "$dev" ]; then wg_endpoint_ips "$dev"; else server_ips; fi
}

# Echo the system's currently-configured IPv4 DNS resolvers, de-duplicated.
# Scopes the tunnel-down DNS allow (see load()): we permit egress to *these*
# resolvers, never to an arbitrary nameserver. Re-read each loop so roaming to a
# network with different resolvers keeps name resolution working.
dns_resolvers() {
  scutil --dns 2>/dev/null \
    | awk '/nameserver\[[0-9]+\]/{print $3}' \
    | while IFS= read -r ip; do
        if valid_ipv4 "$ip"; then printf '%s\n' "$ip"; fi
      done | sort -u || true
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
    if [ -n "$dev" ]; then
      echo "pass out quick on ${dev} all"
    else
      # Tunnel DOWN only: let WireGuard (and our own re-resolve) look up a
      # dynamic endpoint hostname. Scoped to the system's configured resolvers
      # — pf can't match on the queried domain, so resolver-IP scoping is the
      # tightest possible. Dropped the instant the tunnel is up, where DNS rides
      # the tunnel via the rule above; $RESOLVERS is refreshed each loop.
      for ip in $RESOLVERS; do
        echo "pass out quick proto { udp tcp } to ${ip} port 53"
      done
    fi
  } > "$RULES"
  pfctl -nf "$RULES"        # dry-run: bail before applying if syntax is bad
  pfctl -f  "$RULES"
}

# --- subcommands ----------------------------------------------------------

arm() {
  local dev0; dev0="$(vpn_if)"
  IPS="$(endpoint_ips "$dev0")"
  if [ -z "$IPS" ] && [ -n "$dev0" ]; then
    # Tunnel up but its endpoint is unreadable (no 'wg' in PATH, or no handshake
    # yet). Resolving now risks pinning a split-horizon/internal address, so
    # refuse rather than lock down to the wrong endpoint.
    echo "Tunnel is up but its endpoint is unreadable via 'wg show'." >&2
    echo "Install wireguard-tools, or disarm and arm while the tunnel is DOWN." >&2
    exit 1
  fi
  [ -n "$IPS" ] || { echo "Could not resolve ${SERVER}. Fix DNS or use an IP." >&2; exit 1; }

  # Remember whether pf was already enabled, so disarm can restore it.
  if pfctl -s info 2>/dev/null | grep -q '^Status: Enabled'; then
    echo enabled  > "$STATE"
  else
    echo disabled > "$STATE"
  fi

  pfctl -E 2>/dev/null || true
  RESOLVERS="$(dns_resolvers)"   # for the tunnel-down DNS allow (see load())
  load "$dev0"          # default-deny is in effect from here
  pfctl -F states       # drop pre-armed flows so they can't bypass via state
  echo "Armed. Allowed out: tunnel + ${SERVER}:${SERVER_PORT} (${IPS//$'\n'/, }) + DHCP + DNS-to-resolvers while reconnecting."
  echo "Leave this running: it watches for the tunnel and opens it the moment WireGuard connects."
  echo "Bring WireGuard up in ANOTHER terminal (or background this with '&')."
  echo "Ctrl-C stops the watcher but LEAVES the kill-switch rules ON — run '$0 disarm' to lift them."

  local sig="__init__" newsig dev ips
  while true; do
    dev="$(vpn_if)"
    # Keep the pinned endpoint correct: read it from WireGuard while up (split-
    # horizon-proof), re-resolve SERVER via DNS while down (so a DDNS change is
    # tracked). Keep the last good IPS if a lookup/query transiently returns
    # nothing — never strand the endpoint rule on an empty result.
    ips="$(endpoint_ips "$dev")"
    if [ -n "$ips" ]; then IPS="$ips"; fi
    # Refresh the resolver list only while down (that's the only time the DNS
    # allow is emitted), so roaming to a new network keeps name resolution working.
    if [ -z "$dev" ]; then RESOLVERS="$(dns_resolvers)"; fi
    newsig="${dev}|${IPS}|${RESOLVERS}"
    if [ "$newsig" != "$sig" ]; then
      # No state flush here on purpose: the ruleset is already default-deny, so
      # a utun/endpoint-IP change can't have created off-tunnel leak states.
      # Flushing would only disrupt in-tunnel traffic for no safety gain.
      load "$dev"
      if [ -n "$dev" ]; then
        echo "Tunnel up on ${dev} — traffic allowed through it."
      else
        echo "Tunnel down — only reconnect + DNS + DHCP allowed."
      fi
      sig="$newsig"
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
