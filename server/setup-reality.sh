#!/usr/bin/env bash
#
# setup-reality.sh — Install & configure Xray VLESS + XTLS-Vision + REALITY on the VM.
# Run this ON the Azure VM (Ubuntu/Debian), as root. Runs ALONGSIDE AmneziaWG.
#
#   sudo bash setup-reality.sh
#
# This is the plan-B for when AmneziaWG's handshake gets fingerprinted. REALITY
# disguises your VPN as an ordinary HTTPS (TLS 1.3) visit to a real, unblocked
# website (the "borrowed" SNI). To DPI it looks like normal web traffic, and an
# active prober that connects gets proxied to the REAL site — so it sees a genuine
# certificate and nothing suspicious. There is no VPN fingerprint to block.
#
# PORTS: AmneziaWG uses UDP 443; REALITY uses TCP 443 — different transport, no
# conflict, both run at once. You must open BOTH in the Azure NSG:
#   UDP 443 (AmneziaWG)  and  TCP 443 (REALITY)  — see azure/open-ports.sh.
#
# NOTE: an IP block defeats BOTH protocols (see README). REALITY only defeats
# *fingerprinting*, not IP-level blocking — for that you need a fresh IP.
#
set -euo pipefail

# ---- config (override via env vars) ----------------------------------------
XRAY_DIR="/usr/local/etc/xray"
CONFIG="${XRAY_DIR}/config.json"
PARAMS_ENV="${XRAY_DIR}/params.env"
REALITY_PORT="${REALITY_PORT:-443}"        # TCP. Blends with HTTPS.
# The real site we impersonate. It MUST be reachable from the VM, support TLS 1.3
# + HTTP/2, serve content directly (NO redirect — so use www.apple.com, not the
# bare apple.com), and NOT be blocked in the country you connect FROM.
#
# NOT every big site works: the server has to *relay* the client's real TLS
# handshake to this site, and some hosts answer in ways that break the relay
# (the handshake dies with "REALITY: processed invalid connection ... handshake
# did not complete"). www.microsoft.com FAILS this way in practice; www.apple.com
# works. If you see that error with all keys correct, swap this for another site
# (www.swift.com, dl.google.com, www.cloudflare.com) and re-add clients.
REALITY_DEST="${REALITY_DEST:-www.apple.com:443}"
REALITY_SNI="${REALITY_SNI:-${REALITY_DEST%%:*}}"
# ----------------------------------------------------------------------------

if [[ $EUID -ne 0 ]]; then
  echo "Please run as root:  sudo bash $0" >&2
  exit 1
fi

echo ">> Installing packages (jq, qrencode, openssl, curl)..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq jq qrencode openssl curl ca-certificates >/dev/null

# Install Xray-core (official installer sets up the systemd `xray` service and
# reads /usr/local/etc/xray/config.json). Skip if already present.
if ! command -v xray >/dev/null 2>&1; then
  echo ">> Installing Xray-core..."
  bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install >/dev/null
else
  echo ">> Xray already installed, reusing it."
fi

umask 077
mkdir -p "${XRAY_DIR}"

# ---- REALITY params: generate ONCE, then reuse forever ----------------------
# The x25519 keypair + short id are the server's identity. Every client needs the
# PUBLIC key + short id + SNI (there is no client private key — auth is the UUID).
if [[ -f "${PARAMS_ENV}" ]]; then
  echo ">> Reusing existing REALITY params (${PARAMS_ENV})."
  # shellcheck disable=SC1090
  source "${PARAMS_ENV}"
else
  echo ">> Generating REALITY keypair + short id..."
  keys="$(xray x25519)"
  # xray builds vary in wording:
  #   newer:  "PrivateKey: X" / "Password (PublicKey): Y"
  #   older:  "Private key: X" / "Public key: Y"
  # Split on ": " and take the value; match the private line but exclude the
  # public one (which contains "Public"), and grab the public value from whichever
  # line mentions Public or Password.
  REALITY_PRIVATE_KEY="$(printf '%s\n' "${keys}" | awk -F': *' '/[Pp]rivate ?[Kk]ey/ && !/[Pp]ublic/ {print $NF; exit}' | tr -d '[:space:]')"
  REALITY_PUBLIC_KEY="$(printf '%s\n'  "${keys}" | awk -F': *' '/[Pp]ublic ?[Kk]ey|[Pp]assword/    {print $NF; exit}' | tr -d '[:space:]')"
  REALITY_SHORT_ID="$(openssl rand -hex 8)"
  if [[ -z "${REALITY_PRIVATE_KEY}" || -z "${REALITY_PUBLIC_KEY}" ]]; then
    echo "Failed to parse xray x25519 output. Raw output was:" >&2
    printf '%s\n' "${keys}" >&2
    exit 1
  fi
  cat > "${PARAMS_ENV}" <<EOF
REALITY_PRIVATE_KEY=${REALITY_PRIVATE_KEY}
REALITY_PUBLIC_KEY=${REALITY_PUBLIC_KEY}
REALITY_SHORT_ID=${REALITY_SHORT_ID}
REALITY_DEST=${REALITY_DEST}
REALITY_SNI=${REALITY_SNI}
EOF
  chmod 600 "${PARAMS_ENV}"
fi

# Preserve existing clients across re-runs so a redeploy doesn't drop them.
CLIENTS_JSON="$(jq -c '.inbounds[0].settings.clients // []' "${CONFIG}" 2>/dev/null || echo '[]')"
[[ "${CLIENTS_JSON}" != "[]" ]] && echo ">> Preserving existing REALITY clients."

echo ">> Writing ${CONFIG} ..."
jq -n \
  --argjson port "${REALITY_PORT}" \
  --arg dest "${REALITY_DEST}" \
  --arg sni "${REALITY_SNI}" \
  --arg priv "${REALITY_PRIVATE_KEY}" \
  --arg sid "${REALITY_SHORT_ID}" \
  --argjson clients "${CLIENTS_JSON}" \
  '{
    log: { loglevel: "warning" },
    inbounds: [{
      listen: "0.0.0.0",
      port: $port,
      protocol: "vless",
      settings: { clients: $clients, decryption: "none" },
      streamSettings: {
        network: "tcp",
        security: "reality",
        realitySettings: {
          show: false,
          dest: $dest,
          xver: 0,
          serverNames: [ $sni ],
          privateKey: $priv,
          shortIds: [ $sid ]
        }
      },
      sniffing: { enabled: true, destOverride: [ "http", "tls", "quic" ] }
    }],
    outbounds: [ { protocol: "freedom", tag: "direct" } ]
  }' > "${CONFIG}"
# Xray drops privileges to `nobody`, so it must be able to READ config.json —
# 644 (root-owned, world-readable) is what the official installer uses. The
# secret key material stays in params.env, which remains 600 (root only).
chmod 644 "${CONFIG}"

echo ">> Testing config..."
if ! { xray -test -config "${CONFIG}" >/dev/null 2>&1 || xray run -test -config "${CONFIG}" >/dev/null 2>&1; }; then
  echo "xray config test FAILED — not restarting." >&2
  exit 1
fi

echo ">> Enabling service..."
systemctl enable xray >/dev/null 2>&1 || true
systemctl restart xray

PUBLIC_IP="$(curl -fsS --max-time 5 https://api.ipify.org || echo "<your-vm-public-ip>")"

cat <<EOF

============================================================
 REALITY (Xray VLESS + XTLS-Vision) server is UP.
------------------------------------------------------------
 Listen port   : ${REALITY_PORT}/tcp
 Public IP     : ${PUBLIC_IP}
 Borrowed SNI  : ${REALITY_SNI}   (traffic looks like HTTPS to this site)
 Public key    : ${REALITY_PUBLIC_KEY}
 Short id      : ${REALITY_SHORT_ID}
------------------------------------------------------------
 NEXT STEPS:
   1) Open TCP ${REALITY_PORT} in the Azure NSG:
        PROTOCOL=Tcp RULE_NAME=Allow-Reality PRIORITY=1010 \\
          RG=<rg> NSG=<nsg> bash azure/open-ports.sh
   2) Add a client:  sudo bash client/add-reality-client.sh phone
   3) Import the vless:// link/QR into v2rayNG (Android) or sing-box/Streisand
      (iOS). Do NOT use the Amnezia app for REALITY — its vless:// import is
      unreliable (shows "Connected" but routes nothing).
============================================================
EOF
