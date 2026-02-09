#!/bin/bash
# fix_seed_burnclaimdb.sh - Fix Seed by wiping burnclaimdb (will rebuild from chain)

set -e

SSH_KEY="$HOME/.ssh/id_ed25519_vps"
SSH_OPTS="-o StrictHostKeyChecking=no -o ConnectTimeout=10"
SSH="ssh -i $SSH_KEY $SSH_OPTS"

SEED_IP="57.131.33.151"

echo "╔═══════════════════════════════════════════════════════════════╗"
echo "║  Fix Seed: Wipe burnclaimdb                                   ║"
echo "╚═══════════════════════════════════════════════════════════════╝"
echo ""

echo "[1/3] Stopping Seed daemon..."
$SSH ubuntu@$SEED_IP '
    ~/BATHRON-Core/src/bathron-cli -testnet stop 2>/dev/null || true
    sleep 3
    pkill -9 bathrond 2>/dev/null || true
'
echo "  Done"

echo "[2/3] Wiping burnclaimdb..."
$SSH ubuntu@$SEED_IP '
    rm -rf ~/.bathron/testnet5/burnclaimdb
    rm -f ~/.bathron/testnet5/.lock
    echo "  Removed burnclaimdb"
'
echo "  Done"

echo "[3/3] Restarting Seed..."
$SSH ubuntu@$SEED_IP '
    ~/BATHRON-Core/src/bathrond -testnet -daemon
    sleep 5
'

# Check status
for i in {1..12}; do
    HEIGHT=$($SSH ubuntu@$SEED_IP '~/BATHRON-Core/src/bathron-cli -testnet getblockcount 2>/dev/null' || echo "0")
    PEERS=$($SSH ubuntu@$SEED_IP '~/BATHRON-Core/src/bathron-cli -testnet getconnectioncount 2>/dev/null' || echo "0")
    echo "  [${i}0s] height=$HEIGHT peers=$PEERS"

    if [ "$HEIGHT" -gt 1000 ]; then
        echo ""
        echo "✓ Seed recovered! Height: $HEIGHT"
        exit 0
    fi
    sleep 10
done

echo ""
echo "Warning: Seed still syncing after 2 minutes"
