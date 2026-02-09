#!/bin/bash
# check_block_production.sh - Check if blocks are being produced

set -e

SSH_KEY="$HOME/.ssh/id_ed25519_vps"
SSH_OPTS="-i $SSH_KEY -o StrictHostKeyChecking=no -o ConnectTimeout=10"
SEED_IP="57.131.33.151"
CLI="/home/ubuntu/BATHRON-Core/src/bathron-cli -testnet"

echo "=== Block Production Check (Seed - $SEED_IP) ==="
echo ""

echo "1. Current Block:"
ssh $SSH_OPTS ubuntu@$SEED_IP "$CLI getblockcount"
echo ""

echo "2. Last 5 Blocks:"
for i in {0..4}; do
    HEIGHT=$(ssh $SSH_OPTS ubuntu@$SEED_IP "$CLI getblockcount")
    TARGET=$((HEIGHT - i))
    HASH=$(ssh $SSH_OPTS ubuntu@$SEED_IP "$CLI getblockhash $TARGET")
    BLOCK=$(ssh $SSH_OPTS ubuntu@$SEED_IP "$CLI getblock $HASH")
    TIME=$(echo "$BLOCK" | grep '"time"' | head -1 | awk '{print $2}' | tr -d ',')
    echo "Block $TARGET: time=$TIME"
done
echo ""

echo "3. Finality Status:"
ssh $SSH_OPTS ubuntu@$SEED_IP "$CLI getfinalitystatus"
echo ""

echo "4. Active MN Status:"
ssh $SSH_OPTS ubuntu@$SEED_IP "$CLI getactivemnstatus"
echo ""

echo "=== END CHECK ==="
