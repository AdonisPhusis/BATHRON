#!/usr/bin/env bash
set -euo pipefail

SSH_KEY="$HOME/.ssh/id_ed25519_vps"
SSH="ssh -i $SSH_KEY -o StrictHostKeyChecking=no -o ConnectTimeout=10"

# HTLC TX to check (can be overridden by first argument)
HTLC_TXID="${1:-e827249a4a6740c82ce9ff4625f5a24561c20b3ddc91a0204ceb2c4c6f97d155}"

echo "[$(date +%H:%M:%S)] Checking HTLC TX: $HTLC_TXID"
echo ""

# Nodes to check
declare -A NODES=(
    ["Seed"]="57.131.33.151"
    ["Core"]="162.19.251.75"
    ["OP1"]="57.131.33.152"
    ["OP2"]="57.131.33.214"
    ["OP3"]="51.75.31.44"
)

# Check each node
for NODE_NAME in "${!NODES[@]}"; do
    IP="${NODES[$NODE_NAME]}"
    echo "=== $NODE_NAME ($IP) ==="
    
    # Check if TX is confirmed
    echo "  Checking if TX is confirmed..."
    RESULT=$($SSH ubuntu@$IP "~/bathron-cli -testnet getrawtransaction '$HTLC_TXID' 1 2>&1" || echo "NOT_FOUND")
    
    if echo "$RESULT" | grep -q "NOT_FOUND\|No such mempool or blockchain transaction"; then
        echo "  ❌ TX not found in blockchain"
        
        # Check mempool
        echo "  Checking mempool..."
        MEMPOOL=$($SSH ubuntu@$IP "~/bathron-cli -testnet getrawmempool 2>&1" || echo "ERROR")
        if echo "$MEMPOOL" | grep -q "$HTLC_TXID"; then
            echo "  ⏳ TX is in mempool (waiting confirmation)"
        else
            echo "  ❌ TX not in mempool either"
        fi
    else
        # TX found - extract key info
        CONFIRMATIONS=$(echo "$RESULT" | grep '"confirmations"' | head -1 | sed 's/.*: \([0-9]*\).*/\1/')
        BLOCKHASH=$(echo "$RESULT" | grep '"blockhash"' | head -1 | sed 's/.*: "\([^"]*\)".*/\1/')
        
        if [ -n "$CONFIRMATIONS" ] && [ "$CONFIRMATIONS" -gt 0 ]; then
            echo "  ✅ TX confirmed with $CONFIRMATIONS confirmations"
            echo "  Block hash: $BLOCKHASH"
        else
            echo "  ⏳ TX in mempool (0 confirmations)"
        fi
    fi
    
    echo ""
done

echo "=== Recent HTLC Log Entries (Seed) ==="
$SSH ubuntu@57.131.33.151 'grep -i "htlc\|TX_HTLC" ~/.bathron/testnet5/debug.log | tail -20 || echo "No recent HTLC log entries"'
echo ""

echo "=== Recent HTLC Log Entries (Core) ==="
$SSH ubuntu@162.19.251.75 'grep -i "htlc\|TX_HTLC" ~/.bathron/testnet5/debug.log | tail -20 || echo "No recent HTLC log entries"'
echo ""

echo "=== Block Production Check ==="
for NODE_NAME in Seed Core; do
    IP="${NODES[$NODE_NAME]}"
    echo "  $NODE_NAME: Block count..."
    $SSH ubuntu@$IP '~/bathron-cli -testnet getblockcount'
done

echo ""
echo "[$(date +%H:%M:%S)] HTLC TX check complete"
