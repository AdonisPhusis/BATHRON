#!/usr/bin/env bash
set -euo pipefail

TXID="0a72b136f3b9797d2e6be4f3b4935d9d66c7c0c877feeae935b12e0876648deb"
CORE_IP="162.19.251.75"
SEED_IP="57.131.33.151"
KEY="~/.ssh/id_ed25519_vps"

echo "=== Transaction Relay Failure Analysis ==="
echo ""

echo "[1] TX details on Core:"
ssh -i $KEY ubuntu@$CORE_IP "~/BATHRON-Core/src/bathron-cli -testnet getrawtransaction $TXID 1" | jq '{txid, size, vsize, fee: .m0_fee_info.m0_fee, type: .m0_fee_info.tx_type}'

echo ""
echo "[2] Check if TX was announced (INV) by Core:"
ssh -i $KEY ubuntu@$CORE_IP "tail -200 ~/.bathron/testnet5/debug.log | grep -E '$TXID|INV|got inv' | tail -10 || echo '  (no INV messages found)'"

echo ""
echo "[3] Check if Seed saw the INV:"
ssh -i $KEY ubuntu@$SEED_IP "tail -200 ~/.bathron/testnet5/debug.log | grep -E '$TXID|got inv|AlreadyHave' | tail -10 || echo '  (no messages found)'"

echo ""
echo "[4] Check for mempool conflicts:"
ssh -i $KEY ubuntu@$SEED_IP "~/BATHRON-Core/src/bathron-cli -testnet getmempoolentry $TXID 2>&1 | head -5"

echo ""
echo "[5] Network message stats:"
echo "  Core sent INV messages:"
ssh -i $KEY ubuntu@$CORE_IP "~/BATHRON-Core/src/bathron-cli -testnet getnettotals | jq '.totalbytessent'"
echo "  Seed received INV messages:"
ssh -i $KEY ubuntu@$SEED_IP "~/BATHRON-Core/src/bathron-cli -testnet getnettotals | jq '.totalbytesrecv'"
