#!/bin/bash
# Identify who owns the HTLC recipient address

SSH_KEY="$HOME/.ssh/id_ed25519_vps"
SSH_OPTS="-i $SSH_KEY -o StrictHostKeyChecking=no -o ConnectTimeout=10"

OP1_IP="57.131.33.152"   # Alice (LP)
OP3_IP="51.75.31.44"     # Charlie (user)
M1_CLI="\$HOME/bathron-cli -testnet"

HTLC_ADDR="8px7CVhtSg8RH5DKVsHYAfP8676CCoahjL"
SECRET="8f894b5829fc8f4096a9f177260e7cb46c175f2961ade379b58cdcdd338c36ef"
HTLC_OUTPOINT="31ea186b4a59f89d99bc93fe57cabe829e3c68e4df00cef74fa36c5a55651063:0"

echo "=== IDENTIFYING HTLC OWNER ==="
echo ""
echo "HTLC recipient address: $HTLC_ADDR"
echo ""

echo "1. Checking if Alice owns this address..."
ALICE_CHECK=$(ssh $SSH_OPTS ubuntu@$OP1_IP "$M1_CLI validateaddress '$HTLC_ADDR'" 2>&1)
echo "$ALICE_CHECK"
echo ""

echo "2. Checking if Charlie owns this address..."
CHARLIE_CHECK=$(ssh $SSH_OPTS ubuntu@$OP3_IP "$M1_CLI validateaddress '$HTLC_ADDR'" 2>&1)
echo "$CHARLIE_CHECK"
echo ""

# Try to claim from whoever owns it
echo "3. Attempting claim from Alice (OP1)..."
ssh $SSH_OPTS ubuntu@$OP1_IP "$M1_CLI htlc_claim '$HTLC_OUTPOINT' '$SECRET'" 2>&1
echo ""

echo "4. Attempting claim from Charlie (OP3)..."
ssh $SSH_OPTS ubuntu@$OP3_IP "$M1_CLI htlc_claim '$HTLC_OUTPOINT' '$SECRET'" 2>&1
