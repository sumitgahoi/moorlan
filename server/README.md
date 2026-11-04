# Moorlan Linux server

Pair phones with an existing home WireGuard server over trusted-LAN HTTP.
Moorlan assigns individual tunnel addresses, writes its own marked config block,
and applies managed peers through Go's wgctrl library without restarting WireGuard.
The [iPhone app](../ios/README.md) handles the client.

## Supported setup

| Setting | Requirement / example |
| --- | --- |
| Interface | Existing Linux WireGuard interface, already up: `wg0` |
| Server address | Exactly one private IPv4 address, `/16`–`/30`, usually `10.8.0.1/24` |
| Home CIDRs | Private IPv4 prefixes routed to phones when away (not used for hairpin) |
| Config | Regular `/etc/wireguard/wg0.conf`; `SaveConfig=true` must be disabled |
| Privileges | Root; config directory must be writable |
| Phone address | Automatically allocated `/32`, such as `10.8.0.2/32` |

## Install

On the WireGuard host (Linux amd64/arm64):

```bash
curl -fsSL https://raw.githubusercontent.com/sumitgahoi/moorlan/main/server/install.sh | sudo bash
# Or from a checkout / release binary in the current directory:
# sudo ./install.sh
# sudo ./install.sh ./moorlan-linux-amd64
```

This installs:

| Path | Purpose |
| --- | --- |
| `/opt/moorlan/moorlan` | Binary |
| `/usr/local/bin/moorlan` | Symlink on `PATH` |
| `/opt/moorlan/moorlan.conf` | Starter config (created only if missing) |

Edit `private-endpoint` and `home-cidrs` in the conf, then:

```bash
sudo moorlan
sudo moorlan --unpair
sudo moorlan --remove "Kitchen iPhone"
```

## Run (from source)

```bash
cd server
go build -o moorlan ./cmd/moorlan
sudo ./install.sh ./moorlan   # or: cp moorlan.conf.example moorlan.conf && sudo ./moorlan
# Flags override moorlan.conf:
sudo moorlan -private-endpoint 10.10.10.1:8756 -home-cidrs 10.10.0.0/16
# Exact VLAN prefixes:
# sudo moorlan -home-cidrs 10.10.10.0/24,10.10.20.0/24,10.10.30.0/24,10.10.40.0/24
# DDNS or an externally forwarded port different from the WG listen port:
sudo moorlan -public-endpoint home.example.com:51820
```

Static settings live in `moorlan.conf` (`key = value`, `#` comments). Moorlan loads
the first existing of `./moorlan.conf` or `<binary-dir>/moorlan.conf` (so the
`/opt/moorlan` install is picked up via the symlink), or an explicit `-config`
path. See `moorlan.conf.example`.

Options:

- `-private-endpoint`: LAN HTTP control `host:port` (required). Host must be a
  private IPv4 configured on this machine and inside `-home-cidrs`. Used as the
  QR `pair_url` host.
- `-home-cidrs`: private IPv4 CIDR(s) included in phone split-tunnel routes when
  away (required). One prefix or comma-separated list. Hairpin / tunnel-off on
  the phone is SSID-based, not CIDR-based.
- `-wg`: WireGuard interface name, default `wg0`.
- `-public-endpoint`: public WireGuard `host:port`; overrides STUN.
- `--unpair`: display an unpair QR and expose DELETE only.
- `--remove <key|label>`: remove a managed peer by WireGuard public key, or by
  label when that label is unique, then exit.

Advanced options:

- `-config`: path to `moorlan.conf`.
- `-wg-conf`: wg-quick config path, default `/etc/wireguard/<wg>.conf`.

Without `-public-endpoint`, STUN discovers a public IPv4 address, combined with the
WireGuard listen port. The router must forward that same UDP port. Use
`-public-endpoint` for DDNS or a different external port. Discovery failure
requires an override; Moorlan never advertises the LAN address as the public VPN
endpoint.

Startup acquires one interface lock, opens SQLite, and repairs the managed block
and managed live peers before displaying a QR. The process stays up until Ctrl-C.
Multiple devices can scan the same QR and retry requests.

## Protocol and trust

The version 1 pairing QR contains only protocol/discovery information:

```json
{"v":1,"pair_url":"http://192.168.1.10:8756/v1/pair","server_public_key":"<server-key>"}
```

There is no invitation token or expiry. **Anyone who can reach the service can
enroll while it is running.** Run it explicitly for pairing on a trusted home LAN
with trusted users/devices; stop it afterward. HTTP is intentional for this scope.
The QR server key lets the app check the returned identity; it does not authenticate
HTTP traffic or establish an encrypted control channel.

`POST /v1/pair` JSON is `{ "public_key": "<device-key>", "label": "iPhone" }`.
The label is the phone's device name (admin hint only; duplicates are allowed)
and is returned in the lease. The response also contains the assigned `/32`,
tunnel plus home-CIDR routing prefixes, server public key, public endpoint,
`lan` (home CIDRs from `-home-cidrs`, comma-separated when multiple), MTU,
keepalive and a plaintext HMAC `unpair_token`. Responses are constructed from
current settings, not stored. The same key gets the same committed assignment on
retry (including its `unpair_token`) and can refresh its label — see LIMITATIONS.
Unsupported QR versions fail explicitly; update app and server together. The
unpair QR is also version 1.

## Managed configuration and allocation

SQLite lives next to the config: `wg0.conf.moorlan.db`. It stores managed
public-key/address/label assignments, the server's public identity, and temporary
pending removals. Config and database files are owner-only (`0600`). The database
contains no server private key. Do not delete it or back it up independently of
the config.

Only this block is generated, sorted by peer public key. Labels are rendered as
comments:

```
### MOORLAN PEERS ###
# Kitchen iPhone
[Peer]
PublicKey = …
AllowedIPs = 10.8.0.2/32
### END MOORLAN PEERS ###
```

Everything outside the block is preserved byte for byte. Existing peers stay
untouched. There is no automatic migration/adoption of existing peers outside a
marked block by older Moorlan versions; their existing AllowedIPs still reserve
addresses in the pool.

Allocation walks the configured tunnel subnet for a free `/32`, skipping the
server address, network/broadcast, and addresses claimed by any live AllowedIP.
A successful unpair releases that device's allocation for reuse. There is no
pool override.

SQLite is authoritative for managed peers. One process-lifetime interface lock
(`/run/moorlan-<iface>.lock`) prevents other Moorlan processes from managing it.
Pairing commits an assignment, renders and atomically saves the block using a
rename, then applies the live peer. Unpair verifies the HMAC, deletes the
assignment, regenerates the block, removes the live peer, and clears the pending
row in one transaction.

On startup, if the database is present, managed peers are reconciled against the
managed block and live interface. Missing/reversed/duplicate individual peers are
repaired. If the database is missing while the block contains peers, startup fails
instead of erasing them. Restore the database and config together. No
whole-interface `wg-quick save`, per-request backup, rollback, or interface
restart is used.

## Unpair

Phone-initiated (device still present):

```bash
sudo ./moorlan --unpair
```

On home Wi‑Fi, choose **Delete profile** in the app, scan this QR, and confirm.
The public QR identifies the server and current LAN URL. The phone sends
`DELETE /v1/pair` with its public key and saved `unpair_token`. Only an HTTP 204
acknowledgement permits local profile deletion. Failures retain the phone profile
and credential so the user can retry. This mode skips endpoint/STUN discovery.

The credential is a per-peer HMAC derived from the server WireGuard private key.
It survives restarts; rotating that key is unsupported with the existing database.

Admin-initiated (lost device):

```bash
sudo ./moorlan --remove <device-public-key>
# or, when the device name is unique among managed peers:
sudo ./moorlan --remove "Kitchen iPhone"
```

Read the managed conf block (label comment + `PublicKey`) to pick the right
peer. This deletes the SQLite assignment, regenerates the managed block, removes
the live peer, and exits. No phone or HMAC is required. A non-unique label
fails with an error asking for the public key instead.

Enrollment of new keys while pairing is running remains open on the trusted LAN.
`POST` of an already-managed public key also returns that peer's `unpair_token`,
and pairing mode still serves `DELETE /v1/pair`. Stop the process when finished.

## Networking notes

- Forward the WireGuard UDP port. Split-tunnel AllowedIPs cover the tunnel pool
  and `-home-cidrs`. LAN access needs forwarding and return routes; exit mode
  needs NAT/masquerade for phone traffic.
- The home CIDRs and tunnel subnet must not overlap.
- Client access to the LAN/tunnel from away is via WireGuard AllowedIPs; hairpin
  protection on the phone is SSID-based (see the iOS app).

## LIMITATIONS

- Trusted-LAN HTTP only. No public control API, invitation authentication, or
  encrypted control channel. Run pairing/unpair only on a network you trust, and
  stop the process when finished.
- While pairing runs, anyone who can reach the service and knows a managed peer's
  WireGuard public key can `POST` that key, receive its `unpair_token`, refresh
  its label, and `DELETE` the peer. Treat peer public keys and the pairing
  window as sensitive on that LAN. Prefer `--remove` on the host for admin
  revocation when the phone is unavailable.
- Pairing/unpair requires reachable home LAN; there is no offline deletion queue.
- No STUN NAT traversal, UPnP, relay, CGNAT bypass or external-port discovery.
- Do not manually change the managed block/database, move managed peers outside
  the block, change the server key or tunnel subnet, or run other configuration
  writers against the same interface while Moorlan is managing it. Existing
  peers outside the block remain admin-owned; unapplied external file edits are
  not monitored.

## Development

```bash
go test -race ./...
go vet ./...
go build -o moorlan ./cmd/moorlan
```

Pushing a `v*` tag runs `.github/workflows/server-release.yml`: Linux
`amd64`/`arm64` binaries (and SHA-256 checksums) are attached to a GitHub
Release. Manual workflow runs build and test without publishing.

Existing PeerDoor installs: conf markers `### PEERDOOR PEERS ###` are still
read; the next save rewrites them as `### MOORLAN PEERS ###`. The database file
is renamed from `*.peerdoor.db` to `*.moorlan.db` on first open. Re-pair phones
after upgrading so they receive a new `unpair_token` (HMAC domain changed).

SQLite uses the pure-Go modernc driver; Linux cross-compilation needs no C compiler.
