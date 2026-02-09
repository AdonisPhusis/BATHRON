#!/bin/bash
set -euo pipefail

# Script: fix_coresdk_corruption.sh
# Purpose: Fix corrupted block database on Core+SDK node

SSH_KEY="$HOME/.ssh/id_ed25519_vps"
SSH_OPTS="-i $SSH_KEY -o StrictHostKeyChecking=no -o ConnectTimeout=10"
CORESDK_IP="162.19.251.75"
CLI="$HOME/bathron-cli -testnet"
DAEMON="$HOME/bathrond -testnet -daemon"
DATADIR="$HOME/.bathron/testnet5"

echo "============================================"
echo "CORE+SDK CORRUPTION RECOVERY"
echo "============================================"
echo ""

echo "[1/6] Stopping daemon..."
ssh $SSH_OPTS ubuntu@$CORESDK_IP "$CLI stop 2>/dev/null || true"
sleep 5
ssh $SSH_OPTS ubuntu@$CORESDK_IP "pkill -9 bathrond || true"
echo "  ✓ Daemon stopped"
echo ""

echo "[2/6] Removing corrupted consensus data..."
ssh $SSH_OPTS ubuntu@$CORESDK_IP "cd $DATADIR && rm -rf blocks chainstate index evodb llmq settlementdb btcheadersdb hu_finality khu sporks burnclaimdb"
echo "  ✓ Consensus data removed"
echo ""

echo "[3/6] Removing network data to prevent isolation..."
ssh $SSH_OPTS ubuntu@$CORESDK_IP "cd $DATADIR && rm -f peers.dat banlist.dat mempool.dat mncache.dat mnmetacache.dat .lock"
echo "  ✓ Network data removed"
echo ""

echo "[4/6] Restarting daemon..."
ssh $SSH_OPTS ubuntu@$CORESDK_IP "$DAEMON"
echo "  ✓ Daemon started"
echo ""

echo "[5/6] Waiting 15 seconds for initial sync..."
sleep 15
echo ""

echo "[6/6] Verifying recovery..."
HEIGHT=$(ssh $SSH_OPTS ubuntu@$CORESDK_IP "$CLI getblockcount 2>/dev/null" || echo "0")
PEERS=$(ssh $SSH_OPTS ubuntu@$CORESDK_IP "$CLI getconnectioncount 2>/dev/null" || echo "0")
MEMPOOL=$(ssh $SSH_OPTS ubuntu@$CORESDK_IP "$CLI getrawmempool 2>/dev/null | jq 'length'" || echo "?")

echo "  Block height: $HEIGHT"
echo "  Peers: $PEERS"
echo "  Mempool size: $MEMPOOL"
echo ""

if [[ "$HEIGHT" =~ ^[0-9]+$ ]] && [[ "$HEIGHT" -gt "0" ]]; then
    echo "✓ Core+SDK node is recovering (height=$HEIGHT)"
    echo ""
    echo "Node will sync to network tip automatically."
    echo "Monitor with: ./deploy_to_vps.sh --status"
else
    echo "✗ Core+SDK node may need more time to start"
    echo "  Check with: ./deploy_to_vps.sh --status"
fi
echo ""
