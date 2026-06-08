# CLAUDE.md

Guidance for Claude Code working in this repo.

## What this is

`macguardswitch.sh` is a single-file, fail-closed WireGuard kill-switch for macOS implemented with `pf`/`pfctl`. Three subcommands: `arm`, `disarm`, `status`.

`macguard-vpn.sh` is a higher-level wrapper for non-technical users (`connect`/`disconnect`/`status`). It parses the WireGuard `.conf` for the endpoint and tunnel address, injects them into the kill-switch via `MGS_*` env vars (see below), self-elevates with `sudo`, and runs a detached root **supervisor** that brings up the tunnel + kill-switch and tears them down on logout/shutdown. Keep the kill-switch itself policy-free — session/lifecycle logic belongs in the wrapper, not in `macguardswitch.sh`.

Two sets of double-click launchers call the wrapper: `Connect VPN.app` / `Disconnect VPN.app` (primary — native admin prompt, no Terminal) and `Connect VPN.command` / `Disconnect VPN.command` (fallback — Terminal). The apps are compiled from the checked-in `*.applescript` sources with `osacompile -o "Connect VPN.app" "Connect VPN.applescript"`; edit the `.applescript`, recompile, and commit both. Each app must sit next to `macguard-vpn.sh` (it resolves the wrapper via `container of (path to me)`).

## Components and contracts

- **`MGS_*` env overrides.** `macguardswitch.sh` reads `SERVER`/`SERVER_PORT`/`TUNNEL_IP` from `MGS_SERVER`/`MGS_SERVER_PORT`/`MGS_TUNNEL_IP` when set, falling back to the in-file defaults. This is the wrapper's injection point (single source of truth = the `.conf`). Don't remove the env fallback; don't make the kill-switch parse `.conf` files itself.
- **Pass the watched uid explicitly from the apps.** `connect [uid]` takes an optional uid; the `.app` path captures `id -u` in AppleScript *before* elevating and passes it, because `do shell script … with administrator privileges` runs as root and sets **no** `SUDO_UID`. The `.command`/sudo path passes nothing and falls back to `$SUDO_UID`. Don't rely on `SUDO_UID` alone — the apps would then watch `<none>` and never tear down on logout.
- **Supervisor lifecycle (wrapper).** `connect` launches a detached root supervisor (`nohup`, reparented to launchd) so closing the Terminal/window doesn't kill it. The supervisor owns the `arm` watcher (tracked via `ARM_PIDFILE`) and the tunnel, and polls whether the *initiating* user (uid → username) still has a GUI login session via `pgrep -u <user> -x loginwindow`. This is true during fast user switching (session stays loaded) and false on full logout — that distinction is the whole point, so don't replace it with a console-user or `who` check. On logout/SIGTERM it tears down (stop watcher → `wg-quick down` → `disarm`), staying fail-closed until `disarm`. A `disarm`-on-`EXIT` trap is still forbidden — teardown runs only on intentional signals/logout, so an abnormally-killed supervisor leaves the kill-switch up.

## Running and testing

- Syntax check: `bash -n macguardswitch.sh`
- Must run as root (`sudo`). It edits the live `pf` firewall, so test on a machine you can recover (Screen Sharing or a second local session) — not over the SSH connection it might cut.
- Manual verification: `sudo ./macguardswitch.sh arm`, confirm traffic works, quit the WireGuard tunnel, confirm `curl https://example.com` hangs, then `sudo ./macguardswitch.sh disarm`.

## Design invariants — do not regress these

These were deliberate decisions, several non-obvious. Don't "simplify" them away.

- **Fail-closed.** Default-deny outbound; only loopback, DHCP, the server endpoint, and the tunnel are allowed. Ctrl-C on `arm` must **not** disarm — only the `disarm` subcommand opens traffic back up. Never add an EXIT trap that lifts the rules.
- **Load rules before flushing state.** `arm` installs the deny ruleset *then* runs `pfctl -F states`. pf consults the state table before rules, so flushing first (or not at all) would let pre-existing connections keep leaking. Keep this order.
- **Allow the endpoint on every interface.** WireGuard's encrypted packets leave on the *physical* interface, not `utun`. The `pass ... to $SERVER port $SERVER_PORT` rule is what lets the tunnel connect and recover; without it the tunnel can't come back after a drop.
- **Interface-agnostic endpoint + DHCP rules are intentional.** Do not hardcode `en0`/`en1` — that breaks USB-Ethernet, tethering, and Thunderbolt bridges. Roaming robustness wins.
- **Detect the `utun` dynamically.** The tunnel interface is found by matching `TUNNEL_IP`, because WireGuard.app assigns `utun` numbers dynamically and they change across reconnects. Never hardcode `utun3`.
- **No state flush in the watch loop.** Once armed the ruleset is default-deny, so a `utun` change can't have created leak states. Flushing on every reconnect would tear in-tunnel traffic for no gain.
- **DNS is allowed only while the tunnel is down, only to system resolvers.** A dynamic-DNS endpoint means WireGuard must re-resolve the hostname to (re)connect, so `load()` emits `pass ... to <resolver> port 53` rules — but *only* when `dev` is empty (tunnel down) and *only* to the resolvers from `scutil --dns`. pf can't match on the queried domain, so resolver-IP scoping is the tightest possible; per-domain DNS filtering is impossible here. The rule vanishes the instant the tunnel is up (DNS then rides `pass on $dev all`). Don't widen this to all hosts and don't leave it open when up. The watch loop re-resolves `SERVER` and refreshes the resolver list while down, so DDNS IP changes and roaming are tracked without a re-arm.
- **Pin the endpoint from WireGuard when up, from DNS when down.** The off-tunnel transport rule must allow the *real public* endpoint. Resolving the hostname while the tunnel is up can return a split-horizon/internal address (the VPN's own resolver answering for itself) — pinning that breaks reconnection and drops the link. So `endpoint_ips()` reads `wg show <dev> endpoints` (authoritative) whenever a tunnel is up and falls back to `server_ips()` DNS *only* when down, where local DNS gives the public answer. While up it must **never** fall back to DNS. `arm` refuses rather than pin a guessed IP if the tunnel is up but `wg` can't be read. Don't reorder this to "DNS first."
- **`arm` is a long-running foreground watcher, not a one-shot.** After installing rules it loops to detect the dynamically-numbered `utun` and open it on connect. Ctrl-C leaves the rules in place (fail-closed) but stops detection — so the tunnel must be brought up in another terminal (or `arm` backgrounded) *while the watcher runs*. Keep the on-screen guidance saying so; don't turn `arm` into a fire-and-exit command.
- **Validate before applying.** `load()` runs `pfctl -nf` (dry-run) before `pfctl -f`. Keep it.
- **`disarm` must fail loudly.** If reloading `/etc/pf.conf` fails, error and exit non-zero rather than printing success over a still-locked-down machine.
- **Single-owner pf.** While armed it replaces the main ruleset; it is not anchor-based and is not meant to coexist with other pf-managing software. Add coexistence only as a *separate* anchor-based variant — don't compromise this one.
- **IPv4 endpoint only.** Endpoint resolution and pinning are IPv4. The tunnel itself can carry IPv6 (the `pass on $dev all` rule covers both families) when the peer uses `AllowedIPs = 0.0.0.0/0, ::/0`.

## Conventions

- Bash with `set -euo pipefail`; prefer set-e-safe idioms (`if cmd; then ...` over `cmd && ...` where a failure shouldn't abort).
- `macguardswitch.sh` stays a single self-contained script depending only on macOS built-ins (`pfctl`, `ifconfig`, `dig`/`dscacheutil`, `scutil`, `awk`) plus `wg` (read-only, for the split-horizon-proof endpoint). The `macguard-vpn.sh` wrapper additionally needs `wg-quick`; keep that dependency in the wrapper layer, not the kill-switch.
- Syntax-check every script after editing: `for f in macguardswitch.sh macguard-vpn.sh *.command; do bash -n "$f"; done`.
