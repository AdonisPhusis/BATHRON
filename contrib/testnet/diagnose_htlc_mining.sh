#!/usr/bin/env bash
set -euo pipefail

# diagnose_htlc_mining.sh
# Diagnose why HTLC TX 0a72b136... is stuck in mempool

TARGET_TXID="${1:-0a72b136f3b9797d2e6be4f3b4935d9d66c7c0c877feeae935b12e0876648deb}"
SSH_KEY="$HOME/.ssh/id_ed25519_vps"
SSH_OPTS="-i $SSH_KEY -o StrictHostKeyChecking=no -o ConnectTimeout=10"

# Network topology
declare -A NODES
NODES["Seed"]="57.131.33.151:BATHRON-Core"
NODES["CoreSDK"]="162.19.251.75:BATHRON-Core"
NODES["OP1"]="57.131.33.152:bin"
NODES["OP2"]="57.131.33.214:bin"
NODES["OP3"]="51.75.31.44:bin"

echo "=========================================="
echo "HTLC Mining Diagnostic"
echo "Target TX: $TARGET_TXID"
echo "=========================================="
echo ""

# Function to get CLI path for node
get_cli_path() {
    local node_type="$1"
    if [[ "$node_type" == "BATHRON-Core" ]]; then
        echo "\$HOME/BATHRON-Core/src/bathron-cli"
    else
        echo "\$HOME/bathron-cli"
    fi
}

# Check 1: Mempool presence across all nodes
echo "1. Checking mempool presence across all nodes..."
echo "------------------------------------------------"
for node_name in "${!NODES[@]}"; do
    IFS=':' read -r ip node_type <<< "${NODES[$node_name]}"
    CLI=$(get_cli_path "$node_type")
    
    MEMPOOL=$(ssh $SSH_OPTS ubuntu@$ip "$CLI -testnet getrawmempool" 2>/dev/null || echo "ERROR")
    
    if [[ "$MEMPOOL" == "ERROR" ]]; then
        echo "  $node_name ($ip): CONNECTION FAILED"
    elif echo "$MEMPOOL" | grep -q "$TARGET_TXID"; then
        echo "  $node_name ($ip): ✓ TX in mempool"
    else
        echo "  $node_name ($ip): ✗ TX NOT in mempool"
    fi
done
echo ""

# Check 2: Recent block production on Seed (block producer)
echo "2. Recent block production (last 5 blocks on Seed)..."
echo "------------------------------------------------------"
SEED_IP="57.131.33.151"
SEED_CLI="\$HOME/BATHRON-Core/src/bathron-cli"

HEIGHT=$(ssh $SSH_OPTS ubuntu@$SEED_IP "$SEED_CLI -testnet getblockcount" 2>/dev/null || echo "0")
echo "Current height: $HEIGHT"
echo ""

if [[ "$HEIGHT" != "0" && "$HEIGHT" != "ERROR" ]]; then
    for i in $(seq 0 4); do
        BLOCK_HEIGHT=$((HEIGHT - i))
        if [[ $BLOCK_HEIGHT -lt 0 ]]; then
            break
        fi
        
        BLOCK_HASH=$(ssh $SSH_OPTS ubuntu@$SEED_IP "$SEED_CLI -testnet getblockhash $BLOCK_HEIGHT" 2>/dev/null || echo "ERROR")
        
        if [[ "$BLOCK_HASH" != "ERROR" ]]; then
            BLOCK_INFO=$(ssh $SSH_OPTS ubuntu@$SEED_IP "$SEED_CLI -testnet getblock $BLOCK_HASH 1" 2>/dev/null || echo "ERROR")
            
            if [[ "$BLOCK_INFO" != "ERROR" ]]; then
                TX_COUNT=$(echo "$BLOCK_INFO" | grep -c '"tx"' || echo "0")
                TIME=$(echo "$BLOCK_INFO" | grep '"time"' | head -1 | grep -oP '\d+' || echo "unknown")
                echo "  Block $BLOCK_HEIGHT: $TX_COUNT transactions, time=$TIME"
            else
                echo "  Block $BLOCK_HEIGHT: Error fetching block info"
            fi
        fi
    done
else
    echo "Failed to get block height from Seed"
fi
echo ""

# Check 3: Debug log for HTLC rejection
echo "3. Checking debug.log for HTLC/rejection errors (last 100 lines)..."
echo "----------------------------------------------------------------------"
DEBUG_SEARCH=$(ssh $SSH_OPTS ubuntu@$SEED_IP "grep -iE 'bad-htlc|amount-mismatch|0a72b136' \$HOME/.bathron/testnet5/debug.log | tail -20" 2>/dev/null || echo "")

if [[ -z "$DEBUG_SEARCH" ]]; then
    echo "  No HTLC-related errors found in debug.log"
else
    echo "$DEBUG_SEARCH"
fi
echo ""

# Check 4: Try to get TX details from mempool
echo "4. TX details from mempool (if available)..."
echo "---------------------------------------------"
TX_RAW=$(ssh $SSH_OPTS ubuntu@$SEED_IP "$SEED_CLI -testnet getrawtransaction $TARGET_TXID 1" 2>&1 || echo "ERROR")

if [[ "$TX_RAW" == *"ERROR"* ]] || [[ "$TX_RAW" == *"No such mempool"* ]]; then
    echo "  TX not found in mempool or on chain"
else
    echo "$TX_RAW" | head -30
fi
echo ""

# Check 5: Mempool size
echo "5. Mempool size on Seed..."
echo "---------------------------"
MEMPOOL_INFO=$(ssh $SSH_OPTS ubuntu@$SEED_IP "$SEED_CLI -testnet getmempoolinfo" 2>/dev/null || echo "ERROR")
if [[ "$MEMPOOL_INFO" != "ERROR" ]]; then
    echo "$MEMPOOL_INFO"
else
    echo "  Failed to get mempool info"
fi
echo ""

# Check 6: Block template (what would be mined next)
echo "6. Checking block template (next block candidate)..."
echo "-----------------------------------------------------"
TEMPLATE=$(ssh $SSH_OPTS ubuntu@$SEED_IP "$SEED_CLI -testnet getblocktemplate" 2>&1 || echo "ERROR")

if [[ "$TEMPLATE" != "ERROR" ]]; then
    TX_IN_TEMPLATE=$(echo "$TEMPLATE" | grep -c "$TARGET_TXID" || echo "0")
    TOTAL_TXS=$(echo "$TEMPLATE" | grep -c '"txid"' || echo "0")
    echo "  Total TXs in template: $TOTAL_TXS"
    if [[ "$TX_IN_TEMPLATE" -gt 0 ]]; then
        echo "  ✓ Target HTLC TX is in block template"
    else
        echo "  ✗ Target HTLC TX is NOT in block template"
    fi
else
    echo "  Failed to get block template (may require mining setup)"
fi
echo ""

echo "=========================================="
echo "Diagnostic Summary"
echo "=========================================="
echo "Check complete. Key findings:"
echo "1. Mempool presence: See section 1"
echo "2. Recent blocks: See section 2"
echo "3. Rejection errors: See section 3"
echo "4. TX details: See section 4"
echo ""
echo "Next steps:"
echo "- If TX is in mempool but not in template: Check validation errors in debug.log"
echo "- If TX is not in mempool: Check P2P relay issues"
echo "- If blocks are empty: Check CreateNewBlock logic"
