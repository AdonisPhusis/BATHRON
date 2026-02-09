#!/bin/bash
# Detailed block assembly check

SSH_KEY=~/.ssh/id_ed25519_vps
SEED_IP="57.131.33.151"
OP1_IP="57.131.33.152"

CLAIM_TXID="828713fc1f58655a10ca4d6c7930c12c9a8d9809a6feb1cd8c5c10b1e6e91691"

echo "=== Current mempool on Seed ==="
ssh -i $SSH_KEY ubuntu@$SEED_IP "~/bathron-cli -testnet getrawmempool" 2>&1

echo ""
echo "=== Is claim TX still in mempool? ==="
ssh -i $SSH_KEY ubuntu@$SEED_IP "~/bathron-cli -testnet getrawmempool" 2>&1 | grep -q "$CLAIM_TXID" && echo "YES - in mempool" || echo "NO - not in mempool"

echo ""
echo "=== Check if claim TX was confirmed ==="
ssh -i $SSH_KEY ubuntu@$OP1_IP "~/bathron-cli -testnet gettransaction $CLAIM_TXID" 2>&1 | head -10

echo ""
echo "=== Debug log - HTLC_CLAIM processing ==="
ssh -i $SSH_KEY ubuntu@$SEED_IP "grep -i 'htlcclaim\|HTLC_CLAIM\|type.*41\|preimage\|block.*template\|Skipping' ~/.bathron/testnet5/debug.log" 2>&1 | tail -30

echo ""
echo "=== Debug log - block assembly filtering ==="
ssh -i $SSH_KEY ubuntu@$SEED_IP "grep -i 'AddToBlock\|CreateNewBlock\|addpackage\|skip' ~/.bathron/testnet5/debug.log" 2>&1 | tail -20

echo ""
echo "=== Check if TX type 41 is even supported ==="
ssh -i $SSH_KEY ubuntu@$SEED_IP "~/bathron-cli -testnet decoderawtransaction \$(~/bathron-cli -testnet getrawtransaction $CLAIM_TXID)" 2>&1 | grep -E 'type|version'
