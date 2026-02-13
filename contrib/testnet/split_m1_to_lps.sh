#!/usr/bin/env bash
# Split existing M1 receipt on LP1 (alice) → 70% LP1 + 30% LP2 (dev)
set -euo pipefail

SSH_KEY="$HOME/.ssh/id_ed25519_vps"
SSH_OPTS="-i $SSH_KEY -o StrictHostKeyChecking=no -o ConnectTimeout=10 -o BatchMode=yes"

LP1_IP="57.131.33.152"
LP1_CLI="/home/ubuntu/bathron-cli -testnet"
LP1_ADDR="yJYD2bfYYBe6qAojSzMKX949H7QoQifNAo"

LP2_IP="57.131.33.214"
LP2_CLI="/home/ubuntu/bathron-cli -testnet"
LP2_ADDR="y7XRqXgz1d8ELErDxtwQPnvfbe2ZcUecka"

echo "=== Getting M1 receipt from LP1 ==="
WSTATE=$(ssh $SSH_OPTS ubuntu@$LP1_IP "$LP1_CLI getwalletstate true" 2>&1)
RECEIPT=$(echo "$WSTATE" | jq -r '.m1.receipts[0].outpoint' 2>/dev/null)
AMOUNT=$(echo "$WSTATE" | jq -r '.m1.receipts[0].amount' 2>/dev/null)

echo "Receipt: $RECEIPT"
echo "Amount:  $AMOUNT M1"

if [ -z "$RECEIPT" ] || [ "$RECEIPT" = "null" ]; then
    echo "ERROR: No M1 receipt on LP1"
    exit 1
fi

# 30% to LP2, rest to LP1 (minus fee)
LP2_SHARE=$((AMOUNT * 30 / 100))
# Fee estimate for split_m1 ~23-50 sats
FEE=50
LP1_SHARE=$((AMOUNT - LP2_SHARE - FEE))

echo ""
echo "=== Split Plan ==="
echo "LP1 (alice): $LP1_SHARE M1 (→ $LP1_ADDR)"
echo "LP2 (dev):   $LP2_SHARE M1 (→ $LP2_ADDR)"
echo "Fee:         ~$FEE M1"
echo ""

echo "=== Executing split_m1 ==="
# Build the JSON outputs array (careful with quoting through SSH)
OUTPUTS_JSON="[{\"address\":\"${LP1_ADDR}\",\"amount\":${LP1_SHARE}},{\"address\":\"${LP2_ADDR}\",\"amount\":${LP2_SHARE}}]"
echo "Command: split_m1 \"$RECEIPT\" '$OUTPUTS_JSON'"
RESULT=$(ssh $SSH_OPTS ubuntu@$LP1_IP "$LP1_CLI split_m1 \"$RECEIPT\" '$OUTPUTS_JSON'" 2>&1)
echo "$RESULT"

TXID=$(echo "$RESULT" | jq -r '.txid // empty' 2>/dev/null)
if [ -z "$TXID" ]; then
    echo ""
    echo "First attempt failed, trying with higher fee estimate..."
    FEE=200
    LP1_SHARE=$((AMOUNT - LP2_SHARE - FEE))
    OUTPUTS_JSON="[{\"address\":\"${LP1_ADDR}\",\"amount\":${LP1_SHARE}},{\"address\":\"${LP2_ADDR}\",\"amount\":${LP2_SHARE}}]"
    echo "LP1: $LP1_SHARE  LP2: $LP2_SHARE  Fee: ~$FEE"
    RESULT=$(ssh $SSH_OPTS ubuntu@$LP1_IP "$LP1_CLI split_m1 \"$RECEIPT\" '$OUTPUTS_JSON'" 2>&1)
    echo "$RESULT"
    TXID=$(echo "$RESULT" | jq -r '.txid // empty' 2>/dev/null)
fi

if [ -z "$TXID" ]; then
    echo "ERROR: Split failed"
    exit 1
fi

echo ""
echo "=== Split TX: $TXID ==="
echo "Waiting for confirmation..."

for i in $(seq 1 20); do
    sleep 10
    CONF=$(ssh $SSH_OPTS ubuntu@$LP1_IP "$LP1_CLI gettransaction $TXID" 2>&1 | jq -r '.confirmations // 0' 2>/dev/null || echo "0")
    if [ "$CONF" -ge 1 ]; then
        echo "Confirmed! ($CONF confirmations)"
        break
    fi
    echo -n "."
done
echo ""

# Rescan LP2
echo ""
echo "=== Rescanning LP2 ==="
ssh $SSH_OPTS ubuntu@$LP2_IP "$LP2_CLI rescanblockchain 0" 2>/dev/null || true

echo ""
echo "=== Final State ==="
echo ""
echo "--- LP1 (alice) ---"
ssh $SSH_OPTS ubuntu@$LP1_IP "$LP1_CLI getwalletstate true" 2>&1 | jq '{m0: .m0.balance, m1_count: .m1.count, m1_total: .m1.total, receipts: [.m1.receipts[]? | {outpoint, amount}]}' 2>/dev/null
echo ""
echo "--- LP2 (dev) ---"
ssh $SSH_OPTS ubuntu@$LP2_IP "$LP2_CLI getwalletstate true" 2>&1 | jq '{m0: .m0.balance, m1_count: .m1.count, m1_total: .m1.total, receipts: [.m1.receipts[]? | {outpoint, amount}]}' 2>/dev/null
echo ""
echo "--- Global ---"
ssh $SSH_OPTS ubuntu@$LP1_IP "$LP1_CLI getstate" 2>&1 | jq '.supply' 2>/dev/null
