#!/bin/bash
# stress_lockunlock.sh - Continuous lock/unlock stress test
# Usage: ./stress_lockunlock.sh [duration_minutes] [min_amount] [max_amount]

set -e

DURATION_MIN=${1:-20}
MIN_AMOUNT=${2:-100}
MAX_AMOUNT=${3:-5000}

CLI="$HOME/BATHRON-Core/src/bathron-cli -testnet"

# Fallback for VPS nodes
if [ ! -f "$HOME/BATHRON-Core/src/bathron-cli" ]; then
    CLI="$HOME/bathron-cli -testnet"
fi

echo "╔══════════════════════════════════════════════════════════════╗"
echo "║  M0 Lock/Unlock Stress Test                                  ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""
echo "Duration: ${DURATION_MIN} minutes"
echo "Amount range: ${MIN_AMOUNT} - ${MAX_AMOUNT} M0"
echo "Started: $(date)"
echo ""

# Check connection
if ! $CLI getblockcount &>/dev/null; then
    echo "ERROR: Cannot connect to daemon"
    exit 1
fi

# Calculate end time
END_TIME=$(($(date +%s) + DURATION_MIN * 60))

# Counters
LOCKS=0
UNLOCKS=0
LOCK_FAILS=0
UNLOCK_FAILS=0
TOTAL_LOCKED=0
TOTAL_UNLOCKED=0

# Initial state
echo "=== Initial State ==="
$CLI getstate 2>&1 | jq '{height, M0_vaulted, M1_supply, invariant_a6_ok}'
echo ""

echo "=== Starting stress test ==="
echo ""

while [ $(date +%s) -lt $END_TIME ]; do
    REMAINING=$((END_TIME - $(date +%s)))
    REMAINING_MIN=$((REMAINING / 60))
    REMAINING_SEC=$((REMAINING % 60))

    # Random amount
    RANGE=$((MAX_AMOUNT - MIN_AMOUNT))
    AMOUNT=$((MIN_AMOUNT + RANDOM % RANGE))

    # Lock
    echo -n "[${REMAINING_MIN}m${REMAINING_SEC}s] LOCK $AMOUNT M0... "
    LOCK_RESULT=$($CLI lock $AMOUNT 2>&1)

    if echo "$LOCK_RESULT" | grep -q "txid"; then
        TXID=$(echo "$LOCK_RESULT" | jq -r '.txid')
        RECEIPT=$(echo "$LOCK_RESULT" | jq -r '.receipt_outpoint')
        echo "OK (${TXID:0:12}...)"
        LOCKS=$((LOCKS + 1))
        TOTAL_LOCKED=$((TOTAL_LOCKED + AMOUNT))

        # Wait for confirmation (1-2 blocks)
        sleep 65

        # Check receipt exists
        RECEIPTS=$($CLI listreceipts 2>&1)
        RECEIPT_COUNT=$(echo "$RECEIPTS" | jq 'length')

        if [ "$RECEIPT_COUNT" -gt 0 ]; then
            # Pick a random receipt to unlock
            INDEX=$((RANDOM % RECEIPT_COUNT))
            OUTPOINT=$(echo "$RECEIPTS" | jq -r ".[$INDEX].outpoint")
            UNLOCK_AMOUNT=$(echo "$RECEIPTS" | jq -r ".[$INDEX].amount")

            echo -n "[${REMAINING_MIN}m${REMAINING_SEC}s] UNLOCK $UNLOCK_AMOUNT M0... "
            UNLOCK_RESULT=$($CLI unlock "$OUTPOINT" 2>&1)

            if echo "$UNLOCK_RESULT" | grep -q "txid"; then
                UTXID=$(echo "$UNLOCK_RESULT" | jq -r '.txid')
                echo "OK (${UTXID:0:12}...)"
                UNLOCKS=$((UNLOCKS + 1))
                TOTAL_UNLOCKED=$(echo "$TOTAL_UNLOCKED + $UNLOCK_AMOUNT" | bc)
            else
                echo "FAILED: $UNLOCK_RESULT"
                UNLOCK_FAILS=$((UNLOCK_FAILS + 1))
            fi
        else
            echo "  (no receipts to unlock yet)"
        fi
    else
        echo "FAILED: $LOCK_RESULT"
        LOCK_FAILS=$((LOCK_FAILS + 1))
    fi

    # Brief pause
    sleep 5

    # Periodic status check
    if [ $((LOCKS % 5)) -eq 0 ] && [ $LOCKS -gt 0 ]; then
        echo ""
        echo "--- Status check ---"
        HEIGHT=$($CLI getblockcount 2>&1)
        STATE=$($CLI getstate 2>&1)
        VAULTED=$(echo "$STATE" | jq -r '.M0_vaulted')
        M1=$(echo "$STATE" | jq -r '.M1_supply')
        A6=$(echo "$STATE" | jq -r '.invariant_a6_ok')
        echo "Height: $HEIGHT | M0_VAULTED: $VAULTED | M1: $M1 | A6: $A6"
        echo "Locks: $LOCKS (fails: $LOCK_FAILS) | Unlocks: $UNLOCKS (fails: $UNLOCK_FAILS)"
        echo "---"
        echo ""
    fi
done

echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║  Stress Test Complete                                        ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""
echo "Duration: ${DURATION_MIN} minutes"
echo "Ended: $(date)"
echo ""
echo "=== Results ==="
echo "Locks:   $LOCKS successful, $LOCK_FAILS failed"
echo "Unlocks: $UNLOCKS successful, $UNLOCK_FAILS failed"
echo "Total locked:   $TOTAL_LOCKED M0"
echo "Total unlocked: $TOTAL_UNLOCKED M0"
echo ""

echo "=== Final State ==="
$CLI getstate 2>&1 | jq '{height, M0_vaulted, M1_supply, invariant_a6_ok}'

echo ""
echo "=== Network Health ==="
$CLI getblockchaininfo 2>&1 | jq '{blocks, headers}'

# Verify invariant
INVARIANT=$($CLI getstate 2>&1 | jq -r '.invariant_a6_ok')
if [ "$INVARIANT" = "true" ]; then
    echo ""
    echo "✓ Invariant A6: OK"
else
    echo ""
    echo "✗ Invariant A6: BROKEN!"
    exit 1
fi
