#!/bin/bash
# Verify what command was used in step 2

SSH_KEY="$HOME/.ssh/id_ed25519_vps"
SSH_OPTS="-i $SSH_KEY -o StrictHostKeyChecking=no -o ConnectTimeout=10"

OP1_IP="57.131.33.152"   # Alice (LP)
OP3_IP="51.75.31.44"     # Charlie (user)
M1_CLI="\$HOME/bathron-cli -testnet"

echo "=== VERIFYING STEP 2 ISSUE ==="
echo ""

echo "1. Charlie's BATHRON address:"
CHARLIE_ADDR=$(ssh $SSH_OPTS ubuntu@$OP3_IP "$M1_CLI getnewaddress" 2>&1)
echo "   $CHARLIE_ADDR"
echo ""

echo "2. Alice's BATHRON address:"
ALICE_ADDR=$(ssh $SSH_OPTS ubuntu@$OP1_IP "$M1_CLI getnewaddress" 2>&1)
echo "   $ALICE_ADDR"
echo ""

echo "3. Check htlc_lock_m1 RPC help:"
ssh $SSH_OPTS ubuntu@$OP1_IP "$M1_CLI help htlc_lock_m1" 2>&1
echo ""

echo "=== CONCLUSION ==="
echo "Step 2 should have been:"
echo "  htlc_lock_m1 <m1_receipt_outpoint> <hashlock> <expiry_height> <recipient_address>"
echo ""
echo "Where recipient_address = Charlie's address = $CHARLIE_ADDR"
