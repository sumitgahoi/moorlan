# Moorlan Linux server

Pair phones with a dedicated WireGuard device over trusted-LAN HTTP.
Moorlan stores peer assignments in SQLite and applies them live with wgctrl.
It does **not** write networkd or wg-quick peer config. The [iPhone app](../ios/README.md)
handles the client.

## Supported setup

| Setting | Requirement / example |
| --- | --- |
| Interface | Existing WireGuard device named `moorlan0` (or `moorlan1`, …), already up |
| Server address | Exactly one private IPv4 address, `/16`–`/30`, e.g. `10.10.83.1/24` |
| Home CIDRs | Private IPv4 prefixes routed to phones when away (not used for hairpin) |
| Peer persistence | SQLite at `/var/lib/moorlan/<iface>.db` (override with `-db`) |
| Privileges | Root |
| Phone address | Automatically allocated `/32` in the tunnel subnet |

Create and firewall the `moorlan0` device yourself (networkd, wg-quick, etc.). Ship
it with **no peers**; Moorlan owns every peer on that interface.

## Run

```bash
cd server
go build -o moorlan ./cmd/moorlan
# Or use a GitHub Release binary for linux/amd64 or linux/arm64.

# First-time setup, once moorlan0 is up with no peers:
sudo ./moorlan --init

# After boot (or from a systemd oneshot once moorlan0 is up):
sudo ./moorlan --rehydrate

# Enrollment (trusted LAN):
sudo ./moorlan -private-endpoint 10.10.10.1:8756 -home-cidrs 10.10.0.0/24,10.10.10.0/24,10.10.20.0/24,10.10.30.0/24,10.10.40.0/24
sudo ./moorlan --unpair -private-endpoint 10.10.10.1:8756
sudo ./moorlan --remove '<device-public-key>'
```

Flags only (no config file). Options:

- `-wg`: interface name, default `moorlan0` (must match `moorlan` + digits).
- `-db`: SQLite path, default `/var/lib/moorlan/<wg>.db`.
- `-private-endpoint`: LAN HTTP control `host:port` (required for pair and `--unpair`).
- `-home-cidrs`: private IPv4 CIDR(s) for split-tunnel routes when away (pairing only).
- `-public-endpoint`: public WireGuard `host:port`; overrides STUN.
- `--init`: create the database for an empty device, then exit. Refuses an existing file.
- `--rehydrate`: apply SQLite peers to the live device and exit (boot path).
- `--unpair`: unpair QR + DELETE only.
- `--remove <pubkey>`: admin removal by WireGuard public key, then exit (labels are hints only).

Without `-public-endpoint`, STUN discovers a public IPv4 + WireGuard listen port.
Discovery failure requires `-public-endpoint`. Moorlan never advertises the LAN
address as the public VPN endpoint.

## Persistence model

| Owner | Responsibility |
| --- | --- |
| Host (networkd / wg-quick / …) | Device `moorlanN` exists: key, address, listen port, routes/firewall |
| Moorlan SQLite | Phone peers (public key, `/32`, label) |
| Live `wgctrl` | Peers currently on the device |

`--rehydrate` **rehydrates** the live device from SQLite after reboot (and removes
any live peer not in the database). Pair / unpair / `--remove` also reconcile
database peers and pending removals with the live device.
Only `--init` creates a database; every other mode requires an initialized file.
Use `--init` once during setup, never in the boot service. If a database is lost,
restore it from backup.
Sample oneshot units (pick the one that matches how you create `moorlan0`):

| File | When to use |
| --- | --- |
| [`systemd/moorlan-rehydrate.networkd.service`](systemd/moorlan-rehydrate.networkd.service) | `moorlan0` from systemd-networkd |
| [`systemd/moorlan-rehydrate.wg-quick.service`](systemd/moorlan-rehydrate.wg-quick.service) | `moorlan0` from `wg-quick@moorlan0` |

Install one as `moorlan-rehydrate.service` (site deploy / linux-router owns the enabled copy):

```bash
# networkd example:
sudo install -m 644 systemd/moorlan-rehydrate.networkd.service /etc/systemd/system/moorlan-rehydrate.service
# or wg-quick:
# sudo install -m 644 systemd/moorlan-rehydrate.wg-quick.service /etc/systemd/system/moorlan-rehydrate.service
sudo systemctl daemon-reload
sudo systemctl enable --now moorlan-rehydrate.service
```

Moorlan does not wait for the interface inside the binary; unit ordering must
ensure the device exists before `--rehydrate` runs.

## Protocol and trust

The version 1 pairing QR contains only protocol/discovery information:

```json
{"v":1,"pair_url":"http://192.168.1.10:8756/v1/pair","server_public_key":"<server-key>"}
```

There is no invitation token or expiry. **Anyone who can reach the service can
enroll while it is running.** Run it explicitly for pairing on a trusted home LAN;
stop it afterward. HTTP is intentional for this scope.
The QR server key lets the app check the returned identity; it does not authenticate
HTTP traffic or establish an encrypted control channel.

`POST /v1/pair` JSON is `{ "public_key": "<device-key>", "label": "iPhone" }`.
The response contains the assigned `/32`, routing prefixes, server public key,
public endpoint, `lan` (home CIDRs), MTU, keepalive, and a plaintext HMAC
`unpair_token`. The same key gets the same assignment on retry (including its
`unpair_token`) and can refresh its label — see LIMITATIONS.

## Unpair

Phone-initiated: `sudo ./moorlan --unpair ...`, scan QR, confirm. Only HTTP 204
permits local profile deletion.

Admin-initiated: `sudo ./moorlan --remove <device-public-key>` (from `wg show`
or SQLite). Labels are hints only and are not accepted for `--remove`.

The server commits removal intent before revoking live access, so a crash cannot
cause `--rehydrate` to restore a removed peer. Failed live removals remain in a
short journal; retry the same `--remove <pubkey>` or run `--rehydrate` to finish.
The phone removes its local profile only after the server confirms live removal
with HTTP 204.

While pairing runs, `POST` of an already-managed public key also returns that
peer's `unpair_token`, and pairing mode still serves `DELETE /v1/pair`. Stop the
process when finished.

## Networking notes

- Forward the WireGuard UDP port. Split-tunnel AllowedIPs cover the tunnel pool
  and `-home-cidrs`. LAN access needs forwarding and return routes; exit mode
  needs NAT/masquerade for phone traffic.
- The home CIDRs and tunnel subnet must not overlap.
- Hairpin protection on the phone is SSID-based (see the iOS app).

## LIMITATIONS

- Trusted-LAN HTTP only. No public control API, invitation authentication, or
  encrypted control channel. Run pairing/unpair only on a network you trust, and
  stop the process when finished.
- While pairing runs, anyone who can reach the service and knows a managed peer's
  WireGuard public key can `POST` that key, receive its `unpair_token`, refresh
  its label, and `DELETE` the peer. Prefer `--remove` on the host for admin
  revocation when the phone is unavailable.
- Only interfaces named `moorlan0`, `moorlan1`, … are supported.
- Database creation requires `--init`, an empty device, and a new file path.
  Other modes fail on a missing or uninitialized database; restore a lost database
  instead of initializing a replacement.
- Pairing/unpair requires reachable home LAN; there is no offline deletion queue.
- No STUN NAT traversal, UPnP, relay, CGNAT bypass or external-port discovery.
- Do not put Moorlan phone peers in networkd/wg-quick config. Do not change the
  server key or tunnel subnet out from under an existing database.

## Development

```bash
go test -race ./...
go vet ./...
go build -o moorlan ./cmd/moorlan
```

Pushing a `v*` tag runs `.github/workflows/server-release.yml`: Linux
`amd64`/`arm64` binaries (and SHA-256 checksums) are attached to a GitHub
Release. Manual workflow runs build and test without publishing.

SQLite uses the pure-Go modernc driver; Linux cross-compilation needs no C compiler.
