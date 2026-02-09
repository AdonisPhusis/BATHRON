#!/bin/bash
# debug_block_stall.sh - Debug why blocks stopped being produced

set -e

SSH_KEY="$HOME/.ssh/id_ed25519_vps"
SSH_OPTS="-i $SSH_KEY -o StrictHostKeyChecking=no -o ConnectTimeout=10"
SEED_IP="57.131.33.151"
CLI="/home/ubuntu/BATHRON-Core/src/bathron-cli -testnet"

echo "=== Block Production Stall Debug (Seed) ==="
echo ""

echo "1. Current Time vs Last Block:"
CURRENT=$(date +%s)
ssh $SSH_OPTS ubuntu@$SEED_IP "$CLI getblockcount" > /tmp/height.txt
HEIGHT=$(cat /tmp/height.txt)
HASH=$(ssh $SSH_OPTS ubuntu@$SEED_IP "$CLI getblockhash $HEIGHT")
LAST_TIME=$(ssh $SSH_OPTS ubuntu@$SEED_IP "$CLI getblock $HASH" | grep '"time"' | head -1 | awk '{print $2}' | tr -d ',')
DIFF=$((CURRENT - LAST_TIME))
echo "Current time: $CURRENT"
echo "Last block time: $LAST_TIME"
echo "Time since last block: ${DIFF}s (should be ~60s)"
echo ""

echo "2. Mempool Size:"
ssh $SSH_OPTS ubuntu@$SEED_IP "$CLI getmempoolinfo"
echo ""

echo "3. Raw Mempool:"
ssh $SSH_OPTS ubuntu@$SEED_IP "$CLI getrawmempool"
echo ""

echo "4. Recent Debug Log Errors (last 50 lines):"
ssh $SSH_OPTS ubuntu@$SEED_IP "tail -50 ~/.bathron/testnet5/debug.log | grep -E '(ERROR|REJECT|invalid|stall)' || echo 'No errors found'"
echo ""

echo "5. Chain Tips:"
ssh $SSH_OPTS ubuntu@$SEED_IP "$CLI getchaintips"
echo ""

echo "=== END DEBUG ==="
