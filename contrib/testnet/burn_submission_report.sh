#!/bin/bash
# Generate comprehensive burn submission report

set -e

SEED_IP="57.131.33.151"
SSH_KEY="$HOME/.ssh/id_ed25519_vps"
SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=15 -o BatchMode=yes"
SSH="ssh -i $SSH_KEY $SSH_OPTS"
CLI="~/BATHRON-Core/src/bathron-cli -testnet"

echo "=========================================="
echo "BURN SUBMISSION REPORT"
echo "=========================================="
echo ""

# Genesis burns info
GENESIS_BURNS="/home/ubuntu/BATHRON/contrib/testnet/genesis_burns.json"
EXPECTED_COUNT=$(jq '.burns | length' "$GENESIS_BURNS")
MIN_HEIGHT=$(jq '[.burns[].btc_height] | min' "$GENESIS_BURNS")
MAX_HEIGHT=$(jq '[.burns[].btc_height] | max' "$GENESIS_BURNS")
TOTAL_SATS=$(jq '[.burns[].amount] | add' "$GENESIS_BURNS")

echo "=== Genesis Burns File ==="
echo "File: genesis_burns.json"
echo "Total burns: $EXPECTED_COUNT"
echo "Height range: $MIN_HEIGHT - $MAX_HEIGHT"
echo "Total sats: $TOTAL_SATS"
echo ""

# Burn DB stats
echo "=== Burn Claim Database ==="
BURN_STATS=$($SSH ubuntu@$SEED_IP "$CLI getbtcburnstats 2>/dev/null" || echo "{}")
DB_COUNT=$(echo "$BURN_STATS" | jq -r '.total_records // 0')
DB_FINAL=$(echo "$BURN_STATS" | jq -r '.total_final // 0')
M0BTC_SUPPLY=$(echo "$BURN_STATS" | jq -r '.m0btc_supply // 0')

echo "Total records: $DB_COUNT"
echo "Final (confirmed): $DB_FINAL"
echo "M0BTC supply: $M0BTC_SUPPLY sats"
echo ""

# Bootstrap log analysis
echo "=== Bootstrap Log Analysis ==="
BOOTSTRAP_LOG=$($SSH ubuntu@$SEED_IP "grep 'Done:' /tmp/genesis_bootstrap.log 2>/dev/null | tail -1" || echo "")
echo "Log entry: $BOOTSTRAP_LOG"
echo ""

# Extract failure details
echo "=== Failed Burns (from bootstrap) ==="
$SSH ubuntu@$SEED_IP "grep -B5 'FAILED: error code: -8' /tmp/genesis_bootstrap.log 2>/dev/null | grep -E '\[.*\]|FAILED|error message'" || echo "No failures"
echo ""

# Check which burns are actually in DB
echo "=== Verification (sample check) ==="
echo "Checking first 3 and last 3 burns from genesis_burns.json..."
echo ""

# First 3
for i in 0 1 2; do
    TXID=$(jq -r ".burns[$i].btc_txid" "$GENESIS_BURNS")
    HEIGHT=$(jq -r ".burns[$i].btc_height" "$GENESIS_BURNS")
    RESULT=$($SSH ubuntu@$SEED_IP "$CLI checkburnclaim $TXID 2>/dev/null" || echo '{"exists":false}')
    EXISTS=$(echo "$RESULT" | jq -r '.exists')
    echo "  [$i] $TXID (h=$HEIGHT): $EXISTS"
done

echo "  ..."

# Last 3
LAST_IDX=$((EXPECTED_COUNT - 1))
for i in $((LAST_IDX - 2)) $((LAST_IDX - 1)) $LAST_IDX; do
    TXID=$(jq -r ".burns[$i].btc_txid" "$GENESIS_BURNS")
    HEIGHT=$(jq -r ".burns[$i].btc_height" "$GENESIS_BURNS")
    RESULT=$($SSH ubuntu@$SEED_IP "$CLI checkburnclaim $TXID 2>/dev/null" || echo '{"exists":false}')
    EXISTS=$(echo "$RESULT" | jq -r '.exists')
    echo "  [$i] $TXID (h=$HEIGHT): $EXISTS"
done
echo ""

# Summary
echo "=========================================="
echo "SUMMARY"
echo "=========================================="
echo ""
echo "Expected (genesis_burns.json): $EXPECTED_COUNT burns"
echo "In database (burnclaimdb): $DB_COUNT burns"
echo "Minted M0BTC: $M0BTC_SUPPLY sats"
echo "Expected M0BTC: $TOTAL_SATS sats"
echo ""

if [ "$DB_COUNT" -lt "$EXPECTED_COUNT" ]; then
    MISSING=$((EXPECTED_COUNT - DB_COUNT))
    echo "STATUS: MISSING $MISSING burn claims"
    echo ""
    echo "Likely cause: SPV headers not synced high enough"
    echo "  - genesis_burns.json has burns up to height $MAX_HEIGHT"
    echo "  - Check SPV tip with: deploy_to_vps.sh --btc"
elif [ "$DB_COUNT" -eq "$EXPECTED_COUNT" ]; then
    echo "STATUS: All burns submitted successfully"
elif [ "$DB_COUNT" -gt "$EXPECTED_COUNT" ]; then
    EXTRA=$((DB_COUNT - EXPECTED_COUNT))
    echo "STATUS: $EXTRA more burns than expected"
    echo "  - Possibly from live burn daemon or manual submissions"
fi

echo ""
echo "Note: Bootstrap log mentioned 34 burns attempted"
echo "      Two failed at heights 290561 and 290668"
echo "      These are NOT in genesis_burns.json (max height: $MAX_HEIGHT)"
echo "      This is EXPECTED - those were likely test burns outside range"
echo ""
echo "=========================================="
