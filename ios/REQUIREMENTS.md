# Moorlan iOS requirements

Authoritative product contract for the iPhone / iPad app and Packet Tunnel
(`ios/`). Normative. Protocol and lease fields MUST match
[server/REQUIREMENTS.md](../server/REQUIREMENTS.md).

## 1. Product intent

- Pair an iPhone or iPad with one or more Moorlan Linux WireGuard sites over
  **trusted home LAN HTTP**, then roam with a Packet Tunnel and device-local
  network policy.
- v1: enroll / unpair, **multi-tunnel** list, per-network **Off / Split / Full**
  routing, one **on-demand-active** (default) tunnel.
- Reuse WireGuardKit, NetworkExtension, AVFoundation, Network, CoreLocation, and
  Keychain. Do **not** reimplement WireGuard crypto, packet forwarding, or a
  wg-quick config parser.
- **Mac client (planned):** same `moorlan://` QR via in-app camera scan (system
  Camera → app is iPhone/iPad-primary). Packet Tunnel and Mac UI are not in this
  tree yet.

## 2. Trust and permissions

- Control plane trust matches the server: plaintext HTTP on the household LAN
  while pair/unpair runs. No TLS or invite tokens in v1.
- **Camera** — optional fallback for in-app QR scan; primary path is the system
  Camera app opening a `moorlan://` invite. Denial keeps in-app scan retryable
  and offers Open Settings.
- **Local Network** — required for LAN HTTP to the QR host; probe with a real
  connection to that host:port; surface denial / Settings recovery without
  clearing a pending QR retry.
- **VPN configuration** — Apple “Add VPN Configurations” MUST be approved;
  install a distinct profile even when Off policy will keep the tunnel down.
- **Wi‑Fi Information** (+ Precise Location While Using when needed) — SSID only,
  no coordinates. Unavailable SSID → stay Full until a stable path (named Wi‑Fi
  or cellular-only); never a user error. NEVER trust a reused interface name
  (`en0`).
- Physical-device entitlement behavior is authoritative; simulator is not.

## 3. Ownership

| Owner | Owns | Does not own |
| --- | --- | --- |
| Server lease | `tunnel_network`, `home_networks`, `dns_servers`, `dns_search`, `endpoint`, `address`, server `public_key`, `unpair_token`, lease `mtu` / `persistent_keepalive` | Phone SSIDs, routing, which tunnel is on-demand active |
| Phone | Multi-tunnel list, selected tunnel, on-demand-active tunnel, per-network Off/Split/Full (permanent + temporary), cellular routing, device label | Lease identity fields; DNS/search policy |
| Linux host | Forwarding / NAT for exit | iOS permissions / on-demand |

Phone MUST NOT override lease DNS/search, invent resolvers (including Cloudflare
fallback), or override lease tunnel identity fields (endpoint, address, server
key, mtu, keepalive).

**Naming:** phone **Off** SSIDs ≠ server `home_networks`. Off SSIDs keep the
tunnel down (hairpin). `home_networks` are away split-tunnel LAN routes.

## 4. Multi-tunnel and on-demand default

- Support many paired hosts. Distinct native `NETunnelProviderManager` per host,
  keyed by server public key.
- Exactly one tunnel may be **on-demand active** (Default). Activating a tunnel
  MUST turn on-demand **off** on every other Moorlan profile.
- Selecting a tunnel in the list for viewing/manual connect MUST NOT steal
  on-demand unless the user explicitly chooses **Use as default**.
- After pair:
  - **First / only** tunnel → auto-activate as on-demand default (no prompt).
  - If other tunnels already exist → ask **Use as your default?**; Yes activates
    the new tunnel (others off); No keeps the previous default.
- Unpair of the active default: if one tunnel remains → auto-activate it; else
  leave none active until the user picks.
- Pairing another host MUST NOT delete existing tunnels. Unpair removes **one**
  host only; the shared Keychain client identity is retained for other hosts.

## 5. Routing (Off / Split / Full)

Each named Wi‑Fi and cellular has a routing policy:

| Label | Behavior |
| --- | --- |
| **Off** | Tunnel stays down |
| **Split** | Only home routes / DNS through the tunnel |
| **Full** | All traffic through home (`0.0.0.0/0` only; never `::/0`) |

- **Permanent default:** unmarked Wi‑Fi → **Full**; cellular → **Split**.
- **Home** picker changes are **temporary** (until the path/SSID changes).
- **Settings** changes are **permanent**.
- **Pair** on an identifiable Wi‑Fi → that SSID is **permanently Off**.
- Multiple SSIDs may be permanently Off.
- No join prompt for new Wi‑Fi. No separate power button or Exit Node toggle —
  Off / Split / Full is the path control.
- On network switch / unsettled path: apply **Full** until stable. Stable =
  named Wi‑Fi or cellular-only. Then apply that path’s Off / Split / Full only
  if it differs. If never stable (e.g. Wi‑Fi with no SSID forever), remain Full.
  Missing SSID is not an error.
- Policy MUST run in the app **and** the Packet Tunnel extension on **stable**
  path changes. Extension and on-demand use the **permanent** map only.
- On-demand: when the default tunnel has ≥1 permanent Off SSID → Disconnect on
  those SSIDs / Connect elsewhere; with zero Off SSIDs, disable on-demand (avoid
  reconnect loops). On-demand is the system-native connect/disconnect path for
  Off SSIDs.

### AllowedIPs and DNS

- Split: `tunnel_network ∪ home_networks ∪` each lease `dns_servers` host (`/32`).
- Full: that set plus `0.0.0.0/0` only (IPv4). Never `::/0`.
- DNS/search: lease `dns_servers` (required) and optional `dns_search` only.
  WireGuardKit forces all queries through lease DNS (`matchDomains = [""]`); DNS
  host routes keep those resolvers reachable in split tunnel. Phone MUST NOT invent
  Cloudflare (or other) resolvers when the lease has DNS; a TEMP Settings
  override may exist for debugging only.

## 6. Pair / unpair

Protocol MUST match [server/REQUIREMENTS.md](../server/REQUIREMENTS.md) §7.

### Pair

- QR v1 is a Camera-openable URL:
  `moorlan://v1/pair?url=<http control>&spk=<server-wg-public-key>`. No invite
  token. Legacy JSON QR is not supported.
- **Primary UX:** system Camera scans the QR → opens Moorlan via the `moorlan`
  URL scheme → enroll. In-app scanner is a **fallback** only.
- `POST /v1/pair` with peer `public_key` and editable device **label**.
- Verify lease `public_key` equals QR `spk`.
- Name the tunnel from lease `name` (server site conf). The user MAY
  rename locally afterward; a local rename overrides `name` until
  cleared.
- Persist lease; install VPN profile. On success: confirmation, then status home
  with the new tunnel. **MUST** mark current SSID permanently Off when
  identifiable. Then apply on-demand default rules in §4.
- Pair progress: Open invite → Reach server → Save VPN profile (cancellable).

### Unpair

- QR v1: `moorlan://v1/unpair?url=…&spk=…`. Token NOT in QR.
- Match saved host by `spk`. Prefer scanned control `url`.
- If any permanent Off SSIDs exist, require the phone on one of them.
- `DELETE` with peer `public_key` + stored `unpair_token`. Success is **HTTP 204
  only**, then remove that host’s VPN profile and local host record.
- Confirm destructive unpair naming the host. On failure, keep local state for
  retry. No offline deletion queue. Missing `unpair_token` → re-pair first.

## 7. Storage

| Store | Content |
| --- | --- |
| App storage (host records) | Paired hosts: QR card, **full lease including `unpair_token`**, selection, on-demand-active id, label |
| App storage (policy) | Permanent `networkRouting` + `cellularRouting` |
| App Group (`group.app.moorlan`) | Non-secret extension `TunnelProfile` per host — **strip `unpair_token`**; **no** private key |
| Keychain (shared group) | One long-lived client WireGuard private key (`AfterFirstUnlockThisDeviceOnly`); survives unpair of a single host |
| System | Per-host `NETunnelProviderManager` |

`unpair_token` lives only in the **app host/lease record**. The extension never
sees it. Keychain is identity only, not the unpair credential. Temporary Home
routing is in-memory only.

## 8. UX / polish

### Voice

- Plain household English. Prefer Off / Split / Full over jargon where the UI
  already shows those labels; keep protocol detail behind info sheets.
- No childish metaphors (raincoat, “Became friends”, path-sleeps). Warm and clear
  is enough.

### Visual and HIG

- Native SwiftUI: SF Pro via semantic text styles, system/semantic colors,
  standard margins, native `Toggle` / `Form` / `List` / toolbars /
  `NavigationStack`, 44pt minimum hit targets. Do not invent a parallel type
  scale or hard-code a light-only palette that breaks Dark Mode.
- Home: Off/Split/Full segmented control for the current path; tunnel list with
  Default badge / Use as default; status text. No power button; no Exit Node toggle.
- Settings: permanent cellular + Wi‑Fi routing lists.
- **Connected** means a live WireGuard handshake with the paired peer (UAPI
  `last_handshake_time_sec` fresh), not merely `NEVPNStatus.connected`.
- Empty state: invite to pair + primary scan CTA.
- Accessibility: Dynamic Type, VoiceOver, Reduce Motion respected.

### Errors

Every failure MUST show **title + one plain sentence + primary action** (Retry /
Open Settings / OK). No raw NetworkExtension, POSIX, or `NSURLError` strings in
the UI.

MUST map at least: camera / local-network / VPN permission denied; pair
unreachable; pair rejected; lease incomplete; VPN configuration failed; **tunnel
superseded by another VPN** (e.g. Tailscale) with copy that only one VPN can be
active and Retry when Moorlan can resume; unpair not on Off Wi‑Fi; unpair not
acknowledged. Missing Wi‑Fi name is **not** a user-facing error.

## 9. Non-goals (v1)

- IPv6 tunnel pool / IPv6 Internet exit; import foreign WireGuard configs
- TLS / invites on the control plane; offline unpair queue
- Always-on VPN with zero Off SSIDs configured
- Hairpin via `home_networks` CIDR instead of SSID
- DNS/search overrides or phone-invented resolver fallbacks (except TEMP debug)
- Protocol versions other than v1; proving Internet reachability after pair
- Configuring the home router / CGNAT
- Shipping a Mac app in this tree (planned separately)
- Temporary-vs-save affordance beyond Home=temp / Settings=permanent (no “Save
  for this network” button required in v1)

## 10. Failure and recovery

- Permission denial and pair/unpair failures stay retryable without wiping user
  intent (pending scan, selected host).
- Incompatible or missing lease credential → clear re-pair guidance.
- Platform entitlement limits are constraints with Settings deep-links, not dead
  ends.
