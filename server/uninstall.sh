#!/usr/bin/env bash
# Remove Moorlan server files. Does not touch the host WireGuard device.
set -euo pipefail

if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
  echo "moorlan: run as root (sudo bash uninstall.sh)" >&2
  exit 1
fi

systemctl disable --now moorlan-reconcile.service 2>/dev/null || true
rm -f /etc/systemd/system/moorlan-reconcile.service
systemctl daemon-reload 2>/dev/null || true

rm -f /usr/local/bin/moorlan \
  /usr/share/moorlan/moorlan.yaml.example \
  /etc/moorlan/moorlan.yaml \
  /var/lib/moorlan/moorlan.db
rmdir /usr/share/moorlan /etc/moorlan /var/lib/moorlan 2>/dev/null || true

echo "Moorlan removed. WireGuard device unchanged."
echo "If phones are still paired, remove the VPN profile on each device."
