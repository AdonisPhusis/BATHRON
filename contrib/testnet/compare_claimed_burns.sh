#!/bin/bash
# ==============================================================================
# compare_claimed_burns.sh - Compare claimed burns on BATHRON with genesis_burns.json
# ==============================================================================

set -euo pipefail

# SSH config
SEED_IP="57.131.33.151"
SSH_KEY="$HOME/.ssh/id_ed25519_vps"
SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR"

# Genesis burns file
GENESIS_BURNS="$HOME/BATHRON/contrib/testnet/genesis_burns.json"

if [ ! -f "$GENESIS_BURNS" ]; then
    echo "ERROR: genesis_burns.json not found at $GENESIS_BURNS"
    exit 1
fi

echo "=========================================="
echo "Comparing Claimed Burns"
echo "=========================================="
echo ""

# Get expected total from genesis_burns.json
EXPECTED_COUNT=$(jq '.burns | length' "$GENESIS_BURNS")
EXPECTED_SATS=$(jq '.burns | map(.burned_sats) | add' "$GENESIS_BURNS")

echo "Expected (genesis_burns.json):"
echo "  Burns: $EXPECTED_COUNT"
echo "  Total: $EXPECTED_SATS sats"
echo ""

# Get actual claims from BATHRON
echo "Querying BATHRON Seed node for claimed burns..."
CLAIMED_JSON=$(ssh -i "$SSH_KEY" $SSH_OPTS ubuntu@$SEED_IP "~/bathron-cli -testnet listburnclaims all 1000 0 2>/dev/null" || echo "[]")

if [ "$CLAIMED_JSON" == "[]" ] || [ -z "$CLAIMED_JSON" ]; then
    echo "ERROR: No burns claimed on BATHRON or connection failed"
    exit 1
fi

CLAIMED_COUNT=$(echo "$CLAIMED_JSON" | jq 'length')
CLAIMED_SATS=$(echo "$CLAIMED_JSON" | jq '[.[] | .burned_sats] | add // 0')

echo "Actual (BATHRON claimed):"
echo "  Burns: $CLAIMED_COUNT"
echo "  Total: $CLAIMED_SATS sats"
echo ""

# Compare
echo "=========================================="
echo "Comparison"
echo "=========================================="
echo "Burn count diff: $((CLAIMED_COUNT - EXPECTED_COUNT))"
echo "Sats diff: $((CLAIMED_SATS - EXPECTED_SATS))"
echo ""

if [ "$CLAIMED_COUNT" -ne "$EXPECTED_COUNT" ] || [ "$CLAIMED_SATS" -ne "$EXPECTED_SATS" ]; then
    echo "DISCREPANCY DETECTED!"
    echo ""
    
    # Find burns in BATHRON but not in genesis_burns.json
    echo "Burns in BATHRON not in genesis_burns.json:"
    EXTRA_COUNT=0
    
    while IFS= read -r claimed_burn; do
        BTC_TXID=$(echo "$claimed_burn" | jq -r '.btc_txid')
        AMOUNT=$(echo "$claimed_burn" | jq -r '.burned_sats')
        HEIGHT=$(echo "$claimed_burn" | jq -r '.btc_height')
        
        # Check if this txid exists in genesis_burns.json
        IN_GENESIS=$(jq -r ".burns[] | select(.btc_txid == \"$BTC_TXID\") | .btc_txid" "$GENESIS_BURNS" 2>/dev/null || echo "")
        
        if [ -z "$IN_GENESIS" ]; then
            echo "  EXTRA: $BTC_TXID (h=$HEIGHT, $AMOUNT sats)"
            EXTRA_COUNT=$((EXTRA_COUNT + 1))
        fi
    done < <(echo "$CLAIMED_JSON" | jq -c '.[]')
    
    if [ $EXTRA_COUNT -eq 0 ]; then
        echo "  (none)"
    fi
    
    echo ""
    echo "Burns in genesis_burns.json not claimed on BATHRON:"
    MISSING_COUNT=0
    MISSING_SATS=0
    
    while IFS= read -r genesis_burn; do
        BTC_TXID=$(echo "$genesis_burn" | jq -r '.btc_txid')
        AMOUNT=$(echo "$genesis_burn" | jq -r '.burned_sats')
        HEIGHT=$(echo "$genesis_burn" | jq -r '.btc_height')
        
        # Check if this txid exists in claimed burns
        IN_CLAIMED=$(echo "$CLAIMED_JSON" | jq -r ".[] | select(.btc_txid == \"$BTC_TXID\") | .btc_txid" 2>/dev/null || echo "")
        
        if [ -z "$IN_CLAIMED" ]; then
            echo "  NOT CLAIMED: $BTC_TXID (h=$HEIGHT, $AMOUNT sats)"
            MISSING_COUNT=$((MISSING_COUNT + 1))
            MISSING_SATS=$((MISSING_SATS + AMOUNT))
        fi
    done < <(jq -c '.burns[]' "$GENESIS_BURNS")
    
    if [ $MISSING_COUNT -eq 0 ]; then
        echo "  (none)"
    else
        echo ""
        echo "Total missing: $MISSING_COUNT burns, $MISSING_SATS sats"
    fi
else
    echo "SUCCESS: All burns match!"
fi
