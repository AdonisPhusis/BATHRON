#!/bin/bash
# Check if burns were claimed but not minted (K blocks not passed)

set -e

SEED_IP="57.131.33.151"
SSH_KEY="$HOME/.ssh/id_ed25519_vps"
SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=15 -o BatchMode=yes"
SSH="ssh -i $SSH_KEY $SSH_OPTS"
CLI="~/BATHRON-Core/src/bathron-cli -testnet"

echo "=========================================="
echo "BURN MINTING STATUS CHECK"
echo "=========================================="
echo ""

# Get current block height
BLOCK_HEIGHT=$($SSH ubuntu@$SEED_IP "$CLI getblockcount 2>/dev/null" || echo "0")
echo "Current block height: $BLOCK_HEIGHT"
echo ""

# Get burn stats
echo "=== Burn Statistics ==="
BURN_STATS=$($SSH ubuntu@$SEED_IP "$CLI getbtcburnstats 2>/dev/null" || echo "{}")
echo "$BURN_STATS" | jq .
echo ""

# Parse stats
TOTAL_RECORDS=$(echo "$BURN_STATS" | jq -r '.total_records // 0')
TOTAL_PENDING=$(echo "$BURN_STATS" | jq -r '.total_pending // 0')
TOTAL_FINAL=$(echo "$BURN_STATS" | jq -r '.total_final // 0')
M0BTC_SUPPLY=$(echo "$BURN_STATS" | jq -r '.m0btc_supply // 0')
M0BTC_PENDING=$(echo "$BURN_STATS" | jq -r '.m0btc_pending // 0')
K_CONFIRMATIONS=$(echo "$BURN_STATS" | jq -r '.k_confirmations // 6')
K_FINALITY=$(echo "$BURN_STATS" | jq -r '.k_finality // 20')

echo "=== Analysis ==="
echo "Total burn claims: $TOTAL_RECORDS"
echo "  - Pending (< K blocks): $TOTAL_PENDING"
echo "  - Final (≥ K blocks): $TOTAL_FINAL"
echo ""
echo "M0BTC Supply: $M0BTC_SUPPLY sats (minted)"
echo "M0BTC Pending: $M0BTC_PENDING sats (waiting for K blocks)"
echo ""
echo "K confirmations: $K_CONFIRMATIONS blocks"
echo "K finality: $K_FINALITY blocks"
echo ""

# Check genesis burns total
GENESIS_BURNS="/home/ubuntu/BATHRON/contrib/testnet/genesis_burns.json"
EXPECTED_TOTAL=$(jq '[.burns[].amount] | add' "$GENESIS_BURNS")

echo "Expected total from genesis_burns.json: $EXPECTED_TOTAL sats"
echo "Actual M0BTC supply: $M0BTC_SUPPLY sats"
echo "Actual M0BTC pending: $M0BTC_PENDING sats"
echo "Total (supply + pending): $((M0BTC_SUPPLY + M0BTC_PENDING)) sats"
echo ""

MISSING=$((EXPECTED_TOTAL - M0BTC_SUPPLY - M0BTC_PENDING))
echo "Missing: $MISSING sats"
echo ""

if [ "$MISSING" -gt 0 ]; then
    echo "⚠️  ISSUE: $MISSING sats not accounted for!"
    echo ""
    echo "Possible causes:"
    echo "1. Burns claimed but K blocks not yet passed (check pending amount)"
    echo "2. TX_MINT_M0BTC not created (minting logic issue)"
    echo "3. Burns finalized but mint TX rejected (check debug.log)"
    echo ""
    
    # Check if we need to wait for K blocks
    if [ "$TOTAL_PENDING" -gt 0 ]; then
        echo "Note: $TOTAL_PENDING burns are pending (waiting for K=$K_CONFIRMATIONS blocks)"
        echo "      Current height: $BLOCK_HEIGHT"
        echo "      Need to mine at least $K_CONFIRMATIONS more blocks after last burn claim"
    fi
    
    # Check for TX_MINT_M0BTC in recent blocks
    echo ""
    echo "=== Checking for TX_MINT_M0BTC in recent blocks ==="
    for h in $(seq 1 $BLOCK_HEIGHT); do
        BLOCK_HASH=$($SSH ubuntu@$SEED_IP "$CLI getblockhash $h 2>/dev/null" || echo "")
        if [ -n "$BLOCK_HASH" ]; then
            BLOCK_DATA=$($SSH ubuntu@$SEED_IP "$CLI getblock $BLOCK_HASH 2 2>/dev/null" || echo "{}")
            
            # Check for TX_MINT_M0BTC (type 32)
            MINT_COUNT=$(echo "$BLOCK_DATA" | jq '[.tx[]? | select(.type == 32)] | length' 2>/dev/null || echo "0")
            
            if [ "$MINT_COUNT" -gt 0 ]; then
                MINT_AMOUNT=$(echo "$BLOCK_DATA" | jq '[.tx[]? | select(.type == 32) | .vout[]?.value // 0] | add // 0' 2>/dev/null || echo "0")
                # Convert to sats
                MINT_SATS=$(echo "$MINT_AMOUNT * 100000000" | bc -l 2>/dev/null | cut -d'.' -f1)
                echo "  Block $h: $MINT_COUNT TX_MINT_M0BTC ($MINT_SATS sats)"
            fi
        fi
    done
fi

echo ""
echo "=========================================="
