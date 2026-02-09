#!/bin/bash
# ==============================================================================
# verify_genesis_burns.sh - Verify all burns in genesis_burns.json exist on BTC
# ==============================================================================

set -e

# SSH config
SEED_IP="57.131.33.151"
SSH_KEY="$HOME/.ssh/id_ed25519_vps"
SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR"

# BTC CLI path on Seed
BTC_CLI="~/bitcoin-27.0/bin/bitcoin-cli -datadir=~/.bitcoin-signet"

# Genesis burns file
GENESIS_BURNS="$HOME/BATHRON/contrib/testnet/genesis_burns.json"

if [ ! -f "$GENESIS_BURNS" ]; then
    echo "ERROR: genesis_burns.json not found at $GENESIS_BURNS"
    exit 1
fi

echo "=========================================="
echo "Verifying Genesis Burns on BTC Signet"
echo "=========================================="
echo ""

# Extract all TXIDs and expected amounts from .burns[] array
TOTAL_EXPECTED=0
TOTAL_ACTUAL=0
BURN_COUNT=0
VERIFIED_COUNT=0
MISMATCH_COUNT=0

while IFS= read -r line; do
    TXID=$(echo "$line" | jq -r '.btc_txid')
    EXPECTED_SATS=$(echo "$line" | jq -r '.burned_sats')
    HEIGHT=$(echo "$line" | jq -r '.btc_height')
    
    if [ "$TXID" == "null" ] || [ -z "$TXID" ]; then
        continue
    fi
    
    BURN_COUNT=$((BURN_COUNT + 1))
    TOTAL_EXPECTED=$((TOTAL_EXPECTED + EXPECTED_SATS))
    
    echo "Burn $BURN_COUNT: $TXID (h=$HEIGHT, expected=$EXPECTED_SATS sats)"
    
    # Get TX from BTC Signet
    TX_JSON=$(ssh -i "$SSH_KEY" $SSH_OPTS ubuntu@$SEED_IP "$BTC_CLI getrawtransaction $TXID true 2>/dev/null" || echo "{}")
    
    if [ "$TX_JSON" == "{}" ]; then
        echo "  ERROR: TX not found on BTC Signet!"
        MISMATCH_COUNT=$((MISMATCH_COUNT + 1))
        continue
    fi
    
    # Extract burn amount (P2WSH unspendable outputs)
    BURN_AMOUNT=$(echo "$TX_JSON" | jq '[.vout[]? | select(.scriptPubKey.type == "witness_v0_scripthash" and .scriptPubKey.hex == "00206e340b9cffb37a989ca544e6bb780a2c78901d3fb33738768511a30617afa01d") | .value] | add // 0' 2>/dev/null)
    
    # Convert to sats (handle scientific notation)
    BURN_SATS=$(printf "%.0f" $(echo "$BURN_AMOUNT * 100000000" | bc -l))
    
    TOTAL_ACTUAL=$((TOTAL_ACTUAL + BURN_SATS))
    
    if [ "$BURN_SATS" -eq "$EXPECTED_SATS" ]; then
        echo "  OK: $BURN_SATS sats"
        VERIFIED_COUNT=$((VERIFIED_COUNT + 1))
    else
        echo "  MISMATCH: actual=$BURN_SATS sats, expected=$EXPECTED_SATS sats (diff=$((BURN_SATS - EXPECTED_SATS)))"
        MISMATCH_COUNT=$((MISMATCH_COUNT + 1))
    fi
    
done < <(jq -c '.burns[]' "$GENESIS_BURNS")

echo ""
echo "=========================================="
echo "Verification Summary"
echo "=========================================="
echo "Total burns in genesis_burns.json: $BURN_COUNT"
echo "Successfully verified: $VERIFIED_COUNT"
echo "Mismatches: $MISMATCH_COUNT"
echo ""
echo "Total expected: $TOTAL_EXPECTED sats"
echo "Total actual: $TOTAL_ACTUAL sats"
echo "Difference: $((TOTAL_ACTUAL - TOTAL_EXPECTED)) sats"
echo ""

if [ $TOTAL_ACTUAL -ne $TOTAL_EXPECTED ]; then
    echo "DISCREPANCY DETECTED!"
    echo ""
    echo "Expected total: $TOTAL_EXPECTED sats"
    echo "Actual total: $TOTAL_ACTUAL sats"
    echo "Missing: $((TOTAL_EXPECTED - TOTAL_ACTUAL)) sats"
    echo ""
    echo "Possible causes:"
    echo "1. Incorrect burn amount calculation in genesis_burns.json"
    echo "2. Missing burns not captured in genesis_burns.json"
    echo "3. BTC TX not found on Signet"
fi
