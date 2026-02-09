#!/bin/bash
# Provision M1 for LP1 by unlocking small M1 receipts and re-locking a larger one
# Also unlocks M1 on CoreSDK and sends M0 to alice
# Usage: ./provision_lp_m1.sh [target_amount_sats]
set -e

SSH_KEY="$HOME/.ssh/id_ed25519_vps"
SSH_OPTS="-o StrictHostKeyChecking=no -o ConnectTimeout=10"
SSH="ssh -i $SSH_KEY $SSH_OPTS"

OP1_IP="57.131.33.152"
OP1_CLI="/home/ubuntu/bathron-cli -testnet"
CORESDK_IP="162.19.251.75"
CORESDK_CLI="/home/ubuntu/BATHRON-Core/src/bathron-cli -testnet"
ALICE_ADDR="yJYD2bfYYBe6qAojSzMKX949H7QoQifNAo"

TARGET="${1:-3000}"

echo "=== Provision M1 for LP1 (alice) ==="
echo "  Target: single receipt >= ${TARGET} sats"
echo ""

# Step 1: Check current state on OP1
echo "--- Step 1: Current state on OP1 ---"
OP1_STATE=$($SSH ubuntu@${OP1_IP} "$OP1_CLI getwalletstate true" 2>&1)
echo "$OP1_STATE" | python3 -c "
import sys, json
data = json.load(sys.stdin)
m0 = data.get('m0', {}).get('balance', 0)
receipts = data.get('m1', {}).get('receipts', [])
total = data.get('m1', {}).get('total', 0)
print(f'Free M0: {m0} sats')
print(f'M1: {total} sats ({len(receipts)} receipts)')
max_r = max([r.get('amount',0) for r in receipts]) if receipts else 0
print(f'Largest receipt: {max_r} sats')
"
echo ""

# Step 2: Unlock M1 receipts on OP1 to free M0
echo "--- Step 2: Unlock M1 receipts on OP1 ---"
# Unlock ALL small receipts to consolidate
UNLOCK_TOTAL=$($SSH ubuntu@${OP1_IP} "$OP1_CLI getwalletstate true" 2>&1 | python3 -c "
import sys, json
data = json.load(sys.stdin)
receipts = data.get('m1', {}).get('receipts', [])
total = sum(r.get('amount',0) for r in receipts if r.get('unlockable'))
print(total)
")
echo "Total unlockable M1: ${UNLOCK_TOTAL} sats"

if [ "${UNLOCK_TOTAL}" -gt 0 ]; then
    echo "Unlocking ${UNLOCK_TOTAL} M1 → M0..."
    UNLOCK_RESULT=$($SSH ubuntu@${OP1_IP} "$OP1_CLI unlock ${UNLOCK_TOTAL}" 2>&1)
    echo "Result: $UNLOCK_RESULT"
    echo ""

    # Wait for confirmation
    echo "Waiting 15s for unlock confirmation..."
    sleep 15
else
    echo "No M1 to unlock on OP1"
fi

# Step 3: Also unlock a receipt on CoreSDK and send M0 to alice
echo "--- Step 3: Unlock M1 on CoreSDK and send M0 ---"
CORESDK_STATE=$($SSH ubuntu@${CORESDK_IP} "$CORESDK_CLI getwalletstate true" 2>&1)
CORESDK_M0=$(echo "$CORESDK_STATE" | python3 -c "
import sys, json
data = json.load(sys.stdin)
print(data.get('m0', {}).get('balance', 0))
")
echo "CoreSDK free M0: ${CORESDK_M0} sats"

# Unlock 1351 sats receipt (smallest useful one)
echo "Unlocking 1351 M1 on CoreSDK..."
UNLOCK2=$($SSH ubuntu@${CORESDK_IP} "$CORESDK_CLI unlock 1351" 2>&1)
echo "Result: $UNLOCK2"
echo "Waiting 15s..."
sleep 15

# Check updated M0 balance
NEW_M0=$($SSH ubuntu@${CORESDK_IP} "$CORESDK_CLI getwalletstate true" 2>&1 | python3 -c "
import sys, json
data = json.load(sys.stdin)
print(data.get('m0', {}).get('balance', 0))
")
echo "CoreSDK new free M0: ${NEW_M0} sats"

# Send M0 to alice
SEND_AMOUNT=$((NEW_M0 - 200))  # Keep 200 for fees
if [ $SEND_AMOUNT -gt 0 ]; then
    SEND_M0=$(echo "scale=8; $SEND_AMOUNT / 100000000" | bc)
    echo "Sending ${SEND_AMOUNT} sats (${SEND_M0} M0) to alice..."
    SEND_RESULT=$($SSH ubuntu@${CORESDK_IP} "$CORESDK_CLI sendmany '' '{\"${ALICE_ADDR}\":${SEND_AMOUNT}}'" 2>&1)
    echo "Result: $SEND_RESULT"
    echo "Waiting 75s for confirmation..."
    sleep 75
else
    echo "Not enough M0 to send (have: ${NEW_M0})"
fi

# Step 4: Check final state and lock M1
echo "--- Step 4: Final lock on OP1 ---"
FINAL_STATE=$($SSH ubuntu@${OP1_IP} "$OP1_CLI getwalletstate true" 2>&1)
FINAL_M0=$(echo "$FINAL_STATE" | python3 -c "
import sys, json
data = json.load(sys.stdin)
print(data.get('m0', {}).get('balance', 0))
")
echo "Alice final free M0: ${FINAL_M0} sats"

# Lock most of the M0 as M1
LOCK_AMOUNT=$((FINAL_M0 - 1000))  # Keep 1000 for fees
if [ $LOCK_AMOUNT -gt 0 ]; then
    echo "Locking ${LOCK_AMOUNT} M0 → M1..."
    LOCK_RESULT=$($SSH ubuntu@${OP1_IP} "$OP1_CLI lock ${LOCK_AMOUNT}" 2>&1)
    echo "Result: $LOCK_RESULT"
    echo "Waiting 70s for confirmation..."
    sleep 70

    # Final check
    echo ""
    echo "--- Final M1 state on OP1 ---"
    $SSH ubuntu@${OP1_IP} "$OP1_CLI getwalletstate true" 2>&1 | python3 -c "
import sys, json
data = json.load(sys.stdin)
m0 = data.get('m0', {}).get('balance', 0)
receipts = data.get('m1', {}).get('receipts', [])
total = data.get('m1', {}).get('total', 0)
print(f'Free M0: {m0} sats')
print(f'M1: {total} sats ({len(receipts)} receipts)')
for r in receipts:
    print(f'  {r[\"outpoint\"]}: {r[\"amount\"]} sats')
"
else
    echo "Not enough M0 to lock (have: ${FINAL_M0})"
fi

echo ""
echo "✓ Done"
