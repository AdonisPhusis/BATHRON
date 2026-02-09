#!/bin/bash
# Check block assembly and TX rejection

SSH_KEY=~/.ssh/id_ed25519_vps
SEED_IP="57.131.33.151"

CLAIM_TXID="828713fc1f58655a10ca4d6c7930c12c9a8d9809a6feb1cd8c5c10b1e6e91691"

echo "=== Last 100 log lines for HTLC ==="
ssh -i $SSH_KEY ubuntu@$SEED_IP "grep -i htlc ~/.bathron/testnet5/debug.log | tail -30"

echo ""
echo "=== Block assembly logs ==="
ssh -i $SSH_KEY ubuntu@$SEED_IP "grep -i 'block\|assembly\|template\|addblock' ~/.bathron/testnet5/debug.log | tail -20"

echo ""
echo "=== TX rejection for our claim ==="
ssh -i $SSH_KEY ubuntu@$SEED_IP "grep '$CLAIM_TXID' ~/.bathron/testnet5/debug.log" 2>&1 | tail -20

echo ""
echo "=== General errors ==="
ssh -i $SSH_KEY ubuntu@$SEED_IP "grep -iE 'reject|invalid|error' ~/.bathron/testnet5/debug.log" 2>&1 | tail -20

echo ""
echo "=== Preimage verification logs ==="
ssh -i $SSH_KEY ubuntu@$SEED_IP "grep -i preimage ~/.bathron/testnet5/debug.log" 2>&1 | tail -20
