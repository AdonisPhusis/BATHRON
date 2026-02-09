#!/bin/bash
set -euo pipefail

# Script: update_coresdk_binary.sh
# Purpose: Update Core+SDK node binary to match network

SSH_KEY="$HOME/.ssh/id_ed25519_vps"
SSH_OPTS="-i $SSH_KEY -o StrictHostKeyChecking=no -o ConnectTimeout=10"
CORESDK_IP="162.19.251.75"
CLI="$HOME/bathron-cli -testnet"
DAEMON="$HOME/bathrond -testnet -daemon"
LOCAL_SRC="$HOME/BATHRON-Core/src"

echo "============================================"
echo "CORE+SDK BINARY UPDATE"
echo "============================================"
echo ""

# Check local binaries exist
if [[ ! -f "$LOCAL_SRC/bathrond" ]] || [[ ! -f "$LOCAL_SRC/bathron-cli" ]]; then
    echo "✗ Local binaries not found in $LOCAL_SRC"
    echo "  Run 'make -j\$(nproc)' first"
    exit 1
fi

echo "[1/7] Stopping daemon..."
ssh $SSH_OPTS ubuntu@$CORESDK_IP "$CLI stop 2>/dev/null || true"
sleep 5
ssh $SSH_OPTS ubuntu@$CORESDK_IP "pkill -9 bathrond || true"
echo "  ✓ Daemon stopped"
echo ""

echo "[2/7] Backing up old binaries..."
ssh $SSH_OPTS ubuntu@$CORESDK_IP "cp ~/bathrond ~/bathrond.backup.$(date +%s) 2>/dev/null || true"
ssh $SSH_OPTS ubuntu@$CORESDK_IP "cp ~/bathron-cli ~/bathron-cli.backup.$(date +%s) 2>/dev/null || true"
echo "  ✓ Backed up"
echo ""

echo "[3/7] Uploading new bathrond..."
scp $SSH_OPTS "$LOCAL_SRC/bathrond" ubuntu@$CORESDK_IP:~/bathrond
echo "  ✓ bathrond uploaded"
echo ""

echo "[4/7] Uploading new bathron-cli..."
scp $SSH_OPTS "$LOCAL_SRC/bathron-cli" ubuntu@$CORESDK_IP:~/bathron-cli
echo "  ✓ bathron-cli uploaded"
echo ""

echo "[5/7] Setting permissions..."
ssh $SSH_OPTS ubuntu@$CORESDK_IP "chmod +x ~/bathrond ~/bathron-cli"
echo "  ✓ Permissions set"
echo ""

echo "[6/7] Wiping corrupted chain data..."
ssh $SSH_OPTS ubuntu@$CORESDK_IP "cd ~/.bathron/testnet5 && rm -rf blocks chainstate index evodb llmq settlementdb btcheadersdb hu_finality khu sporks burnclaimdb banlist.dat peers.dat .lock"
echo "  ✓ Chain data wiped"
echo ""

echo "[7/7] Restarting with new binary..."
ssh $SSH_OPTS ubuntu@$CORESDK_IP "$DAEMON"
echo "  ✓ Daemon started"
echo ""

echo "============================================"
echo "WAITING FOR SYNC"
echo "============================================"
echo ""

echo "Waiting 20 seconds for initial sync..."
sleep 20

HEIGHT=$(ssh $SSH_OPTS ubuntu@$CORESDK_IP "$CLI getblockcount 2>/dev/null" || echo "0")
PEERS=$(ssh $SSH_OPTS ubuntu@$CORESDK_IP "$CLI getconnectioncount 2>/dev/null" || echo "0")

echo "Current status:"
echo "  Block height: $HEIGHT"
echo "  Peers: $PEERS"
echo ""

if [[ "$HEIGHT" =~ ^[0-9]+$ ]] && [[ "$HEIGHT" -gt "0" ]]; then
    echo "✓ Core+SDK node is syncing successfully!"
else
    echo "⚠ Node may need more time. Monitor with:"
    echo "  ./deploy_to_vps.sh --status"
fi
echo ""
