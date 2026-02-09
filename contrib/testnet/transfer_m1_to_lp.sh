#!/bin/bash
# Transfer M1 from CoreSDK (bob) to LP1 (alice) using transfer_m1 RPC
# Usage: ./transfer_m1_to_lp.sh [amount_sats]
# Default: 5000 sats

set -e

SSH_KEY="$HOME/.ssh/id_ed25519_vps"
SSH_OPTS="-o StrictHostKeyChecking=no -o ConnectTimeout=10"
SSH="ssh -i $SSH_KEY $SSH_OPTS"

CORESDK_IP="162.19.251.75"
CLI="/home/ubuntu/BATHRON-Core/src/bathron-cli -testnet"

# LP1 alice address
ALICE_ADDR="yJYD2bfYYBe6qAojSzMKX949H7QoQifNAo"

AMOUNT_SATS="${1:-5000}"

echo "=== Transfer M1 from CoreSDK (bob) to LP1 (alice) ==="
echo "  Amount: ${AMOUNT_SATS} sats"
echo "  To:     ${ALICE_ADDR}"
echo ""

# Get bob's M1 receipts (correct path: m1.receipts)
echo "Getting M1 receipts on CoreSDK..."
WALLET_STATE=$($SSH ubuntu@${CORESDK_IP} "$CLI getwalletstate true" 2>&1)

echo "$WALLET_STATE" | python3 -c "
import sys, json

data = json.load(sys.stdin)
receipts = data.get('m1', {}).get('receipts', [])
total = data.get('m1', {}).get('total', 0)
print(f'Total M1: {total} sats ({len(receipts)} receipts)')
for r in receipts:
    outpoint = r.get('outpoint', 'n/a')
    amount = r.get('amount', 0)
    print(f'  {outpoint}: {amount} sats')
"

echo ""

# Find a receipt >= requested amount
OUTPOINT=$($SSH ubuntu@${CORESDK_IP} "$CLI getwalletstate true" 2>&1 | python3 -c "
import sys, json
data = json.load(sys.stdin)
receipts = data.get('m1', {}).get('receipts', [])
target = ${AMOUNT_SATS}

# Find smallest receipt >= target
best = None
for r in receipts:
    amt = r.get('amount', 0)
    if amt >= target:
        if best is None or amt < best[1]:
            best = (r.get('outpoint'), amt)

if best:
    print(best[0])
else:
    print('NONE')
")

if [ "$OUTPOINT" = "NONE" ] || [ -z "$OUTPOINT" ]; then
    echo "✗ No M1 receipt >= ${AMOUNT_SATS} sats found on CoreSDK"
    echo "  Try a smaller amount or unlock more M1"
    exit 1
fi

echo "Using receipt: ${OUTPOINT}"
echo ""

# Transfer M1
echo "Transferring M1..."
RESULT=$($SSH ubuntu@${CORESDK_IP} "$CLI transfer_m1 '${OUTPOINT}' '${ALICE_ADDR}'" 2>&1)

echo "Result: $RESULT"
echo ""

if echo "$RESULT" | grep -qi "error"; then
    echo "✗ Transfer failed"
    exit 1
fi

echo "✓ M1 transfer submitted!"
echo "  Wait ~60s for next BATHRON block to confirm"
echo ""

# Wait a bit for confirmation
echo "Waiting 15s for propagation..."
sleep 15

# Show alice's balance after transfer
echo "Checking LP1 alice wallet state..."
OP1_IP="57.131.33.152"
OP1_CLI="/home/ubuntu/bathron-cli -testnet"
$SSH ubuntu@${OP1_IP} "$OP1_CLI getwalletstate true" 2>&1 | python3 -c "
import sys, json
data = json.load(sys.stdin)
receipts = data.get('m1', {}).get('receipts', [])
total = data.get('m1', {}).get('total', 0)
print(f'Alice M1 balance: {total} sats ({len(receipts)} receipts)')
for r in receipts:
    print(f'  {r.get(\"outpoint\")}: {r.get(\"amount\")} sats')
"

echo ""
echo "✓ Done"
