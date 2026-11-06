# Moorlan Linux server

Pair phones with an existing WireGuard device over trusted-LAN HTTP. Peers live
in SQLite and are applied live with wgctrl — not written into wg-quick or
networkd. Client: [iOS README](../ios/README.md). Contract:
[REQUIREMENTS.md](REQUIREMENTS.md). Design: [ARCHITECTURE.md](ARCHITECTURE.md).

## Trusted home LAN only

Plaintext HTTP on your private LAN: **no** TLS, invite token, or LAN auth. While
`--pair` runs, anyone who can reach `private-endpoint` can enroll. Do not publish
the pairing port or run pair/unpair on guest Wi‑Fi. Those modes idle-stop after
2 minutes with no success (or Ctrl-C).

## Supported setup

| Setting | Requirement |
| --- | --- |
| Interface | Existing up WG device with exactly one private IPv4 (`/16`–`/30`) |
| Peers on device | Start with **zero peers** on each WG device you list in YAML |
| Tunnel address | Exactly one private IPv4 on the device |
| `home-networks` | Private IPv4 prefixes for split-tunnel LAN access (per iface) |
| `public-endpoint` | Sticky DDNS or static `host:port` per iface |
| `dns-servers` | Required; one or more unicast IPv4 resolvers (per iface) |
| Site conf | `/etc/moorlan/moorlan.yaml` |
| Peers DB | `/var/lib/moorlan/moorlan.db` (or `db` in YAML) |
| Binary | `/usr/local/bin/moorlan` (reconcile unit calls this path) |
| Privileges | Root |
| Phone address | Auto `/32` in the tunnel subnet |

Create and firewall the WG device yourself. List it under `interfaces` in YAML;
Moorlan enrolls peers in SQLite and reconciles them onto the live device.

## Install

```bash
ARCH=amd64  # or arm64
ASSET="moorlan-linux-${ARCH}"
BASE="https://github.com/sumitgahoi/moorlan/releases/latest/download"

curl -fsSL -o "${ASSET}" "${BASE}/${ASSET}"
curl -fsSL -o "${ASSET}.sha256" "${BASE}/${ASSET}.sha256"
sha256sum -c "${ASSET}.sha256"
sudo install -m 755 "${ASSET}" /usr/local/bin/moorlan
curl -fsSL -o moorlan.yaml.example "${BASE}/moorlan.yaml.example"
sudo mkdir -p /usr/share/moorlan
sudo install -m 644 moorlan.yaml.example /usr/share/moorlan/moorlan.yaml.example

sudo mkdir -p /etc/moorlan
sudo cp /usr/share/moorlan/moorlan.yaml.example /etc/moorlan/moorlan.yaml
# edit /etc/moorlan/moorlan.yaml
sudo install -m 644 systemd/moorlan-reconcile.service /etc/systemd/system/moorlan-reconcile.service
sudo systemctl daemon-reload
sudo systemctl enable --now moorlan-reconcile.service
sudo moorlan --pair
```

From source:

```bash
cd server
go build -o moorlan ./cmd/moorlan
sudo install -m 755 moorlan /usr/local/bin/moorlan
sudo mkdir -p /usr/share/moorlan
sudo install -m 644 moorlan.yaml.example /usr/share/moorlan/moorlan.yaml.example
sudo install -m 644 systemd/moorlan-reconcile.service /etc/systemd/system/moorlan-reconcile.service
```

**Upgrade:** replace the binary (and example YAML / unit if changed); site YAML
and DB stay. **Remove program:** unpair peers, stop/disable the unit, then delete
the binary, YAML, and DB as desired.

## Day to day

```bash
sudo moorlan --pair                          # sole iface in YAML; else add --interface
sudo moorlan --list-peers
sudo moorlan --unpair --interface wg0
sudo moorlan --remove --interface wg0 --peer-public-key '<device-public-key>'
sudo moorlan --reconcile
```

| Command | Role |
| --- | --- |
| `--pair` / `--unpair` | Enrollment / unpair QR; idle-stop 2m |
| `--list-peers` | Label, public key, address |
| `--remove` | Admin revoke by peer public key |
| `--reconcile` | SQLite → live for all managed ifaces (also boot oneshot) |

Success criteria: [REQUIREMENTS.md](REQUIREMENTS.md) §6.

## Site conf

Edit `/etc/moorlan/moorlan.yaml`. Full key comments:
`/usr/share/moorlan/moorlan.yaml.example`. YAML is the only source of site
settings (no CLI overrides). Root `private-endpoint` is shared; each interface
has its own `public-endpoint`, `home-networks`, and DNS. Changes to those fields
apply to **new** pair leases — re-pair phones to refresh existing ones.

If you remove an interface from YAML, new enroll fails for it; existing peers
keep working and can still be unpaired.

## Roles

| Owner | Responsibility |
| --- | --- |
| Host (networkd / wg-quick / …) | Device: key, address, listen port, routes, firewall |
| Operator | `/etc/moorlan/moorlan.yaml`; enable reconcile unit |
| SQLite | Enrolled peers and per-iface server public keys (SoT) |
| Live wgctrl | Projection of SQLite |
| systemd oneshot | Boot `moorlan --reconcile` (~5 min retry window; soft-fail per iface) |

## Protocol

Pair QR (v1):

```json
{"v":1,"pair_url":"http://10.10.10.1:8756/v1/pair","server_public_key":"<server-key>"}
```

Unpair: QR identifies the server; phone `DELETE`s with its key + token; **204**
clears the profile. Details: [REQUIREMENTS.md](REQUIREMENTS.md) §7.

## Notes

- Forward each WireGuard UDP port used in `public-endpoint`.
- Per-iface `home-networks` must not overlap that iface’s tunnel subnet.
- Hairpin protection is phone SSID-based.
- LAN DNS example: AdGuard in `dns-servers`, `dns-search: [home.arpa]`, include
  those subnets in `home-networks`.
- Broken/missing DB: clear peers if possible → fix or replace DB and YAML →
  re-pair. Non-goals: [REQUIREMENTS.md](REQUIREMENTS.md) §9.

## Development

```bash
go test -race ./...
go vet ./...
go build -o moorlan ./cmd/moorlan
sudo install -m 755 moorlan /usr/local/bin/moorlan
sudo install -m 644 moorlan.yaml.example /usr/share/moorlan/moorlan.yaml.example
```

Pushing a `v*` tag runs `.github/workflows/server-release.yml` (linux amd64/arm64
binaries and `.sha256` digests).
