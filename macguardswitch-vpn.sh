#!/bin/bash
#
# macguardswitch-vpn — one-command WireGuard + kill-switch, for non-technical users.
#
# Pairs with macguardswitch.sh (the pf kill-switch) in the SAME folder. Reads the
# server endpoint and tunnel IP straight from your WireGuard .conf, so there is a
# single place to configure and nothing to keep in sync by hand.
#
#   connect     Arm the kill-switch, bring the tunnel up, then leave a small
#               background supervisor running. The supervisor PERSISTS across
#               fast user switching but tears everything down cleanly when the
#               user who connected LOGS OUT (or the machine shuts down).
#   disconnect  Bring the tunnel down and disarm the kill-switch.
#   status      Show whether the VPN is connected.
#
# You normally don't run this directly — double-click "Connect VPN.app" /
# "Disconnect VPN.app" (or the ".command" fallbacks) in this folder; they call
# it for you and handle the password prompt.

set -euo pipefail

# `do shell script … with administrator privileges` and launchd hand us a minimal
# PATH omitting Homebrew/MacPorts. wg-quick is a bash script whose
# `#!/usr/bin/env bash` needs bash 4+, but macOS ships bash 3.2 in /bin — so we
# must PREPEND Homebrew, or env-bash finds the old system bash and wg-quick aborts
# ("Version mismatch: bash 3 detected"). Also makes wg/wireguard-go resolve. Safe:
# Homebrew doesn't shadow system-named tools by default and our usage is POSIX.
export PATH="/opt/homebrew/bin:/usr/local/bin:/opt/local/bin:$PATH"

SELF="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
SCRIPT_DIR="$(dirname "$SELF")"
KS="$SCRIPT_DIR/macguardswitch.sh"

# Path to your WireGuard .conf. Leave empty to auto-use the single *.conf that
# sits next to this script.
WG_CONF=""

PIDFILE="/var/run/macguardswitch-vpn.pid"           # the supervisor
ARM_PIDFILE="/var/run/macguardswitch-vpn-arm.pid"   # the kill-switch watcher it owns
LOG="/var/log/macguardswitch-vpn.log"

CONF_PATH=""        # set by the supervisor; read by teardown()

log() { printf '%s  %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"; }

# --- config ----------------------------------------------------------------

# Echo the path to the WireGuard .conf to use (WG_CONF, else the lone sibling).
find_conf() {
  if [ -n "$WG_CONF" ]; then
    [ -f "$WG_CONF" ] || { echo "WG_CONF is set but not a file: $WG_CONF" >&2; exit 1; }
    printf '%s\n' "$WG_CONF"; return 0
  fi
  local confs=() f
  for f in "$SCRIPT_DIR"/*.conf; do [ -e "$f" ] && confs+=("$f"); done
  case "${#confs[@]}" in
    1) printf '%s\n' "${confs[0]}" ;;
    0) echo "No .conf found next to this script. Put your WireGuard .conf here, or set WG_CONF." >&2; exit 1 ;;
    *) echo "Multiple .conf files next to this script — set WG_CONF to choose one." >&2; exit 1 ;;
  esac
}

# Parse Endpoint + Address out of the .conf and export them for macguardswitch.sh.
# This is the single source of truth, so the kill-switch can never drift from the
# tunnel's real endpoint/address (the mismatch class of bug we hit before).
parse_conf() {
  local conf="$1" endpoint addr part
  endpoint="$(awk -F= '/^[[:space:]]*Endpoint[[:space:]]*=/{sub(/^[^=]*=/,""); gsub(/[[:space:]]/,""); print; exit}' "$conf")"
  [ -n "$endpoint" ] || { echo "No 'Endpoint' line in $conf" >&2; exit 1; }
  MGS_SERVER_PORT="${endpoint##*:}"          # last colon → port (IPv6-safe split)
  MGS_SERVER="${endpoint%:*}"
  MGS_SERVER="${MGS_SERVER#[}"; MGS_SERVER="${MGS_SERVER%]}"   # strip any IPv6 [..]

  addr="$(awk -F= '/^[[:space:]]*Address[[:space:]]*=/{sub(/^[^=]*=/,""); print; exit}' "$conf")"
  MGS_TUNNEL_IP=""
  local IFS=','                              # Address may list several, comma-separated
  for part in $addr; do
    part="${part//[[:space:]]/}"; part="${part%%/*}"          # trim spaces and /NN
    if [[ "$part" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then MGS_TUNNEL_IP="$part"; break; fi
  done
  [ -n "$MGS_TUNNEL_IP" ] || { echo "No IPv4 'Address' in $conf" >&2; exit 1; }
  export MGS_SERVER MGS_SERVER_PORT MGS_TUNNEL_IP
}

# --- helpers ---------------------------------------------------------------

# Re-run ourselves under sudo so the user only gets one password prompt.
need_root() {
  if [ "$(id -u)" -ne 0 ]; then
    exec sudo -p "Password to manage the VPN: " bash "$SELF" "$@"
  fi
}

# Is some utun interface currently holding $1 (the tunnel IP)?
tunnel_up() {
  local ip="$1" i
  for i in $(ifconfig -l | tr ' ' '\n' | grep '^utun'); do
    if ifconfig "$i" 2>/dev/null | awk '/inet /{print $2}' | grep -Fxq "$ip"; then return 0; fi
  done
  return 1
}

# Does $1 (a username) still have a GUI login session? True during fast user
# switching (the session stays loaded), false once they fully log out.
user_logged_in() {
  local u="$1"
  [ -n "$u" ] || return 0
  pgrep -u "$u" -x loginwindow >/dev/null 2>&1
}

supervisor_alive() {
  [ -f "$PIDFILE" ] || return 1
  local pid; pid="$(cat "$PIDFILE" 2>/dev/null)"
  { [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; } || return 1
  # Guard against a reused PID behind a stale pidfile: confirm it's really OUR
  # supervisor, not just any live process that inherited that number.
  ps -p "$pid" -o command= 2>/dev/null | grep -q 'macguardswitch-vpn.sh __supervise'
}

# Kill EVERY running supervisor and arm watcher by command pattern — not just the
# pidfile's PID, which desyncs (gets removed while the process lives) and has
# repeatedly left orphans re-installing rules after disconnect. TERM, then KILL
# any survivor. Excludes our own PID; the patterns don't match `… disconnect`.
kill_macguard_procs() {
  local sig="$1" pat p
  for pat in 'macguardswitch-vpn.sh __supervise' 'macguardswitch.sh arm'; do
    for p in $(pgrep -f "$pat" 2>/dev/null); do
      [ "$p" = "$$" ] && continue
      kill "$sig" "$p" 2>/dev/null || true
    done
  done
}

# Are any supervisor/arm processes still running?
macguard_procs_running() {
  pgrep -f 'macguardswitch-vpn.sh __supervise|macguardswitch.sh arm' >/dev/null 2>&1
}

# Bring the tunnel down and disarm. Runs on disconnect (SIGTERM), logout, or
# shutdown. Order: stop the watcher first so it can't re-arm between down and
# disarm; stay locked down (fail-closed) until disarm restores normal pf.
teardown() {
  trap '' TERM INT          # don't re-enter while tearing down
  log "Teardown: stopping watcher, tunnel, and kill-switch."
  if [ -f "$ARM_PIDFILE" ]; then kill "$(cat "$ARM_PIDFILE" 2>/dev/null)" 2>/dev/null || true; fi
  if [ -n "$CONF_PATH" ]; then
    if wg-quick down "$CONF_PATH" >>"$LOG" 2>&1; then
      log "wg-quick down: ok."
    else
      log "wg-quick down FAILED (tunnel may still be up) — see output above."
    fi
  fi
  bash "$KS" disarm >>"$LOG" 2>&1 || true
  rm -f "$PIDFILE" "$ARM_PIDFILE"
  log "Teardown complete."
  exit 0
}

# --- subcommands -----------------------------------------------------------

cmd_connect() {
  [ -f "$KS" ] || { echo "Can't find macguardswitch.sh next to this script." >&2; exit 1; }
  command -v wg-quick >/dev/null 2>&1 || { echo "wg-quick not found — install WireGuard tools (e.g. 'brew install wireguard-tools')." >&2; exit 1; }

  # Whose logout should tear the VPN down: an explicit uid arg wins (the .app
  # passes it, since `do shell script … with administrator privileges` sets no
  # SUDO_UID), else fall back to sudo's caller (the .command path).
  local uid="${1:-}"; [ -n "$uid" ] || uid="${SUDO_UID:-}"

  local conf; conf="$(find_conf)"
  parse_conf "$conf"

  if supervisor_alive; then
    echo "Already connected. Use “Disconnect VPN” first if you want to reconnect."
    exit 0
  fi

  echo "Connecting to $MGS_SERVER (this can take a few seconds)…"
  log "Connect requested for uid ${uid:-?} using $conf"
  # Detach the supervisor WITHOUT nohup: under `do shell script … with admin
  # privileges` there's no controlling tty, and nohup aborts ("can't detach from
  # console: Inappropriate ioctl for device"). The supervisor ignores SIGHUP
  # itself (trap '' HUP), which is all nohup gave us; redirected I/O + disown +
  # reparenting to launchd complete the detachment.
  bash "$SELF" __supervise "$uid" "$conf" >>"$LOG" 2>&1 </dev/null &
  disown 2>/dev/null || true

  local i ok=""
  for i in $(seq 1 30); do
    sleep 1
    if tunnel_up "$MGS_TUNNEL_IP"; then ok=1; break; fi
    supervisor_alive || break
  done

  if [ -n "$ok" ]; then
    echo "✅ Connected and protected by the kill-switch."
    echo "   You can close this window. Use “Disconnect VPN” when you're done."
  elif ! supervisor_alive; then
    # To stderr so `do shell script` surfaces it in the .app's error dialog.
    {
      echo "❌ Couldn't connect. Recent log:"
      tail -n 25 "$LOG" 2>/dev/null | sed 's/^/    /' || true
      echo "   (full log: $LOG)"
    } >&2
    exit 1
  else
    echo "⚠️  Connecting is taking longer than expected — check $LOG."
    echo "   The kill-switch is on; run “Disconnect VPN” to reset if needed."
  fi
}

cmd_disconnect() {
  local conf tip=""
  conf="$(find_conf 2>/dev/null || true)"
  # Tunnel IP for the post-teardown verification. Subshell + '|| true' because
  # parse_conf calls exit on a bad/missing conf and we must not abort here.
  if [ -n "$conf" ]; then
    tip="$(parse_conf "$conf" >/dev/null 2>&1 && printf '%s' "$MGS_TUNNEL_IP")" || true
  fi

  echo "Disconnecting…"
  # Kill the supervisor AND its arm watcher BY COMMAND PATTERN, not by pidfile —
  # the pidfile desyncs (gets removed while the process lives) and kept leaving
  # orphans that re-installed rules after disconnect. TERM first (lets the
  # supervisor run its own teardown), wait, then KILL any survivor.
  kill_macguard_procs -TERM
  local i
  for i in $(seq 1 20); do macguard_procs_running || break; sleep 0.5; done
  kill_macguard_procs -KILL

  # Self-sufficient cleanup — never assume the supervisor's teardown completed.
  if [ -n "$conf" ]; then wg-quick down "$conf" >>"$LOG" 2>&1 || true; fi
  bash "$KS" disarm >>"$LOG" 2>&1 || true
  rm -f "$PIDFILE" "$ARM_PIDFILE"

  # Verify: tunnel really down AND nothing left to re-arm. To stderr so the .app
  # dialog surfaces failures.
  local still_up="" still_proc=""
  if [ -n "$tip" ] && tunnel_up "$tip"; then still_up=1; fi
  if macguard_procs_running; then still_proc=1; fi
  if [ -n "$still_up" ] || [ -n "$still_proc" ]; then
    {
      echo "❌ Disconnect FAILED."
      if [ -n "$still_up" ]; then echo "   Tunnel still up (${tip} on a utun)."; fi
      if [ -n "$still_proc" ]; then echo "   A watcher process is still running."; fi
      echo "   Force-clean:  sudo pkill -9 -f __supervise; sudo bash '$KS' disarm   (or reboot)"
      echo "   Recent log:"
      tail -n 15 "$LOG" 2>/dev/null | sed 's/^/    /' || true
    } >&2
    exit 1
  fi
  echo "✅ Disconnected. Normal internet restored. You can close this window."
}

cmd_status() {
  if supervisor_alive; then
    echo "VPN: connected & protected (supervisor pid $(cat "$PIDFILE"))."
  else
    echo "VPN: not connected."
  fi
  # Feed the kill-switch the REAL tunnel IP from the .conf; without it,
  # macguardswitch.sh falls back to its placeholder default and always reports
  # the tunnel "down". (Subshell + '|| true' because parse_conf exits on a bad
  # conf and must not abort status.)
  local conf tip=""
  conf="$(find_conf 2>/dev/null || true)"
  if [ -n "$conf" ]; then
    tip="$(parse_conf "$conf" >/dev/null 2>&1 && printf '%s' "$MGS_TUNNEL_IP")" || true
  fi
  if [ -n "$tip" ]; then export MGS_TUNNEL_IP="$tip"; fi
  bash "$KS" status 2>/dev/null || true
}

# The long-running background process started by cmd_connect. Runs as root.
cmd_supervise() {
  local uid="$1" wuser
  CONF_PATH="$2"
  wuser="$(id -un "$uid" 2>/dev/null || true)"
  echo $$ > "$PIDFILE"
  trap '' HUP               # survive the launching terminal/app going away (replaces nohup)
  trap teardown TERM INT    # disconnect / shutdown → clean teardown
  log "Supervisor pid $$ up. Watching user: ${wuser:-<none>}. Conf: $CONF_PATH"

  parse_conf "$CONF_PATH"          # exports MGS_* so the kill-switch matches the conf

  bash "$KS" arm >>"$LOG" 2>&1 &
  echo $! > "$ARM_PIDFILE"
  sleep 2                          # let the deny ruleset install before connecting

  if ! wg-quick up "$CONF_PATH" >>"$LOG" 2>&1; then
    log "wg-quick up failed."
    teardown
  fi
  log "Supervising. Persists across fast user switching; exits on logout/shutdown."

  while true; do
    # Self-heal: if our arm watcher is gone (killed/crashed, or someone disarmed
    # out-of-band), the protection is no longer ours to vouch for — tear down and
    # exit instead of lingering as a zombie that makes `connect` say "already
    # connected" while pf is off and the tunnel is down.
    if [ -f "$ARM_PIDFILE" ] && ! kill -0 "$(cat "$ARM_PIDFILE" 2>/dev/null)" 2>/dev/null; then
      log "arm watcher gone — tearing down."
      teardown
    fi
    if [ -n "$uid" ] && ! user_logged_in "$wuser"; then
      log "User ${wuser:-$uid} logged out."
      teardown
    fi
    sleep 2
  done
}

# --- dispatch --------------------------------------------------------------

case "${1:-}" in
  connect)     need_root "$@"; cmd_connect "${2:-}" ;;
  disconnect)  need_root "$@"; cmd_disconnect ;;
  status)      need_root "$@"; cmd_status ;;
  __supervise) shift; cmd_supervise "$@" ;;   # internal: already root, via cmd_connect
  *) echo "Usage: $0 {connect|disconnect|status}" >&2; exit 1 ;;
esac
