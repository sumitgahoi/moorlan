# Moorlan

Pair an iPhone with an existing Linux WireGuard server by scanning a QR code.
This monorepo contains two independent applications:

| Folder | Application | Setup |
| --- | --- | --- |
| `server/` | Linux Go pairing/unpair service | [Server README](server/README.md) |
| `ios/` | iPhone app and Packet Tunnel extension using WireGuardKit | [iOS README](ios/README.md) |

## Quick start

On the Linux server:

```bash
cd server
go build -o moorlan ./cmd/moorlan
cp moorlan.conf.example moorlan.conf   # set private-endpoint, home-cidrs, optional public-endpoint
sudo ./moorlan
# Or flags (override the file):
sudo ./moorlan -private-endpoint 10.10.10.1:8756 -home-cidrs 10.10.0.0/16 -public-endpoint home.example.com:51820
```

On the iPhone, scan the QR on home Wi-Fi, allow Camera and Local Network, and
approve Apple's VPN profile prompt. Add each home SSID in Settings so the tunnel
stays off there. Select saved profiles from the home-screen menu.

## Automatic routing

| Current network | Default |
| --- | --- |
| Home Wi‑Fi (SSID marked in the app) | Tunnel off (hairpin protection) |
| Other Wi-Fi | Exit node / full tunnel |
| Wi-Fi on the trusted list | Subnet access / split tunnel |
| Cellular | Subnet access / split tunnel |

The Exit node toggle manually chooses full or split routing. **Automatic** in
Settings restores network defaults. Home Wi‑Fi takes precedence in every mode.
Add each home SSID in Settings (join it, then **Add**). Trust other Wi‑Fi names
for split routing; unidentified Wi‑Fi stays untrusted.

For deletion from the phone, run `sudo ./moorlan --unpair` (with `moorlan.conf`
or the usual flags) in `server/`, choose **Delete profile** in the app, scan the
unpair QR on home Wi-Fi, and confirm. The app retains its profile if the server
cannot acknowledge deletion. For a lost phone, run
`sudo ./moorlan --remove <device-public-key>` (or a unique device name). There is
no offline delete queue.

WireGuardKit handles encryption, packet routing and native configuration. Apple's
AVFoundation, Network, NetworkExtension, CoreLocation and Keychain APIs handle
scanning, permissions, VPN profiles, Wi-Fi identification and key storage. The
iPhone UI follows the same system SwiftUI patterns as Cove and Glance (see
[iOS README](ios/README.md#ui) and [Architecture](ARCHITECTURE.md)).

## Validation

```bash
(cd server && go test -race ./...)
swift test --package-path ios/MoorlanCore
```

Full camera, privacy prompts, VPN signing, roaming and home-LAN checks require a
properly signed build on a physical iPhone. See each application's README for
capabilities, network prerequisites, and build steps.

## LIMITATIONS

This MVP targets one conventional Linux/wg-quick home server with a single private
IPv4 tunnel subnet (`/16`–`/30`, normally `/24`) and individual phone addresses.
The home LAN must use a different subnet. There is no pool override, IPv6
provisioning, general site-to-site management, CGNAT relay, automatic NAT setup,
or offline deletion. Pairing and unpair QRs use protocol version 1.

SQLite stores assignments for peers enrolled through Moorlan. Only the marked
Moorlan config block is generated; existing peers remain admin-owned. One process
per interface applies targeted live updates without restarting WireGuard. Failed
changes are finished by retry or startup. Enrollment is open to trusted LAN users
until the process stops. Back up the config and database together.

Native iPhone signing,
privacy permissions and Wi-Fi identification are required for the corresponding
features. Background auto-reconnect requires a known home SSID; overlapping home
and away private networks cannot be reliably classified by subnet alone.

See [server limitations](server/README.md#limitations) and
[iOS limitations](ios/README.md#limitations) for the supported scope and recovery
behavior. Unsupported layouts fail explicitly rather than being guessed.
