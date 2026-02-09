#!/bin/bash
#
# Simple M1 HTLC test - one HTLC only
#

SSH_KEY="$HOME/.ssh/id_ed25519_vps"
SSH_OPTS="-i $SSH_KEY -o StrictHostKeyChecking=no -o ConnectTimeout=10"

OP1_IP="57.131.33.152"   # LP (alice)
OP3_IP="51.75.31.44"     # User (charlie)

M1_CLI="\$HOME/bathron-cli -testnet"

echo "=== SIMPLE M1 HTLC TEST ==="
echo ""

# Step 1: Generate secret
echo "1. Generating secret..."
HTLC_GEN=$(ssh $SSH_OPTS ubuntu@$OP3_IP "$M1_CLI htlc_generate" 2>&1)
echo "   Result: $HTLC_GEN"

SECRET=$(echo "$HTLC_GEN" | python3 -c "import json,sys; print(json.load(sys.stdin).get('secret',''))" 2>/dev/null)
HASHLOCK=$(echo "$HTLC_GEN" | python3 -c "import json,sys; print(json.load(sys.stdin).get('hashlock',''))" 2>/dev/null)

echo "   Secret: $SECRET"
echo "   Hashlock: $HASHLOCK"
echo ""

# Step 2: Get user's receipt
echo "2. Getting user's M1 receipt..."
USER_STATE=$(ssh $SSH_OPTS ubuntu@$OP3_IP "$M1_CLI getwalletstate true" 2>&1)
echo "   Wallet state:"
echo "$USER_STATE" | python3 -c "
import json, sys
d = json.load(sys.stdin)
m1 = d.get('m1', {})
print(f\"   M1 total: {m1.get('total', 0)} sats\")
print(f\"   Receipts: {m1.get('count', 0)}\")
for r in m1.get('receipts', [])[:3]:
    print(f\"     - {r.get('outpoint')}: {r.get('amount')} sats (unlockable={r.get('unlockable')})\")
"

USER_RECEIPT=$(echo "$USER_STATE" | python3 -c "
import json, sys
d = json.load(sys.stdin)
for r in d.get('m1', {}).get('receipts', []):
    if r.get('amount', 0) >= 50000 and r.get('unlockable', False):
        print(r.get('outpoint', ''))
        break
" 2>/dev/null)

echo "   Selected receipt: $USER_RECEIPT"
echo ""

# Step 3: Get LP address
echo "3. Getting LP claim address..."
LP_ADDR=$(ssh $SSH_OPTS ubuntu@$OP1_IP "$M1_CLI getnewaddress 'htlc_test'" 2>&1)
echo "   LP address: $LP_ADDR"
echo ""

# Step 4: Create HTLC
echo "4. Creating M1 HTLC..."
echo "   Command: htlc_create_m1 \"$USER_RECEIPT\" \"$HASHLOCK\" \"$LP_ADDR\" 30"

HTLC_RESULT=$(ssh $SSH_OPTS ubuntu@$OP3_IP "$M1_CLI htlc_create_m1 \"$USER_RECEIPT\" \"$HASHLOCK\" \"$LP_ADDR\" 30" 2>&1)
echo "   Result: $HTLC_RESULT"

HTLC_OUTPOINT=$(echo "$HTLC_RESULT" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('htlc_outpoint', d.get('txid','')+':0'))" 2>/dev/null || echo "")
echo "   HTLC outpoint: $HTLC_OUTPOINT"
echo ""

# Step 5: Wait and check status
echo "5. Checking HTLC status..."
sleep 5
HTLC_STATUS=$(ssh $SSH_OPTS ubuntu@$OP1_IP "$M1_CLI htlc_get \"$HTLC_OUTPOINT\"" 2>&1)
echo "   Status: $HTLC_STATUS"
echo ""

# Step 6: LP claims with secret
echo "6. LP claiming HTLC with secret..."
echo "   Command: htlc_claim \"$HTLC_OUTPOINT\" \"$SECRET\""

CLAIM_RESULT=$(ssh $SSH_OPTS ubuntu@$OP1_IP "$M1_CLI htlc_claim \"$HTLC_OUTPOINT\" \"$SECRET\"" 2>&1)
echo "   Result: $CLAIM_RESULT"
echo ""

echo "=== TEST COMPLETE ==="
