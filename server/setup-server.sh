#!/usr/bin/env bash
#
# setup-server.sh — Install & configure an AmneziaWG VPN server.
# Run this ON the Azure VM (Ubuntu/Debian), as root.
#
#   sudo WG_PORT=51820 bash setup-server.sh
#
# AmneziaWG is a WireGuard fork that obfuscates the handshake (junk packets +
# randomized magic headers) so DPI systems like Russia's TSPU can't fingerprint
# it. It's as fast as WireGuard and the config is near-identical — just extra
# obfuscation params in [Interface].
#
# What it does:
#   - installs amneziawg (kernel module via dkms) + amneziawg-tools + qrencode
#   - enables IPv4 forwarding (so the VM routes client traffic to the internet)
#   - generates the server keypair
#   - generates the obfuscation params ONCE and persists them (so every client
#     added later matches — server & clients MUST share the same params)
#   - writes /etc/amnezia/amneziawg/awg0.conf with NAT (masquerade) to internet
#   - enables & starts the awg-quick@awg0 service on boot
#
# CLIENT NOTE: clients must use an AmneziaWG-capable app (the "AmneziaWG" app on
# iOS/Android, the Amnezia VPN client, or awg-quick on Linux) — the *stock*
# WireGuard app does NOT understand the obfuscation params.
#
set -euo pipefail

# ---- config (override via env vars) ----------------------------------------
WG_IF="${WG_IF:-awg0}"
WG_PORT="${WG_PORT:-51820}"        # tip: 51820 is easy to fingerprint. For censored
WG_NET="${WG_NET:-10.8.0.0/24}"    #      networks try 443 (looks like QUIC/HTTPS).
WG_SERVER_IP="${WG_SERVER_IP:-10.8.0.1}"
WG_DIR="/etc/amnezia/amneziawg"
PARAMS_ENV="${WG_DIR}/params.env"
# ----------------------------------------------------------------------------

if [[ $EUID -ne 0 ]]; then
  echo "Please run as root:  sudo bash $0" >&2
  exit 1
fi

# Detect the interface that reaches the internet (for NAT). Usually eth0 on Azure.
WAN_IF="$(ip -4 route show default | awk '{print $5; exit}')"
if [[ -z "${WAN_IF}" ]]; then
  echo "Could not detect the default (WAN) interface." >&2
  exit 1
fi
echo ">> WAN interface detected: ${WAN_IF}"

echo ">> Installing packages..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
# software-properties-common gives us add-apt-repository; headers are needed to
# build the amneziawg kernel module via dkms.
apt-get install -y -qq software-properties-common qrencode iptables curl >/dev/null
if ! grep -Rq "amnezia" /etc/apt/sources.list.d/ 2>/dev/null; then
  echo ">> Adding AmneziaWG apt repository (ppa:amnezia/ppa)..."
  add-apt-repository -y ppa:amnezia/ppa
  apt-get update -qq
fi
echo ">> Installing kernel headers (needed to build the amneziawg module)..."
apt-get install -y -qq "linux-headers-$(uname -r)" >/dev/null 2>&1 \
  || apt-get install -y -qq linux-headers-generic >/dev/null 2>&1 || true
# On Ubuntu the single 'amneziawg' package pulls in the kernel module AND the
# awg / awg-quick tools. (The split amneziawg-dkms + amneziawg-tools names are
# only for the RHEL/Fedora path.)
echo ">> Installing amneziawg (module + awg/awg-quick tools)..."
apt-get install -y amneziawg

echo ">> Enabling IPv4 forwarding..."
sysctl_conf="/etc/sysctl.d/99-amneziawg.conf"
echo "net.ipv4.ip_forward = 1" > "${sysctl_conf}"
sysctl -q -p "${sysctl_conf}"

# If a plain-WireGuard server from the old setup is running, stop it so it
# doesn't hold the UDP port. (Safe no-op if it was never installed.)
if systemctl is-enabled --quiet wg-quick@wg0 2>/dev/null || \
   systemctl is-active  --quiet wg-quick@wg0 2>/dev/null; then
  echo ">> Stopping the old plain-WireGuard service (wg-quick@wg0)..."
  systemctl disable --now wg-quick@wg0 >/dev/null 2>&1 || true
fi

umask 077
mkdir -p "${WG_DIR}"

if [[ -f "${WG_DIR}/server_private.key" ]]; then
  echo ">> Server keys already exist, reusing them."
else
  echo ">> Generating server keypair..."
  awg genkey | tee "${WG_DIR}/server_private.key" | awg pubkey > "${WG_DIR}/server_public.key"
fi
SERVER_PRIV="$(cat "${WG_DIR}/server_private.key")"

# ---- obfuscation params: generate ONCE, then reuse forever ------------------
# Server AND every client must use the SAME values or the handshake won't match.
# Randomizing per-deploy means your traffic has a unique signature (harder to
# block by a static fingerprint). Constraints (per AmneziaWG):
#   Jc 1..128 (junk packet count) ; Jmin < Jmax <= 1280 (junk packet sizes)
#   S1, S2 < 1280 and S1+56 != S2 (init/response junk sizes)
#   H1..H4 distinct, in 5..2147483647 (magic headers; must differ from 1..4)
if [[ -f "${PARAMS_ENV}" ]]; then
  echo ">> Reusing existing obfuscation params (${PARAMS_ENV})."
  # shellcheck disable=SC1090
  source "${PARAMS_ENV}"
else
  echo ">> Generating obfuscation params..."
  AWG_JC="$(shuf -i 3-10 -n 1)"
  AWG_JMIN=40
  AWG_JMAX=70
  AWG_S1="$(shuf -i 15-150 -n 1)"
  AWG_S2="$(shuf -i 15-150 -n 1)"
  while [[ $((AWG_S1 + 56)) -eq "${AWG_S2}" ]]; do AWG_S2="$(shuf -i 15-150 -n 1)"; done
  # shuf -n 4 guarantees 4 distinct values.
  read -r AWG_H1 AWG_H2 AWG_H3 AWG_H4 < <(shuf -i 5-2147483647 -n 4 | tr '\n' ' ')
  cat > "${PARAMS_ENV}" <<EOF
AWG_JC=${AWG_JC}
AWG_JMIN=${AWG_JMIN}
AWG_JMAX=${AWG_JMAX}
AWG_S1=${AWG_S1}
AWG_S2=${AWG_S2}
AWG_H1=${AWG_H1}
AWG_H2=${AWG_H2}
AWG_H3=${AWG_H3}
AWG_H4=${AWG_H4}
EOF
  chmod 600 "${PARAMS_ENV}"
fi

# Preserve existing [Peer] blocks across re-runs so a redeploy doesn't drop clients.
EXISTING_PEERS=""
if [[ -f "${WG_DIR}/${WG_IF}.conf" ]]; then
  EXISTING_PEERS="$(awk '/^\[Peer\]/{p=1} p{print}' "${WG_DIR}/${WG_IF}.conf")"
  [[ -n "${EXISTING_PEERS}" ]] && echo ">> Preserving existing client peers."
fi

echo ">> Writing ${WG_DIR}/${WG_IF}.conf ..."
cat > "${WG_DIR}/${WG_IF}.conf" <<EOF
# Managed by setup-server.sh — edit [Peer] blocks via client/add-client.sh
[Interface]
Address    = ${WG_SERVER_IP}/${WG_NET##*/}
ListenPort = ${WG_PORT}
PrivateKey = ${SERVER_PRIV}

# AmneziaWG obfuscation — MUST match every client (see ${PARAMS_ENV})
Jc = ${AWG_JC}
Jmin = ${AWG_JMIN}
Jmax = ${AWG_JMAX}
S1 = ${AWG_S1}
S2 = ${AWG_S2}
H1 = ${AWG_H1}
H2 = ${AWG_H2}
H3 = ${AWG_H3}
H4 = ${AWG_H4}

# NAT: rewrite client traffic so it exits to the internet via ${WAN_IF}
PostUp   = iptables -A FORWARD -i %i -j ACCEPT; iptables -A FORWARD -o %i -j ACCEPT; iptables -t nat -A POSTROUTING -o ${WAN_IF} -j MASQUERADE
PostDown = iptables -D FORWARD -i %i -j ACCEPT; iptables -D FORWARD -o %i -j ACCEPT; iptables -t nat -D POSTROUTING -o ${WAN_IF} -j MASQUERADE
EOF
if [[ -n "${EXISTING_PEERS}" ]]; then
  printf '\n%s\n' "${EXISTING_PEERS}" >> "${WG_DIR}/${WG_IF}.conf"
fi
chmod 600 "${WG_DIR}/${WG_IF}.conf"

echo ">> Enabling service..."
systemctl enable "awg-quick@${WG_IF}" >/dev/null 2>&1 || true
systemctl restart "awg-quick@${WG_IF}"

PUBLIC_IP="$(curl -fsS --max-time 5 https://api.ipify.org || echo "<your-vm-public-ip>")"

cat <<EOF

============================================================
 AmneziaWG server is UP.
------------------------------------------------------------
 Interface     : ${WG_IF}
 Listen port   : ${WG_PORT}/udp
 Server subnet : ${WG_NET}
 Public IP     : ${PUBLIC_IP}
 Server pubkey : $(cat "${WG_DIR}/server_public.key")
 Obfuscation   : Jc=${AWG_JC} S1=${AWG_S1} S2=${AWG_S2} (params.env)
------------------------------------------------------------
 NEXT STEPS:
   1) Open UDP ${WG_PORT} in the Azure NSG  (see azure/open-ports.sh)
   2) Add a client:  sudo bash client/add-client.sh phone
   3) Import the config into an AmneziaWG-capable app (NOT stock WireGuard).
============================================================
EOF
