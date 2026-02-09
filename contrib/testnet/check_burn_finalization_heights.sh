#!/bin/bash
set -euo pipefail

# Use Core+SDK node since Seed is offline
NODE_IP="162.19.251.75"
SSH_KEY="$HOME/.ssh/id_ed25519_vps"
SSH="ssh -i $SSH_KEY -o ConnectTimeout=10 -o StrictHostKeyChecking=no"

echo "==================================================================================="
echo "CHECK BURN FINALIZATION HEIGHTS"
echo "==================================================================================="
echo "Using node: $NODE_IP (Core+SDK)"
echo ""

echo "Querying all FINAL burns..."
BURNS=$($SSH ubuntu@${NODE_IP} "~/bathron-cli -testnet listburnclaims all 100")

echo "FINAL burns with finalization height:"
echo "$BURNS" | jq -r '.[] | select(.db_status == "final") | "\(.btc_txid[:16]) \(.burned_sats) sats | claimed: h\(.claim_height) → finalized: h\(.final_height)"' | sort -t'h' -k4 -n

echo ""
echo "==================================================================================="
echo "ANALYSIS"
echo "==================================================================================="

# Count burns by finalization height
echo ""
echo "Burns by finalization height:"
echo "$BURNS" | jq -r '.[] | select(.db_status == "final") | .final_height' | sort -n | uniq -c

echo ""
echo "If ANY burns show final_height > 23, those were minted TWICE:"
echo "  - First at block 23 (genesis batch)"
echo "  - Again at their individual finalization height"

# Check for duplicates
FINAL_AT_23=$(echo "$BURNS" | jq '[.[] | select(.db_status == "final" and .final_height == 23)] | length')
FINAL_AFTER_23=$(echo "$BURNS" | jq '[.[] | select(.db_status == "final" and .final_height > 23)] | length')

echo ""
echo "Finalized at block 23: $FINAL_AT_23"
echo "Finalized after block 23: $FINAL_AFTER_23"

if [ "$FINAL_AFTER_23" -gt 0 ]; then
    echo ""
    echo "⚠️  DOUBLE MINT CONFIRMED"
    echo "Burns finalized after block 23 were ALREADY minted at block 23!"
    echo ""
    echo "This proves each burn created M0 TWICE, violating consensus invariant A5."
fi
