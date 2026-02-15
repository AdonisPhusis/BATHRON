#!/bin/bash
# Split alice's M1 receipt: half to alice, half to charlie
set -uo pipefail

SSH="ssh -i $HOME/.ssh/id_ed25519_vps -o BatchMode=yes -o ConnectTimeout=30 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR"

OP1_IP="57.131.33.152"
OP1_CLI="/home/ubuntu/bathron-cli -testnet"
CHARLIE_ADDR="yBFhaDZ4kJxCXioDT5ztqJzDRFh4wmbwMe"
ALICE_ADDR="yJYD2bfYYBe6qAojSzMKX949H7QoQifNAo"

echo "=== Split M1: alice → alice + charlie ==="

# Get receipt info
echo "[1/3] Getting alice's M1 receipt..."
WALLET_STATE=$($SSH ubuntu@$OP1_IP "$OP1_CLI getwalletstate true 2>&1" 2>/dev/null)
OUTPOINT=$(echo "$WALLET_STATE" | jq -r '.m1.receipts[0].outpoint // empty')
RECEIPT_AMT=$(echo "$WALLET_STATE" | jq -r '.m1.receipts[0].amount // 0')

if [ -z "$OUTPOINT" ] || [ "$OUTPOINT" = "null" ] || [ "$OUTPOINT" = "empty" ]; then
    echo "  ERROR: No M1 receipt found"
    echo "$WALLET_STATE" | jq '.m1'
    exit 1
fi

echo "  Outpoint: $OUTPOINT"
echo "  Amount: $RECEIPT_AMT sats"

# Calculate halves (amounts are integers in sats)
# split_m1 fee comes from M1, ~23 sats - subtract 200 sats margin from charlie
ALICE_HALF=$((RECEIPT_AMT / 2))
CHARLIE_HALF=$((RECEIPT_AMT - ALICE_HALF - 200))

echo "  Alice:   $ALICE_HALF sats"
echo "  Charlie: $CHARLIE_HALF sats"
echo "  Fee margin: $((RECEIPT_AMT - ALICE_HALF - CHARLIE_HALF)) sats"
echo ""

# Execute split
echo "[2/3] Executing split_m1..."
RESULT=$($SSH ubuntu@$OP1_IP "$OP1_CLI split_m1 \"$OUTPOINT\" '[{\"address\":\"$ALICE_ADDR\",\"amount\":$ALICE_HALF},{\"address\":\"$CHARLIE_ADDR\",\"amount\":$CHARLIE_HALF}]' 2>&1" 2>/dev/null)
echo "  Result: $RESULT"

TXID=$(echo "$RESULT" | jq -r '.txid // empty' 2>/dev/null)
if [ -z "$TXID" ]; then
    echo ""
    echo "  Failed. Retrying with 1000 sats fee margin..."
    CHARLIE_HALF=$((RECEIPT_AMT - ALICE_HALF - 1000))
    echo "  Alice: $ALICE_HALF  Charlie: $CHARLIE_HALF"
    RESULT=$($SSH ubuntu@$OP1_IP "$OP1_CLI split_m1 \"$OUTPOINT\" '[{\"address\":\"$ALICE_ADDR\",\"amount\":$ALICE_HALF},{\"address\":\"$CHARLIE_ADDR\",\"amount\":$CHARLIE_HALF}]' 2>&1" 2>/dev/null)
    echo "  Result: $RESULT"
    TXID=$(echo "$RESULT" | jq -r '.txid // empty' 2>/dev/null)
    if [ -z "$TXID" ]; then
        echo "  ERROR: split_m1 still failed"
        exit 1
    fi
fi

echo ""
echo "  Split TX: $TXID"

# Wait for confirmation
echo "[3/3] Waiting for confirmation..."
for i in $(seq 1 24); do
    sleep 5
    CONFS=$($SSH ubuntu@$OP1_IP "$OP1_CLI getrawtransaction $TXID true 2>/dev/null | jq -r '.confirmations // 0'" 2>/dev/null)
    if [ "$CONFS" -gt 0 ] 2>/dev/null; then
        echo "  Confirmed ($CONFS confs) after $((i*5))s"
        break
    fi
    echo "  ... waiting ($((i*5))s)"
done

echo ""
echo "=== Final State ==="
for NODE in "57.131.33.152:OP1-alice" "51.75.31.44:OP3-charlie"; do
    IP="${NODE%%:*}"
    NAME="${NODE##*:}"
    BAL=$($SSH ubuntu@$IP "~/bathron-cli -testnet getbalance 2>&1" 2>/dev/null)
    M0=$(echo "$BAL" | jq -r '.m0 // 0')
    M1=$(echo "$BAL" | jq -r '.m1 // 0')
    echo "  $NAME: M0=$M0  M1=$M1"
done
