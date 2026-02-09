#!/usr/bin/env bash
set -euo pipefail

TARGET_TXID="0a72b136f3b9797d2e6be4f3b4935d9d66c7c0c877feeae935b12e0876648deb"
SSH_KEY="$HOME/.ssh/id_ed25519_vps"
SSH_OPTS="-i $SSH_KEY -o StrictHostKeyChecking=no -o ConnectTimeout=10"
SEED_IP="57.131.33.151"
CLI="\$HOME/BATHRON-Core/src/bathron-cli"

echo "Analyzing HTLC TX amounts..."
echo ""

# Get the HTLC TX
echo "1. HTLC TX details:"
TX_DATA=$(ssh $SSH_OPTS ubuntu@$SEED_IP "$CLI -testnet getrawtransaction $TARGET_TXID 1")
echo "$TX_DATA" | jq '.'
echo ""

# Extract input outpoint
INPUT_TXID=$(echo "$TX_DATA" | jq -r '.vin[0].txid')
INPUT_VOUT=$(echo "$TX_DATA" | jq -r '.vin[0].vout')
echo "2. Input M1 receipt: $INPUT_TXID:$INPUT_VOUT"

# Get the input TX
echo ""
echo "3. Input TX details (M1 receipt source):"
INPUT_TX=$(ssh $SSH_OPTS ubuntu@$SEED_IP "$CLI -testnet getrawtransaction $INPUT_TXID 1")
echo "$INPUT_TX" | jq '.'
echo ""

# Extract amounts
INPUT_AMOUNT=$(echo "$INPUT_TX" | jq -r ".vout[$INPUT_VOUT].value")
OUTPUT_AMOUNT=$(echo "$TX_DATA" | jq -r '.vout[0].value')

echo "4. Amount comparison:"
echo "   M1 Receipt amount: $INPUT_AMOUNT"
echo "   HTLC output amount: $OUTPUT_AMOUNT"
echo ""

if [[ "$INPUT_AMOUNT" == "$OUTPUT_AMOUNT" ]]; then
    echo "   ✓ Amounts MATCH"
else
    echo "   ✗ Amounts MISMATCH - This is the validation error!"
    echo "   Expected: $INPUT_AMOUNT"
    echo "   Got: $OUTPUT_AMOUNT"
fi
echo ""

# Check if input is actually an M1 receipt
echo "5. Checking if input is M1 receipt..."
INPUT_TYPE=$(echo "$INPUT_TX" | jq -r '.type')
echo "   Input TX type: $INPUT_TYPE"

if [[ "$INPUT_TYPE" == "20" ]]; then
    echo "   ✓ Type 20 = TX_LOCK (creates M1 receipt)"
elif [[ "$INPUT_TYPE" == "22" ]]; then
    echo "   ✓ Type 22 = TX_TRANSFER_M1 (M1 receipt)"
else
    echo "   ✗ Type $INPUT_TYPE is NOT an M1 receipt type!"
fi
echo ""

# Get wallet state to verify M1 receipt
echo "6. Checking wallet state for M1 receipts..."
WALLET_STATE=$(ssh $SSH_OPTS ubuntu@$SEED_IP "$CLI -testnet getwalletstate true")
echo "$WALLET_STATE" | jq -r '.m1_receipts[] | select(.outpoint == "'$INPUT_TXID:$INPUT_VOUT'")' || echo "   (Receipt not found in wallet state)"

