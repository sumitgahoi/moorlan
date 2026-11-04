# Architecture

`server/` is an independent Linux Go module. `ios/` contains the iPhone app, core
Swift package, Packet Tunnel extension and vendored WireGuardKit. See their READMEs
for setup and protocol details.

## Server

Go net reads LAN/interface addresses and MTU. wgctrl reads/configures the existing
WireGuard interface. Pairing uses trusted-LAN HTTP and a version 1 QR containing
the LAN URL and server public key. Request and response bodies are plaintext JSON.
No invitation token or expiry; multiple devices can enroll until the admin stops
the process. An explicit endpoint overrides STUN; there is no LAN-only public
endpoint fallback.

SQLite persists managed public-key/address assignments before they are applied.
The allocator picks the lowest free /32 within one private IPv4 subnet, reserving
saved/live external peer ranges and committed assignments. Existing peers remain
unmanaged. A pure renderer sorts managed peers into a marked config block and
preserves all bytes outside it. The caller atomically saves the file and applies
only managed changes with wgctrl, preserving existing sessions. No interface
restart, wg-quick save, response cache, or rollback is needed. A lifetime interface
lock prevents another Moorlan process; one operation mutex serializes mutations.

Unpair deletes the assignment and journals the pending live removal in one database
transaction. Startup or retry finishes saving/applying before clearing the journal.
The HMAC credential is derived from the WireGuard private key, not stored in SQLite.
`--unpair` skips STUN and exposes DELETE only; its public QR is version 1.
`--remove` deletes a managed peer by public key (or unique label) without the
phone. Pairing stores the phone's device name as a label in SQLite and renders
it as a conf comment; labels may repeat.

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
