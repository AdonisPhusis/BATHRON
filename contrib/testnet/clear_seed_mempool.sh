#!/usr/bin/env bash
set -euo pipefail

SSH_KEY="$HOME/.ssh/id_ed25519_vps"
SSH_OPTS="-i $SSH_KEY -o StrictHostKeyChecking=no -o ConnectTimeout=10"
SEED_IP="57.131.33.151"

echo "=== Clearing Seed Mempool ==="
echo ""

echo "1. Stopping Seed daemon..."
ssh $SSH_OPTS ubuntu@$SEED_IP "~/bathron-cli -testnet stop 2>/dev/null || true"
sleep 5

echo "2. Removing mempool.dat..."
ssh $SSH_OPTS ubuntu@$SEED_IP "rm -f ~/.bathron/testnet5/mempool.dat ~/.bathron/testnet5/.lock"

echo "3. Restarting Seed daemon..."
ssh $SSH_OPTS ubuntu@$SEED_IP "~/bathrond -testnet -daemon"
sleep 10

echo "4. Checking status..."
HEIGHT=$(ssh $SSH_OPTS ubuntu@$SEED_IP "~/bathron-cli -testnet getblockcount")
MEMPOOL=$(ssh $SSH_OPTS ubuntu@$SEED_IP "~/bathron-cli -testnet getrawmempool | jq length")
echo "   Height: $HEIGHT"
echo "   Mempool: $MEMPOOL entries"

echo ""
echo "=== Done ==="
