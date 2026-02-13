#!/bin/bash
# Check detailed burn status including which specific burns are in burnclaimdb

set -e

SEED_IP="57.131.33.151"
SSH_KEY="$HOME/.ssh/id_ed25519_vps"
SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=15 -o BatchMode=yes"
SSH="ssh -i $SSH_KEY $SSH_OPTS"
CLI="~/BATHRON-Core/src/bathron-cli -testnet"

echo "=== Detailed Burn Status ==="
echo ""

# Get list of all burns from genesis_burns.json
GENESIS_BURNS="$HOME/BATHRON/contrib/testnet/genesis_burns.json"

echo "Checking each burn from genesis_burns.json:"
echo ""

TOTAL=0
FOUND=0
MISSING=0

while IFS= read -r line; do
    TXID=$(echo "$line" | jq -r '.btc_txid')
    HEIGHT=$(echo "$line" | jq -r '.btc_height')
    SATS=$(echo "$line" | jq -r '.burned_sats')
    
    TOTAL=$((TOTAL + 1))
    
    # Check if this burn exists in burnclaimdb
    RESULT=$($SSH ubuntu@$SEED_IP "$CLI checkburnclaim $TXID 2>/dev/null" || echo "{}")
    EXISTS=$(echo "$RESULT" | jq -r '.exists // false')
    
    if [ "$EXISTS" == "true" ]; then
        echo "  OK: $TXID (h=$HEIGHT, $SATS sats)"
        FOUND=$((FOUND + 1))
    else
        echo "  MISSING: $TXID (h=$HEIGHT, $SATS sats)"
        MISSING=$((MISSING + 1))
    fi
    
done < <(jq -c '.burns[]' "$GENESIS_BURNS")

echo ""
echo "=== Summary ==="
echo "Total burns in genesis_burns.json: $TOTAL"
echo "Found in burnclaimdb: $FOUND"
echo "Missing from burnclaimdb: $MISSING"
echo ""

# Also check bootstrap log details
echo "=== Bootstrap Log - Burn Claim Details ==="
$SSH ubuntu@$SEED_IP "grep -B2 -A2 'FAILED: error code: -8' /tmp/genesis_bootstrap.log 2>/dev/null | head -40" || echo "No details found"
echo ""

# Check if there's more info in debug.log
echo "=== Recent Debug Log Entries (burn-related) ==="
$SSH ubuntu@$SEED_IP "tail -200 ~/.bathron/testnet5/debug.log 2>/dev/null | grep -i 'burn\|TX_BURN_CLAIM\|TX_MINT' | tail -30" || echo "No entries found"

