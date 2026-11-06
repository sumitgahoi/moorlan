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

## 3. Roles and state

| Role | Owns | Does not own |
| --- | --- | --- |
| Host (networkd / wg-quick / …) | WireGuard device: private key, address, listen port, routes, firewall | Peer enrollment |
| Operator | Creates/edits `/etc/moorlan/moorlan.yaml` from the shipped example; enables the reconcile unit | Peer rows |
| `/etc/moorlan/moorlan.yaml` | Static host + per-interface settings (source of truth for those settings) | Peers |
| SQLite (`db` path) | **Source of truth for enrolled peers** and per-interface server public keys | Live kernel state |
| Live WireGuard (wgctrl) | Projection of SQLite peers | Persistence |
| systemd oneshot | Boot `--reconcile` across managed interfaces (bounded retries) | Long-running daemon |
| Binary `/usr/local/bin/moorlan` | CLI; path invoked by the reconcile unit | Host networking; authoring YAML |

Invariants:

- YAML lists interfaces used for **new** enroll and lease fields. There is no
  separate registration CLI and no device “ownership” ceremony.
- Reconcile MUST project SQLite → live for each interface it reconciles:
  ensure each DB peer is present with correct AllowedIPs, then remove every live
  peer absent from the DB for that interface.
- Moorlan MUST NOT write peer entries into wg-quick or networkd config files.
- Moorlan MUST NEVER delete or modify the host WireGuard device
  (e.g. `/etc/wireguard/wg0.conf`).
- `interfaces.server_public_key` is set once (first successful use of that
  interface name). It MUST NOT be updated. If the live WireGuard public key does
  not match the stored row, Moorlan MUST refuse to operate on that interface.

### Interface removed from YAML

- `--pair` for that interface MUST fail (interface not listed).
- Existing peers in SQLite continue to work: reconcile still applies them; live
  peers remain usable.
- `--unpair`, `--remove`, and `--list-peers` MUST still work from the DB for that
  interface.

## 4. Preconditions

- Linux, root.
- An existing, up WireGuard interface with **exactly one** private IPv4 address
  in a `/16`–`/30` prefix. Operators are expected to start each device with zero
  peers (see README); the server does not enforce a zero-peer check.
- Per interface, sticky `public-endpoint` (`host:port`) is required. No STUN,
  UPnP, relay, or LAN-only public-endpoint fallback. The advertised port is
  whatever reaches this iface from the internet (may differ from the local listen
  port when NAT/port-mapping is used); the server MUST NOT require them to match.
- Per interface, `home-networks`: one or more private IPv4 prefixes. MUST NOT
  overlap that interface’s tunnel subnet. These are split-tunnel destinations on
  the phone (LAN reachability when away). They are **not** hairpin / home Wi‑Fi
  identity — hairpin is phone-local SSIDs only.
- Per interface, `dns-servers`: required; one or more unicast IPv4 resolvers
  (private home resolver and/or public, e.g. `1.1.1.1`).
- Root `private-endpoint`: private IPv4 on a non-WireGuard, up, non-loopback host
  interface; MUST lie inside the pairing interface’s `home-networks`; host:port
  is sticky and shared for all interfaces. Bind MUST use that configured address
  and port. Refuse if bind fails. No ephemeral / auto-picked port.

## 5. Site conf (YAML)

- Canonical path only: `/etc/moorlan/moorlan.yaml`.
- Shipped example: `/usr/share/moorlan/moorlan.yaml.example`.
- The example MUST document every key with an inline comment: purpose,
  constraints, and a concrete example (including `dns-search` / short names such
  as `carbon` → `carbon.home.arpa`, and the public-DNS escape hatch). Optional
  keys that are commented out MUST still carry their explanation.
- Root keys: `db`, `private-endpoint`.
- Under `interfaces.<name>`: `public-endpoint`, `home-networks`, `dns-servers`
  (required), `dns-search` (optional). Map key `<name>` is the WireGuard
  interface name.
- List-valued keys preserve order as preference order. Unknown keys MUST fail
  load.
- Site settings come from the YAML file only. No CLI overrides of site keys in v1.
- Setup:

```bash
sudo cp /usr/share/moorlan/moorlan.yaml.example /etc/moorlan/moorlan.yaml
# edit …
sudo systemctl enable --now moorlan-reconcile.service
sudo moorlan --pair
```

### Naming

- `home-networks` / lease `home_networks`: IPv4 prefixes the phone routes into
  the tunnel for LAN access when away. Distinct from phone “home Wi‑Fi” SSIDs.
- `dns-servers` / lease `dns_servers`: required resolvers for the tunnel. The
  phone MUST use only lease DNS and search domains. No phone Settings override
  of DNS/search. No phone-invented Cloudflare (or other) fallback. Server conf
  is the sole DNS policy.
- Canonical LAN DNS example: `home-networks` includes the host subnet(s) (e.g.
  `10.10.10.0/24` and the AdGuard subnet); `dns-servers` lists the AdGuard IPv4;
  `dns-search` includes `home.arpa`. In split tunnel the phone queries AdGuard
  over the tunnel; `carbon` → `carbon.home.arpa` → `10.10.10.10`.

## 6. Commands

Exactly one primary mode per process. One flock per interface
(`/run/moorlan-<iface>.lock`); concurrent mutators on the same interface MUST be
refused. `--reconcile` with no interface locks each target interface in stable
name order.

| Command | Behavior | Success means |
| --- | --- | --- |
| `--pair [--interface <iface>]` | Interface MUST be listed in YAML. If YAML lists exactly one interface, `--interface` MAY be omitted; if more than one, `--interface` is required. Reconcile that iface, print pair QR, serve HTTP on root `private-endpoint` | Session until idle/Ctrl-C; each enroll: DB committed and reconcile attempted |
| `--unpair [--interface <iface>]` | Same interface selection rules when the iface is in YAML; when the iface is absent from YAML but still has DB state, `--interface` is required. Reconcile, print unpair QR, DELETE-only HTTP server | Peer removed from DB → HTTP success; live MAY lag until next reconcile |
| `--remove --interface <iface> --peer-public-key <key>` | Admin revoke by peer WireGuard public key (no QR). Works with DB state even if iface is absent from YAML | Same DB-first success as unpair |
| `--list-peers [--interface <iface>]` | Print label, public key, address from SQLite. Optional `--interface` filters; omit to list all | Read-only |
| `--reconcile [--interface <iface>]` | With `--interface`: apply SQLite → live for that iface. Without: every iface that appears in YAML **or** still has rows in `interfaces` / `peers`. Soft-fail per iface (one down device MUST NOT block others) | Each successful iface: live matches DB; overall process fails only if every target fails, or fails loudly per operator-facing summary (retryable) |

`--rehydrate` is not a product name; boot and operators use `--reconcile`.

There is no `--add-interface` or `--remove-interface`.

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
- Enroll is allowed only for the interface selected for this `--pair` session, and
  that interface MUST be present in YAML. Lease fields come from the YAML stanza
  for that interface plus root `private-endpoint` for the pair URL.
- Server allocates the next free `/32` in the tunnel subnet (deterministic scan
  of free host addresses). Re-pair of the same public key on the same interface
  keeps the existing address and refreshes the label. Duplicate labels are
  allowed; peer identity is `(interface_id, public_key)`.
- Success response lease MUST include:
  - `public_key` — server WireGuard public key (MUST match QR)
  - `endpoint` — that interface’s `public-endpoint`
  - `address` — peer tunnel address (`/32`)
  - `tunnel_network` — WireGuard pool prefix from the live device (e.g. `10.8.0.0/24`)
  - `home_networks` — from that interface’s `home-networks` (list)
  - `dns_servers` — from that interface’s `dns-servers` (required list; order = preference)
  - `dns_search` — optional, from that interface’s `dns-search`
  - `unpair_token` — per-peer capability
  - `persistent_keepalive`, `mtu`, `label` as applicable
- Lease MUST NOT use fields `prefixes` or `lan`.
- Phone AllowedIPs (client contract): `tunnel_network ∪ home_networks ∪`
  each `dns_servers` host (`/32`), plus `0.0.0.0/0` only in exit / full-tunnel
  mode. Never `::/0` (IPv4-only exit; no IPv6 tunnel pool).

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

- SQLite tables `interfaces` and `peers` are authoritative. There is **no**
  `pending_removals` (or equivalent) deletion journal.
- Per interface, reconcile order: ensure each DB peer is present on the live
  device with the correct AllowedIPs → remove every live peer absent from the DB
  for that interface.
- Unpair / `--remove`: delete the peer row, then reconcile. If reconcile fails,
  the DB already won; the next reconcile or boot clears the live orphan.
- `--pair` / `--unpair` / `--remove` reconcile around mutation. Boot runs
  `moorlan --reconcile` via a single systemd oneshot with a bounded restart
  window (~5 minutes) while WireGuard devices are not yet usable. Soft-fail per
  interface.

## 9. Non-goals (v1)

- TLS, invite tokens, multi-user auth
- Ephemeral pairing ports / automatic port selection
- Writing peer config into wg-quick or networkd
- Interface registration CLI (`--add-interface` / `--remove-interface`)
- STUN, UPnP, relays, IPv6 tunnel address pools
- Interactive prompts
- Offline client deletion queue
- Long-running pair daemon
- CLI overrides of site conf keys

## 10. Failure and recovery

- Missing `/etc/moorlan/moorlan.yaml` → error that names that path and the example
  path to copy.
- Missing, corrupt, or server-key-mismatched DB → refuse to operate on the
  affected interface(s). Operator path: remove peers if the DB still works, fix
  or replace the DB and YAML as needed, re-pair.
- Reconcile failure after a DB commit → DB wins; next reconcile or boot fixes
  live.
- Failed mutations are retryable. Same inputs and explicit state MUST yield
  predictable outcomes.

## 11. SQLite schema

```sql
interfaces (
  name TEXT PRIMARY KEY NOT NULL,
  server_public_key TEXT NOT NULL UNIQUE
);
peers (
  interface_id TEXT NOT NULL REFERENCES interfaces(name),
  public_key TEXT NOT NULL,
  address TEXT NOT NULL,
  label TEXT NOT NULL DEFAULT '',
  PRIMARY KEY (interface_id, public_key),
  UNIQUE (interface_id, address)
);
```

No `metadata` table. No `pending_removals`. The same peer public key MAY exist on
two interfaces. Address uniqueness is per interface.
