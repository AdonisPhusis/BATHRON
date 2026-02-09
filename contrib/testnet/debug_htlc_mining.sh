#!/usr/bin/env bash
set -euo pipefail

# debug_htlc_mining.sh
# Investigate why HTLC TXs are not being mined

SSH_KEY="$HOME/.ssh/id_ed25519_vps"
SSH_OPTS="-i $SSH_KEY -o StrictHostKeyChecking=no -o ConnectTimeout=10"
SEED_IP="57.131.33.151"

echo "================================================"
echo "  HTLC Mining Debug - Seed Node"
echo "================================================"
echo ""

echo "1. Current state:"
echo "-----------------"
HEIGHT=$(ssh $SSH_OPTS ubuntu@$SEED_IP "~/bathron-cli -testnet getblockcount")
MEMPOOL=$(ssh $SSH_OPTS ubuntu@$SEED_IP "~/bathron-cli -testnet getrawmempool | jq length")
echo "   Block height: $HEIGHT"
echo "   Mempool size: $MEMPOOL"

echo ""
echo "2. Mempool TXs:"
echo "---------------"
ssh $SSH_OPTS ubuntu@$SEED_IP "~/bathron-cli -testnet getrawmempool"

echo ""
echo "3. Recent blocks (last 5):"
echo "--------------------------"
for i in $(seq $((HEIGHT-4)) $HEIGHT); do
    HASH=$(ssh $SSH_OPTS ubuntu@$SEED_IP "~/bathron-cli -testnet getblockhash $i")
    TX_COUNT=$(ssh $SSH_OPTS ubuntu@$SEED_IP "~/bathron-cli -testnet getblock $HASH | jq '.tx | length'")
    echo "   Block $i: $TX_COUNT TXs"
done

echo ""
echo "4. Debug log - HTLC and block creation:"
echo "----------------------------------------"
ssh $SSH_OPTS ubuntu@$SEED_IP "grep -iE 'htlc|CreateNewBlock|AddToBlock|TestBlock|bad-|invalid' ~/.bathron/testnet5/debug.log | tail -40"

echo ""
echo "5. Test block template:"
echo "-----------------------"
TEMPLATE=$(ssh $SSH_OPTS ubuntu@$SEED_IP "~/bathron-cli -testnet getblocktemplate" 2>&1) || {
    echo "   getblocktemplate failed: $TEMPLATE"
}
if [ -n "$TEMPLATE" ] && [ "$TEMPLATE" != "" ]; then
    echo "$TEMPLATE" | jq '{height, curtime, transactions: (.transactions | length)}'
fi

echo ""
echo "================================================"
