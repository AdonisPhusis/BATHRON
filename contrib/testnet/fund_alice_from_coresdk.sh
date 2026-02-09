#!/bin/bash
# Unlock M1 on CoreSDK (bob) and send M0 to alice (LP1)
set -e

SSH_KEY="$HOME/.ssh/id_ed25519_vps"
SSH_OPTS="-o StrictHostKeyChecking=no -o ConnectTimeout=15"
SSH="ssh -i $SSH_KEY $SSH_OPTS"

CORESDK_IP="162.19.251.75"
CLI="/home/ubuntu/BATHRON-Core/src/bathron-cli -testnet"
ALICE_ADDR="yJYD2bfYYBe6qAojSzMKX949H7QoQifNAo"
OP1_IP="57.131.33.152"
OP1_CLI="/home/ubuntu/bathron-cli -testnet"

echo "=== Fund alice from CoreSDK (bob) ==="
echo ""

# Step 1: Check CoreSDK state
echo "--- Step 1: CoreSDK wallet state ---"
$SSH ubuntu@${CORESDK_IP} "$CLI getwalletstate true" 2>&1 | python3 -c "
import sys, json
data = json.load(sys.stdin)
m0 = data.get('m0', {}).get('balance', 0)
receipts = data.get('m1', {}).get('receipts', [])
total = data.get('m1', {}).get('total', 0)
print(f'Free M0: {m0} sats')
print(f'M1: {total} sats ({len(receipts)} receipts)')
for r in receipts:
    print(f'  {r[\"outpoint\"]}: {r[\"amount\"]} sats unlockable={r.get(\"unlockable\")}')
"
echo ""

# Step 2: Unlock 10000 M1 on CoreSDK
echo "--- Step 2: Unlock 10000 M1 on CoreSDK ---"
UNLOCK_RESULT=$($SSH ubuntu@${CORESDK_IP} "$CLI unlock 10000" 2>&1)
echo "Unlock result: $UNLOCK_RESULT"
echo ""

if echo "$UNLOCK_RESULT" | grep -qi "error"; then
    echo "Unlock failed. Trying smaller amount: 5000"
    UNLOCK_RESULT=$($SSH ubuntu@${CORESDK_IP} "$CLI unlock 5000" 2>&1)
    echo "Unlock result: $UNLOCK_RESULT"
    echo ""
fi

# Step 3: Wait for block
echo "--- Step 3: Waiting 70s for confirmation ---"
sleep 70

# Step 4: Check new balance and send
echo "--- Step 4: Check and send M0 to alice ---"
NEW_M0=$($SSH ubuntu@${CORESDK_IP} "$CLI getwalletstate true" 2>&1 | python3 -c "
import sys, json
data = json.load(sys.stdin)
print(data.get('m0', {}).get('balance', 0))
")
echo "CoreSDK free M0: ${NEW_M0} sats"

SEND_AMOUNT=$((NEW_M0 - 500))
if [ $SEND_AMOUNT -lt 1000 ]; then
    echo "Not enough M0 to send (have ${NEW_M0}, need > 1500)"
    exit 1
fi

echo "Sending ${SEND_AMOUNT} sats to alice (${ALICE_ADDR})..."
SEND_RESULT=$($SSH ubuntu@${CORESDK_IP} "$CLI sendmany '' '{\"${ALICE_ADDR}\":${SEND_AMOUNT}}'" 2>&1)
echo "Send result: $SEND_RESULT"
echo ""

# Step 5: Wait for confirmation
echo "--- Step 5: Waiting 70s for send confirmation ---"
sleep 70

# Step 6: Lock M1 on OP1
echo "--- Step 6: Lock M0 → M1 on OP1 ---"
ALICE_M0=$($SSH ubuntu@${OP1_IP} "$OP1_CLI getwalletstate true" 2>&1 | python3 -c "
import sys, json
data = json.load(sys.stdin)
print(data.get('m0', {}).get('balance', 0))
")
echo "Alice free M0: ${ALICE_M0} sats"

LOCK_AMOUNT=$((ALICE_M0 - 1000))
if [ $LOCK_AMOUNT -lt 2000 ]; then
    echo "Not enough M0 to lock meaningfully"
    exit 1
fi

echo "Locking ${LOCK_AMOUNT} M0 → M1..."
LOCK_RESULT=$($SSH ubuntu@${OP1_IP} "$OP1_CLI lock ${LOCK_AMOUNT}" 2>&1)
echo "Lock result: $LOCK_RESULT"
echo ""

# Step 7: Wait + verify
echo "--- Step 7: Wait 70s + verify ---"
sleep 70

echo "--- Final state ---"
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

echo ""
echo "✓ Done"
