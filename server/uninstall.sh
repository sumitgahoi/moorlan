#!/usr/bin/env bash
# Remove Moorlan server files; --purge also removes configuration and state.
set -euo pipefail

purge=false
for arg in "$@"; do
  case "$arg" in
    --purge) purge=true ;;
    -h|--help)
      echo "Usage: uninstall.sh [--purge]"
      echo "  --purge  Also delete all Moorlan configuration, database, and runtime files."
      exit 0
      ;;
    *)
      echo "moorlan: unknown option: $arg" >&2
      exit 1
      ;;
  esac
done

if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
  echo "moorlan: run as root (sudo bash uninstall.sh [--purge])" >&2
  exit 1
fi

systemctl disable --now moorlan-reconcile.service 2>/dev/null || true
rm -f /etc/systemd/system/moorlan-reconcile.service
if "$purge"; then
  rm -rf /etc/systemd/system/moorlan-reconcile.service.d \
    /run/systemd/system/moorlan-reconcile.service.d
fi
systemctl daemon-reload 2>/dev/null || true
systemctl reset-failed moorlan-reconcile.service 2>/dev/null || true

rm -f /usr/local/bin/moorlan
rm -rf /usr/share/moorlan

if "$purge"; then
  rm -rf /etc/moorlan /var/lib/moorlan /run/moorlan
  rm -f /run/moorlan-*.lock
  echo "Moorlan purged (binary, unit, overrides, configuration, database, and runtime files)."
else
  echo "Moorlan removed (binary, unit, and example files)."
  echo "Configuration and peer DB preserved. Use --purge to remove them too."
fi

echo "WireGuard device unchanged."
echo "If phones are still paired, remove the VPN profile on each device."
