# CLAUDE.md

Guidance for Claude Code working in this repo.

## What this is

`macguardswitch.sh` is a single-file, fail-closed WireGuard kill-switch for macOS implemented with `pf`/`pfctl`. Three subcommands: `arm`, `disarm`, `status`.

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
- Keep it a single self-contained script with no dependencies beyond macOS built-ins (`pfctl`, `ifconfig`, `dig`/`dscacheutil`, `awk`).
