#!/bin/bash
set -euo pipefail

SEED_IP="57.131.33.151"
SSH_KEY="$HOME/.ssh/id_ed25519_vps"
SSH="ssh -i $SSH_KEY -o ConnectTimeout=10 -o StrictHostKeyChecking=no"

echo "==================================================================================="
echo "QUICK M0 SUPPLY CHECK"
echo "==================================================================================="
echo ""

echo "[1] BATHRON Chain State"
echo "----------------------------"
$SSH ubuntu@${SEED_IP} "~/bathron-cli -testnet getstate"
echo ""

echo "[2] All Burn Claims"
echo "----------------------------"
$SSH ubuntu@${SEED_IP} "~/bathron-cli -testnet listburnclaims all 100"
echo ""

echo "[3] Check Block 1 (First Mint)"
echo "----------------------------"
BLOCK1=$($SSH ubuntu@${SEED_IP} "~/bathron-cli -testnet getblock \$(~/bathron-cli -testnet getblockhash 1) 2")
echo "$BLOCK1" | jq -r '.tx[] | select(.type == 32)'
echo ""

echo "[4] Summary"
echo "----------------------------"
STATE=$($SSH ubuntu@${SEED_IP} "~/bathron-cli -testnet getstate")
M0_TOTAL=$(echo "$STATE" | jq -r '.m0_total // 0')
echo "M0 Total: $M0_TOTAL sats"

BURNS=$($SSH ubuntu@${SEED_IP} "~/bathron-cli -testnet listburnclaims all 100")
BURN_TOTAL=$(echo "$BURNS" | jq -r '[.[].amount] | add // 0')
echo "Burn Claims Total: $BURN_TOTAL sats"

DIFF=$((M0_TOTAL - BURN_TOTAL))
echo "Discrepancy: $DIFF sats"

if [ $DIFF -ne 0 ]; then
    echo ""
    echo "⚠️  CONSENSUS VIOLATION: Extra $DIFF sats created without burns!"
fi
