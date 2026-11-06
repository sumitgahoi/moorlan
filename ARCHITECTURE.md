# Architecture

`server/` is an independent Linux Go module. `ios/` contains the iPhone / iPad
app, core Swift package, Packet Tunnel extension and vendored WireGuardKit. Mac
is planned separately (same `moorlan://` QR; in-app scan on Mac).

## Server

See [server/ARCHITECTURE.md](server/ARCHITECTURE.md).

## iOS (iPhone / iPad)

See [ios/ARCHITECTURE.md](ios/ARCHITECTURE.md).
