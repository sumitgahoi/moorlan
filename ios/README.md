# Moorlan iPhone / iPad app

iOS 17+ app and Packet Tunnel for the [Moorlan Linux server](../server/README.md)
(iPhone and iPad). A Mac client is planned with the same in-app JSON QR pair
flow; it is not in this tree yet. WireGuardKit owns crypto and the tunnel
adapter. Contract: [REQUIREMENTS.md](REQUIREMENTS.md). Design:
[ARCHITECTURE.md](ARCHITECTURE.md).

## Build

Needs macOS, Xcode, [XcodeGen](https://github.com/yonaskolb/XcodeGen), and Go on
PATH (vendored WireGuardKit Go bridge).

```bash
cd ios
xcodegen generate
open Moorlan.xcodeproj
```

Set `DEVELOPMENT_TEAM` in `project.yml` (or both app/extension targets). Profiles
must include:

- Packet Tunnel Network Extension
- App Group `group.app.moorlan` (app + extension)
- Access Wi‑Fi Information (app + extension)
- Keychain group `<AppIdentifierPrefix>app.moorlan.shared`

Entitlements are wired via `project.yml`. Changing bundle IDs/groups means
updating project settings, entitlements, Info.plist keychain entries, and
`Shared/AppIdentity.swift` together.

Validate on a **physical iPhone or iPad** (camera, Local Network, VPN, roaming).
Device builds are the supported path.

## Pair

1. On the server: WireGuard up and managed by Moorlan, then
   `sudo moorlan --pair` (add `--interface` if the YAML lists more than one).
2. Join home Wi‑Fi; open the **Camera** app and scan the QR (opens Moorlan).
3. Allow Local Network and Add VPN Configuration when prompted.
4. The app saves the lease, marks that Wi‑Fi **Off**, and installs a VPN profile.
   The first tunnel becomes the on-demand **Default** automatically.

In-app scan is a fallback if Camera did not open the app. See
[REQUIREMENTS.md](REQUIREMENTS.md) §2 and §6.

## Day to day

- **Off / Split / Full** from the tunnel-list menu on the current network —
  saved for next time. App launch only shows status (does not bounce the VPN).
- **Default** tunnel (at most one) auto-connects when away from Off Wi‑Fi. After
  pairing a second house, the app asks whether to make it the default.
- **Unpair:** on the server run `sudo moorlan --unpair --interface wg0`; in the
  app scan the unpair QR while on an Off Wi‑Fi. Only **HTTP 204** clears the
  local profile. Other tunnels and the shared Keychain identity stay.

## Networks

| Network | Permanent default |
| --- | --- |
| Unmarked Wi‑Fi | Full |
| Cellular | Full |
| Wi‑Fi at pair time | Off (saved) |

DNS comes from the server lease only. Full matrix and UX rules:
[REQUIREMENTS.md](REQUIREMENTS.md) §5 and §8.

## Storage

| Store | Holds |
| --- | --- |
| App host record | Lease including `unpair_token` |
| App policy | Durable Off/Split/Full map |
| App Group | Extension profile — **no** token, **no** private key |
| Keychain | One client WireGuard private key |
| System | Per-host `NETunnelProviderManager` |

## Development

```bash
swift test --package-path ios/MoorlanCore
```

Camera, privacy prompts, VPN signing, and roaming require a signed build on a
physical iPhone or iPad.
