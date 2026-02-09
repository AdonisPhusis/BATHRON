#!/bin/bash
# Fund alice (LP1) with M1 from available sources
set -uo pipefail

SSH_KEY="$HOME/.ssh/id_ed25519_vps"
SSH_OPTS="-o StrictHostKeyChecking=no -o ConnectTimeout=10 -o BatchMode=yes"
SSH="ssh -i $SSH_KEY $SSH_OPTS"

OP1_IP="57.131.33.152"
OP1_CLI="/home/ubuntu/bathron-cli -testnet"

OP2_IP="57.131.33.214"
OP2_CLI="/home/ubuntu/bathron/bin/bathron-cli -testnet"

ALICE_ADDR="yJYD2bfYYBe6qAojSzMKX949H7QoQifNAo"

echo "============================================================"
echo "  FUND ALICE M1"
echo "============================================================"
echo ""

# Step 1: Lock alice's free M0 → M1
echo "=== Step 1: Lock alice's M0 → M1 ==="
ALICE_BAL=$($SSH ubuntu@$OP1_IP "$OP1_CLI getbalance" 2>/dev/null)
ALICE_M0=$(echo "$ALICE_BAL" | python3 -c 'import sys,json; d=json.load(sys.stdin); print(d.get("m0",0) - d.get("locked",0))' 2>/dev/null)
echo "  alice free M0: $ALICE_M0 sats"

if [ "${ALICE_M0:-0}" -gt 50 ] 2>/dev/null; then
    # Keep 20 for fees, lock the rest
    LOCK_AMT=$((ALICE_M0 - 20))
    echo "  Locking $LOCK_AMT M0 → M1..."
    $SSH ubuntu@$OP1_IP "$OP1_CLI lock $LOCK_AMT" 2>/dev/null
    echo "  Done."
else
    echo "  Not enough M0 to lock (need >50, have $ALICE_M0)"
fi
echo ""

# Step 2: Transfer dev's M1 to alice
echo "=== Step 2: Transfer dev M1 → alice ==="
DEV_STATE=$($SSH ubuntu@$OP2_IP "$OP2_CLI getwalletstate true" 2>/dev/null)
OUTPOINT=$(echo "$DEV_STATE" | python3 -c '
import sys,json
d = json.load(sys.stdin)
receipts = d.get("m1",{}).get("receipts",[])
if receipts:
    biggest = max(receipts, key=lambda r: r["amount"])
    print(biggest["outpoint"])
' 2>/dev/null)

if [ -n "$OUTPOINT" ]; then
    echo "  Transferring M1 receipt $OUTPOINT → alice..."
    RESULT=$($SSH ubuntu@$OP2_IP "$OP2_CLI transfer_m1 \"$OUTPOINT\" \"$ALICE_ADDR\" 2>&1" 2>/dev/null)
    echo "  $RESULT"
else
    echo "  No M1 receipts on dev to transfer"
fi
echo ""

# Wait for confirmation
echo "=== Waiting 75s for confirmations ==="
for i in $(seq 1 15); do sleep 5; printf "."; done
echo ""
echo ""

# Verify
echo "=== Final: alice balance ==="
$SSH ubuntu@$OP1_IP "$OP1_CLI getbalance" 2>/dev/null
echo ""
echo "=== alice M1 receipts ==="
$SSH ubuntu@$OP1_IP "$OP1_CLI getwalletstate true 2>/dev/null | python3 -c '
import sys,json
d = json.load(sys.stdin)
m1 = d.get(\"m1\",{})
print(f\"M1 total: {m1.get(\\\"total\\\",0)} sats ({m1.get(\\\"count\\\",0)} receipts)\")
for r in m1.get(\"receipts\\\",[]):
    print(f\"  {r[\\\"outpoint\\\"]}: {r[\\\"amount\\\"]} sats\")
'" 2>/dev/null || echo "(parse error)"
echo ""
echo "============================================================"
echo "  DONE"
echo "============================================================"
