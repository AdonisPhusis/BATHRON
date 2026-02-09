#!/bin/bash
# ==============================================================================
# isolate_seed_and_clear.sh - Disconnect Seed from network, clear mempool
# ==============================================================================

set -e

SEED_IP="57.131.33.151"
SSH_KEY="$HOME/.ssh/id_ed25519_vps"
SSH_OPTS="-o StrictHostKeyChecking=no -o ConnectTimeout=15 -o BatchMode=yes"
SSH="ssh -i $SSH_KEY $SSH_OPTS"

CLI_PATH="/home/ubuntu/BATHRON-Core/src/bathron-cli -testnet"

case "${1:-isolate}" in
    isolate)
        echo "=== Isolating Seed from network ==="
        
        # Get all peers
        echo "Disconnecting all peers..."
        PEERS=$($SSH ubuntu@$SEED_IP "$CLI_PATH getpeerinfo | jq -r '.[].addr' | cut -d: -f1")
        
        for PEER in $PEERS; do
            echo "  Disconnecting $PEER..."
            $SSH ubuntu@$SEED_IP "$CLI_PATH disconnectnode \"$PEER\"" || true
        done
        
        echo ""
        echo "=== Clearing mempool ==="
        $SSH ubuntu@$SEED_IP "$CLI_PATH stop"
        sleep 5
        $SSH ubuntu@$SEED_IP "rm -f ~/.bathron/testnet5/mempool.dat"
        $SSH ubuntu@$SEED_IP "cd ~/BATHRON-Core && ./src/bathrond -testnet -daemon -connect=0"
        
        sleep 10
        
        echo ""
        echo "=== Status (isolated) ==="
        $SSH ubuntu@$SEED_IP "$CLI_PATH getblockcount"
        $SSH ubuntu@$SEED_IP "$CLI_PATH getpeerinfo | jq length"
        $SSH ubuntu@$SEED_IP "$CLI_PATH getrawmempool"
        ;;
        
    reconnect)
        echo "=== Reconnecting Seed to network ==="
        $SSH ubuntu@$SEED_IP "$CLI_PATH stop"
        sleep 5
        $SSH ubuntu@$SEED_IP "cd ~/BATHRON-Core && ./src/bathrond -testnet -daemon"
        
        sleep 10
        echo "Reconnected"
        ;;
        
    *)
        echo "Usage: $0 {isolate|reconnect}"
        exit 1
        ;;
esac
