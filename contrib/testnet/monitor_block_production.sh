#!/bin/bash
# Monitor block production in real-time

set -e

SEED_IP="57.131.33.151"
SSH_KEY="$HOME/.ssh/id_ed25519_vps"
SSH_OPTS="-o StrictHostKeyChecking=no -o ConnectTimeout=15 -o BatchMode=yes"
SSH="ssh -i $SSH_KEY $SSH_OPTS"

CLI_PATH="/home/ubuntu/BATHRON-Core/src/bathron-cli -testnet"

echo "=== Current Status ==="
HEIGHT=$($SSH ubuntu@$SEED_IP "$CLI_PATH getblockcount")
echo "Height: $HEIGHT"

$SSH ubuntu@$SEED_IP "$CLI_PATH getmempoolinfo"

echo ""
echo "=== Recent debug.log (CreateNewBlock) ==="
$SSH ubuntu@$SEED_IP "tail -1000 ~/.bathron/testnet5/debug.log | grep -i 'CreateNewBlock' | tail -10"

echo ""
echo "=== Checking for transaction errors ==="
$SSH ubuntu@$SEED_IP "tail -500 ~/.bathron/testnet5/debug.log | grep -E 'bad-txns|invalid|rejected|ERROR' | tail -20"

echo ""
echo "=== Waiting 90 seconds to see if a new block is produced ==="
START_HEIGHT=$HEIGHT
sleep 90

NEW_HEIGHT=$($SSH ubuntu@$SEED_IP "$CLI_PATH getblockcount")
echo "Previous height: $START_HEIGHT"
echo "Current height: $NEW_HEIGHT"

if [ "$NEW_HEIGHT" -gt "$START_HEIGHT" ]; then
    echo "SUCCESS: Block production resumed!"
else
    echo "FAILED: No new blocks produced"
fi
