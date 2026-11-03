# PeerDoor

Pair an iPhone with an existing Linux WireGuard server by scanning a QR code.
This monorepo contains two independent applications:

| Folder | Application | Setup |
| --- | --- | --- |
| `server/` | Linux Go pairing/unjoin service | [Server README](server/README.md) |
| `ios/` | iPhone app and Packet Tunnel extension using WireGuardKit | [iOS README](ios/README.md) |

## Quick start

On the Linux server:

```bash
cd server
go build -o peerdoor ./cmd/peerdoor
sudo ./peerdoor
# DDNS or an external UDP-port override:
sudo ./peerdoor -endpoint home.example.com:51820
```

On the iPhone, scan the QR on home Wi-Fi, allow Camera and Local Network, and
approve Apple's VPN profile prompt. A profile is installed even while the tunnel
stays off on the home LAN. Select saved profiles from the home-screen menu.

## Automatic routing

| Current network | Default |
| --- | --- |
| Server's home LAN | Tunnel off (hairpin protection) |
| Other Wi-Fi | Exit node / full tunnel |
| Wi-Fi on the trusted list | Subnet access / split tunnel |
| Cellular | Subnet access / split tunnel |

The Exit node toggle manually chooses full or split routing. **Automatic** in
Settings restores network defaults. Hairpin protection takes precedence in every
mode. Trust a specific Wi-Fi name in Settings; unidentified Wi-Fi stays untrusted.

For deletion, run `sudo ./peerdoor --unjoin` in `server/`, choose **Delete profile**
in the app, scan the unjoin QR on home Wi-Fi, and confirm. The app retains its
profile if the server cannot acknowledge deletion. There is no offline delete queue.

WireGuardKit handles encryption, packet routing and native configuration. Apple's
AVFoundation, Network, NetworkExtension, CoreLocation and Keychain APIs handle
scanning, permissions, VPN profiles, Wi-Fi identification and key storage.

## Validation

```bash
(cd server && go test -race ./...)
swift test --package-path ios/PeerDoorCore
```

Full camera, privacy prompts, VPN signing, roaming and home-LAN checks require a
properly signed build on a physical iPhone. See each application's README for
capabilities, network prerequisites, and build steps.

## LIMITATIONS

This MVP targets one conventional Linux/wg-quick home server with a single private
IPv4 tunnel subnet (`/16`–`/30`, normally `/24`) and individual phone addresses.
The home LAN must use a different subnet. There is no pool override, IPv6
provisioning, general site-to-site management, CGNAT relay, automatic NAT setup,
or offline deletion. Pairing uses QR version 3; unjoin retains version 2.

SQLite stores assignments for peers enrolled through PeerDoor. Only the marked
PeerDoor config block is generated; existing peers remain admin-owned. One process
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
