# Moorlan iPhone requirements

Authoritative product contract for the iPhone app and Packet Tunnel (`ios/`).
Normative. Protocol and lease fields MUST match
[server/REQUIREMENTS.md](../server/REQUIREMENTS.md).

## 1. Product intent

- Pair an iPhone with one or more Moorlan Linux WireGuard sites over **trusted
  home LAN HTTP**, then roam with a Packet Tunnel and phone-local network policy.
- v1: enroll / unpair, **multi-tunnel** list, subnet + exit per tunnel, automatic
  Home / Trusted / Away roles, polished status UI.
- Reuse WireGuardKit, NetworkExtension, AVFoundation, Network, CoreLocation, and
  Keychain. Do **not** reimplement WireGuard crypto, packet forwarding, or a
  wg-quick config parser.

## 2. Trust and permissions

- Control plane trust matches the server: plaintext HTTP on the household LAN
  while pair/unpair runs. No TLS or invite tokens in v1.
- **Camera** — scan pair/unpair QR; denial keeps scan retryable and offers Open
  Settings.
- **Local Network** — required for LAN HTTP to the QR host; probe with a real
  connection to that host:port; surface denial / Settings recovery without
  clearing a pending QR retry.
- **VPN configuration** — Apple “Add VPN Configurations” MUST be approved;
  install a distinct profile even when Home policy will keep the tunnel off.
- **Wi‑Fi Information** (+ Precise Location While Using when needed) — SSID only,
  no coordinates. Unavailable SSID → network id `unidentified`. NEVER trust a
  reused interface name (`en0`).
- Physical-device entitlement behavior is authoritative; simulator is not.

## 3. Ownership

| Owner | Owns | Does not own |
| --- | --- | --- |
| Server lease | `tunnel_network`, `home_networks`, `dns_servers`, `dns_search`, `endpoint`, `address`, server `public_key`, `unpair_token`, lease `mtu` / `persistent_keepalive` | Phone SSIDs, routing mode, which tunnel is selected |
| Phone | Multi-tunnel list, selected tunnel, Home / Trusted SSIDs, cellular-as-trusted, automatic vs manual exit/split, device label | Lease identity fields; DNS/search policy |
| Linux host | Forwarding / NAT for exit | iOS permissions / on-demand |

Phone MUST NOT override lease DNS/search, invent resolvers (including Cloudflare
fallback), or override lease tunnel identity fields (endpoint, address, server
key, mtu, keepalive).

**Naming:** phone “Home” SSIDs ≠ server `home_networks`. Home SSIDs are hairpin
(tunnel off). `home_networks` are away split-tunnel LAN routes.

## 4. Multi-tunnel

- Support many paired hosts. Each tunnel supports **subnet** and **exit**.
- Distinct native `NETunnelProviderManager` per host, keyed by server public key.
- Home UI: tunnel list / switcher with a clear active card (Tailscale-like host
  list energy; NordVPN-like status clarity — patterns, not clones).
- Exactly one **selected** tunnel drives automatic activation; switching MUST be
  explicit and reversible.
- Pairing another host MUST NOT delete existing tunnels. Unpair removes **one**
  host only; the shared Keychain client identity is retained for other hosts.

## 5. Routing (per selected tunnel)

### Network roles (Home ≠ Trusted)

| Role | Meaning | Automatic default |
| --- | --- | --- |
| **Home** SSID | Already on that LAN | Tunnel **off** (hairpin). Wins over manual exit. |
| **Trusted** Wi‑Fi | Known safe network that is not Home | **Subnet** only |
| **Away** / unidentified Wi‑Fi | Assume hostile | **Exit** |
| **Cellular** | Trusted by default | **Subnet** (unless user turns off cellular-as-trusted → exit) |

Trusted does **not** cover Home. Collapsing them would subnet-route on the home
LAN and hairpin. First-run copy MUST explain the three Wi‑Fi roles in one short
sentence each (dismissible coach).

When the user joins a **new named** Wi‑Fi, prompt to set Home, Trusted, or leave
as Away — never assign silently. Marking Home → disconnect-default; marking
Trusted → subnet-default.

### Modes

- **Automatic** (default), manual **exit**, manual **split**.
- Manual overrides Automatic except **Home always disconnects**.
- Policy MUST run in the app **and** the Packet Tunnel extension on path
  changes.
- On-demand: when ≥1 Home SSID is known → disconnect on those SSIDs / connect
  elsewhere; with zero Home SSIDs, disable on-demand (avoid reconnect loops after
  a self-stop at home).

### AllowedIPs and DNS

- Split: `tunnel_network ∪ home_networks`.
- Exit: that set plus `0.0.0.0/0` and `::/0`.
- DNS/search: lease `dns_servers` (required) and optional `dns_search` only.

## 6. Pair / unpair

Protocol MUST match [server/REQUIREMENTS.md](../server/REQUIREMENTS.md) §7.

### Pair

- QR v1: `v`, `pair_url` (`http`, path `/v1/pair` only), `server_public_key`. No
  invite token.
- `POST /v1/pair` with peer `public_key` and editable device **label**.
- Verify lease `public_key` equals QR `server_public_key`.
- Persist lease; install VPN profile. On success: cheerful confirmation, then
  status home showing the new tunnel. Prefer marking current SSID as Home when
  identifiable; preserve prior Home/Trusted sets on re-pair of the same host.
- Pair progress: Scan → Reach server → Save VPN profile (cancellable).

### Unpair

- QR v1: `action: unpair`, `server_public_key`, `unpair_url`. Token NOT in QR.
- Match saved host by `server_public_key`. Prefer scanned `unpair_url`.
- If the profile has Home SSIDs, require the phone on one of them.
- `DELETE` with peer `public_key` + stored `unpair_token`. Success is **HTTP 204
  only**, then remove that host’s VPN profile and local host record.
- Confirm destructive unpair naming the host. On failure, keep local state for
  retry. No offline deletion queue. Missing `unpair_token` → re-pair first.

## 7. Storage

| Store | Content |
| --- | --- |
| App storage (host records) | Paired hosts: QR card, **full lease including `unpair_token`**, Home/Trusted SSIDs, selection, label, policy knobs |
| App Group (`group.app.moorlan`) | Non-secret extension `TunnelProfile` per host — **strip `unpair_token`**; **no** private key |
| Keychain (shared group) | One long-lived client WireGuard private key (`AfterFirstUnlockThisDeviceOnly`); survives unpair of a single host |
| System | Per-host `NETunnelProviderManager` |

`unpair_token` lives only in the **app host/lease record**. The extension never
sees it. Keychain is identity only, not the unpair credential.

## 8. UX / polish

### Visual and HIG

- System SwiftUI: SF Pro, semantic colors, `NavigationStack`, inset grouped
  `List` / `Form`, SF Symbols, standard toolbars and sheets. No custom brand
  theme, status orbs, or glass chrome that fights iOS.
- Cheerful calm: clear success for “Connected”; soft warning for unprotected /
  hostile-network exit — never alarmist copy for normal states.
- Status hero in plain English, e.g. “Connected · Home access”, “Connected · Full
  protection”, “Off at home”, “Paused — another VPN is active”.
- Empty state: `ContentUnavailableView` + primary “Scan to pair”.
- Technical details (keys, endpoints) behind disclosure / detail — not on the
  home hero.
- Accessibility: Dynamic Type, VoiceOver for status and tunnel switcher, Reduce
  Motion respected. Haptics only on successful pair/connect when appropriate.
- Household tone: warm, competent, brief. No dark-pattern urgency. No marketing
  VPN upsell chrome. Inspire status clarity from Tailscale/NordVPN; do not
  pixel-clone them.

### Errors

Every failure MUST show **title + one plain sentence + primary action** (Retry /
Open Settings / OK). No raw NetworkExtension, POSIX, or `NSURLError` strings in
the UI.

MUST map at least: camera / local-network / VPN permission denied; pair
unreachable; pair rejected; lease incomplete; VPN configuration failed; **tunnel
superseded by another VPN** (e.g. Tailscale) with copy that only one VPN can be
active and Retry when Moorlan can resume; unpair not on Home Wi‑Fi; unpair not
acknowledged; Wi‑Fi name unavailable.

## 9. Non-goals (v1)

- macOS; IPv6 tunnel pool / IPv6 Internet exit; import foreign WireGuard configs
- TLS / invites on the control plane; offline unpair queue
- Always-on VPN with zero Home SSIDs configured
- Hairpin via `home_networks` CIDR instead of SSID
- DNS/search overrides or phone-invented resolver fallbacks
- Protocol versions other than v1; proving Internet reachability after pair
- Configuring the home router / CGNAT

## 10. Failure and recovery

- Permission denial and pair/unpair failures stay retryable without wiping user
  intent (pending scan, selected host).
- Incompatible or missing lease credential → clear re-pair guidance.
- Platform entitlement limits are constraints with Settings deep-links, not dead
  ends.
