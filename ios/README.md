# Moorlan iPhone app

iOS 17+ app and Packet Tunnel for the [Moorlan Linux server](../server/README.md).
WireGuardKit owns crypto and the tunnel adapter. Contract:
[REQUIREMENTS.md](REQUIREMENTS.md). Design: [ARCHITECTURE.md](ARCHITECTURE.md).

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

Validate on a **physical iPhone** (camera, Local Network, VPN, roaming). Device
builds are the supported path.

## Pair

1. On the server: empty WG device managed by Moorlan, then
   `sudo moorlan --pair --interface wg0`.
2. Join home Wi‑Fi; open Moorlan → scan the pair QR.
3. Allow Camera, Local Network, and Add VPN Configuration when prompted.
4. The app saves the lease and installs a distinct VPN profile for that host.

Denial of Camera/Local Network keeps the scan retryable and offers Open Settings.
See [REQUIREMENTS.md](REQUIREMENTS.md) §2 and §6.

## Day to day

- **Select a tunnel** from the home list (multi-host). Only the selected tunnel
  auto-activates.
- **Automatic** (default): Home → off; Trusted Wi‑Fi / cellular → subnet; other
  Wi‑Fi → exit. Manual Exit / Split override Automatic except Home always stays
  off.
- Mark SSIDs as Home or Trusted in Settings (join the network first). New named
  Wi‑Fi should prompt for a role.
- **Unpair:** on the server run `sudo moorlan --unpair --interface wg0`; in the
  app choose Delete profile, scan the unpair QR on Home Wi‑Fi. Only **HTTP 204**
  clears the local profile. Other tunnels and the shared Keychain identity stay.

## Networks

| Network | Automatic default |
| --- | --- |
| Home SSID | Tunnel off (hairpin) |
| Trusted Wi‑Fi | Subnet |
| Cellular (trusted by default) | Subnet |
| Other / unidentified Wi‑Fi | Exit |

Home ≠ Trusted. DNS comes from the server lease only. Full matrix and UX rules:
[REQUIREMENTS.md](REQUIREMENTS.md) §5 and §8.

## Storage

| Store | Holds |
| --- | --- |
| App host record | Lease including `unpair_token` |
| App Group | Extension profile — **no** token, **no** private key |
| Keychain | One client WireGuard private key |
| System | Per-host `NETunnelProviderManager` |

## Development

```bash
swift test --package-path ios/MoorlanCore
```

Camera, privacy prompts, VPN signing, and roaming require a signed build on a
physical iPhone.
