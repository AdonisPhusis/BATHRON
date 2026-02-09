#!/bin/bash

SEED_IP="57.131.33.151"
SSH_KEY="$HOME/.ssh/id_ed25519_vps"

echo "=== SEED NODE HEALTH CHECK ==="
echo ""

# Status
HEIGHT=$(ssh -o LogLevel=ERROR -i "$SSH_KEY" ubuntu@$SEED_IP '~/bathron-cli -testnet getblockcount 2>&1' | tail -1)
PEERS=$(ssh -o LogLevel=ERROR -i "$SSH_KEY" ubuntu@$SEED_IP '~/bathron-cli -testnet getconnectioncount 2>&1' | tail -1)
PID=$(ssh -o LogLevel=ERROR -i "$SSH_KEY" ubuntu@$SEED_IP 'pgrep -x bathrond 2>&1' | tail -1)

echo "Process PID: $PID"
echo "Block height: $HEIGHT"
echo "Peer count: $PEERS"
echo ""

# Check for recent errors
echo "Recent log (last 20 lines):"
ssh -o LogLevel=ERROR -i "$SSH_KEY" ubuntu@$SEED_IP 'tail -20 ~/.bathron/testnet5/debug.log' 2>/dev/null | grep -v BURNSCAN || echo "(No errors found)"
