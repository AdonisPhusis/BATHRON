#!/bin/bash
# ==============================================================================
# find_burn_mismatch.sh - Find which burn has amount mismatch
# ==============================================================================

set -euo pipefail

# SSH config
SEED_IP="57.131.33.151"
SSH_KEY="$HOME/.ssh/id_ed25519_vps"
SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR"

# Genesis burns file
GENESIS_BURNS="$HOME/BATHRON/contrib/testnet/genesis_burns.json"

echo "=========================================="
echo "Finding Burn Amount Mismatches"
echo "=========================================="
echo ""

# Get claimed burns
CLAIMED_JSON=$(ssh -i "$SSH_KEY" $SSH_OPTS ubuntu@$SEED_IP "~/bathron-cli -testnet listburnclaims all 1000 0 2>/dev/null" || echo "[]")

MISMATCH_COUNT=0

while IFS= read -r genesis_burn; do
    BTC_TXID=$(echo "$genesis_burn" | jq -r '.btc_txid')
    EXPECTED_SATS=$(echo "$genesis_burn" | jq -r '.burned_sats')
    HEIGHT=$(echo "$genesis_burn" | jq -r '.btc_height')
    
    # Find corresponding claimed burn
    CLAIMED_BURN=$(echo "$CLAIMED_JSON" | jq -r ".[] | select(.btc_txid == \"$BTC_TXID\")")
    
    if [ -z "$CLAIMED_BURN" ]; then
        echo "ERROR: Burn not found in claimed: $BTC_TXID"
        continue
    fi
    
    ACTUAL_SATS=$(echo "$CLAIMED_BURN" | jq -r '.burned_sats')
    
    if [ "$EXPECTED_SATS" -ne "$ACTUAL_SATS" ]; then
        echo "MISMATCH:"
        echo "  TXID: $BTC_TXID"
        echo "  Height: $HEIGHT"
        echo "  Expected (genesis_burns.json): $EXPECTED_SATS sats"
        echo "  Actual (BATHRON): $ACTUAL_SATS sats"
        echo "  Difference: $((ACTUAL_SATS - EXPECTED_SATS)) sats"
        echo ""
        MISMATCH_COUNT=$((MISMATCH_COUNT + 1))
    fi
done < <(jq -c '.burns[]' "$GENESIS_BURNS")

if [ $MISMATCH_COUNT -eq 0 ]; then
    echo "No amount mismatches found."
else
    echo "Total mismatches: $MISMATCH_COUNT"
fi
