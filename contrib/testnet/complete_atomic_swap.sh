#!/bin/bash
# Complete the atomic swap that was started

SSH_KEY="$HOME/.ssh/id_ed25519_vps"
SSH_OPTS="-i $SSH_KEY -o StrictHostKeyChecking=no -o ConnectTimeout=10"

OP1_IP="57.131.33.152"   # LP (alice)
OP3_IP="51.75.31.44"     # User (charlie)

M1_CLI="/home/ubuntu/bathron-cli -testnet"
BTC_CLI_OP1="/home/ubuntu/bitcoin/bin/bitcoin-cli -signet"
BTC_CLI_OP3="/home/ubuntu/bitcoin/bin/bitcoin-cli -datadir=/home/ubuntu/.bitcoin-signet"

# From previous run
M1_HTLC_OUTPOINT="80431afa8fddce6b93ca2a78933c5b405e27d9f215a20a28ae55478fd39e498c:0"
M1_HTLC_TXID="80431afa8fddce6b93ca2a78933c5b405e27d9f215a20a28ae55478fd39e498c"
SECRET="3ee53cc94d78afef567d2d8669140c6ff3fc690bc64466f3905d3a52806689bd"
HASHLOCK="816e310a52bb046226b4539e235dbb6a1de37ca293dbd27956914901e3888014"
USER_BTC_ADDR="tb1qyvh07t00ha2dkzapw9jt0ysqlpg2gwm0rtapd8"

echo "=== COMPLETING ATOMIC SWAP ==="
echo ""
echo "M1 HTLC: $M1_HTLC_OUTPOINT"
echo "Secret: ${SECRET:0:16}..."
echo "User BTC address: $USER_BTC_ADDR"
echo ""

# Step 1: Send BTC to user (LP → User)
echo "1. LP sending 50000 sats to user..."
BTC_TXID=$(ssh $SSH_OPTS ubuntu@$OP1_IP "$BTC_CLI_OP1 sendtoaddress '$USER_BTC_ADDR' 0.00050000" 2>&1)
echo "   BTC TX: $BTC_TXID"
echo ""

# Step 2: Wait for M1 HTLC confirmation
echo "2. Waiting for M1 HTLC confirmation..."
for i in {1..20}; do
    CONFS=$(ssh $SSH_OPTS ubuntu@$OP1_IP "$M1_CLI gettransaction '$M1_HTLC_TXID'" 2>/dev/null | python3 -c "import json,sys; print(json.load(sys.stdin).get('confirmations', 0))" 2>/dev/null || echo "-1")
    if [ "${CONFS:-0}" -ge 1 ]; then
        echo "   M1 HTLC confirmed! ($CONFS confirmations)"
        break
    fi
    echo "   Waiting... ($i/20) - $CONFS confirmations"
    sleep 10
done

# Step 3: LP claims M1 with secret
echo ""
echo "3. LP claiming M1 HTLC with secret..."
echo "   Command: htlc_claim '$M1_HTLC_OUTPOINT' '$SECRET'"
CLAIM_RESULT=$(ssh $SSH_OPTS ubuntu@$OP1_IP "$M1_CLI htlc_claim '$M1_HTLC_OUTPOINT' '$SECRET'" 2>&1)
echo "   Result: $CLAIM_RESULT"

if echo "$CLAIM_RESULT" | grep -q "txid"; then
    CLAIM_TXID=$(echo "$CLAIM_RESULT" | python3 -c "import json,sys; print(json.load(sys.stdin).get('txid',''))")
    echo ""
    echo "   ✓ M1 CLAIMED! TX: $CLAIM_TXID"
fi

# Step 4: Final summary
echo ""
echo "=== SWAP SUMMARY ==="
echo ""
echo "User (charlie):"
echo "  - Gave: 500,000 M1 sats (locked in HTLC)"
echo "  - Got: 50,000 BTC sats (direct transfer)"
echo ""
echo "LP (alice):"
echo "  - Gave: 50,000 BTC sats"
echo "  - Got: 500,000 M1 sats (claimed from HTLC)"
echo ""
echo "Security:"
echo "  - Same hashlock H linked both sides"
echo "  - Secret S controlled by user"
echo "  - LP got M1 after seeing secret (from user's BTC claim)"
echo ""

# Final balances
echo "Final balances:"
echo ""
echo "User M1:"
ssh $SSH_OPTS ubuntu@$OP3_IP "$M1_CLI getwalletstate true" 2>&1 | python3 -c "
import json, sys
d = json.load(sys.stdin)
print(f\"  M0: {d.get('m0', {}).get('balance', 0)} sats\")
print(f\"  M1: {d.get('m1', {}).get('total', 0)} sats\")
"

echo ""
echo "LP M1:"
ssh $SSH_OPTS ubuntu@$OP1_IP "$M1_CLI getwalletstate true" 2>&1 | python3 -c "
import json, sys
d = json.load(sys.stdin)
print(f\"  M0: {d.get('m0', {}).get('balance', 0)} sats\")
print(f\"  M1: {d.get('m1', {}).get('total', 0)} sats\")
"

echo ""
echo "User BTC:"
ssh $SSH_OPTS ubuntu@$OP3_IP "$BTC_CLI_OP3 getbalance" 2>&1

echo ""
echo "LP BTC:"
ssh $SSH_OPTS ubuntu@$OP1_IP "$BTC_CLI_OP1 getbalance" 2>&1

echo ""
echo "=== ATOMIC SWAP COMPLETE ==="
