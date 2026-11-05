# Requirements

## Monorepo

- `server/`: Linux Go service and its module, tests and README.
- `ios/`: iPhone app, Packet Tunnel extension, core Swift package and README.

## Server

- Pair with an existing Linux WireGuard device (any path-safe name, default `wg0`)
  using trusted-LAN HTTP. **Trusted home LAN only:** plaintext HTTP, no invite
  token, no TLS; open enrollment while `--pair` runs is deliberate. Host owns
  the device; after `--add-interface`, Moorlan owns all peers on it (device must
  have zero peers when first added).
- Version 1 pairing QR: LAN URL and server public key, no invitation token;
  plaintext JSON over trusted-LAN HTTP including the phone device name as a
  label (duplicates allowed). Multiple devices can enroll while `--pair` runs;
  the process idle-stops after 2 minutes with no successful enroll/unpair.
  `--list-peers` prints label, public key, and address for enrolled peers.
- Sticky `public-endpoint` (DDNS or static host:port) is required; no STUN and
  no LAN-only public endpoint fallback.
- One private IPv4 interface subnet (/16–/30), automatic /32 allocation from
  live peers and SQLite assignments; no pool override. No wg-quick/networkd
  peer file writes.
- Per-iface `/etc/moorlan/<iface>.conf` stores static site flags; CLI flags
  override. Peers stay in SQLite. The release binary is installed to
  `/usr/local/bin/moorlan` (checksummed GitHub Release asset; no installer
  script). `--add-interface` is greenfield (refuses existing conf, DB, or
  rehydrate unit). `--remove-interface` deletes those when no peers remain.
- SQLite is authoritative for enrolled peers; boot `--rehydrate` applies them
  live (one attempt; systemd retries while the WG device is not yet usable).
  Pair/unpair/`--remove-peer` reconcile before work, then mutate via wgctrl.
- `--add-interface` requires `-private-endpoint`, `-home-cidrs`, and
  `-public-endpoint` flags (no interactive prompts); writes them to the site
  conf, creates a new database for an empty device, and never adopts an existing
  DB. `--pair`/`--unpair` require an existing site conf.
- One process per interface and one mutation mutex. Failed changes are retryable.
- Unpair deletes the assignment and journals live removal until applied. Phone
  deletion uses the version 1 public QR and per-peer HMAC. Admin deletion uses
  `--remove-peer` by WireGuard public key only. No offline client queue.

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
