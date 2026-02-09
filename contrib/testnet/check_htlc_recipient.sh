#!/bin/bash
# Check who the HTLC recipient is

SSH_KEY="$HOME/.ssh/id_ed25519_vps"
SSH_OPTS="-i $SSH_KEY -o StrictHostKeyChecking=no -o ConnectTimeout=10"

OP1_IP="57.131.33.152"   # Alice (LP)
OP3_IP="51.75.31.44"     # Charlie (user)
M1_CLI="\$HOME/bathron-cli -testnet"

HTLC_OUTPOINT="31ea186b4a59f89d99bc93fe57cabe829e3c68e4df00cef74fa36c5a55651063:0"

echo "=== HTLC RECIPIENT CHECK ==="
echo ""

echo "1. Charlie's address:"
ssh $SSH_OPTS ubuntu@$OP3_IP "$M1_CLI getaccountaddress ''" 2>&1
echo ""

echo "2. Alice's address:"
ssh $SSH_OPTS ubuntu@$OP1_IP "$M1_CLI getaccountaddress ''" 2>&1
echo ""

echo "3. HTLC details (from Alice's node):"
ssh $SSH_OPTS ubuntu@$OP1_IP "$M1_CLI htlc_get '$HTLC_OUTPOINT'" 2>&1
echo ""

echo "4. Can Alice claim it?"
echo "   Testing on OP1 (Alice)..."
ssh $SSH_OPTS ubuntu@$OP1_IP "$M1_CLI htlc_claim '$HTLC_OUTPOINT' '8f894b5829fc8f4096a9f177260e7cb46c175f2961ade379b58cdcdd338c36ef'" 2>&1
