#!/bin/bash
set -euo pipefail

# Quick script to restart Core+SDK node

SSH_KEY="$HOME/.ssh/id_ed25519_vps"
SSH_OPTS="-i $SSH_KEY -o StrictHostKeyChecking=no -o ConnectTimeout=10"
CORESDK_IP="162.19.251.75"
CLI="$HOME/bathron-cli -testnet"
DAEMON="$HOME/bathrond -testnet -daemon"

echo "=== Restarting Core+SDK Node ==="
echo ""

echo "[1/4] Checking if daemon is running..."
RUNNING=$(timeout 10 ssh $SSH_OPTS ubuntu@$CORESDK_IP "pgrep bathrond || echo NONE")
echo "  Result: $RUNNING"
echo ""

echo "[2/4] Starting daemon..."
START_OUTPUT=$(timeout 10 ssh $SSH_OPTS ubuntu@$CORESDK_IP "$DAEMON 2>&1 && echo OK")
echo "  $START_OUTPUT"
echo ""

echo "[3/4] Waiting 10 seconds for startup..."
sleep 10
echo ""

echo "[4/4] Verifying node status..."
HEIGHT=$(timeout 10 ssh $SSH_OPTS ubuntu@$CORESDK_IP "$CLI getblockcount 2>/dev/null" || echo "ERROR")
PEERS=$(timeout 10 ssh $SSH_OPTS ubuntu@$CORESDK_IP "$CLI getconnectioncount 2>/dev/null" || echo "ERROR")
MEMPOOL=$(timeout 10 ssh $SSH_OPTS ubuntu@$CORESDK_IP "$CLI getrawmempool 2>/dev/null | jq 'length'" || echo "ERROR")

echo "  Block height: $HEIGHT"
echo "  Peers: $PEERS"
echo "  Mempool size: $MEMPOOL"
echo ""

if [[ "$HEIGHT" =~ ^[0-9]+$ ]]; then
    echo "✓ Core+SDK node is ONLINE"
else
    echo "✗ Core+SDK node is still having issues"
fi
