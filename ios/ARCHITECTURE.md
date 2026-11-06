# Moorlan iOS architecture

Architecture for the iPhone / iPad app and Packet Tunnel (`ios/`). Product rules
live in [REQUIREMENTS.md](REQUIREMENTS.md); this file describes components, data
flow, and package boundaries. Protocol and lease fields match
[server/REQUIREMENTS.md](../server/REQUIREMENTS.md).

## 1. Role and boundary

- App + Packet Tunnel extension. **WireGuardKit** owns crypto, typed config, and
  the packet-tunnel adapter. Moorlan does not reimplement WireGuard or parse
  wg-quick text.
- **Multi-tunnel:** many paired hosts; one **on-demand-active** (default) tunnel
  may auto-connect. The device owns Off / Split / Full per network. Server owns
  lease identity and DNS.
- **Mac (planned):** same `moorlan://` QR via in-app camera scan; no Mac app
  target in this package map yet.

## 2. Ownership and state

```mermaid
flowchart LR
  server[Moorlan server] -->|lease HTTP| app[Moorlan app]
  app -->|host record + unpair_token| appStore[App storage]
  app -->|strip token| appGroup[App Group TunnelProfile]
  app -->|private key| keychain[Shared Keychain]
  app -->|NETunnelProviderManager| systemVPN[System VPN]
  ext[Packet Tunnel] --> appGroup
  ext --> keychain
  ext -->|WireGuardKit| wg[WireGuard]
  path[Path + SSID] --> app
  path --> ext
```

| Owner | Responsibility |
| --- | --- |
| Server lease | `tunnel_network`, `home_networks`, `dns_servers`, `dns_search`, endpoint, address, keys, token |
| App storage | Host records (full lease including `unpair_token`), selection, on-demand-active id, permanent routing map |
| App Group | Extension profile per host — no private key, no `unpair_token` |
| Keychain | One long-lived client WireGuard private key |
| System VPN | Per-host `NETunnelProviderManager` |
| App + extension | Path/SSID → AllowedIPs + connect/disconnect |

## 3. Package map

| Target / area | Owns |
| --- | --- |
| `Moorlan` app | SwiftUI (Home, Settings, Scanner fallback), `onOpenURL` for `moorlan://`, `TunnelManager`, permissions UX, tunnel list / default |
| `MoorlanCore` | Lease, QR / `ScannedCode`, `PairingClient`, `TunnelPolicy`, `ServerStore`, `IdentityStore`, path/SSID helpers, errors |
| `PacketTunnel` | `NE` provider; load App Group profile; apply permanent policy; WireGuardKit start/update/stop |
| `Shared` | `AppIdentity`, `WireGuardProfileBuilder` |
| `Vendor/wireguard-apple` | Vendored WireGuardKit |

Dependency direction: app and extension → MoorlanCore + Shared → WireGuardKit.
Pairing HTTP and unpair credentials stay in the app process; the extension never
reads `unpair_token`.

## 4. Critical flows

### Pair

1. System Camera (primary) or in-app fallback scans `moorlan://v1/pair?…` on
   home Wi‑Fi → reach control `url` on the LAN.
2. `POST /v1/pair` with client public key + device label.
3. Persist host + full lease (including `unpair_token`) in app storage.
4. Mark current SSID permanently **Off** when identifiable.
5. Install `NETunnelProviderManager` for this server key.
6. Write App Group `TunnelProfile` with token stripped.
7. First/only tunnel → auto on-demand active; else ask to make default.
8. Show status home with the new tunnel selected.

### Policy (roaming)

1. Observe network path + Apple Wi‑Fi identity (SSID).
2. **Effective** routing (app): temporary Home override for current path, else
   permanent map (Wi‑Fi default Full; cellular default Split).
3. Extension / on-demand: **permanent** map only.
4. Off → disconnect; Split → subnet AllowedIPs; Full → plus `0.0.0.0/0` (never
   `::/0`). DNS host routes required because WireGuardKit sends all queries to
   lease DNS.
5. On-demand only on the on-demand-active manager when ≥1 permanent Off SSID
   exists.

### Unpair

1. Confirm; require Off Wi‑Fi when permanent Off SSIDs are configured.
2. Scan unpair QR → match host by `server_public_key`.
3. `DELETE /v1/pair` with peer key + app-stored `unpair_token`.
4. On **204** only: remove that host’s VPN profile, App Group blob, and app
   host record. Keep Keychain identity and other tunnels. Repair on-demand
   default per REQUIREMENTS §4.

### VPN conflict

If another VPN (e.g. Tailscale) supersedes Moorlan, surface a plain-English
error (title + sentence + Retry). Only one VPN can be active at a time.

## 5. Storage

| Store | Content |
| --- | --- |
| App storage | Paired hosts: card, full lease (`unpair_token` included), selected id, on-demand-active id, label |
| App storage | Permanent `networkRouting` + `cellularRouting` |
| App Group `group.app.moorlan` | `TunnelProfile` per host for the extension — strip `unpair_token`; no private key |
| Keychain shared group | Client WireGuard private key (`AfterFirstUnlockThisDeviceOnly`) |
| System | One `NETunnelProviderManager` per server public key |

## 6. UX architecture

- HIG-native SwiftUI (`NavigationStack`, inset grouped lists/forms, SF Symbols).
  See [REQUIREMENTS.md](REQUIREMENTS.md) §8.
- Home: temporary Off/Split/Full; tunnel list with Default / Use as default.
- Settings: permanent cellular + Wi‑Fi routing.
- Errors: title + one sentence + action. No raw NE / URL error strings in UI.
- Accessibility: Dynamic Type, VoiceOver, Reduce Motion.

## 7. What this architecture excludes

See [REQUIREMENTS.md](REQUIREMENTS.md) §9: no Mac app in this tree yet, no
offline unpair queue, no hairpin via CIDR, no phone-invented DNS, no foreign
config import.
