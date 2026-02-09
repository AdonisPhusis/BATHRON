#!/bin/bash
# Provision M1 liquidity for LP by unlocking M1 from a donor node,
# transferring M0, and re-locking on the LP.
#
# Usage: ./provision_m1_lp.sh <amount> <from_node> <to_lp>
#   e.g.: ./provision_m1_lp.sh 20000 op3 lp1

set -e

AMOUNT="${1:-20000}"
FROM="${2:-op3}"
TO_LP="${3:-lp1}"

SSH_KEY="$HOME/.ssh/id_ed25519_vps"
SSH_OPTS="-o StrictHostKeyChecking=no -o ConnectTimeout=10"
SSH="ssh -i $SSH_KEY $SSH_OPTS"

# Map nodes
case "$FROM" in
    seed) FROM_IP="57.131.33.151"; FROM_CLI="/home/ubuntu/BATHRON-Core/src/bathron-cli -testnet" ;;
    coresdk) FROM_IP="162.19.251.75"; FROM_CLI="/home/ubuntu/BATHRON-Core/src/bathron-cli -testnet" ;;
    op1) FROM_IP="57.131.33.152"; FROM_CLI="/home/ubuntu/bathron-cli -testnet" ;;
    op2) FROM_IP="57.131.33.214"; FROM_CLI="/home/ubuntu/bathron/bin/bathron-cli -testnet" ;;
    op3) FROM_IP="51.75.31.44"; FROM_CLI="/home/ubuntu/bathron-cli -testnet" ;;
    *) echo "Unknown from node: $FROM"; exit 1 ;;
esac

case "$TO_LP" in
    lp1) TO_IP="57.131.33.152"; TO_CLI="/home/ubuntu/bathron-cli -testnet"; TO_ADDR="yJYD2bfYYBe6qAojSzMKX949H7QoQifNAo" ;;
    lp2) TO_IP="57.131.33.214"; TO_CLI="/home/ubuntu/bathron/bin/bathron-cli -testnet"; TO_ADDR="y7XRqXgz1d8ELErDxtwQPnvfbe2ZcUecka" ;;
    *) echo "Unknown LP target: $TO_LP"; exit 1 ;;
esac

# Need extra for fees: lock fee (~130) + send fee (~94)
SEND_AMOUNT=$((AMOUNT + 300))

echo "============================================"
echo "  Provision M1 Liquidity"
echo "  Amount: $AMOUNT M1"
echo "  From: $FROM ($FROM_IP) — unlock M1 → M0"
echo "  To: $TO_LP ($TO_IP) — lock M0 → M1"
echo "  Send: $SEND_AMOUNT M0 (includes fees)"
echo "============================================"
echo ""

# Step 1: Check donor M1 balance
echo "=== Step 1: Check donor M1 balance ==="
DONOR_BAL=$($SSH ubuntu@$FROM_IP "$FROM_CLI getbalance" 2>/dev/null)
DONOR_M1=$(echo "$DONOR_BAL" | python3 -c "import sys,json; print(json.load(sys.stdin).get('m1',0))" 2>/dev/null || echo "0")
echo "  $FROM M1: $DONOR_M1"
if [ "$DONOR_M1" -lt "$AMOUNT" ] 2>/dev/null; then
    echo "  ERROR: Not enough M1 on $FROM ($DONOR_M1 < $AMOUNT)"
    exit 1
fi
echo ""

# Step 2: Unlock M1 on donor
echo "=== Step 2: Unlock $SEND_AMOUNT M1 on $FROM ==="
UNLOCK=$($SSH ubuntu@$FROM_IP "$FROM_CLI unlock $SEND_AMOUNT" 2>&1 || true)
echo "  Result: $(echo "$UNLOCK" | head -5)"
UNLOCK_TXID=$(echo "$UNLOCK" | python3 -c "import sys,json; print(json.load(sys.stdin).get('txid',''))" 2>/dev/null || echo "")
if [ -z "$UNLOCK_TXID" ]; then
    echo "  ERROR: Unlock failed"
    echo "  $UNLOCK"
    exit 1
fi
echo "  TXID: $UNLOCK_TXID"
echo ""

# Step 3: Wait for unlock to confirm
echo "=== Step 3: Waiting for unlock confirmation (~60s) ==="
sleep 65
DONOR_BAL2=$($SSH ubuntu@$FROM_IP "$FROM_CLI getbalance" 2>/dev/null)
echo "  $FROM balance after unlock:"
echo "  $DONOR_BAL2" | python3 -c "import sys,json; d=json.load(sys.stdin); print(f'    M0={d.get(\"m0\",0)} M1={d.get(\"m1\",0)} free={d.get(\"m0\",0)-d.get(\"locked\",0)}')" 2>/dev/null
echo ""

# Step 4: Send M0 to LP
echo "=== Step 4: Send $SEND_AMOUNT M0 from $FROM to $TO_LP ($TO_ADDR) ==="
SEND=$($SSH ubuntu@$FROM_IP "$FROM_CLI sendmany \"\" '{\"${TO_ADDR}\":${SEND_AMOUNT}}'" 2>&1 || true)
echo "  Result: $SEND"
SEND_TXID=$(echo "$SEND" | tr -d '[:space:]' | head -1)
if [ ${#SEND_TXID} -ne 64 ]; then
    echo "  ERROR: Send failed"
    exit 1
fi
echo "  TXID: $SEND_TXID"
echo ""

# Step 5: Wait for send to confirm
echo "=== Step 5: Waiting for transfer confirmation (~60s) ==="
sleep 65
LP_BAL=$($SSH ubuntu@$TO_IP "$TO_CLI getbalance" 2>/dev/null)
echo "  $TO_LP balance:"
echo "  $LP_BAL" | python3 -c "import sys,json; d=json.load(sys.stdin); print(f'    M0={d.get(\"m0\",0)} M1={d.get(\"m1\",0)} free={d.get(\"m0\",0)-d.get(\"locked\",0)}')" 2>/dev/null
echo ""

# Step 6: Lock M0 → M1 on LP
echo "=== Step 6: Lock $AMOUNT M0 → M1 on $TO_LP ==="
LOCK=$($SSH ubuntu@$TO_IP "$TO_CLI lock $AMOUNT" 2>&1 || true)
echo "  Result: $(echo "$LOCK" | head -5)"
LOCK_TXID=$(echo "$LOCK" | python3 -c "import sys,json; print(json.load(sys.stdin).get('txid',''))" 2>/dev/null || echo "")
if [ -z "$LOCK_TXID" ]; then
    echo "  ERROR: Lock failed"
    echo "  $LOCK"
    exit 1
fi
echo "  TXID: $LOCK_TXID"
echo ""

# Step 7: Wait and verify
echo "=== Step 7: Waiting for lock confirmation (~60s) ==="
sleep 65
LP_FINAL=$($SSH ubuntu@$TO_IP "$TO_CLI getbalance" 2>/dev/null)
echo "  $TO_LP final balance:"
echo "  $LP_FINAL" | python3 -c "import sys,json; d=json.load(sys.stdin); print(f'    M0={d.get(\"m0\",0)} M1={d.get(\"m1\",0)} free={d.get(\"m0\",0)-d.get(\"locked\",0)}')" 2>/dev/null

echo ""
echo "============================================"
echo "  Provisioning complete!"
echo "  Unlocked: $SEND_AMOUNT M1 from $FROM"
echo "  Locked: $AMOUNT M1 on $TO_LP"
echo "============================================"
