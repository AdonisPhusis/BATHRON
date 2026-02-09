#!/bin/bash
SSH_KEY="$HOME/.ssh/id_ed25519_vps"
SSH="ssh -i $SSH_KEY -o StrictHostKeyChecking=no -o ConnectTimeout=10"
SEED="57.131.33.151"
CLI="/home/ubuntu/bathron-cli -datadir=/tmp/bathron_bootstrap -testnet"

echo "=== RPC check on Seed bootstrap daemon ==="
$SSH ubuntu@$SEED "timeout 5 $CLI getblockcount 2>&1 || echo 'RPC TIMEOUT/FAILED'"

echo ""
echo "=== Mempool ==="
$SSH ubuntu@$SEED "timeout 5 $CLI getrawmempool 2>&1 | head -20 || echo 'RPC TIMEOUT'"

echo ""
echo "=== Last 30 lines debug.log ==="
$SSH ubuntu@$SEED "tail -30 /tmp/bathron_bootstrap/testnet5/debug.log 2>/dev/null"
