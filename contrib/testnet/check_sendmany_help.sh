#!/bin/bash
SSH_KEY="$HOME/.ssh/id_ed25519_vps"
SSH_OPTS="-i $SSH_KEY -o StrictHostKeyChecking=no -o ConnectTimeout=10"
SEED_IP="57.131.33.151"
BATHRON_CLI="/home/ubuntu/bathron-cli -testnet"

echo "=== sendmany help ==="
ssh $SSH_OPTS "ubuntu@$SEED_IP" "$BATHRON_CLI help sendmany" 2>&1 | head -60

echo ""
echo "=== List available wallet RPCs ==="
ssh $SSH_OPTS "ubuntu@$SEED_IP" "$BATHRON_CLI help" 2>&1 | grep -i "send\|transfer\|lock\|m0\|m1"
