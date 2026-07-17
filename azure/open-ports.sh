#!/usr/bin/env bash
#
# open-ports.sh — Open the AmneziaWG UDP port on your existing Azure VM's NSG.
# Run this LOCALLY (where `az` is logged in), not on the VM.
#
#   az login                                  # once
#   RG=myResourceGroup NSG=myVm-nsg bash open-ports.sh   # opens UDP 443
#
# The deploy defaults to UDP 443; override with WG_PORT=51820 if you use that.
# Find your NSG name with:
#   az network nsg list -o table
#
set -euo pipefail

RG="${RG:?Set RG=<resource-group>}"
NSG="${NSG:?Set NSG=<network-security-group-name>}"
WG_PORT="${WG_PORT:-443}"
RULE_NAME="${RULE_NAME:-Allow-AmneziaWG}"
PRIORITY="${PRIORITY:-1000}"

echo ">> Adding inbound UDP rule '${RULE_NAME}' for port ${WG_PORT} to NSG '${NSG}'..."
az network nsg rule create \
  --resource-group "${RG}" \
  --nsg-name "${NSG}" \
  --name "${RULE_NAME}" \
  --priority "${PRIORITY}" \
  --direction Inbound \
  --access Allow \
  --protocol Udp \
  --destination-port-ranges "${WG_PORT}" \
  --source-address-prefixes '*' \
  --destination-address-prefixes '*' \
  -o table

echo ">> Done. UDP ${WG_PORT} is now allowed inbound."
