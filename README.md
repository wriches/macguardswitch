# macguardswitch

A fail-closed [WireGuard](https://www.wireguard.com/) kill-switch for macOS, built on the system `pf` firewall.

When armed, all outbound traffic is blocked except:

- loopback
- DHCP (so you can still get a lease when roaming)
- the encrypted transport to your WireGuard server
- anything routed through the tunnel

If the tunnel drops, traffic stops instead of leaking onto your normal connection — and the endpoint stays reachable so the tunnel can reconnect on its own.

## Requirements

- macOS (uses the built-in `pfctl`)
- An existing WireGuard tunnel (WireGuard.app or `wireguard-tools`)
- `sudo` / admin rights

## Easy mode — double-click to connect (recommended)

For a non-technical user, you don't touch the Terminal at all. The wrapper
`macguardswitch-vpn.sh` reads the endpoint and tunnel IP **straight from your `.conf`**
(so there's nothing to configure twice), brings up WireGuard, arms the kill-switch,
and supervises the session.

**Setup (once):** put your WireGuard `.conf` in this folder, next to the scripts.
That's it — no editing required. (If you keep more than one `.conf` here, set
`WG_CONF` at the top of `macguardswitch-vpn.sh` to pick one. `wireguard-tools` must be
installed — `brew install wireguard-tools`.)

**To connect:** double-click **`Connect VPN.app`**. macOS shows its standard
"enter your password to make changes" dialog; after a few seconds a **✅ Connected
and protected** popup appears. No Terminal window — there's nothing to leave open
or close. The VPN and kill-switch keep running in the background.

**To disconnect:** double-click **`Disconnect VPN.app`**.

> **`.command` fallback.** `Connect VPN.command` / `Disconnect VPN.command` do the
> same thing in a Terminal window (you type your password there, and close the
> window yourself afterwards). Use these if you prefer to see the live log.

Session lifecycle, handled for you:

- **Fast user switching** (switch to another account without logging out) — the
  VPN and kill-switch **keep running**.
- **Log out** — the tunnel is brought down and the firewall restored **cleanly**.
- **Reboot / shutdown** — torn down cleanly; after restart the machine is back to
  normal (run Connect again).

> If you got these files by download (email, web), macOS may quarantine them and
> refuse to open them. Clear it once: in this folder run
> `xattr -dr com.apple.quarantine .` — or right-click → **Open** the first time
> (for `.app`s, approve via **System Settings → Privacy & Security → Open Anyway**).
> Cloning the repo with `git` avoids quarantine entirely.

The apps are thin GUI shims over `macguardswitch-vpn.sh`; their AppleScript source
(`*.applescript`) is in the repo. To rebuild after editing:
`osacompile -o "Connect VPN.app" "Connect VPN.applescript"`.

## Setup (advanced — running the kill-switch by hand)

You can also run the kill-switch directly without the wrapper. Edit the three
variables at the top of `macguardswitch.sh` to match your WireGuard config:

| Variable | From your config | Notes |
| --- | --- | --- |
| `SERVER` | Peer `Endpoint` host | An IP works. A hostname is also fine — while the tunnel is down, DNS is allowed out to your system resolvers so the endpoint is re-resolved automatically, so a dynamic-DNS endpoint is tracked without a re-arm. |
| `SERVER_PORT` | Peer `Endpoint` port | |
| `TUNNEL_IP` | `[Interface]` `Address` | Without the `/NN` suffix. |

## Usage

```sh
sudo ./macguardswitch.sh arm      # block everything outside the tunnel, then watch
sudo ./macguardswitch.sh disarm   # restore the default pf config
sudo ./macguardswitch.sh status   # show pf + tunnel state
```

`arm` runs in the **foreground as a watcher**: after installing the rules it keeps running to detect the tunnel's `utun` interface (whose number is dynamic) and open it the moment WireGuard connects. **Leave it running** — bring WireGuard up in a *second* terminal:

```sh
# terminal 1
sudo ./macguardswitch.sh arm
# terminal 2
sudo wg-quick up ./your.conf      # watch terminal 1 flip to "Tunnel up on utunN"
```

Or background the watcher instead of using a second terminal:

```sh
sudo nohup ./macguardswitch.sh arm >/tmp/macguardswitch.log 2>&1 &
```

**Ctrl-C stops the watcher but leaves the kill-switch rules in place** (fail-closed by design). The machine stays locked down until you run `disarm`; the only thing you lose by stopping the watcher is automatic tunnel detection — so don't Ctrl-C before the tunnel is up.

You can arm before or after connecting; **before is recommended** (no leak window). The endpoint is pinned from your local DNS while the tunnel is down and from WireGuard's actual endpoint (`wg show`) while it's up, so [split-horizon DNS](https://en.wikipedia.org/wiki/Split-horizon_DNS) can't poison it either way.

## Verify it works

Arm it, confirm normal traffic works, then quit the WireGuard tunnel in the app and check that traffic actually stops:

```sh
curl https://example.com   # should hang or fail while the tunnel is down
```

## Known, intentional trade-offs

- **It owns `pf` while armed.** It replaces the active ruleset, so don't run it alongside Internet Sharing or other software that manages `pf` at runtime. (Coexistence would need an anchor-based variant.)
- **DHCP is allowed off-tunnel** so roaming to new networks works.
- **UDP to the pinned endpoint is allowed off-tunnel** — that is the encrypted transport, and it's how the tunnel reconnects.
- **IPv4 endpoint only.** Native IPv6 is blocked (no leak), but the tunnel can still carry IPv6 if your peer uses `AllowedIPs = 0.0.0.0/0, ::/0`.

## License

No license is set yet. This script was inspired by [badeax/MacOS-Wireguard-VPN-Killswitch](https://github.com/badeax/MacOS-Wireguard-VPN-Killswitch), which is GPL-3.0 — consider whether that affects your choice before publishing.
