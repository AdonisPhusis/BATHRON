#!/bin/bash
set -euo pipefail

SEED_IP="57.131.33.151"
SSH_KEY="$HOME/.ssh/id_ed25519_vps"
SSH="ssh -i $SSH_KEY -o ConnectTimeout=10 -o StrictHostKeyChecking=no"

echo "==================================================================================="
echo "FINAL M0 SUPPLY AUDIT - Consensus Invariant A5 Verification"
echo "==================================================================================="
echo ""

# Get current height
HEIGHT=$($SSH ubuntu@${SEED_IP} "~/bathron-cli -testnet getblockcount")
echo "Chain height: $HEIGHT"
echo ""

# Calculate total minted M0 from blockchain
echo "[1] Calculating M0 minted from TX_MINT_M0BTC transactions..."
MINT_VALUES=$($SSH ubuntu@${SEED_IP} "
for h in \$(seq 0 $HEIGHT); do
    hash=\$(~/bathron-cli -testnet getblockhash \$h)
    ~/bathron-cli -testnet getblock \$hash 2 | jq -r '.tx[] | select(.type == 32) | .vout[] | .value'
done
")

TOTAL_MINTED=0
if [ -n "$MINT_VALUES" ]; then
    TOTAL_MINTED=$(echo "$MINT_VALUES" | awk '{sum+=$1} END {print int(sum)}')
fi

echo "    Total M0 minted: $TOTAL_MINTED sats"
echo ""

# Get burn claims total
echo "[2] Calculating burn claims total..."
BURNS=$($SSH ubuntu@${SEED_IP} "~/bathron-cli -testnet listburnclaims all 100")
BURN_COUNT=$(echo "$BURNS" | jq 'length')
BURN_TOTAL=$(echo "$BURNS" | jq '[.[].burned_sats] | add')

echo "    Total burn claims: $BURN_COUNT"
echo "    Total burned sats: $BURN_TOTAL sats"
echo ""

# Get state
STATE=$($SSH ubuntu@${SEED_IP} "~/bathron-cli -testnet getstate")
M0_TOTAL=$(echo "$STATE" | jq -r '.supply.m0_total')

echo "[3] getstate M0 total: $M0_TOTAL sats"
echo ""

echo "==================================================================================="
echo "ANALYSIS"
echo "==================================================================================="
echo ""

# Check consistency between minted and getstate
if [ "$TOTAL_MINTED" -eq "$M0_TOTAL" ]; then
    echo "✓ getstate matches blockchain: $M0_TOTAL sats"
else
    echo "⚠️  MISMATCH between getstate ($M0_TOTAL) and blockchain mints ($TOTAL_MINTED)"
fi
echo ""

# Check A5 invariant
DISCREPANCY=$((TOTAL_MINTED - BURN_TOTAL))
echo "Invariant A5: M0_total = sum(BurnClaims)"
echo ""
echo "  Actual M0 (minted):   $TOTAL_MINTED sats"
echo "  Expected (burns):     $BURN_TOTAL sats"
echo "  DISCREPANCY:          $DISCREPANCY sats"
echo ""

if [ $DISCREPANCY -eq 0 ]; then
    echo "✓✓✓ A5 SATISFIED - No consensus violation"
else
    PCT=$(awk "BEGIN {printf \"%.1f\", ($DISCREPANCY / $BURN_TOTAL) * 100}")
    echo "⚠️⚠️⚠️  CONSENSUS VIOLATION DETECTED"
    echo ""
    echo "Extra M0 created without burns: $DISCREPANCY sats ($PCT% excess)"
    echo ""
    
    # Check if it's exactly double
    RATIO=$(awk "BEGIN {printf \"%.2f\", $TOTAL_MINTED / $BURN_TOTAL}")
    echo "Ratio (minted/burned): $RATIO"
    
    if [ "$RATIO" = "2.00" ] || [ "$RATIO" = "2.01" ] || [ "$RATIO" = "1.99" ]; then
        echo ""
        echo "💡 HYPOTHESIS: Burns are being DOUBLE-COUNTED!"
        echo "   Each burn is minting M0 TWICE."
    fi
    
    echo ""
    echo "[4] Checking for duplicate mints per burn claim..."
    echo ""
    
    # Check block 23 (first big mint) and block 138-151 (subsequent mints)
    echo "Block 23 minted: (genesis batch)"
    $SSH ubuntu@${SEED_IP} "~/bathron-cli -testnet getblock \$(~/bathron-cli -testnet getblockhash 23) 2" | \
        jq -r '.tx[] | select(.type == 32) | .vout[] | .value' | awk '{sum+=$1} END {print "  Total: " int(sum) " sats"}'
    
    echo ""
    echo "Blocks 138-151 minted: (subsequent claims)"
    for h in {138..151}; do
        BLOCK=$($SSH ubuntu@${SEED_IP} "~/bathron-cli -testnet getblock \$(~/bathron-cli -testnet getblockhash $h) 2")
        MINT_COUNT=$(echo "$BLOCK" | jq '[.tx[] | select(.type == 32)] | length')
        if [ "$MINT_COUNT" -gt 0 ]; then
            BLOCK_TOTAL=$(echo "$BLOCK" | jq -r '.tx[] | select(.type == 32) | .vout[] | .value' | awk '{sum+=$1} END {print int(sum)}')
            echo "  Block $h: $BLOCK_TOTAL sats"
        fi
    done
    
    echo ""
    echo "[5] Comparing mint timings to burn claim status..."
    echo ""
    echo "Burns by finalization height:"
    echo "$BURNS" | jq -r '.[] | select(.db_status == "final") | "  Height \(.final_height): \(.burned_sats) sats (burn \(.btc_height))"' | sort -n
    
    echo ""
    echo "DIAGNOSTIC: Check if each finalized burn has TWO mints:"
    echo "  - One at genesis (block 23)"
    echo "  - One at finalization height"
fi

echo ""
echo "==================================================================================="
echo "INVESTIGATION COMPLETE"
echo "==================================================================================="
