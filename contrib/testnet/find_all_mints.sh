#!/bin/bash
set -euo pipefail

SEED_IP="57.131.33.151"
SSH_KEY="$HOME/.ssh/id_ed25519_vps"
SSH="ssh -i $SSH_KEY -o ConnectTimeout=10 -o StrictHostKeyChecking=no"

echo "==================================================================================="
echo "SCANNING ALL TX_MINT_M0BTC TRANSACTIONS"
echo "==================================================================================="
echo ""

HEIGHT=$($SSH ubuntu@${SEED_IP} "~/bathron-cli -testnet getblockcount")
echo "Scanning blocks 0 to $HEIGHT..."
echo ""

TOTAL_MINTED=0

for h in $(seq 0 $HEIGHT); do
    HASH=$($SSH ubuntu@${SEED_IP} "~/bathron-cli -testnet getblockhash $h")
    BLOCK=$($SSH ubuntu@${SEED_IP} "~/bathron-cli -testnet getblock $HASH 2")
    
    # Check for TX_MINT_M0BTC (type 32)
    MINT_COUNT=$(echo "$BLOCK" | jq '[.tx[] | select(.type == 32)] | length')
    
    if [ "$MINT_COUNT" -gt 0 ]; then
        echo "Block $h: $MINT_COUNT mint(s)"
        
        echo "$BLOCK" | jq -r '.tx[] | select(.type == 32) | {
            txid: .txid,
            type: .type,
            vout: [.vout[] | {value: .value, address: .scriptPubKey.addresses[0]?}]
        }' | while IFS= read -r line; do
            echo "  $line"
            
            # Extract value if this is a complete object
            if echo "$line" | grep -q '"value"'; then
                VALUE=$(echo "$line" | jq -r '.value // 0' 2>/dev/null || echo 0)
                TOTAL_MINTED=$((TOTAL_MINTED + VALUE))
            fi
        done
        echo ""
    fi
    
    # Progress indicator
    if [ $((h % 20)) -eq 0 ] && [ $h -gt 0 ]; then
        echo "  ... scanned up to block $h"
    fi
done

echo ""
echo "==================================================================================="
echo "SUMMARY"
echo "==================================================================================="
echo "Total blocks scanned: $((HEIGHT + 1))"
echo ""

# Get accurate total by summing all mints
echo "Calculating total minted M0..."

MINTS_JSON=$($SSH ubuntu@${SEED_IP} "
for h in \$(seq 0 $HEIGHT); do
    hash=\$(~/bathron-cli -testnet getblockhash \$h)
    ~/bathron-cli -testnet getblock \$hash 2 | jq -r '.tx[] | select(.type == 32) | .vout[] | .value'
done
")

if [ -n "$MINTS_JSON" ]; then
    TOTAL_MINTED=$(echo "$MINTS_JSON" | awk '{sum+=$1} END {print sum}')
    echo "Total M0 minted via TX_MINT_M0BTC: $TOTAL_MINTED sats"
else
    echo "No TX_MINT_M0BTC transactions found!"
fi

# Compare with getstate
STATE=$($SSH ubuntu@${SEED_IP} "~/bathron-cli -testnet getstate")
M0_TOTAL=$(echo "$STATE" | jq -r '.supply.m0_total')

echo "M0 total from getstate:         $M0_TOTAL sats"
echo ""

if [ "$TOTAL_MINTED" != "$M0_TOTAL" ]; then
    DIFF=$((M0_TOTAL - TOTAL_MINTED))
    echo "⚠️  MISMATCH: Difference of $DIFF sats"
    echo "    This suggests M0 is being created outside TX_MINT_M0BTC!"
else
    echo "✓ Match: All M0 came from TX_MINT_M0BTC"
fi
