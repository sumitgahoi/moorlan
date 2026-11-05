# Architecture

`server/` is an independent Linux Go module. `ios/` contains the iPhone app, core
Swift package, Packet Tunnel extension and vendored WireGuardKit. See their READMEs
for setup and protocol details.

## Server

Go net reads LAN/interface addresses and MTU. wgctrl reads/configures the existing
WireGuard interface. Pairing uses trusted-LAN HTTP and a version 1 QR containing
the LAN URL and server public key. Request and response bodies are plaintext JSON.
No invitation token or expiry; multiple devices can enroll until the admin stops
the process. A sticky `public-endpoint` (DDNS or static host:port) is required;
there is no STUN and no LAN-only public endpoint fallback.

The host owns the WireGuard device configuration; after `--add-interface`, Moorlan
owns all peers on it. Per-iface `/etc/moorlan/<iface>.conf` stores static site flags
(private endpoint, home CIDRs, public endpoint); CLI flags override the file. Peers
are never written there. SQLite persists public-key/address assignments before they are applied.
The allocator picks the lowest free /32 within one private IPv4 subnet, reserving
live peer ranges and committed assignments. No networkd or wg-quick peer file is
written. `--add-interface` is greenfield: refuses existing conf, DB, or rehydrate
unit, requires zero live peers, then creates all three. `--pair` and related modes
require that site conf and DB. Boot `--rehydrate` is a oneshot that fails until the
WG device is usable; systemd retries for about five minutes. Pair/unpair/remove-peer
reconcile before work. A lifetime interface lock prevents another Moorlan process;
one operation mutex serializes mutations. No interface restart is needed. The
release ships static linux amd64/arm64 binaries plus `.sha256` digests; operators
install to `/usr/local/bin/moorlan`. `--remove-interface` deletes conf, empty DB,
and unit when no peers remain.

Unpair deletes the assignment and journals the pending live removal in one database
transaction. Rehydrate or retry finishes live removal before clearing the journal.
The HMAC credential is derived from the WireGuard private key, not stored in SQLite.
`--unpair` exposes DELETE only; its public QR is version 1.
`--remove-peer` deletes a managed peer by WireGuard public key without the
phone. Pending removals retain the label so administrative retries can find them.
Pairing stores the phone's device name as a label in SQLite; labels may repeat.

## iPhone

AVFoundation scans action-specific QR payloads; URLSession performs pairing and
delete requests after an actual NWConnection triggers/checks local network access.
Each host has a native NETunnelProviderManager profile keyed by its server key.
App Group data is per profile and non-secret. The shared private identity is in
Keychain. The extension constructs WireGuardKit typed configurations and uses
WireGuardAdapter start/update/stop, without a text config builder/parser.

SwiftUI screens follow Apple HIG the same way as Cove and Glance: system
typography and semantic colors, `NavigationStack`, inset grouped `List`/`Form`,
standard toolbars, sheets, and SF Symbols. There is no custom brand theme,
status orb, or glass chrome. Home is a status hero plus grouped detail rows;
pairing empty state uses `ContentUnavailableView`; Settings is a system `Form`.

A shared policy defaults to exit on other Wi-Fi and subnet routing on trusted
Wi-Fi/cellular. Explicit split/exit overrides are available. Physical IPv4 home
subnet detection always disconnects; VPN addresses never classify a network as
home. SSIDs come from Apple's NEHotspotNetwork API, not interface fingerprints.
The extension runs policy while the UI is backgrounded. Known home SSIDs enable
native on-demand disconnect/reconnect rules; without one, reconnection after a
home-LAN stop requires foregrounding/Connect to avoid a restart loop.

Deletion runs on home LAN and waits for durable server acknowledgement before
removing that host's system VPN profile and stored settings. Other profiles and
the shared identity are retained. Lost responses and cleanup failures are retryable.
