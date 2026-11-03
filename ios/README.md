# PeerDoor iPhone app

An iOS 17+ app and Packet Tunnel extension for the [PeerDoor Linux server](../server/README.md).
WireGuardKit owns the WireGuard backend, typed configurations, IP ranges, endpoint
parsing and packet-tunnel adapter. The app does not implement cryptography,
packet forwarding, or a wg-quick parser.

## Build and signing

Requirements: macOS, Xcode with an iOS SDK, XcodeGen, and Go on PATH for the
vendored WireGuardKit Go bridge. From the monorepo root:

```bash
cd ios
xcodegen generate
open PeerDoor.xcodeproj
```

Set your development team in `project.yml` (`DEVELOPMENT_TEAM`) or both Xcode
application/extension targets. Use matching provisioning profiles with:

- Network Extensions: Packet Tunnel Provider.
- App Groups: `group.app.peerdoor`, on app and extension.
- Access Wi-Fi Information, on app and extension.
- Shared Keychain group: `<AppIdentifierPrefix>app.peerdoor.shared`.
- The app also retains its original `<AppIdentifierPrefix>app.peerdoor.ios`
  Keychain group to migrate identities from older versions.

The entitlement files contain these capabilities and are referenced by
`project.yml`; regenerating the project preserves them. `PeerDoorKeychainAccessGroup`
in each Info.plist expands to the shared group for the selected signing team.
If changing bundle identifiers/groups, update project settings, entitlement files,
Info.plist keychain-group entries, and `Shared/AppIdentity.swift` together.

Use a **physical iPhone** to validate camera, Local Network privacy, VPN permission,
roaming and on-demand behavior. An unsigned device compile is useful for checking
source compatibility but cannot exercise those features. The bundled historical
WireGuard Go bridge has an x86_64 simulator linker limitation; device builds are
the supported validation path here.

## Pair and create a profile

1. Start `peerdoor` on the server with its existing WireGuard interface up.
2. Join the server's home Wi-Fi and tap **Start QR scan** / the scanner icon.
3. Allow **Camera** when asked. If denied, the camera alert offers **Open Settings**.
4. Scan the server's version 3 pairing QR. The actual connection to its LAN URL
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

The pairing/unjoin service intentionally uses HTTP on the trusted home LAN and
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

Pairing now uses QR version 3 (LAN URL and server key, no invitation token).
Unjoin retains QR version 2. A version 1 or 2 pairing QR usually
means an old Linux binary is still running. Update the Linux server source and
rebuild it from `server/`, stop the old process, then explicitly run the new binary:

```bash
cd /path/to/peerdoor/server
go build -o peerdoor ./cmd/peerdoor
sudo ./peerdoor
```

Scan the newly printed QR, not a previous screenshot. For deletion, start the
new binary with `--unjoin` instead. Updating the iPhone app alone does not upgrade
the server or change a QR already printed by an older process.

## Routes and exit node

**Automatic** is the default routing mode:

| Network | Behavior |
| --- | --- |
| Physical Wi-Fi/Ethernet address on the server LAN | Disconnect / do not start |
| Other Wi-Fi | Exit node (full tunnel) |
| Explicitly trusted Wi-Fi | Subnet access (split tunnel) |
| Cellular | Subnet access (trusted by default) |
| Unknown network | Exit node |

Subnet mode includes the server-supplied tunnel prefixes and home LAN. Exit mode
adds `0.0.0.0/0` and `::/0` and sends DNS through the tunnel. The Linux server/router
must support forwarding, return routes, and Internet NAT for these routes to work;
see the server README. The current server provisions IPv4 device addresses, so it
does not provide IPv6 Internet connectivity.

The home Exit node toggle reflects the **effective** mode; changing it selects a
manual full/split override. Tap **Use automatic network policy**, or select
**Automatic** in Settings, to restore network defaults. Manual exit can be enabled
on cellular/trusted Wi-Fi; manual subnet mode can be selected on other Wi-Fi.
Home-LAN protection always wins, including over manual exit mode.

## Trusted Wi-Fi and background behavior

In Settings, choose **Allow Wi-Fi identification** when the Wi-Fi name is unavailable.
Apple may require **While Using the App + Precise Location** and Access Wi-Fi
Information capability before exposing the SSID. No location coordinates are used.
A denied/unavailable Wi-Fi name never becomes a trustable interface fingerprint.
See [Apple's fetchCurrent requirements](https://developer.apple.com/documentation/networkextension/nehotspotnetwork/fetchcurrent(completionhandler:)).

Tap **Trust** on the current named network to add it to the list and restore
Automatic mode. Remove it to use automatic exit routing again. Cellular starts
trusted and has its own setting. Network transitions fetch the new Wi-Fi identity;
an old SSID is not carried over to another association.

The Packet Tunnel extension independently monitors network changes and applies
the same policy through `WireGuardAdapter.update`. It shuts down upon detecting
the physical home LAN, including when the app is backgrounded. VPN `utun` addresses
are excluded from home-LAN detection.

When the home Wi-Fi name is available, Apple's native on-demand rules disconnect
on that SSID and reconnect away from it. Open Settings on home Wi-Fi and allow
identification to enable this behavior. Without a known home SSID, the extension
still stops on the home subnet, but automatic background reconnection after that
stop is disabled to avoid an on-demand restart loop; reopen the app or Connect
when away. Same-LAN detection uses physical IPv4 subnet membership and is a
best-effort convenience: overlapping private subnets can look like home.

## Delete a profile from both ends

On the Linux host, start `peerdoor --unjoin`. On home Wi-Fi, select **Settings →
Paired host → Delete profile** and scan its public unjoin QR (the main scanner also
accepts it). Confirm the named saved host.

The app matches the server public key, contacts the **current scanned LAN URL**,
and supplies the saved per-peer HMAC credential. After HTTP 204, it removes only
that host's native VPN profile, its extension settings and saved host/lease.
The shared Keychain identity remains because other hosts may use it. A network,
server-save/apply or local profile-cleanup failure retains the pairing/credential for
retry. Unknown servers are rejected and there is no offline deletion queue.
Old pairings without an unjoin credential need to pair again first.

## Storage and implementation

- `PeerDoor/`: SwiftUI screens, AVFoundation scanner, native profile management,
  real LAN permission checks, CoreLocation/NEHotspotNetwork Wi-Fi access.
- `PeerDoorCore/`: Codable protocol models, URLSession pairing/deletion, routing
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
swift test --package-path ios/PeerDoorCore
xcodebuild -project ios/PeerDoor.xcodeproj -scheme PeerDoor \
  -sdk iphoneos -destination 'generic/platform=iOS' \
  -derivedDataPath /tmp/peerdoor-build CODE_SIGNING_ALLOWED=NO build
```

Core tests cover pairing/unjoin QR dispatch, target matching, failed/offline
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
- Deletion is confirmed on the reachable home LAN using the server's unjoin QR;
  there is no offline deletion queue or delete-over-VPN acknowledgement protocol.
- Pairing QR versions 1 and 2 are unsupported. Update app and server together.
  Stored legacy records can be read,
  but must be re-paired against the current server to obtain a deletion credential.

Enrollment is open to any trusted LAN user while the server process is running.
The app checks the returned server key against the scanned version 3 QR. This is
an identity consistency check, not authentication of the HTTP transport. Server
peers from older versions outside the managed block remain unmanaged; the tool
will not adopt or delete them. See the server README for migration limitations.
