#!/bin/bash
set -euo pipefail

SEED_IP="57.131.33.151"
SSH_KEY="$HOME/.ssh/id_ed25519_vps"
SSH="ssh -i $SSH_KEY -o ConnectTimeout=10 -o StrictHostKeyChecking=no"

echo "==================================================================================="
echo "M0 SUPPLY DISCREPANCY ANALYSIS"
echo "==================================================================================="
echo ""

# Get state
STATE=$($SSH ubuntu@${SEED_IP} "~/bathron-cli -testnet getstate")
M0_TOTAL=$(echo "$STATE" | jq -r '.supply.m0_total')
M0_VAULTED=$(echo "$STATE" | jq -r '.supply.m0_vaulted')
M1_SUPPLY=$(echo "$STATE" | jq -r '.supply.m1_supply')

echo "Current State:"
echo "  M0 Total:   $M0_TOTAL sats"
echo "  M0 Vaulted: $M0_VAULTED sats"
echo "  M1 Supply:  $M1_SUPPLY sats"
echo ""

# Get burn claims
BURNS=$($SSH ubuntu@${SEED_IP} "~/bathron-cli -testnet listburnclaims all 100")

# Count and sum
BURN_COUNT=$(echo "$BURNS" | jq 'length')
BURN_TOTAL=$(echo "$BURNS" | jq '[.[].burned_sats] | add')

echo "Burn Claims:"
echo "  Total Claims: $BURN_COUNT"
echo "  Total Burned: $BURN_TOTAL sats"
echo ""

# Break down by status
FINAL_COUNT=$(echo "$BURNS" | jq '[.[] | select(.db_status == "final")] | length')
FINAL_TOTAL=$(echo "$BURNS" | jq '[.[] | select(.db_status == "final") | .burned_sats] | add')
PENDING_COUNT=$(echo "$BURNS" | jq '[.[] | select(.db_status == "pending")] | length')
PENDING_TOTAL=$(echo "$BURNS" | jq '[.[] | select(.db_status == "pending") | .burned_sats] | add')

echo "By Status:"
echo "  Final:   $FINAL_COUNT claims, $FINAL_TOTAL sats"
echo "  Pending: $PENDING_COUNT claims, $PENDING_TOTAL sats"
echo ""

# Calculate discrepancy
DISCREPANCY=$((M0_TOTAL - BURN_TOTAL))
echo "==================================================================================="
echo "DISCREPANCY: $DISCREPANCY sats"
echo "==================================================================================="
echo ""

if [ $DISCREPANCY -ne 0 ]; then
    echo "⚠️  CONSENSUS VIOLATION DETECTED"
    echo ""
    echo "Invariant A5 states: M0_total = sum of burn claims ONLY"
    echo "But we have:"
    echo "  Expected M0:  $BURN_TOTAL sats (from burns)"
    echo "  Actual M0:    $M0_TOTAL sats"
    echo "  Extra:        $DISCREPANCY sats created without burns!"
    echo ""
    
    # Check if extra M0 = pending burns
    if [ $DISCREPANCY -eq $PENDING_TOTAL ]; then
        echo "Hypothesis: Pending burns already minted?"
        echo "  Pending total: $PENDING_TOTAL sats"
        echo "  Discrepancy:   $DISCREPANCY sats"
        echo "  MATCH! Pending burns may have been prematurely minted."
    fi
    
    echo ""
    echo "Checking TX_MINT_M0BTC transactions..."
    
    # Get blockchain height
    HEIGHT=$($SSH ubuntu@${SEED_IP} "~/bathron-cli -testnet getblockcount")
    
    # Scan first 20 blocks for mints
    echo ""
    echo "TX_MINT_M0BTC in blocks 0-20:"
    for h in {0..20}; do
        HASH=$($SSH ubuntu@${SEED_IP} "~/bathron-cli -testnet getblockhash $h")
        BLOCK=$($SSH ubuntu@${SEED_IP} "~/bathron-cli -testnet getblock $HASH 2")
        
        MINTS=$(echo "$BLOCK" | jq -r '.tx[] | select(.type == 32) | {txid: .txid, vout: [.vout[] | {value: .value, scriptPubKey: .scriptPubKey.hex}]}')
        
        if [ -n "$MINTS" ]; then
            echo "  Block $h:"
            echo "$MINTS" | jq -c '.'
        fi
    done
else
    echo "✓ A5 satisfied: M0_total = BurnClaims"
fi

echo ""
echo "Analysis complete."
