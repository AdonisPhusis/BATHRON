#!/bin/bash
set -e

SEED_IP="57.131.33.151"
SSH_KEY="$HOME/.ssh/id_ed25519_vps"

echo "=== RESTARTING SEED NODE ==="

# Check current status
echo "Checking if daemon is running..."
RUNNING=$(ssh -i "$SSH_KEY" ubuntu@$SEED_IP 'pgrep -x bathrond || echo "NOT_RUNNING"')

if [[ "$RUNNING" == "NOT_RUNNING" ]]; then
    echo "Daemon is NOT running. Starting..."
else
    echo "Daemon is running (PID: $RUNNING). Stopping first..."
    ssh -i "$SSH_KEY" ubuntu@$SEED_IP '~/bathron-cli -testnet stop' || true
    sleep 5
fi

# Start daemon
echo "Starting bathrond..."
ssh -i "$SSH_KEY" ubuntu@$SEED_IP '~/bathrond -testnet -daemon'
sleep 3

# Verify
echo ""
echo "Verifying startup..."
for i in {1..10}; do
    if ssh -i "$SSH_KEY" ubuntu@$SEED_IP '~/bathron-cli -testnet getblockcount' 2>/dev/null; then
        echo ""
        echo "SUCCESS: Seed node restarted"
        ssh -i "$SSH_KEY" ubuntu@$SEED_IP '~/bathron-cli -testnet getnetworkinfo | grep -E "(version|subversion|connections)"'
        exit 0
    fi
    echo -n "."
    sleep 2
done

echo ""
echo "WARNING: Daemon started but RPC not responding yet. Check manually."
exit 1
