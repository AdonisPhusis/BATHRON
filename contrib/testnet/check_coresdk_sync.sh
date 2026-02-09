#!/bin/bash
set -euo pipefail

SSH_KEY="$HOME/.ssh/id_ed25519_vps"
SSH_OPTS="-i $SSH_KEY -o StrictHostKeyChecking=no -o ConnectTimeout=10"
CORESDK_IP="162.19.251.75"
CLI="$HOME/bathron-cli -testnet"

echo "=== Core+SDK Sync Status ==="
echo ""

echo "[1] Block count:"
ssh $SSH_OPTS ubuntu@$CORESDK_IP "$CLI getblockcount 2>/dev/null" || echo "ERROR"
echo ""

echo "[2] Blockchain info:"
ssh $SSH_OPTS ubuntu@$CORESDK_IP "$CLI getblockchaininfo 2>/dev/null | jq '{blocks, headers, verificationprogress, initialblockdownload}'" || echo "ERROR"
echo ""

echo "[3] Peer info:"
ssh $SSH_OPTS ubuntu@$CORESDK_IP "$CLI getconnectioncount 2>/dev/null" || echo "ERROR"
echo ""

echo "[4] Recent debug.log (last 30 lines):"
ssh $SSH_OPTS ubuntu@$CORESDK_IP "tail -30 ~/.bathron/testnet5/debug.log" || echo "ERROR"
echo ""
