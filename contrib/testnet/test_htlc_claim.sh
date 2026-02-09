#!/bin/bash
# Test HTLC claim by LP

SSH_KEY="$HOME/.ssh/id_ed25519_vps"
SSH_OPTS="-i $SSH_KEY -o StrictHostKeyChecking=no -o ConnectTimeout=10"

OP1_IP="57.131.33.152"   # LP (alice)
OP3_IP="51.75.31.44"     # User (charlie)

M1_CLI="\$HOME/bathron-cli -testnet"

echo "=== HTLC CLAIM TEST ==="
echo ""

# From previous test
SECRET="1158b4b41ace764f1974ffd253fd6705d1d3439bfcbe24329598cb82519586be"
HASHLOCK="035c69ef4497c7e9d8b3529e1ad15a1c885d2e44a0cbd594e40efc578a2c810c"
HTLC_OUTPOINT="33c1f8cf27a38c85dab6e1462fb1a12f17509fc3dbb76f671514d7e88309d753:0"

echo "HTLC Details:"
echo "  Outpoint: $HTLC_OUTPOINT"
echo "  Secret: ${SECRET:0:16}..."
echo "  Hashlock: ${HASHLOCK:0:16}..."
echo ""

# Step 1: Check HTLC status on LP
echo "1. Checking HTLC status on LP..."
ssh $SSH_OPTS ubuntu@$OP1_IP "$M1_CLI htlc_get '$HTLC_OUTPOINT'" 2>&1
echo ""

# Step 2: LP claims with secret
echo "2. LP claiming HTLC with secret..."
echo "   Command: htlc_claim '$HTLC_OUTPOINT' '$SECRET'"
CLAIM_RESULT=$(ssh $SSH_OPTS ubuntu@$OP1_IP "$M1_CLI htlc_claim '$HTLC_OUTPOINT' '$SECRET'" 2>&1)
echo "   Result: $CLAIM_RESULT"
echo ""

# Step 3: Verify claim
if echo "$CLAIM_RESULT" | grep -q "txid"; then
    CLAIM_TXID=$(echo "$CLAIM_RESULT" | python3 -c "import json,sys; print(json.load(sys.stdin).get('txid',''))")
    echo "3. HTLC CLAIMED SUCCESSFULLY!"
    echo "   Claim TX: $CLAIM_TXID"

    # Check LP wallet state
    echo ""
    echo "4. LP wallet state after claim:"
    ssh $SSH_OPTS ubuntu@$OP1_IP "$M1_CLI getwalletstate true" 2>&1 | python3 -c "
import json, sys
d = json.load(sys.stdin)
m1 = d.get('m1', {})
print(f'   M1 total: {m1.get(\"total\", 0)} sats')
print(f'   M1 receipts: {m1.get(\"count\", 0)}')
"

    # Check user wallet state
    echo ""
    echo "5. User wallet state after claim:"
    ssh $SSH_OPTS ubuntu@$OP3_IP "$M1_CLI getwalletstate true" 2>&1 | python3 -c "
import json, sys
d = json.load(sys.stdin)
m1 = d.get('m1', {})
print(f'   M1 total: {m1.get(\"total\", 0)} sats')
print(f'   M1 receipts: {m1.get(\"count\", 0)}')
"
else
    echo "3. HTLC claim failed or still pending"
    echo "   Checking HTLC status again..."
    ssh $SSH_OPTS ubuntu@$OP1_IP "$M1_CLI htlc_get '$HTLC_OUTPOINT'" 2>&1
fi

echo ""
echo "=== TEST COMPLETE ==="
