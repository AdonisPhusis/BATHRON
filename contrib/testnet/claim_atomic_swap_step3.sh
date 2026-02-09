#!/bin/bash
# Atomic Swap Step 3: Charlie claims M1 HTLC (reveals preimage S)

SSH_KEY="$HOME/.ssh/id_ed25519_vps"
SSH_OPTS="-i $SSH_KEY -o StrictHostKeyChecking=no -o ConnectTimeout=10"

OP3_IP="51.75.31.44"     # Charlie (fake user)
M1_CLI="\$HOME/bathron-cli -testnet"

# Step 3 parameters
SECRET="8f894b5829fc8f4096a9f177260e7cb46c175f2961ade379b58cdcdd338c36ef"
HTLC_OUTPOINT="31ea186b4a59f89d99bc93fe57cabe829e3c68e4df00cef74fa36c5a55651063:0"

echo "=== ATOMIC SWAP STEP 3: CHARLIE CLAIMS M1 HTLC ==="
echo ""
echo "This reveals the preimage S on the BATHRON blockchain!"
echo ""
echo "HTLC Details:"
echo "  Outpoint: $HTLC_OUTPOINT"
echo "  Secret: ${SECRET}"
echo ""

# Step 1: Check HTLC status before claim
echo "1. Checking HTLC status on OP3 (Charlie)..."
HTLC_STATUS=$(ssh $SSH_OPTS ubuntu@$OP3_IP "$M1_CLI htlc_get '$HTLC_OUTPOINT'" 2>&1)
echo "$HTLC_STATUS"
echo ""

# Step 2: Charlie claims with secret
echo "2. Charlie claiming HTLC with secret preimage..."
echo "   Command: htlc_claim '$HTLC_OUTPOINT' '$SECRET'"
CLAIM_RESULT=$(ssh $SSH_OPTS ubuntu@$OP3_IP "$M1_CLI htlc_claim '$HTLC_OUTPOINT' '$SECRET'" 2>&1)
echo "$CLAIM_RESULT"
echo ""

# Step 3: Verify claim
if echo "$CLAIM_RESULT" | grep -q "txid"; then
    CLAIM_TXID=$(echo "$CLAIM_RESULT" | python3 -c "import json,sys; print(json.load(sys.stdin).get('txid',''))" 2>/dev/null)
    echo "3. SUCCESS! HTLC CLAIMED BY CHARLIE"
    echo "   Claim TX: $CLAIM_TXID"
    echo ""
    echo "   🔓 PREIMAGE S IS NOW REVEALED ON-CHAIN!"
    echo "   Alice (LP) can now extract S from this TX to claim her BTC HTLC."
    echo ""
    
    # Wait for confirmation
    echo "4. Waiting for confirmation..."
    sleep 5
    
    # Check Charlie's wallet state
    echo ""
    echo "5. Charlie's wallet state after claim:"
    ssh $SSH_OPTS ubuntu@$OP3_IP "$M1_CLI getwalletstate true" 2>&1 | python3 -c "
import json, sys
try:
    d = json.load(sys.stdin)
    m1 = d.get('m1', {})
    print(f'   M1 total: {m1.get(\"total\", 0)} sats')
    print(f'   M1 receipts: {m1.get(\"count\", 0)}')
    print(f'   M1 available: {m1.get(\"available\", 0)} sats')
    print(f'   M1 locked_in_htlc: {m1.get(\"locked_in_htlc\", 0)} sats')
except:
    print('   (wallet state unavailable)')
"
    
    echo ""
    echo "   ✅ Step 3 complete. Charlie now has 950,000 M1 sats!"
    echo ""
    echo "NEXT STEP: Alice extracts S from TX $CLAIM_TXID and claims her BTC HTLC"
else
    echo "3. ❌ HTLC CLAIM FAILED OR PENDING"
    echo ""
    echo "Error details:"
    echo "$CLAIM_RESULT"
    echo ""
    echo "Checking HTLC status again..."
    ssh $SSH_OPTS ubuntu@$OP3_IP "$M1_CLI htlc_get '$HTLC_OUTPOINT'" 2>&1
    exit 1
fi

echo ""
echo "=== STEP 3 COMPLETE ==="
