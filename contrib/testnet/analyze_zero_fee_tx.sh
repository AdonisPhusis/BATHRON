#!/usr/bin/env bash
set -euo pipefail

TXID="0a72b136f3b9797d2e6be4f3b4935d9d66c7c0c877feeae935b12e0876648deb"
CORE_IP="162.19.251.75"
KEY="~/.ssh/id_ed25519_vps"

echo "=== Zero-Fee Transaction Analysis ==="
echo ""

echo "[Full TX details]"
ssh -i $KEY ubuntu@$CORE_IP "~/BATHRON-Core/src/bathron-cli -testnet getrawtransaction $TXID 1" | jq '{
  txid,
  version,
  size,
  vin: .vin | length,
  vout: .vout | length,
  m0_fee_info,
  type,
  extraPayload
}'

echo ""
echo "[TX inputs]"
ssh -i $KEY ubuntu@$CORE_IP "~/BATHRON-Core/src/bathron-cli -testnet getrawtransaction $TXID 1" | jq '.vin'

echo ""
echo "[TX outputs]"
ssh -i $KEY ubuntu@$CORE_IP "~/BATHRON-Core/src/bathron-cli -testnet getrawtransaction $TXID 1" | jq '.vout'
