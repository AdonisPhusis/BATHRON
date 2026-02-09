#!/bin/bash
# ==============================================================================
# clear_mempool.sh - Remove invalid transactions from mempool
# ==============================================================================

set -e

SEED_IP="57.131.33.151"
SSH_KEY="$HOME/.ssh/id_ed25519_vps"
SSH_OPTS="-o StrictHostKeyChecking=no -o ConnectTimeout=15 -o BatchMode=yes"
SSH="ssh -i $SSH_KEY $SSH_OPTS"

CLI_PATH="/home/ubuntu/BATHRON-Core/src/bathron-cli -testnet"

case "${1:-status}" in
    status)
        echo "=== Mempool Status on Seed ==="
        $SSH ubuntu@$SEED_IP "$CLI_PATH getmempoolinfo"
        echo ""
        echo "=== Mempool TXIDs ==="
        $SSH ubuntu@$SEED_IP "$CLI_PATH getrawmempool"
        echo ""
        echo "=== Block Height ==="
        $SSH ubuntu@$SEED_IP "$CLI_PATH getblockcount"
        ;;
        
    wipe)
        echo "=== Wiping mempool by deleting mempool.dat ==="
        
        # Stop daemon
        echo "Stopping daemon..."
        $SSH ubuntu@$SEED_IP "$CLI_PATH stop" || true
        
        # Wait for shutdown
        echo "Waiting 5 seconds for shutdown..."
        sleep 5
        
        # Delete mempool.dat
        echo "Deleting mempool.dat..."
        $SSH ubuntu@$SEED_IP "rm -f ~/.bathron/testnet5/mempool.dat"
        
        # Start daemon
        echo "Starting daemon..."
        $SSH ubuntu@$SEED_IP "cd ~/BATHRON-Core && ./src/bathrond -testnet -daemon"
        
        # Wait for startup
        echo "Waiting 10 seconds for startup..."
        sleep 10
        
        # Check status
        echo ""
        echo "=== Status after wipe ==="
        $SSH ubuntu@$SEED_IP "$CLI_PATH getblockcount"
        $SSH ubuntu@$SEED_IP "$CLI_PATH getmempoolinfo"
        $SSH ubuntu@$SEED_IP "$CLI_PATH getrawmempool"
        ;;
        
    restart)
        echo "=== Restarting daemon on Seed ==="
        
        # Stop daemon
        echo "Stopping daemon..."
        $SSH ubuntu@$SEED_IP "$CLI_PATH stop" || true
        
        # Wait for shutdown
        echo "Waiting 5 seconds for shutdown..."
        sleep 5
        
        # Start daemon
        echo "Starting daemon..."
        $SSH ubuntu@$SEED_IP "cd ~/BATHRON-Core && ./src/bathrond -testnet -daemon"
        
        # Wait for startup
        echo "Waiting 10 seconds for startup..."
        sleep 10
        
        # Check status
        echo ""
        echo "=== Status after restart ==="
        $SSH ubuntu@$SEED_IP "$CLI_PATH getblockcount"
        $SSH ubuntu@$SEED_IP "$CLI_PATH getmempoolinfo"
        ;;
        
    *)
        echo "Usage: $0 {status|wipe|restart}"
        exit 1
        ;;
esac
