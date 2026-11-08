# Moorlan server requirements

Authoritative product contract for the Linux Go server (`server/`). Normative.
[README.md](README.md) and [ARCHITECTURE.md](ARCHITECTURE.md) describe the same
system for operators and engineers.

## 1. Product intent

- Pair phones to an **existing** Linux WireGuard device over **trusted home LAN HTTP**.
- v1 core: install/setup (guess site conf), enroll, list, revoke, boot-reapply peers.

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
| Operator | Reviews/edits `/etc/moorlan/moorlan.yaml` after `--setup`; sets `enabled` | Peer rows |
| `/etc/moorlan/moorlan.yaml` | Static host + per-interface settings (source of truth for those settings) | Peers |
| SQLite (`/var/lib/moorlan/moorlan.db`) | **Source of truth for enrolled peers** and per-interface server public keys | Live kernel state |
| Live WireGuard (wgctrl) | Projection of SQLite peers | Persistence |
| systemd oneshot | Boot `--reconcile` across managed interfaces (bounded retries) | Long-running daemon |
| Binary `/usr/local/bin/moorlan` | CLI; path invoked by the reconcile unit; `--setup` writes unit + site YAML | Host networking ownership |

Invariants:

- YAML lists interfaces; only **`enabled: true`** interfaces are used for **new**
  enroll. There is no separate registration CLI.
- Reconcile MUST project SQLite → live for each interface it reconciles:
  ensure each DB peer is present with correct AllowedIPs, then remove every live
  peer absent from the DB for that interface.
- Moorlan MUST NOT write peer entries into wg-quick or networkd config files.
- Moorlan MUST NEVER delete or modify the host WireGuard device
  (e.g. `/etc/wireguard/wg0.conf`).
- `interfaces.server_public_key` is set once (first successful use of that
  interface name). It MUST NOT be updated. If the live WireGuard public key does
  not match the stored row, Moorlan MUST refuse to operate on that interface.

### Interface disabled or removed from YAML

- `--pair` for a disabled or absent interface MUST fail.
- Existing peers in SQLite continue to work: reconcile still applies them; live
  peers remain usable.
- `--unpair`, `--remove`, and `--list-peers` MUST still work from the DB for that
  interface.

## 4. Preconditions

- Linux, root.
- An existing, up WireGuard interface with **exactly one** private IPv4 address
  in a `/16`–`/30` prefix. Operators often start each device with zero peers;
  the server does not enforce a zero-peer check. Enabling an iface that already
  has live peers MAY strip those peers from the live device on reconcile (conf
  files are untouched; `enabled: false` + restart WG from host conf restores
  conf-backed peers).
- Per interface, sticky `public-endpoint` (`host:port`) is required after setup.
  `--setup` MAY best-effort guess it via STUN (bound to the WG listen port), with
  a global unicast IPv4 + listen-port fallback. No UPnP or relays. Operators MAY
  override with DDNS. The advertised port is whatever reaches this iface from the
  internet (may differ from the local listen port when NAT/port-mapping is used);
  the server MUST NOT require them to match.
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
- Shipped example: `/usr/share/moorlan/moorlan.yaml.example` — minimal template
  (`interfaces: {}`) for reference; normal path is `--setup` create/merge.
- Root `private-endpoint` is always required. Empty `interfaces` is valid;
  `--reconcile` is a successful no-op. Peer DB path is fixed at
  `/var/lib/moorlan/moorlan.db` (not a YAML key).
- Under `interfaces.<name>`: `enabled` (required bool), `name`, `public-endpoint`,
  `home-networks`, `dns-servers` (required), `dns-search` (optional). Map key
  `<name>` is the WireGuard interface name. `name` is the tunnel display name
  phones show after pairing (max 64 characters; same rules as a device label).
- Missing `enabled` MUST fail load (no omit default).
- List-valued keys preserve order as preference order. Unknown keys MUST fail
  load.
- Site settings come from the YAML file only. No CLI overrides of site keys in v1.
- Operator path: run `install.sh` (exclusive supported install/upgrade) → review
  YAML / set `enabled: true` → `--pair` day to day. From source: place binary,
  then `moorlan --setup`.

### Naming

- `name` / lease `name`: human tunnel name for the phone UI.
  Distinct from peer `label` (the phone’s device name stored on the server).
- `home-networks` / lease `home_networks`: IPv4 prefixes the phone routes into
  the tunnel for LAN access when away. Distinct from phone “home Wi‑Fi” SSIDs.
- `dns-servers` / lease `dns_servers`: required resolvers for the tunnel. The
  phone MUST use only lease DNS and search domains. No phone Settings override
  of DNS/search. No phone-invented Cloudflare (or other) fallback. Server conf
  is the sole DNS policy.
- Canonical example: `dns-servers` lists the server WireGuard tunnel address
  (e.g. `10.10.83.1`); `dns-search` includes `home.arpa`; `home-networks` lists
  LAN prefixes only (not the tunnel pool). Short names resolve over the tunnel
  (`carbon` → `carbon.home.arpa`).

## 6. Commands

Exactly one primary mode per process (or bare usage with no mode). One flock per
interface (`/run/moorlan-<iface>.lock`); concurrent mutators on the same
interface MUST be refused. `--reconcile` with no interface locks each target
interface in stable name order.

| Command | Behavior | Success means |
| --- | --- | --- |
| `--setup` | In order: create/merge `/etc/moorlan/moorlan.yaml` (existing set fields win; new ifaces `enabled: false`); additive DB migrate; replace embedded systemd unit; `systemctl enable` (boot only — does **not** run reconcile); ask to review the YAML before `--pair` (does **not** dump conf contents). Binary placement is `install.sh` only. | YAML written; unit enabled |
| `--pair [--interface <iface>]` | Interface MUST be listed and **`enabled: true`**. If exactly one enabled interface, `--interface` MAY be omitted; if more than one enabled, `--interface` is required. Reconcile that iface, print pair QR, serve HTTP on root `private-endpoint` | Session until idle/Ctrl-C; each enroll: DB committed and reconcile attempted |
| `--unpair [--interface <iface>]` | Same selection among enabled YAML ifaces when listed; when the iface is absent/disabled in YAML but still has DB state, `--interface` is required. Reconcile, print unpair QR, DELETE-only HTTP server | Peer removed from DB → HTTP success; live MAY lag until next reconcile |
| `--remove --interface <iface> --peer-public-key <key>` | Admin revoke by peer WireGuard public key (no QR). Works with DB state even if iface is absent/disabled in YAML | Same DB-first success as unpair |
| `--list-peers [--interface <iface>]` | Print label, public key, address from SQLite. Optional `--interface` filters; omit to list all | Read-only |
| `--reconcile [--interface <iface>]` | With `--interface`: apply SQLite → live for that iface. Without: every **enabled** YAML iface **or** still has rows in `interfaces` / `peers`. Soft-fail per iface inside the run; process exits non-zero if any target failed so boot retries can continue | Each successful iface: live matches DB; overall process fails (retryable) if any target failed |

Bare `moorlan` (no mode flags) prints usage and exits non-zero (or zero on `-h`/`--help` only via flag help).

`--rehydrate` is not a product name; boot and operators use `--reconcile`.

There is no `--add-interface` or `--remove-interface`.

### Install / upgrade (exclusive)

- Supported path: `install.sh` replaces `/usr/local/bin/moorlan`, then runs
  `moorlan --setup`. Re-run `install.sh` to upgrade.
- Replacing the binary without `--setup` / `install.sh` is unsupported.
- `--setup` does not download a binary. From source: install binary to path, then
  `moorlan --setup`.

### `--setup` merge (normative)

`--setup` builds site conf in four steps. `Load` / `Parse` only decode (never
validate). `Validate` is a separate step and requires every site key to be
**explicitly set** (omit ≠ assumed default; omitted `enabled` is unset, not
false). Unknown YAML keys are ignored and dropped on rewrite.

1. **Best-effort (guessed) site** from the live host (`CreateDefaultConf`):
   - Every up WireGuard device with exactly one private IPv4 (`/16`–`/30`)
   - Each guessed iface: `enabled: false` set explicitly; `name` from hostname
     (or `hostname-iface`); `public-endpoint` via STUN (or global-IPv4 +
     listen-port fallback); `home-networks` from private non-WG prefixes
     (exclude tunnel pool; include private-endpoint’s prefix); `dns-servers` =
     that iface’s WG IPv4; `dns-search: [home.arpa]`
   - Root `private-endpoint`: first suitable LAN IPv4 + port `8756`
2. **Load** the on-disk file if present (decode only; missing file → guessed
   only). Omitted keys stay unset.
3. **Merge**: start from the guessed site; for each field, if the existing
   value is set (non-empty string/list, or `enabled` present), keep the
   existing value; otherwise keep the guess. Interface names only in guessed →
   add guessed stanza (`enabled: false`). Interface names only in existing →
   keep (may note “not seen on host”).
4. **Validate** the merged site (all required keys explicitly set), then
   atomic write (temp + rename). Write always emits every site key.

Day-to-day modes (`--pair`, `--reconcile`, …): `Load` then `Validate`.

## 7. Pair / unpair protocol

### Pair QR

Camera-openable custom URL (ANSI QR encodes this string):

```
moorlan://v1/pair?url=http%3A%2F%2F<private-endpoint>%2Fv1%2Fpair&spk=<server-wg-public-key>
```

- Host `v1`, path `/pair`.
- `url`: control plane `http` URL, path exactly `/v1/pair`, no userinfo/query/fragment
  (percent-encoded in the query).
- `spk`: server WireGuard public key (same value returned as lease `public_key`).
- No invitation token in the QR. Legacy JSON QR payloads are not supported.

### Enroll

- `POST /v1/pair` body: `{"public_key":"<peer>","label":"<device label>"}`.
- Enroll is allowed only for the interface selected for this `--pair` session, and
  that interface MUST be present in YAML and `enabled: true`. Lease fields come
  from the YAML stanza for that interface plus root `private-endpoint` for the
  pair URL.
- Server allocates the next free `/32` in the tunnel subnet (deterministic scan
  of free host addresses). Re-pair of the same public key on the same interface
  keeps the existing address and refreshes the label. Duplicate labels are
  allowed; peer identity is `(interface, public_key)`.
- Success response lease MUST include:
  - `public_key` — server WireGuard public key (MUST match QR)
  - `endpoint` — that interface’s `public-endpoint`
  - `address` — peer tunnel address (`/32`)
  - `tunnel_network` — WireGuard pool prefix from the live device (e.g. `10.8.0.0/24`)
  - `home_networks` — from that interface’s `home-networks` (list)
  - `dns_servers` — from that interface’s `dns-servers` (required list; order = preference)
  - `dns_search` — optional, from that interface’s `dns-search`
  - `name` — from that interface’s `name` (tunnel display name)
  - `unpair_token` — per-peer capability
  - `persistent_keepalive`, `mtu`, `label` as applicable
- Lease MUST NOT use fields `prefixes` or `lan`.
- Phone AllowedIPs (client contract): `tunnel_network ∪ home_networks ∪`
  each `dns_servers` host (`/32`), plus `0.0.0.0/0` only in exit / full-tunnel
  mode. Never `::/0` (IPv4-only exit; no IPv6 tunnel pool).

### Unpair QR

```
moorlan://v1/unpair?url=http%3A%2F%2F<private-endpoint>%2Fv1%2Fpair&spk=<server-wg-public-key>
```

- Host `v1`, path `/unpair`.
- `spk` identifies which saved phone profile to clear (stable host identity).
  The phone’s public key is NOT in the QR.
- Unpair credential MUST NOT appear in the QR. Legacy JSON QR payloads are not
  supported.

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
  interface inside the run; any failed iface makes the process exit non-zero so
  systemd retries.

## 9. Non-goals (v1)

- TLS, invite tokens, multi-user auth
- Ephemeral pairing ports / automatic port selection
- Writing peer config into wg-quick or networkd
- Interface registration CLI (`--add-interface` / `--remove-interface`)
- UPnP, relays, IPv6 tunnel address pools
- Interactive prompts
- Offline client deletion queue
- Long-running pair daemon
- CLI overrides of site conf keys
- ensureHost / unit+migrate on every day-to-day command (only `--setup`)
- Self-updating binary download inside `--setup`

## 10. Failure and recovery

- Missing `/etc/moorlan/moorlan.yaml` → error that names that path and suggests
  `sudo moorlan --setup` (or re-run `install.sh`).
- No enabled interfaces on `--pair` → error that suggests review YAML / `--setup`
  / `install.sh`.
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
  interface TEXT NOT NULL REFERENCES interfaces(name),
  public_key TEXT NOT NULL,
  address TEXT NOT NULL,
  label TEXT NOT NULL DEFAULT '',
  PRIMARY KEY (interface, public_key),
  UNIQUE (interface, address)
);
```

No `metadata` table. No `pending_removals`. The same peer public key MAY exist on
two interfaces. Address uniqueness is per interface. Schema creation/migrate runs
during `--setup` (and whenever the DB is opened for peer ops, remaining additive
and backward compatible).
