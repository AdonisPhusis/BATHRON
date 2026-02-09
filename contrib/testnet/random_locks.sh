#!/bin/bash
# random_locks.sh - Lock random amounts of M0 for testing
# Usage: ./random_locks.sh [count] [min_amount] [max_amount] [delay_seconds]

set -e

# Configuration
COUNT=${1:-5}           # Number of locks to create
MIN_AMOUNT=${2:-100}    # Minimum amount to lock
MAX_AMOUNT=${3:-10000}  # Maximum amount to lock
DELAY=${4:-5}           # Delay between locks (seconds)

CLI="$HOME/BATHRON-Core/src/bathron-cli -testnet"

echo "=== Random M0 Lock Script ==="
echo "Count: $COUNT locks"
echo "Amount range: $MIN_AMOUNT - $MAX_AMOUNT M0"
echo "Delay: ${DELAY}s between locks"
echo ""

# Check connection
if ! $CLI getblockcount &>/dev/null; then
    echo "ERROR: Cannot connect to daemon"
    exit 1
fi

# Get initial state
echo "=== Initial State ==="
BALANCE=$($CLI getbalance 2>&1 | jq -r '.m0')
M0_VAULTED=$($CLI getstate 2>&1 | jq -r '.m0.vaulted')
M1_SUPPLY=$($CLI getstate 2>&1 | jq -r '.m1.supply')
echo "M0 Balance: $BALANCE"
echo "M0_VAULTED: $M0_VAULTED"
echo "M1_SUPPLY: $M1_SUPPLY"
echo ""

# Create locks
echo "=== Creating $COUNT random locks ==="
TOTAL_LOCKED=0

for i in $(seq 1 $COUNT); do
    # Generate random amount
    RANGE=$((MAX_AMOUNT - MIN_AMOUNT))
    RANDOM_OFFSET=$((RANDOM % RANGE))
    AMOUNT=$((MIN_AMOUNT + RANDOM_OFFSET))

    echo -n "[$i/$COUNT] Locking $AMOUNT M0... "

    # Execute lock
    RESULT=$($CLI lock $AMOUNT 2>&1)

    if echo "$RESULT" | grep -q "txid"; then
        TXID=$(echo "$RESULT" | jq -r '.txid')
        echo "OK (txid: ${TXID:0:16}...)"
        TOTAL_LOCKED=$((TOTAL_LOCKED + AMOUNT))
    else
        echo "FAILED: $RESULT"
    fi

    # Wait before next lock (except last one)
    if [ $i -lt $COUNT ]; then
        sleep $DELAY
    fi
done

echo ""
echo "=== Waiting for confirmations (60s) ==="
sleep 60

# Get final state
echo "=== Final State ==="
BALANCE_AFTER=$($CLI getbalance 2>&1 | jq -r '.m0')
M0_VAULTED_AFTER=$($CLI getstate 2>&1 | jq -r '.m0.vaulted')
M1_SUPPLY_AFTER=$($CLI getstate 2>&1 | jq -r '.m1.supply')
echo "M0 Balance: $BALANCE_AFTER"
echo "M0_VAULTED: $M0_VAULTED_AFTER"
echo "M1_SUPPLY: $M1_SUPPLY_AFTER"
echo ""

echo "=== Summary ==="
echo "Total locked: $TOTAL_LOCKED M0"
echo "Locks created: $COUNT"

# Verify invariant
INVARIANT_OK=$($CLI getstate 2>&1 | jq -r '.checks[] | select(.id=="A6") | .ok')
if [ "$INVARIANT_OK" = "true" ]; then
    echo "Invariant A6: ✓ OK"
else
    echo "Invariant A6: ✗ BROKEN"
fi
