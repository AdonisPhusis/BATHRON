#!/usr/bin/env bash
set -euo pipefail

CORESDK_IP="162.19.251.75"
SSH_KEY="$HOME/.ssh/id_ed25519_vps"
SSH="ssh -i $SSH_KEY -o StrictHostKeyChecking=no -o ConnectTimeout=10"

echo "[$(date +%H:%M:%S)] Checking latest block details"
echo ""

BEST_HASH=$($SSH ubuntu@$CORESDK_IP '~/bathron-cli -testnet getbestblockhash')
echo "Best block hash: $BEST_HASH"
echo ""

echo "Block details:"
$SSH ubuntu@$CORESDK_IP "~/bathron-cli -testnet getblock '$BEST_HASH'"
echo ""

echo "Current time: $(date +%s)"
echo "Current time readable: $(date)"
echo ""

echo "Checking for errors in debug.log..."
$SSH ubuntu@$CORESDK_IP 'tail -100 ~/.bathron/testnet5/debug.log | grep -i -E "(error|reject|invalid)" || echo "No recent errors"'
echo ""

echo "[$(date +%H:%M:%S)] Latest block check complete"
