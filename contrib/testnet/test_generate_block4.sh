#!/bin/bash
SSH_KEY="$HOME/.ssh/id_ed25519_vps"
SSH="ssh -i $SSH_KEY -o StrictHostKeyChecking=no -o ConnectTimeout=10"
SEED="57.131.33.151"
CLI="/home/ubuntu/bathron-cli -datadir=/tmp/bathron_bootstrap -testnet"

echo "=== Height before ==="
$SSH ubuntu@$SEED "timeout 5 $CLI getblockcount 2>&1"

echo ""
echo "=== Mempool count ==="
$SSH ubuntu@$SEED "timeout 5 $CLI getrawmempool 2>&1 | jq length"

echo ""
echo "=== Attempting generatebootstrap 1 (timeout 120s) ==="
$SSH ubuntu@$SEED "timeout 120 $CLI generatebootstrap 1 2>&1"
EXIT_CODE=$?
echo "Exit code: $EXIT_CODE"

echo ""
echo "=== Height after ==="
$SSH ubuntu@$SEED "timeout 5 $CLI getblockcount 2>&1"

echo ""
echo "=== Last 20 lines debug.log ==="
$SSH ubuntu@$SEED "tail -20 /tmp/bathron_bootstrap/testnet5/debug.log 2>/dev/null"
