#!/usr/bin/env bash
set -euo pipefail

TXID="0a72b136f3b9797d2e6be4f3b4935d9d66c7c0c877feeae935b12e0876648deb"
CORE_IP="162.19.251.75"
SEED_IP="57.131.33.151"
KEY="~/.ssh/id_ed25519_vps"

echo "[1/5] Checking Core mempool for TX..."
ssh -i $KEY ubuntu@$CORE_IP "~/BATHRON-Core/src/bathron-cli -testnet getrawmempool" | grep -q "$TXID" && echo "  ✓ TX in Core mempool" || echo "  ✗ TX NOT in Core mempool"

echo ""
echo "[2/5] Checking Seed mempool for TX..."
ssh -i $KEY ubuntu@$SEED_IP "~/BATHRON-Core/src/bathron-cli -testnet getrawmempool" | grep -q "$TXID" && echo "  ✓ TX in Seed mempool" || echo "  ✗ TX NOT in Seed mempool"

echo ""
echo "[3/5] Getting raw TX from Core..."
RAW_TX=$(ssh -i $KEY ubuntu@$CORE_IP "~/BATHRON-Core/src/bathron-cli -testnet getrawtransaction $TXID")
echo "  Raw TX length: ${#RAW_TX} bytes"

echo ""
echo "[4/5] Attempting manual relay to Seed..."
RESULT=$(ssh -i $KEY ubuntu@$SEED_IP "~/BATHRON-Core/src/bathron-cli -testnet sendrawtransaction '$RAW_TX' 2>&1" || true)
echo "  Result: $RESULT"

echo ""
echo "[5/5] Checking Seed debug.log for rejection..."
ssh -i $KEY ubuntu@$SEED_IP "tail -30 ~/.bathron/testnet5/debug.log | grep -iE 'bad-|reject|$TXID' || echo '  (no rejection found)'"
