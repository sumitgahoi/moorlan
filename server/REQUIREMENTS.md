# Moorlan server requirements

Authoritative product contract for the Linux Go server (`server/`). Normative.
[README.md](README.md) and [ARCHITECTURE.md](ARCHITECTURE.md) describe the same
system for operators and engineers.

## 1. Product intent

- Pair phones to an **existing** Linux WireGuard device over **trusted home LAN HTTP**.
- v1 core only: enroll, list, revoke, boot-reapply peers. Nothing else.

## 2. Trust model

- Control plane is plaintext HTTP on the private LAN. **No** TLS, invite token,
  or LAN authentication in v1.
- While `--pair` runs, anyone who can reach `private-endpoint` MAY enroll.
  That is deliberate for a trusted household LAN — not a gap to “fix” with
  invites or TLS in v1.
- `--pair` / `--unpair` MUST idle-stop after **2 minutes** with no successful
  enroll/unpair (or on Ctrl-C sooner).
- Operators MUST NOT publish the pairing port or run pair/unpair on guest or
  untrusted networks.

## 3. Ownership

| Owner | Owns | Does not own |
| --- | --- | --- |
| Host (networkd / wg-quick / …) | WireGuard device: private key, address, listen port, routes, firewall | Peers after Moorlan takes over |
| Operator | Creates/edits `/etc/moorlan/<iface>.conf` from the shipped example | Peers, SQLite DB, systemd unit |
| `/etc/moorlan/<iface>.conf` | Static site settings (source of truth for those settings) | Peers |
| SQLite (`db` path) | **Source of truth for enrolled peers** | Live kernel state |
| Live WireGuard (wgctrl) | Projection of SQLite peers | Persistence |
| systemd oneshot | Boot `--reconcile` until the device is usable (bounded retries) | Long-running daemon |
| Binary `/usr/local/bin/moorlan` | CLI; path invoked by the reconcile unit | Host networking; authoring site conf on add |

Invariants:

- After `--add-interface`, Moorlan owns **all** peers on that device. Reconcile
  MUST remove live peers that are not in SQLite (including peers added outside
  Moorlan).
- Moorlan MUST NOT write peer entries into wg-quick or networkd config files.
- `--add-interface` MUST NOT create or overwrite the site conf. It validates the
  conf and creates the DB and reconcile unit only.
- `--remove-interface` removes the site conf, DB, and unit. It MUST NEVER delete
  or modify the host WireGuard device (e.g. `/etc/wireguard/wg0.conf`).

## 4. Preconditions

- Linux, root.
- An existing, up WireGuard interface with **exactly one** private IPv4 address
  in a `/16`–`/30` prefix, and **zero peers**, at `--add-interface`.
- Sticky `public-endpoint` (`host:port`) is required. No STUN, UPnP, relay, or
  LAN-only public-endpoint fallback.
- `home-networks`: one or more private IPv4 prefixes. MUST NOT overlap the
  tunnel subnet. These are split-tunnel destinations on the phone (LAN reachability
  when away). They are **not** hairpin / home Wi‑Fi identity — hairpin is
  phone-local SSIDs only.
- `dns-servers`: required; one or more unicast IPv4 resolvers (private home
  resolver and/or public, e.g. `1.1.1.1`).
- `private-endpoint`: private IPv4 on a non-WireGuard, up, non-loopback host
  interface; MUST lie inside `home-networks` for pairing; host:port is sticky.
  Bind MUST use that configured address and port. Refuse if bind fails. No
  ephemeral / auto-picked port.

## 5. Site conf

- Canonical path only: `/etc/moorlan/<iface>.conf`.
- Shipped example: `/usr/share/moorlan/moorlan.conf.example`.
- The example MUST document every key with an inline comment: purpose,
  constraints, and a concrete example (including `dns-search` / short names such
  as `carbon` → `carbon.home.arpa`, and the public-DNS escape hatch). Optional
  keys that are commented out MUST still carry their explanation.
- Allowed keys: `interface` (MUST match `<iface>`), `db`, `private-endpoint`,
  `public-endpoint`, `home-networks`, `dns-servers` (required), `dns-search`
  (optional). List-valued keys are comma-separated; order is preserved as
  preference order. Unknown keys MUST fail load.
- Site settings come from the conf file only. No CLI overrides of site keys in v1.
- Setup:

```bash
sudo cp /usr/share/moorlan/moorlan.conf.example /etc/moorlan/wg0.conf
# edit …
sudo moorlan --add-interface wg0
```

### Naming

- `home-networks` / lease `home_networks`: IPv4 prefixes the phone routes into
  the tunnel for LAN access when away. Distinct from phone “home Wi‑Fi” SSIDs.
- `dns-servers` / lease `dns_servers`: required resolvers for the tunnel. The
  phone MUST use only lease DNS and search domains. No phone Settings override
  of DNS/search. No phone-invented Cloudflare (or other) fallback. Server conf
  is the sole DNS policy.
- Canonical LAN DNS example: `home-networks` includes the host subnet(s) (e.g.
  `10.10.10.0/24` and the AdGuard subnet); `dns-servers=<AdGuard IPv4>`;
  `dns-search=home.arpa`. In split tunnel the phone queries AdGuard over the
  tunnel; `carbon` → `carbon.home.arpa` → `10.10.10.10`.

## 6. Commands

Exactly one primary mode per process. One flock per interface; concurrent
mutators MUST be refused. Interface selection uses `--interface`.

| Command | Behavior | Success means |
| --- | --- | --- |
| `--add-interface <iface>` | Read `/etc/moorlan/<iface>.conf` (if missing, fail with a hint to copy `/usr/share/moorlan/moorlan.conf.example`); validate; create empty DB + reconcile unit; live device MUST have 0 peers; DB and unit MUST NOT already exist | DB + unit exist; site conf unchanged |
| `--remove-interface <iface>` | Fail if any peers remain; else delete DB, site conf, and unit | Moorlan registration gone; host WG device untouched |
| `--pair --interface <iface>` | Reconcile, print pair QR, serve HTTP on configured `private-endpoint` | Session until idle/Ctrl-C; each enroll: DB committed and reconcile attempted |
| `--unpair --interface <iface>` | Reconcile, print unpair QR, DELETE-only HTTP server | Peer removed from DB → HTTP success; live MAY lag until next reconcile |
| `--remove --interface <iface> --peer-public-key <key>` | Admin revoke by peer WireGuard public key (no QR) | Same DB-first success as unpair |
| `--list-peers --interface <iface>` | Print label, public key, address from SQLite | Read-only |
| `--reconcile --interface <iface>` | Apply SQLite → live: add/update each DB peer; remove every live peer not in DB | Live matches DB, or fail loudly (retryable) |

`--rehydrate` is not a product name; boot and operators use `--reconcile`.

## 7. Pair / unpair protocol

### Pair QR

```json
{"v":1,"pair_url":"http://<private-endpoint>/v1/pair","server_public_key":"<server-wg-public-key>"}
```

- `v` MUST be `1`.
- `pair_url`: scheme `http`, path exactly `/v1/pair`, no userinfo/query/fragment.
- No invitation token in the QR.

### Enroll

- `POST /v1/pair` body: `{"public_key":"<peer>","label":"<device label>"}`.
- Server allocates the next free `/32` in the tunnel subnet (deterministic scan
  of free host addresses). Re-pair of the same public key keeps the existing
  address and refreshes the label. Duplicate labels are allowed; identity is
  the peer public key only.
- Success response lease MUST include:
  - `public_key` — server WireGuard public key (MUST match QR)
  - `endpoint` — site `public-endpoint`
  - `address` — peer tunnel address (`/32`)
  - `tunnel_network` — WireGuard pool prefix from the live device (e.g. `10.8.0.0/24`)
  - `home_networks` — from site `home-networks` (list)
  - `dns_servers` — from site `dns-servers` (required list; order = preference)
  - `dns_search` — optional, from site `dns-search`
  - `unpair_token` — per-peer capability
  - `persistent_keepalive`, `mtu`, `label` as applicable
- Lease MUST NOT use legacy fields `prefixes` or `lan`.
- Phone AllowedIPs (client contract): `tunnel_network ∪ home_networks`, plus
  `0.0.0.0/0` and `::/0` only in exit / full-tunnel mode.

### Unpair QR

```json
{"v":1,"action":"unpair","server_public_key":"<server-wg-public-key>","unpair_url":"http://<private-endpoint>/v1/pair"}
```

- `server_public_key` identifies which saved phone profile to clear (stable host
  identity). The phone’s public key is NOT in the QR.
- Unpair credential MUST NOT appear in the QR.

### Unpair HTTP

- `DELETE /v1/pair` body: `{"public_key":"<peer>","unpair_token":"<token>"}`.
- Success MUST be **204** only when the peer row has been removed from SQLite.
- Unpair token: HMAC derived from the server WireGuard private key and the peer
  public key. Changing the server private key invalidates tokens; the DB MUST
  refuse operate if stored server public key does not match the live device.

## 8. Reconcile

- SQLite table `peers` is authoritative. There is **no** `pending_removals`
  (or equivalent) deletion journal.
- Reconcile order: ensure each DB peer is present on the live device with the
  correct AllowedIPs → remove every live peer absent from the DB.
- Unpair / `--remove`: delete the DB row, then reconcile. If reconcile fails,
  the DB already won; the next reconcile or boot clears the live orphan.
- `--pair` / `--unpair` / `--remove` reconcile around mutation. Boot runs
  `moorlan --reconcile --interface <iface>` via a systemd oneshot with a
  bounded restart window (~5 minutes) while the WireGuard device is not yet
  usable.

## 9. Non-goals (v1)

- TLS, invite tokens, multi-user auth
- Ephemeral pairing ports / automatic port selection
- Writing peer config into wg-quick or networkd
- Adopting an existing peer DB or live peers at `--add-interface`
- STUN, UPnP, relays, IPv6 tunnel address pools
- Interactive prompts
- Offline client deletion queue
- Long-running pair daemon
- CLI overrides of site conf keys

## 10. Failure and recovery

- Partial `--add-interface` failure → roll back **DB and unit only**. MUST NOT
  delete or rewrite `/etc/moorlan/<iface>.conf` (operator-edited Moorlan site
  settings — not the host WireGuard device file).
- Missing site conf on add → error that names `/etc/moorlan/<iface>.conf` and
  the example path to copy.
- Missing, corrupt, or server-key-mismatched DB → refuse to operate. Operator
  path: remove peers if the DB still works, `--remove-interface`, restore/edit
  site conf, `--add-interface`, re-pair.
- Reconcile failure after a DB commit → DB wins; next reconcile or boot fixes
  live.
- Failed mutations are retryable. Same inputs and explicit state MUST yield
  predictable outcomes.
