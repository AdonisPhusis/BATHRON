#!/bin/bash
# Check M0 supply on Seed node

SSH_KEY="${SSH_KEY:-$HOME/.ssh/id_ed25519_vps}"
SSH_OPTS="-o StrictHostKeyChecking=no -o ConnectTimeout=10 -o BatchMode=yes"
SEED_IP="57.131.33.151"

echo "═══ M0 Supply Verification ═══"
echo ""

# Get state from Seed
STATE=$(ssh $SSH_OPTS -i "$SSH_KEY" ubuntu@$SEED_IP '~/bathron-cli -testnet getstate 2>/dev/null')

if [ -z "$STATE" ]; then
    echo "[ERROR] Could not get state from Seed"
    exit 1
fi

M0_TOTAL=$(echo "$STATE" | jq -r '.supply.m0_total // .totals.total_m0 // "N/A"')
M1_SUPPLY=$(echo "$STATE" | jq -r '.supply.m1_supply // .totals.total_m1 // "N/A"')
M0_VAULTED=$(echo "$STATE" | jq -r '.supply.m0_vaulted // "N/A"')
HEIGHT=$(echo "$STATE" | jq -r '.height // "N/A"')

echo "Height: $HEIGHT"
echo ""
echo "M0 Total Supply: $M0_TOTAL sats"
echo "M1 Supply:       $M1_SUPPLY sats"
echo "M0 Vaulted:      $M0_VAULTED sats"
echo ""

# Get burn claims
BURNS=$(ssh $SSH_OPTS -i "$SSH_KEY" ubuntu@$SEED_IP '~/bathron-cli -testnet listburnclaims final 100 2>/dev/null')
BURN_COUNT=$(echo "$BURNS" | jq 'length')
BURN_SUM=$(echo "$BURNS" | jq '[.[] | .amount] | add')

echo "═══ Burn Claims ═══"
echo "Final burns: $BURN_COUNT"
echo "Sum of burns: $BURN_SUM sats"
echo ""

# Verify invariants
echo "═══ Invariant Check ═══"
if [ "$M0_TOTAL" = "$BURN_SUM" ]; then
    echo "[OK] A5: M0_total ($M0_TOTAL) = Sum of burns ($BURN_SUM)"
else
    echo "[ERROR] A5 VIOLATION: M0_total ($M0_TOTAL) != Sum of burns ($BURN_SUM)"
    echo "  Difference: $((M0_TOTAL - BURN_SUM)) sats"
fi

if [ "$M0_VAULTED" = "$M1_SUPPLY" ]; then
    echo "[OK] A6: M0_vaulted ($M0_VAULTED) = M1_supply ($M1_SUPPLY)"
else
    echo "[ERROR] A6 VIOLATION: M0_vaulted ($M0_VAULTED) != M1_supply ($M1_SUPPLY)"
fi

echo ""
