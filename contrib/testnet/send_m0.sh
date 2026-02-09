#!/bin/bash
# Send M0 from a node to an address
# Usage: ./send_m0.sh <node> <address> <amount_sats>

set -e

if [ $# -ne 3 ]; then
    echo "Usage: $0 <node> <address> <amount_sats>"
    echo "  node: seed|coresdk|op1|op2|op3"
    echo "  address: BATHRON testnet address"
    echo "  amount_sats: Amount in sats (e.g., 100000 = 0.001 M0)"
    exit 1
fi

NODE=$1
DEST_ADDR=$2
AMOUNT_SATS=$3

# Map node names to IPs
case $NODE in
    seed) IP="57.131.33.151"; CLI="/home/ubuntu/BATHRON-Core/src/bathron-cli -testnet" ;;
    coresdk) IP="162.19.251.75"; CLI="/home/ubuntu/BATHRON-Core/src/bathron-cli -testnet" ;;
    op1) IP="57.131.33.152"; CLI="/home/ubuntu/bathron-cli -testnet" ;;
    op2) IP="57.131.33.214"; CLI="/home/ubuntu/bathron/bin/bathron-cli -testnet" ;;
    op3) IP="51.75.31.44"; CLI="/home/ubuntu/bathron-cli -testnet" ;;
    *)
        echo "Error: Unknown node '$NODE'"
        exit 1
        ;;
esac

SSH_CMD="ssh -i ~/.ssh/id_ed25519_vps -o StrictHostKeyChecking=no ubuntu@${IP}"

# Convert sats to M0 decimal
AMOUNT_M0=$(echo "scale=8; $AMOUNT_SATS / 100000000" | bc)

echo "=== Sending ${AMOUNT_SATS} sats (${AMOUNT_M0} M0) from ${NODE} (${IP}) to ${DEST_ADDR} ==="
echo ""

# Check balance
echo "Checking balance..."
BALANCE=$($SSH_CMD "$CLI getbalance" 2>&1)
echo "$BALANCE"
echo ""

# Extract spendable M0
TOTAL=$(echo "$BALANCE" | jq -r '.total // 0')
LOCKED=$(echo "$BALANCE" | jq -r '.locked // 0')
SPENDABLE=$((TOTAL - LOCKED))

echo "Spendable M0: $SPENDABLE sats"
echo ""

if [ $SPENDABLE -lt $AMOUNT_SATS ]; then
    echo "✗ Error: Insufficient spendable balance"
    echo "  Requested: $AMOUNT_SATS sats"
    echo "  Available: $SPENDABLE sats"
    exit 1
fi

# Send transaction using sendmany with integer sats
echo "Sending transaction..."
TMPFILE=$(mktemp)
set +e

$SSH_CMD "$CLI sendmany \"\" '{\"${DEST_ADDR}\":${AMOUNT_SATS}}'" > "$TMPFILE" 2>&1
SEND_EXIT=$?
RESULT=$(cat "$TMPFILE")
rm -f "$TMPFILE"
set -e

if [ $SEND_EXIT -ne 0 ]; then
    echo "✗ Transaction failed (exit code: $SEND_EXIT)"
    echo "Error: $RESULT"
    exit 1
fi

TXID="$RESULT"
echo "✓ Transaction sent successfully"
echo "TXID: ${TXID}"
echo ""

# Get transaction details
echo "Transaction details:"
$SSH_CMD "$CLI gettransaction '${TXID}'" 2>&1 | jq '.'

echo ""
echo "✓ Done"
