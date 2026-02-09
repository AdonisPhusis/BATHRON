#!/bin/bash
# random_unlocks.sh - Unlock random M1 receipts for testing
# Usage: ./random_unlocks.sh [count] [delay_seconds]

set -e

# Configuration
COUNT=${1:-3}           # Number of unlocks (or "all")
DELAY=${2:-5}           # Delay between unlocks (seconds)

CLI="$HOME/BATHRON-Core/src/bathron-cli -testnet"

# Fallback for VPS nodes
if [ ! -f "$HOME/BATHRON-Core/src/bathron-cli" ]; then
    CLI="$HOME/bathron-cli -testnet"
fi

echo "=== Random M1 Unlock Script ==="
echo "Count: $COUNT unlocks"
echo "Delay: ${DELAY}s between unlocks"
echo ""

# Check connection
if ! $CLI getblockcount &>/dev/null; then
    echo "ERROR: Cannot connect to daemon"
    exit 1
fi

# Get initial state
echo "=== Initial State ==="
M0_VAULTED=$($CLI getstate 2>&1 | jq -r '.m0.vaulted')
M1_SUPPLY=$($CLI getstate 2>&1 | jq -r '.m1.supply')
echo "M0_VAULTED: $M0_VAULTED"
echo "M1_SUPPLY: $M1_SUPPLY"
echo ""

# List receipts
echo "=== Available Receipts ==="
RECEIPTS=$($CLI listreceipts 2>&1)
RECEIPT_COUNT=$(echo "$RECEIPTS" | jq 'length')
echo "Found $RECEIPT_COUNT M1 receipts"

if [ "$RECEIPT_COUNT" -eq 0 ]; then
    echo "No receipts to unlock!"
    exit 0
fi

echo "$RECEIPTS" | jq -r '.[] | "  \(.outpoint[0:20])... = \(.amount) M0"'
echo ""

# Determine how many to unlock
if [ "$COUNT" = "all" ]; then
    COUNT=$RECEIPT_COUNT
fi

if [ "$COUNT" -gt "$RECEIPT_COUNT" ]; then
    COUNT=$RECEIPT_COUNT
fi

# Shuffle and select receipts
echo "=== Unlocking $COUNT receipts ==="
TOTAL_UNLOCKED=0
UNLOCKED=0

# Get random selection of receipts
SELECTED=$(echo "$RECEIPTS" | jq -c '.[]' | shuf | head -n $COUNT)

while IFS= read -r receipt; do
    UNLOCKED=$((UNLOCKED + 1))
    OUTPOINT=$(echo "$receipt" | jq -r '.outpoint')
    AMOUNT=$(echo "$receipt" | jq -r '.amount')

    echo -n "[$UNLOCKED/$COUNT] Unlocking $AMOUNT M0 from ${OUTPOINT:0:20}... "

    # Execute unlock
    RESULT=$($CLI unlock "$OUTPOINT" 2>&1)

    if echo "$RESULT" | grep -q "txid"; then
        TXID=$(echo "$RESULT" | jq -r '.txid')
        echo "OK (txid: ${TXID:0:16}...)"
        TOTAL_UNLOCKED=$(echo "$TOTAL_UNLOCKED + $AMOUNT" | bc)
    else
        echo "FAILED: $RESULT"
    fi

    # Wait before next unlock (except last one)
    if [ $UNLOCKED -lt $COUNT ]; then
        sleep $DELAY
    fi
done <<< "$SELECTED"

echo ""
echo "=== Waiting for confirmations (60s) ==="
sleep 60

# Get final state
echo "=== Final State ==="
M0_VAULTED_AFTER=$($CLI getstate 2>&1 | jq -r '.m0.vaulted')
M1_SUPPLY_AFTER=$($CLI getstate 2>&1 | jq -r '.m1.supply')
echo "M0_VAULTED: $M0_VAULTED_AFTER"
echo "M1_SUPPLY: $M1_SUPPLY_AFTER"
echo ""

echo "=== Summary ==="
echo "Total unlocked: $TOTAL_UNLOCKED M0"
echo "Unlocks executed: $UNLOCKED"

# Verify invariant
INVARIANT_OK=$($CLI getstate 2>&1 | jq -r '.checks[] | select(.id=="A6") | .ok')
if [ "$INVARIANT_OK" = "true" ]; then
    echo "Invariant A6: ✓ OK"
else
    echo "Invariant A6: ✗ BROKEN"
fi
