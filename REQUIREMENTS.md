# Requirements

## Monorepo

- `server/`: Linux Go service and its module, tests and README.
- `ios/`: iPhone app, Packet Tunnel extension, core Swift package and README.

## Server

- Pair with an existing Linux WireGuard interface using trusted-LAN HTTP.
- Version 1 pairing QR: LAN URL and server public key, no invitation token;
  plaintext JSON over trusted-LAN HTTP including the phone device name as a
  label (duplicates allowed). Multiple devices can enroll while the admin
  leaves the process running.
- Explicit endpoint or STUN public IPv4 plus configured WG port; no LAN fallback.
- One private IPv4 interface subnet (/16–/30), automatic /32 allocation. Reserve
  existing saved/live routes and SQLite assignments; no pool override.
- SQLite is authoritative for enrolled peers. Preserve all config outside the
  marked block. Save atomically and apply only managed live changes via wgctrl.
- One process per interface and one mutation mutex. Failed changes are retryable;
  startup reconciles assignments and pending removals. No interface restart.
- Unpair deletes the assignment and journals live removal until applied. Phone
  deletion uses the version 1 public QR and per-peer HMAC. Admin deletion uses
  `--remove` by public key, or by label when unique. No offline client queue.
- Existing peers are never adopted or removed. Unsupported external edits,
  database loss and layout changes are documented in README LIMITATIONS.

## iPhone

- Request camera access for scanning and Local Network access for LAN requests,
  with denial/retry/Settings recovery.
- Scan and pair, save the lease, and create a distinct native VPN profile per host,
  including when hairpin policy keeps the tunnel off at home.
- Provide server subnet access and manual/automatic exit routing.
- Automatic: exit on other Wi-Fi; split on explicit trusted Wi-Fi and cellular.
- Home LAN always disconnects. Detect physical addresses, not the VPN's address.
- Never trust unknown Wi-Fi by a reused interface name; use Apple's Wi-Fi identity.
- Run policy in the Packet Tunnel extension, and native on-demand rules where the
  home SSID is known, with documented platform/permission limitations.
- Delete profiles using the server unpair QR; clear locally only after acknowledgement.
- Reuse WireGuardKit, NetworkExtension, AVFoundation, Network, CoreLocation and Keychain.
