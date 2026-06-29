#!/usr/bin/env bash
#
# setup-server.sh — Install & configure a WireGuard VPN server.
# Run this ON the Azure VM (Ubuntu/Debian), as root.
#
#   sudo WG_PORT=51820 bash setup-server.sh
#
# What it does:
#   - installs wireguard + qrencode
#   - enables IPv4 forwarding (so the VM routes client traffic to the internet)
#   - generates the server keypair
#   - writes /etc/wireguard/wg0.conf with NAT (masquerade) to the internet
#   - enables & starts the wg-quick@wg0 service on boot
#
set -euo pipefail

# ---- config (override via env vars) ----------------------------------------
WG_IF="${WG_IF:-wg0}"
WG_PORT="${WG_PORT:-51820}"        # tip: 51820 is the WG default & easy to fingerprint.
WG_NET="${WG_NET:-10.8.0.0/24}"    #      For censored networks try 443 (see README).
WG_SERVER_IP="${WG_SERVER_IP:-10.8.0.1}"
WG_DIR="/etc/wireguard"
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
apt-get install -y -qq wireguard qrencode iptables >/dev/null

echo ">> Enabling IPv4 forwarding..."
sysctl_conf="/etc/sysctl.d/99-wireguard.conf"
echo "net.ipv4.ip_forward = 1" > "${sysctl_conf}"
sysctl -q -p "${sysctl_conf}"

umask 077
mkdir -p "${WG_DIR}"

if [[ -f "${WG_DIR}/server_private.key" ]]; then
  echo ">> Server keys already exist, reusing them."
else
  echo ">> Generating server keypair..."
  wg genkey | tee "${WG_DIR}/server_private.key" | wg pubkey > "${WG_DIR}/server_public.key"
fi
SERVER_PRIV="$(cat "${WG_DIR}/server_private.key")"

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

# NAT: rewrite client traffic so it exits to the internet via ${WAN_IF}
PostUp   = iptables -A FORWARD -i %i -j ACCEPT; iptables -A FORWARD -o %i -j ACCEPT; iptables -t nat -A POSTROUTING -o ${WAN_IF} -j MASQUERADE
PostDown = iptables -D FORWARD -i %i -j ACCEPT; iptables -D FORWARD -o %i -j ACCEPT; iptables -t nat -D POSTROUTING -o ${WAN_IF} -j MASQUERADE
EOF
if [[ -n "${EXISTING_PEERS}" ]]; then
  printf '\n%s\n' "${EXISTING_PEERS}" >> "${WG_DIR}/${WG_IF}.conf"
fi
chmod 600 "${WG_DIR}/${WG_IF}.conf"

echo ">> Enabling service..."
systemctl enable "wg-quick@${WG_IF}" >/dev/null 2>&1 || true
systemctl restart "wg-quick@${WG_IF}"

PUBLIC_IP="$(curl -fsS --max-time 5 https://api.ipify.org || echo "<your-vm-public-ip>")"

cat <<EOF

============================================================
 WireGuard server is UP.
------------------------------------------------------------
 Interface     : ${WG_IF}
 Listen port   : ${WG_PORT}/udp
 Server subnet : ${WG_NET}
 Public IP     : ${PUBLIC_IP}
 Server pubkey : $(cat "${WG_DIR}/server_public.key")
------------------------------------------------------------
 NEXT STEPS:
   1) Open UDP ${WG_PORT} in the Azure NSG  (see azure/open-ports.sh)
   2) Add a client:  sudo bash client/add-client.sh phone
============================================================
EOF
