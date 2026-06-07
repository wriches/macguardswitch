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

## Setup

Edit the three variables at the top of `wg-killswitch.sh` to match your WireGuard config:

| Variable | From your config | Notes |
| --- | --- | --- |
| `SERVER` | Peer `Endpoint` host | An IP is best. A hostname is resolved **once, before arming** (that lookup is not protected) and the result pinned; a later DNS change needs a re-arm. |
| `SERVER_PORT` | Peer `Endpoint` port | |
| `TUNNEL_IP` | `[Interface]` `Address` | Without the `/NN` suffix. |

## Usage

```sh
sudo ./wg-killswitch.sh arm      # block everything outside the tunnel, then watch
sudo ./wg-killswitch.sh disarm   # restore the default pf config
sudo ./wg-killswitch.sh status   # show pf + tunnel state
```

`arm` runs in the foreground and re-detects the tunnel interface if it changes. **Ctrl-C leaves the kill-switch active** (by design) — use `disarm` to lift it.

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
