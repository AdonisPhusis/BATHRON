#!/usr/bin/env bash
set -euo pipefail

SEED_IP="57.131.33.151"
CLI_SEED="ssh -o StrictHostKeyChecking=no -i ~/.ssh/id_ed25519_vps ubuntu@$SEED_IP /home/ubuntu/BATHRON-Core/src/bathron-cli -testnet"

echo "=== MN Registration Status ==="
$CLI_SEED masternode count || echo "No masternodes registered"
echo ""

echo "=== MN List ==="
$CLI_SEED masternode list || echo "Empty list"
echo ""

echo "=== Recent Blocks (last 5) ==="
for i in {0..4}; do
    HEIGHT=$($CLI_SEED getblockcount)
    BLOCK_HEIGHT=$((HEIGHT - i))
    HASH=$($CLI_SEED getblockhash $BLOCK_HEIGHT)
    echo "Block $BLOCK_HEIGHT: $HASH"
    $CLI_SEED getblock $HASH | jq -r '{height: .height, time: .time, tx: .tx | length, cbvalue: .tx[0]}'
done
echo ""

echo "=== Mempool ==="
$CLI_SEED getmempoolinfo
echo ""

echo "=== Config Check ==="
$CLI_SEED getinfo | jq -r '{version, blocks, connections}'
