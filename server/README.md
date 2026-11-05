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
| Interface | Existing up WG device; **zero peers** at `--add-interface` |
| Tunnel address | Exactly one private IPv4, `/16`–`/30` |
| `home-networks` | Private IPv4 prefixes for split-tunnel LAN access |
| `public-endpoint` | Sticky DDNS or static `host:port` |
| `dns-servers` | Required; one or more unicast IPv4 resolvers |
| Site conf | `/etc/moorlan/<iface>.conf` (not a wg-quick file) |
| Peers DB | `/var/lib/moorlan/<iface>.db` (or `db=` in conf) |
| Binary | `/usr/local/bin/moorlan` (reconcile unit calls this path) |
| Privileges | Root |
| Phone address | Auto `/32` in the tunnel subnet |

Create and firewall the WG device yourself. After `--add-interface`, Moorlan owns
every peer on it.

## Install

```bash
ARCH=amd64  # or arm64
ASSET="moorlan-linux-${ARCH}"
BASE="https://github.com/sumitgahoi/moorlan/releases/latest/download"

curl -fsSL -o "${ASSET}" "${BASE}/${ASSET}"
curl -fsSL -o "${ASSET}.sha256" "${BASE}/${ASSET}.sha256"
sha256sum -c "${ASSET}.sha256"
sudo install -m 755 "${ASSET}" /usr/local/bin/moorlan
curl -fsSL -o moorlan.conf.example "${BASE}/moorlan.conf.example"
sudo mkdir -p /usr/share/moorlan
sudo install -m 644 moorlan.conf.example /usr/share/moorlan/moorlan.conf.example

sudo mkdir -p /etc/moorlan
sudo cp /usr/share/moorlan/moorlan.conf.example /etc/moorlan/wg0.conf
# edit /etc/moorlan/wg0.conf
sudo moorlan --add-interface wg0
sudo moorlan --pair --interface wg0
```

From source:

```bash
cd server
go build -o moorlan ./cmd/moorlan
sudo install -m 755 moorlan /usr/local/bin/moorlan
sudo mkdir -p /usr/share/moorlan
sudo install -m 644 moorlan.conf.example /usr/share/moorlan/moorlan.conf.example
```

**Upgrade:** replace the binary (and example conf if changed); site conf, DB, and
units stay. **Remove program:** `--remove-interface` per iface first, then delete
the binary.

## Day to day

```bash
sudo moorlan --pair --interface wg0
sudo moorlan --list-peers --interface wg0
sudo moorlan --unpair --interface wg0
sudo moorlan --remove --interface wg0 --peer-public-key '<device-public-key>'
sudo moorlan --reconcile --interface wg0
sudo moorlan --remove-interface wg0   # after all peers are gone
```

| Command | Role |
| --- | --- |
| `--add-interface` | Validate site conf; create DB + reconcile unit |
| `--remove-interface` | Delete DB, conf, unit (refuses if peers remain) |
| `--pair` / `--unpair` | Enrollment / unpair QR; idle-stop 2m |
| `--list-peers` | Label, public key, address |
| `--remove` | Admin revoke by peer public key |
| `--reconcile` | SQLite → live (also boot oneshot) |

Success criteria: [REQUIREMENTS.md](REQUIREMENTS.md) §6.

## Site conf

Edit `/etc/moorlan/<iface>.conf`. Full key comments:
`/usr/share/moorlan/moorlan.conf.example`. Conf is the only source of site
settings (no CLI overrides). Changes to `home-networks`, `dns-servers`,
`dns-search`, or endpoints apply to **new** pair leases — re-pair phones to
refresh existing ones.

## Ownership

| Owner | Responsibility |
| --- | --- |
| Host (networkd / wg-quick / …) | Device: key, address, listen port, routes, firewall |
| Operator | `/etc/moorlan/<iface>.conf` |
| SQLite | Enrolled peers (SoT) |
| Live wgctrl | Projection of SQLite |
| systemd oneshot | Boot `--reconcile --interface <iface>` (~5 min retry window) |

## Protocol

Pair QR (v1):

```json
{"v":1,"pair_url":"http://10.10.10.1:8756/v1/pair","server_public_key":"<server-key>"}
```

Unpair: QR identifies the server; phone `DELETE`s with its key + token; **204**
clears the profile. Details: [REQUIREMENTS.md](REQUIREMENTS.md) §7.

## Notes

- Forward the WireGuard UDP port.
- `home-networks` must not overlap the tunnel subnet.
- Hairpin protection is phone SSID-based.
- LAN DNS example: AdGuard in `dns-servers`, `dns-search=home.arpa`, include those
  subnets in `home-networks`.
- Broken/missing DB: clear peers if possible → `--remove-interface` → fix conf →
  `--add-interface` → re-pair. Non-goals: [REQUIREMENTS.md](REQUIREMENTS.md) §9.

## Development

```bash
go test -race ./...
go vet ./...
go build -o moorlan ./cmd/moorlan
sudo install -m 755 moorlan /usr/local/bin/moorlan
sudo install -m 644 moorlan.conf.example /usr/share/moorlan/moorlan.conf.example
```

Pushing a `v*` tag runs `.github/workflows/server-release.yml` (linux amd64/arm64
binaries and `.sha256` digests).
