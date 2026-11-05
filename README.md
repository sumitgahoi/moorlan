# Moorlan

Pair an iPhone with an existing Linux WireGuard server by scanning a QR code.
This monorepo contains two independent applications:

| Folder | Application | Setup |
| --- | --- | --- |
| `server/` | Linux Go pairing/unpair service | [Server README](server/README.md) |
| `ios/` | iPhone app and Packet Tunnel extension using WireGuardKit | [iOS README](ios/README.md) |

## Trusted home LAN only

**Moorlan is for a trusted home LAN.** Pairing and unpair use plaintext HTTP on
your private network with **no invitation token, no TLS, and no LAN
authentication**. While `moorlan --pair` is running, **anyone who can reach the
control address can enroll a device**. That is deliberate: security is lax by
design so a household setup stays simple. Do not expose the pairing port to the
Internet, untrusted VLANs, or guest Wi‑Fi. Stop `--pair` / `--unpair` when you
are done.

## Quick start

On the Linux server, bring up an empty WireGuard device (e.g. `wg0`), then:

```bash
TAG=v0.1.0  # pick a release tag
ARCH=amd64  # or arm64
ASSET="moorlan-linux-${ARCH}"
BASE="https://github.com/sumitgahoi/moorlan/releases/download/${TAG}"

curl -fsSL -o "${ASSET}" "${BASE}/${ASSET}"
curl -fsSL -o "${ASSET}.sha256" "${BASE}/${ASSET}.sha256"
sha256sum -c "${ASSET}.sha256"
sudo install -m 755 "${ASSET}" /usr/local/bin/moorlan

sudo moorlan --add-interface wg0   # site conf + peer DB + rehydrate unit
sudo moorlan --pair                # enrollment QR (home Wi‑Fi)
```

Or build from source: `cd server && go build -o moorlan ./cmd/moorlan` and
`sudo install -m 755 moorlan /usr/local/bin/moorlan`. See [server/README.md](server/README.md).

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

For deletion from the phone, run `sudo moorlan --unpair`, choose **Delete profile**
in the app, scan the unpair QR on home Wi-Fi, and confirm. The app retains its
profile if the server cannot acknowledge deletion. List enrolled devices with
`sudo moorlan --list-peers`. For a lost phone, run
`sudo moorlan --remove-peer <device-public-key>`.
There is no offline delete queue.

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

This MVP targets one conventional Linux WireGuard home server with a single private
IPv4 tunnel subnet (`/16`–`/30`, normally `/24`) and individual phone addresses.
The home LAN must use a different subnet. There is no pool override, IPv6
provisioning, general site-to-site management, CGNAT relay, automatic NAT setup,
or offline deletion. Pairing and unpair QRs use protocol version 1.

SQLite stores assignments per interface under `/var/lib/moorlan/<iface>.db`.
Site settings are `/etc/moorlan/<iface>.conf`. The host owns the device; Moorlan
owns all peers on it after `--add-interface`. Put the release binary at
`/usr/local/bin/moorlan`; use `--add-interface` / `--remove-interface` for devices.
`--add-interface` is greenfield only. A sticky `public-endpoint` (DDNS or static)
is required.

Do not change the WireGuard server private key under an existing peer DB, and do
not restore a lost DB from scratch while phones still hold leases — re-pair or
`--remove-peer` as needed.

Native iPhone signing,
capabilities, and store distribution remain outside this repository.
