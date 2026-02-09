#!/bin/bash
# ==============================================================================
# clear_mempool_seed.sh - Clear invalid transactions from Seed mempool
# ==============================================================================

set -e

SEED_IP="57.131.33.151"
SEED_CLI="/home/ubuntu/BATHRON-Core/src/bathron-cli -testnet"
SSH="ssh -i ~/.ssh/id_ed25519_vps ubuntu@${SEED_IP}"

echo "[$(date +%H:%M:%S)] Clearing mempool on Seed (${SEED_IP})"

# Step 1: Get current status
echo ""
echo "=== Current Status ==="
MEMPOOL_SIZE=$($SSH "${SEED_CLI} getmempoolinfo | jq -r '.size'")
HEIGHT=$($SSH "${SEED_CLI} getblockcount")
echo "Height: ${HEIGHT}"
echo "Mempool size: ${MEMPOOL_SIZE}"

if [ "$MEMPOOL_SIZE" -eq 0 ]; then
    echo "Mempool is already empty. Nothing to do."
    exit 0
fi

# Step 2: Get mempool txids
echo ""
echo "=== Mempool Transactions ==="
$SSH "${SEED_CLI} getrawmempool false" | tee /tmp/mempool_txids.json
TXIDS=$(cat /tmp/mempool_txids.json | jq -r '.[]')

# Step 3: Try to remove each transaction
echo ""
echo "=== Attempting to remove transactions ==="
for TXID in $TXIDS; do
    echo "Trying to remove: ${TXID:0:16}..."
    
    # Try removefrom mempool (if RPC exists)
    if $SSH "${SEED_CLI} help removefrom" &>/dev/null; then
        echo "  -> Using removefrom mempool"
        $SSH "${SEED_CLI} removefrom mempool ${TXID}" || echo "  -> Failed (expected if RPC doesn't exist)"
    fi
    
    # Try abandontransaction
    echo "  -> Trying abandontransaction"
    $SSH "${SEED_CLI} abandontransaction ${TXID}" || echo "  -> Failed (expected if not wallet tx)"
done

# Step 4: Check if mempool cleared
sleep 2
MEMPOOL_SIZE_AFTER=$($SSH "${SEED_CLI} getmempoolinfo | jq -r '.size'")
echo ""
echo "=== After removal attempts ==="
echo "Mempool size: ${MEMPOOL_SIZE_AFTER}"

if [ "$MEMPOOL_SIZE_AFTER" -gt 0 ]; then
    echo ""
    echo "Mempool still has transactions. Restarting daemon to force clear..."
    
    # Step 5: Restart daemon
    echo "  -> Stopping daemon..."
    $SSH "${SEED_CLI} stop" || true
    sleep 5
    
    echo "  -> Starting daemon..."
    $SSH "/home/ubuntu/BATHRON-Core/src/bathrond -testnet -daemon"
    sleep 3
    
    # Wait for daemon to be ready
    echo "  -> Waiting for daemon to be ready..."
    for i in {1..30}; do
        if $SSH "${SEED_CLI} getblockcount" &>/dev/null; then
            echo "  -> Daemon ready"
            break
        fi
        sleep 1
    done
    
    # Check mempool again
    MEMPOOL_SIZE_FINAL=$($SSH "${SEED_CLI} getmempoolinfo | jq -r '.size'")
    HEIGHT_FINAL=$($SSH "${SEED_CLI} getblockcount")
    echo ""
    echo "=== After restart ==="
    echo "Height: ${HEIGHT_FINAL}"
    echo "Mempool size: ${MEMPOOL_SIZE_FINAL}"
fi

# Step 6: Verify blocks are being produced
echo ""
echo "=== Waiting for new blocks ==="
HEIGHT_START=$($SSH "${SEED_CLI} getblockcount")
echo "Starting height: ${HEIGHT_START}"
echo "Waiting 90 seconds for new blocks..."

sleep 90

HEIGHT_END=$($SSH "${SEED_CLI} getblockcount")
BLOCKS_PRODUCED=$((HEIGHT_END - HEIGHT_START))
echo "Ending height: ${HEIGHT_END}"
echo "Blocks produced: ${BLOCKS_PRODUCED}"

if [ "$BLOCKS_PRODUCED" -gt 0 ]; then
    echo ""
    echo "✅ SUCCESS: Network is producing blocks again"
else
    echo ""
    echo "⚠️  WARNING: No new blocks produced in 90 seconds"
    echo "Check debug.log for errors"
fi

# Step 7: Check if LP lock TX confirmed
echo ""
echo "=== Checking LP pending transactions ==="
$SSH "${SEED_CLI} getrawmempool false"

echo ""
echo "Done."
