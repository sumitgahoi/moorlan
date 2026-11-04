# Requirements

## Monorepo

- `server/`: Linux Go service and its module, tests and README.
- `ios/`: iPhone app, Packet Tunnel extension, core Swift package and README.

## Server

- Pair with an existing Linux WireGuard device named `moorlan0` / `moorlanN`
  using trusted-LAN HTTP. Host owns the device; Moorlan owns all peers on it.
- Version 1 pairing QR: LAN URL and server public key, no invitation token;
  plaintext JSON over trusted-LAN HTTP including the phone device name as a
  label (duplicates allowed). Multiple devices can enroll while the admin
  leaves the process running.
- Explicit endpoint or STUN public IPv4 plus configured WG port; no LAN fallback.
- One private IPv4 interface subnet (/16–/30), automatic /32 allocation from
  live peers and SQLite assignments; no pool override. No wg-quick/networkd
  peer file writes.
- SQLite is authoritative for enrolled peers; `--rehydrate` applies them live
  after boot. Pair/unpair/`--remove` apply mutations via wgctrl.
- `--init` exclusively creates a database for an empty device and never overwrites
  an existing file. Every other mode requires an initialized database; no automatic
  creation on startup or rehydrate.
- One process per interface and one mutation mutex. Failed changes are retryable.
- Unpair deletes the assignment and journals live removal until applied. Phone
  deletion uses the version 1 public QR and per-peer HMAC. Admin deletion uses
  `--remove` by WireGuard public key only. No offline client queue.

## iPhone

- Request camera access for scanning and Local Network access for LAN requests,
  with denial/retry/Settings recovery.
- Scan and pair, save the lease, and create a distinct native VPN profile per host,
  including when hairpin policy keeps the tunnel off at home.
- Provide server subnet access and manual/automatic exit routing.
- Automatic: exit on other Wi-Fi; split on explicit trusted Wi-Fi and cellular.
- Home Wi‑Fi always disconnects when the current SSID is in the profile’s home
  SSID set (Add current network in Settings). Home CIDRs from the server
  (`-home-cidrs`) are for split-tunnel routes when away, not hairpin. Pairing
  HTTP uses an explicit `-private-endpoint host:port` on the server.
- Never trust unknown Wi-Fi by a reused interface name; use Apple's Wi-Fi identity.
- Run policy in the Packet Tunnel extension, and native on-demand rules where the
  home SSID is known, with documented platform/permission limitations.
- Delete profiles using the server unpair QR; clear locally only after acknowledgement.
- Reuse WireGuardKit, NetworkExtension, AVFoundation, Network, CoreLocation and Keychain.
