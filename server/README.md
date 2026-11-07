# Moorlan Linux server

Pair phones with an existing WireGuard device over trusted home LAN. You keep
owning WireGuard; Moorlan only enrolls peers and applies them live. Client:
[iOS README](../ios/README.md). Contract: [REQUIREMENTS.md](REQUIREMENTS.md).
Design: [ARCHITECTURE.md](ARCHITECTURE.md).

## Setup

You need an up WireGuard interface (e.g. `wg0`) with exactly one private IPv4
(`/16`–`/30`). Starting with zero peers is the usual path for a new device.

### Download

```bash
curl -fsSL https://github.com/sumitgahoi/moorlan/releases/latest/download/install.sh | sudo bash
```

### Configure (one time)

```bash
sudoedit /etc/moorlan/moorlan.yaml
```

Install ships a dummy `private-endpoint` and `interfaces: {}` so nothing is
claimed yet and reconcile succeeds as a no-op. Replace with your values when
ready (see Site conf / Notes). On a configured interface, reconciliation removes
live peers absent from Moorlan's database. Then pair phones under Day to day.

```yaml
private-endpoint: 10.10.10.1:8756
interfaces:
  wg0:
    name: Home
    public-endpoint: vpn.example.com:51820
    home-networks:
      - 10.10.0.0/24
      - 10.10.10.0/24
      - 10.10.20.0/24
      - 10.10.30.0/24
      - 10.10.40.0/24
    dns-servers:
      - 10.10.83.1
    dns-search:
      - home.arpa
```

**Upgrade:** re-run the download step (keeps your YAML and DB).

**Remove:** unpair in the app if you want phones cleared, then:

```bash
curl -fsSL https://github.com/sumitgahoi/moorlan/releases/latest/download/uninstall.sh | sudo bash
```

Removes the binary, unit, and example files; preserves configuration and the peer
DB. To also delete all Moorlan configuration, database files (including SQLite
sidecars), runtime locks, and systemd overrides, close any running pairing/unpairing
sessions and use `--purge`:

```bash
curl -fsSL https://github.com/sumitgahoi/moorlan/releases/latest/download/uninstall.sh | sudo bash -s -- --purge
```

Both modes leave WireGuard devices and their host configuration alone. Historical
entries in the shared system journal are retained.

## Trusted home LAN only

Plaintext HTTP on your private LAN: **no** TLS, invite token, or LAN auth. While
`--pair` runs, anyone who can reach `private-endpoint` can enroll. Do not publish
the pairing port or run pair/unpair on guest Wi‑Fi. Those modes idle-stop after
2 minutes with no success (or Ctrl-C).

## Day to day

```bash
sudo moorlan --pair                            # sole iface in YAML; else add --interface
sudo moorlan --unpair                          # same --interface rules
sudo moorlan --list-peers
sudo moorlan --remove --interface wg0 --peer-public-key '<device-public-key>'
sudo moorlan --reconcile
```

`--pair` / `--unpair` print only a QR on stdout (`moorlan://…` invite for the
system Camera app) and stay up for more devices until idle or Ctrl-C. Successful
enroll/unpair lines appear on stderr. Confirm peers with `--list-peers`.

| Command | Role |
| --- | --- |
| `--pair` / `--unpair` | Enrollment / unpair QR; idle-stop 2m |
| `--list-peers` | Label, public key, address |
| `--remove` | Admin revoke by peer public key |
| `--reconcile` | SQLite → live for all managed ifaces (also boot oneshot) |

## Site conf

`/etc/moorlan/moorlan.yaml` is the only site settings source (no CLI overrides).
Root `private-endpoint` is shared; each interface has its own `name`,
`public-endpoint`, `home-networks`, and DNS. `name` is what phones show
as the tunnel name after pairing. Changes apply to **new** pair leases — re-pair
phones to refresh existing ones.

If you remove an interface from YAML, new enroll fails for it; existing peers
keep working and can still be unpaired.

## Notes

- Forward each WireGuard UDP port used in `public-endpoint`.
- Per-iface `home-networks` must not overlap that iface’s tunnel subnet.
- Hairpin protection is phone SSID-based.
- DNS: point `dns-servers` at a resolver reachable over the tunnel (often the
  server’s WireGuard address), set `dns-search: [home.arpa]`, and list only LAN
  prefixes in `home-networks` (not the tunnel pool).
- Paths: binary `/usr/local/bin/moorlan`, DB `/var/lib/moorlan/moorlan.db`,
  unit `moorlan-reconcile.service`.
- Broken/missing DB: clear peers if possible → fix or replace DB and YAML →
  re-pair. Non-goals: [REQUIREMENTS.md](REQUIREMENTS.md) §9.

## Development

```bash
go test -race ./...
go vet ./...
go build -o moorlan ./cmd/moorlan
```

From source, install the binary, `moorlan.yaml.example`, and
`systemd/moorlan-reconcile.service` the same way `install.sh` does. Pushing a
`v*` tag runs `.github/workflows/server-release.yml`.
