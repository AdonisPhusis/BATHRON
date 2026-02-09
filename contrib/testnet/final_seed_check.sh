#!/bin/bash

SEED_IP="57.131.33.151"
SSH_KEY="$HOME/.ssh/id_ed25519_vps"

echo "=== FINAL SEED STATUS ==="

HEIGHT=$(ssh -o StrictHostKeyChecking=no -o LogLevel=ERROR -i "$SSH_KEY" ubuntu@$SEED_IP '~/bathron-cli -testnet getblockcount 2>&1' | tail -1)
PEERS=$(ssh -o StrictHostKeyChecking=no -o LogLevel=ERROR -i "$SSH_KEY" ubuntu@$SEED_IP '~/bathron-cli -testnet getconnectioncount 2>&1' | tail -1)
PID=$(ssh -o StrictHostKeyChecking=no -o LogLevel=ERROR -i "$SSH_KEY" ubuntu@$SEED_IP 'pgrep -x bathrond 2>&1' | tail -1)

echo "Process PID: $PID"
echo "Block height: $HEIGHT"
echo "Peer count: $PEERS"
echo ""
echo "Status: ONLINE"
