#!/bin/bash
# test_lp_m1_htlc.sh - Test M1 HTLC creation on OP1 with current wallet state

set -e

KEY="$HOME/.ssh/id_ed25519_vps"
SSH_OPTS="-i $KEY -o StrictHostKeyChecking=no -o ConnectTimeout=10"
OP1_IP="57.131.33.152"
M1_CLI="/home/ubuntu/bathron-cli -testnet"

echo "=== Testing M1 HTLC Creation on OP1 ==="
echo

echo "Step 1: Check current M1 balance and receipts..."
WALLET_STATE=$(ssh $SSH_OPTS ubuntu@$OP1_IP "$M1_CLI getwalletstate true")
echo "$WALLET_STATE" | python3 -m json.tool
echo

# Extract the first receipt outpoint
RECEIPT_OUTPOINT=$(echo "$WALLET_STATE" | python3 -c "
import json, sys
data = json.load(sys.stdin)
receipts = data.get('m1', {}).get('receipts', [])
if receipts:
    print(receipts[0]['outpoint'])
else:
    print('NONE')
")

if [ "$RECEIPT_OUTPOINT" = "NONE" ]; then
    echo "ERROR: No M1 receipts found!"
    exit 1
fi

RECEIPT_AMOUNT=$(echo "$WALLET_STATE" | python3 -c "
import json, sys
data = json.load(sys.stdin)
receipts = data.get('m1', {}).get('receipts', [])
if receipts:
    print(receipts[0]['amount'])
")

echo "Step 2: Will use receipt:"
echo "  Outpoint: $RECEIPT_OUTPOINT"
echo "  Amount: $RECEIPT_AMOUNT M1"
echo

echo "Step 3: Creating M1 HTLC with small amount (2703 M1)..."
HASHLOCK="1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef"
DEST_ADDR="yBFhaDZ4kJxCXioDT5ztqJzDRFh4wmbwMe"  # charlie
EXPIRY=100  # blocks from now

echo "HTLC parameters:"
echo "  Receipt: $RECEIPT_OUTPOINT (full $RECEIPT_AMOUNT will be locked)"
echo "  Hashlock: $HASHLOCK"
echo "  Claim address: $DEST_ADDR"
echo "  Expiry: $EXPIRY blocks"
echo

ssh $SSH_OPTS ubuntu@$OP1_IP "$M1_CLI htlc_create_m1 '$RECEIPT_OUTPOINT' '$HASHLOCK' '$DEST_ADDR' $EXPIRY" 2>&1
RESULT=$?

if [ $RESULT -eq 0 ]; then
    echo
    echo "SUCCESS: HTLC created!"
    echo
    echo "New wallet state:"
    ssh $SSH_OPTS ubuntu@$OP1_IP "$M1_CLI getwalletstate true" | python3 -m json.tool
else
    echo
    echo "FAILED: Exit code $RESULT"
    echo
    echo "Checking M0 balance (for fees)..."
    ssh $SSH_OPTS ubuntu@$OP1_IP "$M1_CLI getbalance" 2>&1
fi

echo
echo "=== Test Complete ==="
