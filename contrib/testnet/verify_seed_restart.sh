#!/bin/bash
set -e

SEED_IP="57.131.33.151"
SSH_KEY="$HOME/.ssh/id_ed25519_vps"

echo "=== VERIFYING SEED NODE RESTART ==="

# Wait for RPC to be ready
for i in {1..20}; do
    echo "Attempt $i/20..."
    
    if ssh -i "$SSH_KEY" ubuntu@$SEED_IP '~/bathron-cli -testnet getblockcount' 2>/dev/null; then
        echo ""
        echo "SUCCESS: Seed node is responding"
        echo ""
        echo "Block count:"
        ssh -i "$SSH_KEY" ubuntu@$SEED_IP '~/bathron-cli -testnet getblockcount'
        echo ""
        echo "Connection count:"
        ssh -i "$SSH_KEY" ubuntu@$SEED_IP '~/bathron-cli -testnet getconnectioncount'
        echo ""
        echo "Network info:"
        ssh -i "$SSH_KEY" ubuntu@$SEED_IP '~/bathron-cli -testnet getnetworkinfo | grep -E "(version|subversion|connections)"'
        exit 0
    fi
    
    sleep 3
done

echo ""
echo "ERROR: Seed node not responding after 60 seconds"
echo "Checking debug.log for errors..."
ssh -i "$SSH_KEY" ubuntu@$SEED_IP 'tail -30 ~/.bathron/testnet5/debug.log'
exit 1
