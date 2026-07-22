#!/usr/bin/env bash
#
# add-reality-client.sh — Add a VLESS/REALITY client and print its vless:// link + QR.
# Run this ON the Azure VM, as root, AFTER setup-reality.sh.
#
#   sudo bash add-reality-client.sh <name>            # e.g. phone, laptop
#   sudo ENDPOINT=1.2.3.4 bash add-reality-client.sh laptop
#
# Produces  clients/<name>-reality.txt  (a vless:// link) and prints a QR.
# Unlike AmneziaWG, a REALITY client has NO private key — its credential is the
# UUID. The disguise (borrowed SNI, keys) lives entirely in the server config, so
# nothing device-specific needs to stay in sync.
#
# CLIENT NOTE: import the link into the full "Amnezia VPN" app, or any Xray client
# (v2rayNG on Android, Streisand/Shadowrocket on iOS). The standalone AmneziaWG app
# does NOT support REALITY.
#
set -euo pipefail

XRAY_DIR="/usr/local/etc/xray"
CONFIG="${XRAY_DIR}/config.json"
PARAMS_ENV="${XRAY_DIR}/params.env"
REALITY_PORT="${REALITY_PORT:-$(jq -r '.inbounds[0].port' "${CONFIG}" 2>/dev/null || echo 443)}"
OUT_DIR="${OUT_DIR:-$(pwd)/clients}"
FORCE="${FORCE:-0}"

if [[ $EUID -ne 0 ]]; then echo "Run as root: sudo bash $0 <name>" >&2; exit 1; fi
NAME="${1:-}"
if [[ -z "${NAME}" ]]; then echo "Usage: sudo bash $0 <name>" >&2; exit 1; fi

if [[ ! -f "${PARAMS_ENV}" || ! -f "${CONFIG}" ]]; then
  echo "REALITY not set up (${CONFIG} missing). Run setup-reality.sh first." >&2
  exit 1
fi
# shellcheck disable=SC1090
source "${PARAMS_ENV}"

ENDPOINT="${ENDPOINT:-$(curl -fsS --max-time 5 https://api.ipify.org || true)}"
if [[ -z "${ENDPOINT}" ]]; then
  echo "Could not auto-detect public IP. Pass it: sudo ENDPOINT=<vm-ip> bash $0 ${NAME}" >&2
  exit 1
fi

# Idempotent re-runs: a client's `email` field is its name.
#   - If it already exists, keep its UUID (repeated deploys don't invalidate it).
#   - FORCE=1 wipes and regenerates it (new UUID).
EXISTING_UUID="$(jq -r --arg n "${NAME}" \
  '.inbounds[0].settings.clients[]? | select(.email==$n) | .id' "${CONFIG}" | head -n1)"

if [[ -n "${EXISTING_UUID}" && "${FORCE}" != "1" ]]; then
  echo ">> Client '${NAME}' already exists — keeping it (set FORCE=1 to regenerate)." >&2
  UUID="${EXISTING_UUID}"
else
  if [[ -n "${EXISTING_UUID}" ]]; then
    echo ">> FORCE=1 — replacing existing client '${NAME}'." >&2
    tmp="$(mktemp)"
    jq --arg n "${NAME}" '.inbounds[0].settings.clients |= map(select(.email!=$n))' \
      "${CONFIG}" > "${tmp}" && mv "${tmp}" "${CONFIG}"
  fi
  UUID="$(xray uuid 2>/dev/null || cat /proc/sys/kernel/random/uuid)"
  tmp="$(mktemp)"
  jq --arg id "${UUID}" --arg n "${NAME}" \
    '.inbounds[0].settings.clients += [{ "id": $id, "flow": "xtls-rprx-vision", "email": $n }]' \
    "${CONFIG}" > "${tmp}" && mv "${tmp}" "${CONFIG}"
  chmod 600 "${CONFIG}"
  if ! { xray -test -config "${CONFIG}" >/dev/null 2>&1 || xray run -test -config "${CONFIG}" >/dev/null 2>&1; }; then
    echo "xray config test FAILED after adding client — not reloading." >&2
    exit 1
  fi
  systemctl restart xray
fi

# Build the vless:// share link (Amnezia / Xray clients import this directly).
LINK="vless://${UUID}@${ENDPOINT}:${REALITY_PORT}?security=reality&encryption=none&flow=xtls-rprx-vision&type=tcp&sni=${REALITY_SNI}&fp=chrome&pbk=${REALITY_PUBLIC_KEY}&sid=${REALITY_SHORT_ID}#${NAME}-reality"

umask 077
mkdir -p "${OUT_DIR}"
CONF="${OUT_DIR}/${NAME}-reality.txt"
printf '%s\n' "${LINK}" > "${CONF}"

# If invoked via sudo, hand the file back to the real user (so they can read/scp it).
if [[ -n "${SUDO_USER:-}" ]]; then
  chown "${SUDO_USER}:${SUDO_USER}" "${CONF}" 2>/dev/null || true
fi

echo ">> REALITY client '${NAME}' ready." >&2
echo ">> Link written to: ${CONF}" >&2
echo ">> Scan this QR with the Amnezia VPN app (or v2rayNG / Streisand):" >&2
echo >&2
qrencode -t ansiutf8 <<< "${LINK}" >&2
echo >&2
echo "${LINK}"
