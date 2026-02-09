#!/usr/bin/env bash
set -euo pipefail

CORE_IP="162.19.251.75"
SEED_IP="57.131.33.151"
KEY="~/.ssh/id_ed25519_vps"

echo "=== Checking TX Relay Settings ==="
echo ""

echo "[Core → Seed connection details]"
ssh -i $KEY ubuntu@$CORE_IP "~/BATHRON-Core/src/bathron-cli -testnet getpeerinfo" | jq '.[] | select(.addr | contains("57.131.33.151")) | {addr, inbound, relaytxes, minfeefilter, bytessent_per_msg, bytesrecv_per_msg}'

echo ""
echo "[Seed → Core connection details]"
ssh -i $KEY ubuntu@$SEED_IP "~/BATHRON-Core/src/bathron-cli -testnet getpeerinfo" | jq '.[] | select(.addr | contains("162.19.251.75")) | {addr, inbound, relaytxes, minfeefilter, bytessent_per_msg, bytesrecv_per_msg}'
