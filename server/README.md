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
| Home LAN | Private IPv4 subnet separate from the tunnel subnet |
| Config | Regular `/etc/wireguard/wg0.conf`; `SaveConfig=true` must be disabled |
| Privileges | Root; config directory must be writable |
| Phone address | Automatically allocated `/32`, such as `10.8.0.2/32` |

## Run

From the monorepo root:

```bash
cd server
go build -o moorlan ./cmd/moorlan
sudo ./moorlan
# DDNS or an externally forwarded port different from the WG listen port:
sudo ./moorlan -endpoint home.example.com:51820
```

Options:

- `-iface`: interface name, default `wg0`.
- `-endpoint`: public WireGuard `host:port`; overrides STUN.
- `--unpair`: display an unpair QR and expose DELETE only.
- `--remove <key|label>`: remove a managed peer by WireGuard public key, or by
  label when that label is unique, then exit.

Advanced options:

- `-conf`: config path, default `/etc/wireguard/<iface>.conf`.
- `-lan-iface`: select the LAN interface if default-route discovery is unsuitable.
- `-pair-port`: LAN HTTP port, default `8756`.

Without `-endpoint`, STUN discovers a public IPv4 address, combined with the
WireGuard listen port. The router must forward that same UDP port. Use `-endpoint`
for DDNS or a different external port. Discovery failure requires an override;
Moorlan never advertises the LAN address as the public VPN endpoint.

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
tunnel/LAN routing prefixes, server public key, public endpoint, LAN, MTU,
keepalive and a plaintext HMAC `unpair_token`. Responses are constructed from
current settings, not stored. The same key gets the same committed assignment
on retry and can refresh its label. Unsupported QR versions fail explicitly;
update app and server together. The unpair QR is also version 1.

## Managed configuration and allocation

SQLite lives next to the config: `wg0.conf.moorlan.db`. It stores managed
public-key/address/label assignments, the server's public identity, and temporary
pending removals. Config and database files are owner-only (`0600`). The database
contains no server private key. Do not delete it or back it up independently of
the config.

Only this block is generated, sorted by peer public key. Labels are rendered as
comments for operators reading the file; SQLite remains authoritative:

```ini
### MOORLAN PEERS ###
[Peer]
# iPhone 17
PublicKey = <device-key>
AllowedIPs = 10.8.0.2/32

### END MOORLAN PEERS ###
```

Everything outside the block is preserved byte for byte. Existing peers stay
unmanaged: their keys cannot be enrolled or removed by Moorlan. This also applies
to peers created outside a marked block by older Moorlan versions; their existing
VPN profiles still work, but removal requires normal WireGuard administration.
There is no automatic migration/adoption of existing peers.

Allocation scans the server's tunnel subnet from the lowest usable address,
excluding network, broadcast, server, committed managed assignments, and addresses
covered by saved or live existing peer routes. Existing `/28` or other routed
ranges reserve the whole overlapping range. IPv6 and routes outside the tunnel
pool do not consume IPv4 pool addresses. A full pool gives an explicit error.
Only phones with one `/32` each are enrolled; there is no per-device IP input or
pool override. A successful unpair releases that device's allocation for reuse.

## Changes, retries, and recovery

SQLite is authoritative for managed peers. One process-lifetime interface lock
(`/run/moorlan-<iface>.lock`) prevents other Moorlan processes from managing it.
One operation mutex serializes pairing, unpair and reconciliation.

Pairing commits an assignment, renders and atomically saves the block using a
private temporary file, then applies managed peers with wgctrl. Success is returned
only after saving and applying succeed. A failed save/apply does not roll back the
assignment: retry uses the same address and finishes the operation. Unchanged live
peers are skipped; unmanaged peers are never replaced or removed.

Unpair deletes the assignment and records a pending removal in one SQLite
transaction. It regenerates the block, removes the live peer, and clears the pending
removal only after success. Repeated DELETEs are safe. The short removal journal
lets startup finish deletion even if the process crashed after removing its config
section but before removing the live peer. It is not an offline client queue.

On startup, assignments and pending removals are reapplied. A completely missing
managed block is recreated from SQLite. Missing/reversed/duplicate individual
markers are errors; the surrounding config and `[Interface]` section must remain.
If the database is missing while the block contains peers, startup fails instead
of erasing them. Restore the database and config together. No whole-interface
`wg-quick save`, per-request backup, rollback, or interface restart is used.

## Unpair

Phone-initiated (device still present):

```bash
sudo ./moorlan --unpair
```

On home Wi-Fi, choose **Delete profile** in the app, scan this QR, and confirm.
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

Enrollment of new keys while pairing is running remains open on the trusted LAN;
stop the process when finished.

## Routing prerequisites

Moorlan does not create interfaces, routes, forwarding, NAT, or firewall rules.
Use an existing working WireGuard installation. The interface route must already
cover the tunnel pool. LAN access needs forwarding and return routes; exit mode
also needs Internet routing/NAT and firewall rules. Pairing success does not test
VPN reachability, forwarding or DNS.

## LIMITATIONS

- Linux, existing wg-quick-style config, one private IPv4 tunnel subnet only.
  NetworkManager, containers/network namespaces, IPv6 provisioning and IPv6 exit
  are unsupported. The home LAN and tunnel subnet must not overlap.
- Each enrolled device receives one `/32`. Advertising a subnet behind an enrolled
  device (router/site-to-site use) is unsupported. Client access to the LAN/tunnel
  subnet and exit mode are separate routing choices and remain supported.
- Do not manually change the managed block/database, move managed peers outside
  the block, change the server key or tunnel subnet, or run other configuration
  tools concurrently. Moorlan does not coordinate with external tools. Existing
  peers outside the block remain admin-owned; unapplied external file edits are
  not applied by Moorlan. Keep `SaveConfig=true` disabled.
- SQLite, disk config and live WireGuard cannot change in one transaction. Failed
  operations may leave them temporarily different until retry/startup. Moorlan
  repairs only while running; there is no background daemon or database-loss
  recovery. Back up config and database together while Moorlan is stopped.
- No STUN NAT traversal, UPnP, relay, CGNAT bypass or external-port discovery.
- Trusted-LAN HTTP only. No public control API or invitation authentication.
  Proof of private-key ownership is not required for first enrollment. Deletion
  requires reachable home LAN; there is no offline deletion queue.
- Regular config files only; symlinks are unsupported. The complete config cannot
  be reconstructed if deleted. A lost SQLite database requires operator recovery.

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
