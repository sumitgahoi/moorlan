# Moorlan iPhone app

An iOS 17+ app and Packet Tunnel extension for the [Moorlan Linux server](../server/README.md).
WireGuardKit owns the WireGuard backend, typed configurations, IP ranges, endpoint
parsing and packet-tunnel adapter. The app does not implement cryptography,
packet forwarding, or a wg-quick parser.

## Build and signing

Requirements: macOS, Xcode with an iOS SDK, XcodeGen, and Go on PATH for the
vendored WireGuardKit Go bridge. From the monorepo root:

```bash
cd ios
xcodegen generate
open Moorlan.xcodeproj
```

Set your development team in `project.yml` (`DEVELOPMENT_TEAM`) or both Xcode
application/extension targets. Use matching provisioning profiles with:

- Network Extensions: Packet Tunnel Provider.
- App Groups: `group.app.moorlan`, on app and extension.
- Access Wi-Fi Information, on app and extension.
- Shared Keychain group: `<AppIdentifierPrefix>app.moorlan.shared`.
- The app also retains its original `<AppIdentifierPrefix>app.moorlan.ios`
  Keychain group to migrate identities from older versions.

The entitlement files contain these capabilities and are referenced by
`project.yml`; regenerating the project preserves them. `MoorlanKeychainAccessGroup`
in each Info.plist expands to the shared group for the selected signing team.
If changing bundle identifiers/groups, update project settings, entitlement files,
Info.plist keychain-group entries, and `Shared/AppIdentity.swift` together.

Use a **physical iPhone** to validate camera, Local Network privacy, VPN permission,
roaming and on-demand behavior. An unsigned device compile is useful for checking
source compatibility but cannot exercise those features. The bundled historical
WireGuard Go bridge has an x86_64 simulator linker limitation; device builds are
the supported validation path here.

## Pair and create a profile

1. Start `moorlan` on the server with its existing WireGuard interface up.
2. Join the server's home Wi-Fi and tap **Start QR scan** / the scanner icon.
3. Allow **Camera** when asked. If denied, the camera alert offers **Open Settings**.
4. Scan the server's version 1 pairing QR. The actual connection to its LAN URL
   triggers **Local Network** access. Allow it; denial and reachability errors keep
   the QR retryable and offer Settings recovery.
5. Approve Apple's **Add VPN Configurations** prompt. The app installs a distinct
   `NETunnelProviderManager` profile for this host, even when home-LAN protection
   means it must not start the tunnel there.
6. Select saved profiles from the menu below the app title. Only the selected
   profile is managed for automatic activation; other profiles retain their own
   settings instead of sharing one overwritten global configuration.

Local Network is required to contact the private pairing/deletion service; camera
is needed for QR scanning. Apple provides no separate Local Network authorization
request API. The app uses an `NWConnection` to the scanned address and waits for
permission/readiness rather than cancelling a fixed-length dummy browse.
See [Apple's Local Network privacy guidance](https://developer.apple.com/documentation/technotes/tn3179-understanding-local-network-privacy).

### HTTP pairing and App Transport Security

The pairing/unpair service intentionally uses HTTP on the trusted home LAN and
its QR contains a dynamic numeric IP address. The app's `NSAppTransportSecurity`
dictionary therefore sets `NSAllowsArbitraryLoads = YES`. Do **not** add
`NSAllowsLocalNetworking` alongside it: on modern iOS, the presence of that key
causes the broader arbitrary-load allowance to be ignored. Local Network privacy
permission remains a separate requirement. See
[Apple's ATS precedence documentation](https://developer.apple.com/documentation/bundleresources/information-property-list/nsapptransportsecurity/nsallowsarbitraryloads).

After changing this setting, rebuild and reinstall/run the iPhone app from Xcode.
The installed app's compiled Info.plist must contain the corrected settings;
restarting the Linux server cannot change them.

### QR version mismatch

Pairing and unpair use QR protocol version 1 (LAN URL and server key). A
mismatched QR version usually means an old Linux binary is still running.
Update the Linux server source and rebuild it from `server/`, stop the old
process, then explicitly run the new binary:

```bash
cd /path/to/moorlan/server
go build -o moorlan ./cmd/moorlan
sudo moorlan --pair   # enrollment QR; requires --add-interface first; scan on home Wi‑Fi
```

Scan the newly printed QR, not a previous screenshot. For deletion, start the
new binary with `--unpair` instead. Updating the iPhone app alone does not upgrade
the server or change a QR already printed by an older process.

## Routes and exit node

**Automatic** is the default routing mode:

| Network | Behavior |
| --- | --- |
| Home Wi‑Fi (SSID marked in Settings) | Disconnect / do not start |
| Other Wi-Fi | Exit node (full tunnel) |
| Explicitly trusted Wi-Fi | Subnet access (split tunnel) |
| Cellular | Subnet access (trusted by default) |
| Unknown network | Exit node |

Subnet mode includes the server-supplied tunnel prefixes and home CIDRs. Exit mode
adds `0.0.0.0/0` and `::/0`. When the lease includes `dns`, both modes use those
resolvers (and optional `dns_search` like `home.arpa` for short names); otherwise
exit mode falls back to `1.1.1.1` / `1.0.0.1`. In Settings → **Tunnel on this
iPhone**, you can override DNS, search domains, keepalive, and MTU for this phone
without changing the server lease (server key / endpoint / client IP stay
read-only). AllowedIPs follow the Away default routing mode. The Linux server/router
must support forwarding, return routes, and Internet NAT for these routes to work;
see the server README. The current server provisions IPv4 device addresses, so it
does not provide IPv6 Internet connectivity.

The home Exit node toggle reflects the **effective** mode; changing it selects a
manual full/split override. Tap **Use automatic network policy**, or select
**Automatic** in Settings, to restore network defaults. Manual exit can be enabled
on cellular/trusted Wi-Fi; manual subnet mode can be selected on other Wi-Fi.
Home Wi‑Fi protection always wins, including over manual exit mode.

## Home Wi‑Fi, trusted Wi‑Fi, and background behavior

In Settings, choose **Allow Wi-Fi identification** when the Wi-Fi name is unavailable.
Apple may require **While Using the App + Precise Location** and Access Wi-Fi
Information capability before exposing the SSID. No location coordinates are used.
A denied/unavailable Wi-Fi name never becomes a trustable interface fingerprint.
See [Apple's fetchCurrent requirements](https://developer.apple.com/documentation/networkextension/nehotspotnetwork/fetchcurrent(completionhandler:)).

**Networks:** in Settings, set each named Wi‑Fi to **Home** (tunnel off),
**Trusted** (Home LAN only in Automatic), or **Normal** (Exit Node in Automatic).
Join the SSID first so it can be identified. Pairing also marks the current SSID
as Home when it is already identified. Cellular starts trusted and has its own
setting. Network transitions fetch the new Wi-Fi identity; an old SSID is not
carried over to another association.

The Packet Tunnel extension independently monitors network changes and applies
the same SSID policy through `WireGuardAdapter.update`, including when the app is
backgrounded. Without any home SSIDs configured, on-demand auto-reconnect is
disabled to avoid a restart loop; add home networks in Settings.

## Delete a profile from both ends

On the Linux host, start `moorlan --unpair`. On home Wi-Fi, select **Settings →
Paired host → Delete profile** and scan its public unpair QR (the main scanner also
accepts it). Confirm the named saved host.

At pair time the app sends a **device label** for admin hints (`moorlan
--list-peers`). Set it in Settings → This iPhone. iOS 16+ returns a generic
model name from `UIDevice.current.name` unless Apple grants a restricted
entitlement, so the editable label is the reliable source. Re-pair to update an
existing peer’s label; admin `--remove-peer` uses the peer public key only.

The app matches the server public key, contacts the **current scanned LAN URL**,
and supplies the saved per-peer HMAC credential in the DELETE body. After
HTTP 204, it removes only
that host's native VPN profile, its extension settings and saved host/lease.
The shared Keychain identity remains because other hosts may use it. A network,
server-save/apply or local profile-cleanup failure retains the pairing/credential for
retry. Unknown servers are rejected and there is no offline deletion queue.
Old pairings without an unpair credential need to pair again first.

## UI

The SwiftUI shell uses Apple's native components and Human Interface Guidelines:
system typography, semantic colors, SF Symbols, standard navigation, forms,
sheets, and controls. Do not add a custom theme, fonts, glass panels, or forced
dark chrome unless there is a documented functional need.

Home is a single status composition, not a settings dump. Technical lease and
key details live under Settings → Advanced.

| Screen | Pattern |
| --- | --- |
| Home | Phone ↔ house diagram (flowing green link when connected), status, live ↓/↑ rates, Exit Node toggle, Connect/Disconnect |
| Empty pairing | `ContentUnavailableView` with a bordered-prominent scan action |
| Settings | System `Form`: routing, single Networks list with Home/Trusted/Normal roles (help behind ⓘ), paired host + Advanced |
| Scanner | System sheet; camera preview only where needed; light/dark follows the device |

Connection diagram states: grey idle, accent connecting, green flowing connected
(faster when Exit Node is on), orange unreachable, muted at home.
Prefer outcome copy (“Home LAN only”, “All traffic via home”) over WireGuard
jargon on primary surfaces.

## Storage and implementation

- `Moorlan/`: SwiftUI screens, AVFoundation scanner, native profile management,
  real LAN permission checks, CoreLocation/NEHotspotNetwork Wi-Fi access.
- `MoorlanCore/`: Codable protocol models, URLSession pairing/deletion, routing
  policy, physical network classification, profile store and Keychain identity.
- `PacketTunnel/`: NEPacketTunnelProvider and WireGuardAdapter; policy remains active
  outside the foreground app.
- `Shared/`: capability identifiers and typed WireGuardKit profile construction.
- `Vendor/wireguard-apple/`: existing WireGuardKit and its Go bridge.

Private identity material is in the shared Keychain with
`AfterFirstUnlockThisDeviceOnly` accessibility. Per-profile App Group settings
contain no private key or deletion capability. Legacy rendered private configs
are removed after native profile migration. Pairing/deletion credentials remain
in the app's saved host record. No new VPN or wg-quick parser is implemented.

## Tests

From the monorepo root:

```bash
swift test --package-path ios/MoorlanCore
xcodebuild -project ios/Moorlan.xcodeproj -scheme Moorlan \
  -sdk iphoneos -destination 'generic/platform=iOS' \
  -derivedDataPath /tmp/moorlan-build CODE_SIGNING_ALLOWED=NO build
```

Core tests cover pairing/unpair QR dispatch, target matching, failed/offline
requests, routing defaults/overrides, default-route removal in split mode,
legacy trust migration, profile-data secrecy and IPv4 subnet boundaries. Physical
device permission dialogs, signing, native profile installation, actual forwarding,
DNS, background roaming and hairpin transitions still require a device/network test.

## LIMITATIONS

- iPhone/iOS 17+ and a properly signed Packet Tunnel extension are the supported
  client platform. macOS core tests are not a desktop VPN app. Physical device
  permission, routing and roaming tests are required; unsigned compilation cannot
  validate entitlement/provisioning behavior.
- The server supports one conventional private IPv4 subnet (`/16`–`/30`, normally
  `/24`) and single-address phone peers. IPv6 provisioning/Internet exit,
  site-to-site configuration and general WireGuard config import are unsupported.
  Server `/32`-only addresses and custom pool overrides are not supported for pairing.
- Exit mode requires working server forwarding/NAT. The app does not set up the
  router, bypass CGNAT, or prove Internet reachability from a successful pairing.
- Trust is based on a user-approved Wi-Fi SSID, not an authenticated network
  identity. Unavailable Wi-Fi identification stays untrusted in Automatic mode.
  Apple capabilities and, where needed, precise location permission are required.
- Native background auto-reconnect requires a known home SSID. Without one, the
  extension still stops on the home subnet, but returning away requires opening
  the app/Connect. Unconditional always-on behavior on every network is unsupported.
- Home-LAN classification is a physical IPv4 subnet check. Away networks reusing
  the same private subnet as home are unsupported for automatic classification.
- Deletion is confirmed on the reachable home LAN using the server's unpair QR;
  there is no offline deletion queue or delete-over-VPN acknowledgement protocol.
- Pairing QR versions 1 and 2 are unsupported. Update app and server together.
  Stored legacy records can be read,
  but must be re-paired against the current server to obtain a deletion credential.

Enrollment is open to any trusted LAN user while `--pair` is running (idle-stops after 2m with no success).
The app checks the returned server key against the scanned version 1 QR. This is
an identity consistency check, not authentication of the HTTP transport. See the
server README for the site conf / SQLite persistence model.
