#!/bin/bash
# Debug claim TX

SSH_KEY=~/.ssh/id_ed25519_vps
OP1_IP="57.131.33.152"
SEED_IP="57.131.33.151"

CLAIM_TXID="828713fc1f58655a10ca4d6c7930c12c9a8d9809a6feb1cd8c5c10b1e6e91691"

echo "=== Current block height (OP1) ==="
ssh -i $SSH_KEY ubuntu@$OP1_IP "~/bathron-cli -testnet getblockcount"

echo ""
echo "=== Mempool info (OP1) ==="
ssh -i $SSH_KEY ubuntu@$OP1_IP "~/bathron-cli -testnet getmempoolinfo"

echo ""
echo "=== Is claim TX in mempool (OP1)? ==="
ssh -i $SSH_KEY ubuntu@$OP1_IP "~/bathron-cli -testnet getrawmempool" 2>&1 | grep -o "$CLAIM_TXID" || echo "Not in mempool"

echo ""
echo "=== Raw claim TX ==="
ssh -i $SSH_KEY ubuntu@$OP1_IP "~/bathron-cli -testnet getrawtransaction $CLAIM_TXID true" 2>&1 | head -50

echo ""
echo "=== Check Seed mempool ==="
ssh -i $SSH_KEY ubuntu@$SEED_IP "~/bathron-cli -testnet getrawmempool" 2>&1 | grep -o "$CLAIM_TXID" || echo "Not in Seed mempool"

echo ""
echo "=== Recent log errors (OP1) ==="
ssh -i $SSH_KEY ubuntu@$OP1_IP "tail -50 ~/.bathron/testnet5/debug.log" 2>&1 | grep -iE '(reject|error|invalid|htlc)' | tail -20

echo ""
echo "=== Recent log errors (Seed) ==="
ssh -i $SSH_KEY ubuntu@$SEED_IP "tail -50 ~/.bathron/testnet5/debug.log" 2>&1 | grep -iE '(reject|error|invalid|htlc)' | tail -20
