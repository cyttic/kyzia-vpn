#!/usr/bin/env bash
#
# add-client.sh — Add a new VPN client (peer) to the AmneziaWG server.
# Run this ON the Azure VM, as root, AFTER setup-server.sh.
#
#   sudo bash add-client.sh <name>            # e.g. phone, laptop
#   sudo ENDPOINT=1.2.3.4 bash add-client.sh laptop
#
# Produces  clients/<name>.conf  and prints a QR code for the AmneziaWG app.
# The client config includes the SAME obfuscation params as the server (read
# from the server's params.env) — they must match or the handshake fails.
#
# CLIENT NOTE: import the config into an AmneziaWG-capable app (the "AmneziaWG"
# app on iOS/Android, the Amnezia VPN client, or awg-quick on Linux). The stock
# WireGuard app does NOT understand the obfuscation params.
#
set -euo pipefail

WG_IF="${WG_IF:-awg0}"
WG_DIR="/etc/amnezia/amneziawg"
PARAMS_ENV="${WG_DIR}/params.env"
WG_PORT="${WG_PORT:-$(awk -F'= *' '/ListenPort/{print $2}' "${WG_DIR}/${WG_IF}.conf")}"
WG_NET_PREFIX="${WG_NET_PREFIX:-10.8.0}"   # must match WG_NET in setup-server.sh
# DNS handed to the client. 1.1.1.1 = Cloudflare. Change if you prefer.
CLIENT_DNS="${CLIENT_DNS:-1.1.1.1}"
OUT_DIR="${OUT_DIR:-$(pwd)/clients}"

if [[ $EUID -ne 0 ]]; then echo "Run as root: sudo bash $0 <name>" >&2; exit 1; fi
NAME="${1:-}"
if [[ -z "${NAME}" ]]; then echo "Usage: sudo bash $0 <name>" >&2; exit 1; fi

if [[ ! -f "${PARAMS_ENV}" ]]; then
  echo "Obfuscation params not found (${PARAMS_ENV}). Run setup-server.sh first." >&2
  exit 1
fi
# shellcheck disable=SC1090
source "${PARAMS_ENV}"

ENDPOINT="${ENDPOINT:-$(curl -fsS --max-time 5 https://api.ipify.org || true)}"
if [[ -z "${ENDPOINT}" ]]; then
  echo "Could not auto-detect public IP. Pass it: sudo ENDPOINT=<vm-ip> bash $0 ${NAME}" >&2
  exit 1
fi

SERVER_PUB="$(cat "${WG_DIR}/server_public.key")"

# Idempotent re-runs:
#   - If this device already exists AND its config is on disk, keep it as-is so
#     repeated deploys don't invalidate a config you're already using.
#   - Set FORCE=1 to wipe and regenerate it (new keys).
FORCE="${FORCE:-0}"
if grep -q "^# ${NAME}$" "${WG_DIR}/${WG_IF}.conf" && [[ -f "${OUT_DIR}/${NAME}.conf" ]]; then
  if [[ "${FORCE}" != "1" ]]; then
    echo ">> Client '${NAME}' already exists — keeping it (set FORCE=1 to regenerate)."
    if [[ -n "${SUDO_USER:-}" ]]; then
      chown "${SUDO_USER}:${SUDO_USER}" "${OUT_DIR}/${NAME}.conf" 2>/dev/null || true
    fi
    echo ">> Existing config: ${OUT_DIR}/${NAME}.conf"
    exit 0
  fi
  echo ">> FORCE=1 — replacing existing client '${NAME}'."
  awk -v name="# ${NAME}" '
    BEGIN { RS=""; ORS="\n\n" }
    $0 ~ ("(^|\n)" name "(\n|$)") { next }
    { print }
  ' "${WG_DIR}/${WG_IF}.conf" > "${WG_DIR}/${WG_IF}.conf.tmp"
  mv "${WG_DIR}/${WG_IF}.conf.tmp" "${WG_DIR}/${WG_IF}.conf"
  chmod 600 "${WG_DIR}/${WG_IF}.conf"
fi

# Pick the next free IP in the subnet (.2, .3, ...) by scanning existing peers.
used="$(grep -oE "${WG_NET_PREFIX}\.[0-9]+" "${WG_DIR}/${WG_IF}.conf" || true)"
next=2
while echo "${used}" | grep -q "${WG_NET_PREFIX}\.${next}\b"; do next=$((next+1)); done
CLIENT_IP="${WG_NET_PREFIX}.${next}"

umask 077
mkdir -p "${OUT_DIR}"
CLIENT_PRIV="$(awg genkey)"
CLIENT_PUB="$(echo "${CLIENT_PRIV}" | awg pubkey)"
PRESHARED="$(awg genpsk)"

# Append peer to the server config, then apply live without dropping the tunnel.
cat >> "${WG_DIR}/${WG_IF}.conf" <<EOF

[Peer]
# ${NAME}
PublicKey    = ${CLIENT_PUB}
PresharedKey = ${PRESHARED}
AllowedIPs   = ${CLIENT_IP}/32
EOF
awg syncconf "${WG_IF}" <(awg-quick strip "${WG_IF}")

# Write the client config. AllowedIPs 0.0.0.0/0 = route ALL traffic through VPN.
# The Jc/Jmin/Jmax/S1/S2/H1..H4 lines MUST match the server's params.env.
CONF="${OUT_DIR}/${NAME}.conf"
cat > "${CONF}" <<EOF
[Interface]
PrivateKey = ${CLIENT_PRIV}
Address    = ${CLIENT_IP}/32
DNS        = ${CLIENT_DNS}
Jc = ${AWG_JC}
Jmin = ${AWG_JMIN}
Jmax = ${AWG_JMAX}
S1 = ${AWG_S1}
S2 = ${AWG_S2}
H1 = ${AWG_H1}
H2 = ${AWG_H2}
H3 = ${AWG_H3}
H4 = ${AWG_H4}

[Peer]
PublicKey    = ${SERVER_PUB}
PresharedKey = ${PRESHARED}
Endpoint     = ${ENDPOINT}:${WG_PORT}
AllowedIPs   = 0.0.0.0/0
# Keep the tunnel alive through NAT/firewalls (important on mobile networks)
PersistentKeepalive = 25
EOF

# If invoked via sudo, hand the config back to the real user (so they can read/scp it).
if [[ -n "${SUDO_USER:-}" ]]; then
  chown "${SUDO_USER}:${SUDO_USER}" "${CONF}" 2>/dev/null || true
fi

echo ">> Client '${NAME}' added as ${CLIENT_IP}"
echo ">> Config written to: ${CONF}"
echo ">> Scan this QR with the AmneziaWG mobile app (NOT stock WireGuard):"
echo
qrencode -t ansiutf8 < "${CONF}"
