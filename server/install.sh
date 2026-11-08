#!/usr/bin/env bash
# Install or upgrade Moorlan server from the latest GitHub release.
# Replaces the binary, then runs moorlan --setup (unit, DB, YAML merge).
set -euo pipefail

if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
  echo "moorlan: run as root (sudo bash install.sh)" >&2
  exit 1
fi

case "$(uname -m)" in
  x86_64 | amd64) arch=amd64 ;;
  aarch64 | arm64) arch=arm64 ;;
  *)
    echo "moorlan: unsupported architecture $(uname -m) (need amd64 or arm64)" >&2
    exit 1
    ;;
esac

base="${MOORLAN_RELEASE_BASE:-https://github.com/sumitgahoi/moorlan/releases/latest/download}"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

curl -fsSL -o "$tmp/moorlan" "$base/moorlan-linux-${arch}"
install -m 755 "$tmp/moorlan" /usr/local/bin/moorlan
mkdir -p /usr/share/moorlan /etc/moorlan /var/lib/moorlan

if curl -fsSL -o "$tmp/moorlan.yaml.example" "$base/moorlan.yaml.example"; then
  install -m 644 "$tmp/moorlan.yaml.example" /usr/share/moorlan/moorlan.yaml.example
fi

echo "moorlan: binary installed; running --setup"
if ! /usr/local/bin/moorlan --setup; then
  echo "moorlan: --setup failed. Binary is installed; fix the error above, then: sudo moorlan --setup" >&2
  exit 0
fi
