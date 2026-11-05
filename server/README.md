# Moorlan Linux server

Pair phones with an existing WireGuard device over trusted-LAN HTTP.
Moorlan stores peer assignments in SQLite and applies them live with wgctrl.
It does **not** write networkd or wg-quick peer config. The [iPhone app](../ios/README.md)
handles the client.

## Trusted home LAN only

**This tool targets a trusted home LAN.** Control traffic is plaintext HTTP on
your private network. There is **no invitation token, no TLS, and no LAN
authentication**. While `--pair` is running, **anyone who can reach
`private-endpoint` can enroll**. Security is deliberately lax so setup stays
simple for a household. Do not publish the pairing port, and do not leave
`--pair` / `--unpair` running on guest or untrusted networks. Those modes stop
after 2 minutes with no successful enroll/unpair (or Ctrl-C sooner).

## Supported setup

| Setting | Requirement / example |
| --- | --- |
| Interface | Existing WireGuard device (e.g. `wg0`), already up, **no peers** when first added |
| Server address | Exactly one private IPv4 address, `/16`–`/30`, e.g. `10.10.83.1/24` |
| Home CIDRs | Private IPv4 prefixes routed to phones when away |
| Public endpoint | Sticky DDNS or static `host:port` (required) |
| Site settings | `/etc/moorlan/<iface>.conf` (one file per interface; **not** a wg-quick file) |
| Peer persistence | SQLite at `/var/lib/moorlan/<iface>.db` |
| Binary path | `/usr/local/bin/moorlan` (rehydrate units call this path) |
| Privileges | Root |
| Phone address | Automatically allocated `/32` in the tunnel subnet |

Create and firewall the WireGuard device yourself. Ship it with **no peers**;
Moorlan owns every peer on that interface after `--add-interface`.

## Install

Three steps: **put the binary on PATH** → **`--add-interface`** → **`--pair`**.

```bash
ARCH=amd64  # or arm64
ASSET="moorlan-linux-${ARCH}"
BASE="https://github.com/sumitgahoi/moorlan/releases/latest/download"

curl -fsSL -o "${ASSET}" "${BASE}/${ASSET}"
curl -fsSL -o "${ASSET}.sha256" "${BASE}/${ASSET}.sha256"
sha256sum -c "${ASSET}.sha256"
sudo install -m 755 "${ASSET}" /usr/local/bin/moorlan

# Copy, edit the three -flags for your network, then paste:
sudo moorlan --add-interface wg0 \
  -private-endpoint 10.10.10.1:8756 \
  -home-cidrs 10.10.0.0/24,10.10.10.0/24 \
  -public-endpoint vpn.example.com:51820

# Enroll phones (on home Wi‑Fi when scanning from the phone):
sudo moorlan --pair
```

`--add-interface` writes those flags into `/etc/moorlan/<iface>.conf` (plus DB and
rehydrate unit). Later `--pair` reads the conf; edit the file or pass flags to
override. To pin a release, use `…/releases/download/vX.Y.Z/…` instead of
`…/releases/latest/download/…`.

From source:

```bash
cd server
go build -o moorlan ./cmd/moorlan
sudo install -m 755 moorlan /usr/local/bin/moorlan
```

**Upgrade:** download the newer binary, verify the checksum, and
`sudo install -m 755 moorlan-linux-… /usr/local/bin/moorlan`. Site conf, peer DB,
and rehydrate units are unchanged.

**Remove the program:** `sudo rm /usr/local/bin/moorlan`. Remove Moorlan
registrations first (`sudo moorlan --remove-interface …` per iface) so rehydrate
units are not left pointing at a missing binary.

To wipe Moorlan’s registration for an iface (peers must already be gone):
`sudo moorlan --remove-interface wg0`. Then `--add-interface` and re-pair phones.

## Day to day

```bash
sudo moorlan --pair                    # sole conf auto-picked; else default -wg wg0
sudo moorlan --pair -wg wg1
sudo moorlan --list-peers              # label, public key, address
sudo moorlan --unpair -wg wg0
sudo moorlan --remove-peer '<device-public-key>'
```

Settings: edit `/etc/moorlan/<iface>.conf`. CLI flags override the file.
`public-endpoint` must stay a sticky DDNS or static host:port so every phone
gets the same reachable WireGuard endpoint.

### Site conf

Written by `--add-interface` from the flags (not a wg-quick/networkd peer file):

```
# Moorlan site settings for wg0 (not peers; peers live in SQLite).
wg=wg0
private-endpoint=10.10.10.1:8756
home-cidrs=10.10.0.0/24,10.10.10.0/24
public-endpoint=vpn.example.com:51820
```

### Commands

| Command | Role |
| --- | --- |
| `--add-interface <iface>` | Greenfield: requires `-private-endpoint`, `-home-cidrs`, `-public-endpoint`; writes conf + DB + unit |
| `--remove-interface <iface>` | Disable+delete unit, conf, and empty DB (refuses if peers remain) |
| `--pair` / `--unpair` | Enrollment / unpair QR; idle-stop after 2m with no success |
| `--list-peers` | Print enrolled peers: label, public key, address |
| `--remove-peer <pubkey>` | Admin revoke by device public key (reconcile first) |
| `--rehydrate` | Boot path: one attempt; fails until WG is usable; systemd retries |

`-wg` defaults to `wg0`, or the sole configured conf when exactly one exists.

## Persistence model

| Owner | Responsibility |
| --- | --- |
| Host (networkd / wg-quick / …) | Device exists: key, address, listen port, routes/firewall |
| Release binary / `install` | `/usr/local/bin/moorlan` |
| `/etc/moorlan/<iface>.conf` | Static site flags (via `--add-interface`) |
| Moorlan SQLite | Phone peers |
| Live `wgctrl` | Peers currently on the device |
| systemd rehydrate unit | Boot: `moorlan --rehydrate -wg <iface>` (retries ~5 min if WG not ready yet) |

`--add-interface` is greenfield only: no existing conf, DB, or rehydrate unit; live
device must have zero peers; then it writes all three and enables the unit.
Partial failure rolls back conf/DB/unit. Moorlan then exclusively owns peers on
that interface (rehydrate drops orphans). `--pair` / `--unpair` / `--remove-peer`
reconcile SQLite to the live device before serving or mutating.

## Protocol and trust

See [Trusted home LAN only](#trusted-home-lan-only) above. Version 1 pairing QR:

```json
{"v":1,"pair_url":"http://192.168.1.10:8756/v1/pair","server_public_key":"<server-key>"}
```

No invitation token. **Anyone who can reach the service can enroll while it runs.**
Plaintext HTTP on the trusted LAN is intentional — not a production hardening
gap to “fix” with TLS or invites for this threat model.

## Unpair

Phone: `sudo moorlan --unpair`, scan QR, confirm. Only HTTP 204 clears the phone profile.

Admin: `sudo moorlan --remove-peer <device-public-key>`.

## Networking notes

- Forward the WireGuard UDP port. Split-tunnel AllowedIPs cover the tunnel pool
  and home CIDRs.
- Home CIDRs and the tunnel subnet must not overlap.
- Hairpin protection on the phone is SSID-based.

## LIMITATIONS

- Trusted-LAN HTTP only; `--pair` / `--unpair` idle-stop after 2m with no success.
- One private IPv4 tunnel subnet `/16`–`/30` per interface.
- Database is created only by `--add-interface` (never adopted).
- Do not change the WireGuard server private key under an existing peer DB.
- If the peer DB is missing or unreadable: clear live peers, `--remove-interface`,
  `--add-interface`, and re-pair (or unpair/`--remove-peer` first while the DB works).
- No offline deletion queue; no STUN / UPnP / relay. Sticky `public-endpoint` is required.
- Rehydrate units expect the binary at `/usr/local/bin/moorlan`.

## Development

```bash
go test -race ./...
go vet ./...
go build -o moorlan ./cmd/moorlan
sudo install -m 755 moorlan /usr/local/bin/moorlan
```

Pushing a `v*` tag runs `.github/workflows/server-release.yml` (linux amd64/arm64
binaries and `.sha256` digests).
