#!/bin/bash
SSH_KEY="$HOME/.ssh/id_ed25519_vps"
SSH="ssh -i $SSH_KEY -o StrictHostKeyChecking=no -o ConnectTimeout=30"
IP="${1:-162.19.251.75}"
LINES="${2:-80}"

echo "=== debug.log last $LINES lines on $IP ==="
$SSH ubuntu@$IP "tail -$LINES ~/.bathron/testnet5/debug.log 2>/dev/null"

echo ""
echo "=== Is daemon running? ==="
$SSH ubuntu@$IP 'pgrep -a bathrond 2>/dev/null || echo "NOT RUNNING"'
