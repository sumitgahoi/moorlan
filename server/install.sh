#!/usr/bin/env bash
# Install Moorlan under /opt/moorlan and link it on PATH.
# Usage:
#   sudo ./install.sh                 # local ./moorlan, else download latest release
#   sudo ./install.sh /path/to/moorlan
#   curl -fsSL https://raw.githubusercontent.com/sumitgahoi/moorlan/main/server/install.sh | sudo bash
set -euo pipefail

PREFIX="${MOORLAN_PREFIX:-/opt/moorlan}"
BIN_LINK="${MOORLAN_BIN_LINK:-/usr/local/bin/moorlan}"
REPO="${MOORLAN_REPO:-sumitgahoi/moorlan}"
CONF_PATH="${PREFIX}/moorlan.conf"

if [[ "${EUID}" -ne 0 ]]; then
  echo "moorlan install: run as root (try: sudo $0)" >&2
  exit 1
fi

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd || true)"

arch="$(uname -m)"
case "${arch}" in
  x86_64 | amd64) goarch=amd64 ;;
  aarch64 | arm64) goarch=arm64 ;;
  *)
    echo "moorlan install: unsupported architecture: ${arch}" >&2
    exit 1
    ;;
esac

if [[ "$(uname -s)" != Linux ]]; then
  echo "moorlan install: Linux only" >&2
  exit 1
fi

pick_local_binary() {
  if [[ $# -ge 1 && -n "${1:-}" ]]; then
    echo "$1"
    return
  fi
  if [[ -n "${script_dir}" && -f "${script_dir}/moorlan" && -x "${script_dir}/moorlan" ]]; then
    echo "${script_dir}/moorlan"
    return
  fi
  if [[ -f ./moorlan && -x ./moorlan ]]; then
    echo "./moorlan"
    return
  fi
  return 1
}

download_latest() {
  local dest="$1"
  local tmp asset url
  tmp="$(mktemp -d)"
  asset="moorlan-linux-${goarch}"
  echo "Downloading ${asset} from latest ${REPO} release..."
  if command -v gh >/dev/null 2>&1; then
    gh release download --repo "${REPO}" --pattern "${asset}" --pattern "${asset}.sha256" --dir "${tmp}"
  else
    url="$(curl -fsSL "https://api.github.com/repos/${REPO}/releases/latest" \
      | sed -n "s/.*\"browser_download_url\": \"\\([^\"]*${asset}\\)\"/\\1/p" | head -1)"
    if [[ -z "${url}" ]]; then
      rm -rf "${tmp}"
      echo "moorlan install: could not find ${asset} on the latest release" >&2
      exit 1
    fi
    curl -fsSL -o "${tmp}/${asset}" "${url}"
    curl -fsSL -o "${tmp}/${asset}.sha256" "${url}.sha256" || true
  fi
  if [[ -f "${tmp}/${asset}.sha256" ]]; then
    (cd "${tmp}" && sha256sum -c "${asset}.sha256")
  fi
  install -m 755 "${tmp}/${asset}" "${dest}"
  rm -rf "${tmp}"
}

write_example_conf() {
  local dest="$1"
  if [[ -n "${script_dir}" && -f "${script_dir}/moorlan.conf.example" ]]; then
    cp "${script_dir}/moorlan.conf.example" "${dest}"
    return
  fi
  cat >"${dest}" <<'EOF'
# Edit private-endpoint / home-cidrs before first run.
# CLI flags override these values when provided.

private-endpoint = 10.10.10.1:8756
home-cidrs = 10.10.0.0/16
# home-cidrs = 10.10.10.0/24,10.10.20.0/24,10.10.30.0/24,10.10.40.0/24

# Optional: skip STUN and pin the public WireGuard endpoint.
# public-endpoint = home.example.com:51820

# wg = wg0
# wg-conf = /etc/wireguard/wg0.conf
EOF
}

mkdir -p "${PREFIX}"
staged="${PREFIX}/moorlan.new"
cleanup() { rm -f "${staged}"; }
trap cleanup EXIT

if src="$(pick_local_binary "${1:-}")"; then
  echo "Using local binary: ${src}"
  install -m 755 "${src}" "${staged}"
else
  download_latest "${staged}"
fi

mv -f "${staged}" "${PREFIX}/moorlan"
trap - EXIT
ln -sfn "${PREFIX}/moorlan" "${BIN_LINK}"

if [[ -e "${CONF_PATH}" ]]; then
  echo "Keeping existing config: ${CONF_PATH}"
else
  write_example_conf "${CONF_PATH}"
  chmod 600 "${CONF_PATH}"
  echo "Wrote starter config: ${CONF_PATH}"
fi

echo
echo "Installed:"
echo "  binary  ${PREFIX}/moorlan"
echo "  link    ${BIN_LINK}"
echo "  config  ${CONF_PATH}"
echo
echo "Next:"
echo "  1. Edit ${CONF_PATH} (private-endpoint, home-cidrs)"
echo "  2. sudo moorlan"
echo "     (or: sudo moorlan --unpair / sudo moorlan --remove <peer>)"
