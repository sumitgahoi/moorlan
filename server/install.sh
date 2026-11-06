#!/usr/bin/env bash
# Install Moorlan server from the latest GitHub release.
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
curl -fsSL -o "$tmp/moorlan.yaml.example" "$base/moorlan.yaml.example"
curl -fsSL -o "$tmp/moorlan-reconcile.service" "$base/moorlan-reconcile.service"

install -m 755 "$tmp/moorlan" /usr/local/bin/moorlan
mkdir -p /usr/share/moorlan /etc/moorlan /var/lib/moorlan
install -m 644 "$tmp/moorlan.yaml.example" /usr/share/moorlan/moorlan.yaml.example
if [[ ! -e /etc/moorlan/moorlan.yaml ]]; then
  cp /usr/share/moorlan/moorlan.yaml.example /etc/moorlan/moorlan.yaml
  echo "wrote /etc/moorlan/moorlan.yaml (example values; edit before pairing)"
else
  echo "kept existing /etc/moorlan/moorlan.yaml"
fi
install -m 644 "$tmp/moorlan-reconcile.service" /etc/systemd/system/moorlan-reconcile.service
systemctl daemon-reload
systemctl enable --now moorlan-reconcile.service

echo
echo "Next: edit /etc/moorlan/moorlan.yaml, then: sudo moorlan --pair"
