# Moorlan Linux server

Pair phones with an existing WireGuard device over trusted home LAN. You keep
owning WireGuard; Moorlan only enrolls peers and applies them live. Client:
[iOS README](../ios/README.md). Contract: [REQUIREMENTS.md](REQUIREMENTS.md).
Design: [ARCHITECTURE.md](ARCHITECTURE.md).

## Setup

You need an up WireGuard interface (e.g. `wg0`) with exactly one private IPv4
(`/16`–`/30`).

### Install (and upgrade)

```bash
curl -fsSL https://github.com/sumitgahoi/moorlan/releases/latest/download/install.sh | sudo bash
```

This replaces `/usr/local/bin/moorlan` and runs `moorlan --setup` (systemd unit,
DB migrate, create/merge `/etc/moorlan/moorlan.yaml` with guessed values).
**Re-run the same command to upgrade.**

### Review YAML

```bash
sudoedit /etc/moorlan/moorlan.yaml
```

Set `enabled: true` on interfaces Moorlan should manage. Override
`public-endpoint` (e.g. DDNS) or other fields as needed. Setup leaves new ifaces
as `enabled: false`. On an enabled interface, reconcile removes live peers that
are not in Moorlan’s database (host conf files are untouched).

Example after setup:

```yaml
private-endpoint: 10.10.10.1:8756
interfaces:
  wg0:
    enabled: true
    name: Home
    public-endpoint: vpn.example.com:51820
    home-networks:
      - 10.10.0.0/24
      - 10.10.10.0/24
    dns-servers:
      - 10.10.83.1
    dns-search:
      - home.arpa
```

### From source

```bash
go build -o /usr/local/bin/moorlan ./cmd/moorlan
sudo moorlan --setup
```

**Remove:** unpair in the app if you want phones cleared, then:

```bash
curl -fsSL https://github.com/sumitgahoi/moorlan/releases/latest/download/uninstall.sh | sudo bash
```

Preserves configuration and the peer DB. With `--purge`, also deletes conf, DB,
locks, and unit overrides (see script). WireGuard devices are left alone.

## Trusted home LAN only

Plaintext HTTP on your private LAN: **no** TLS, invite token, or LAN auth. While
`--pair` runs, anyone who can reach `private-endpoint` can enroll. Do not publish
the pairing port or run pair/unpair on guest Wi‑Fi. Those modes idle-stop after
2 minutes with no success (or Ctrl-C).

## Day to day

```bash
sudo moorlan --pair                            # sole enabled iface; else --interface
sudo moorlan --unpair
sudo moorlan --list-peers
sudo moorlan --remove --interface wg0 --peer-public-key '<device-public-key>'
sudo moorlan --reconcile
sudo moorlan --setup                           # re-guess/merge YAML (also from install.sh)
```

`--pair` / `--unpair` print only a QR on stdout (`moorlan://…` invite for the
system Camera app) and stay up for more devices until idle or Ctrl-C.

| Command | Role |
| --- | --- |
| `--setup` | Unit + DB + create/merge site YAML |
| `--pair` / `--unpair` | Enrollment / unpair QR; idle-stop 2m |
| `--list-peers` | Label, public key, address |
| `--remove` | Admin revoke by peer public key |
| `--reconcile` | SQLite → live (enabled YAML ∪ DB; also boot oneshot) |

## Site conf

`/etc/moorlan/moorlan.yaml` is the only site settings source. Root
`private-endpoint` is shared; each interface has `enabled`, `name`,
`public-endpoint`, `home-networks`, and DNS. Only `enabled: true` ifaces accept
new enroll. Changes apply to **new** pair leases — re-pair phones to refresh
existing ones.

If you disable or remove an interface from YAML, new enroll fails for it;
existing peers keep working and can still be unpaired.

## Notes

- Forward each WireGuard UDP port used in `public-endpoint`.
- `--setup` best-effort guesses `public-endpoint` via STUN (override with DDNS).
- Per-iface `home-networks` must not overlap that iface’s tunnel subnet.
- Hairpin protection is phone SSID-based.
- DNS: often the server’s WireGuard address in `dns-servers`, `dns-search:
  [home.arpa]`, LAN prefixes only in `home-networks`.
- Paths: binary `/usr/local/bin/moorlan`, DB `/var/lib/moorlan/moorlan.db`,
  unit `moorlan-reconcile.service`.
- Non-goals: [REQUIREMENTS.md](REQUIREMENTS.md) §9.

## Development

```bash
go test -race ./...
go vet ./...
go build -o moorlan ./cmd/moorlan
```

Pushing a `v*` tag runs `.github/workflows/server-release.yml`.
