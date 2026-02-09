#!/bin/bash
set -e

SEED_IP="57.131.33.151"
SSH_KEY="$HOME/.ssh/id_ed25519_vps"

echo "=== SEED NODE STATUS ==="

# Check process
PID=$(ssh -i "$SSH_KEY" ubuntu@$SEED_IP 'pgrep -x bathrond || echo "NONE"')
echo "Process: $PID"

# Check RPC
echo ""
echo "Block count:"
ssh -i "$SSH_KEY" ubuntu@$SEED_IP '~/bathron-cli -testnet getblockcount' || echo "RPC not ready yet"

echo ""
echo "Peer count:"
ssh -i "$SSH_KEY" ubuntu@$SEED_IP '~/bathron-cli -testnet getconnectioncount' || echo "RPC not ready yet"
