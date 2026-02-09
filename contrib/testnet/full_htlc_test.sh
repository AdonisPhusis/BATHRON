#!/bin/bash
# Full HTLC test with the block assembly fix

SSH_KEY=~/.ssh/id_ed25519_vps
OP1_IP="57.131.33.152"

# Generate new secret/hashlock
PREIMAGE="53dda021db232a7063a1f3fe77e9e4627eccdd00f344188d494a34cad12efb4e"
HASHLOCK="01896bec29c0719e99294db65365dcbe492c15c6050a29300df959c47c1f8298"
CLAIM_ADDR="yJYD2bfYYBe6qAojSzMKX949H7QoQifNAo"

echo "╔══════════════════════════════════════════════════════════════╗"
echo "║  Full HTLC Test (with block assembly fix)                     ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""

echo "=== Step 0: Current state ==="
ssh -i $SSH_KEY ubuntu@$OP1_IP "~/bathron-cli -testnet getblockcount"

echo ""
echo "=== Step 1: Create new M1 lock (100000 sats) ==="
LOCK_RESULT=$(ssh -i $SSH_KEY ubuntu@$OP1_IP "~/bathron-cli -testnet lock 100000" 2>&1)
echo "$LOCK_RESULT"

LOCK_TXID=$(echo "$LOCK_RESULT" | python3 -c "import sys, json; print(json.load(sys.stdin).get('txid', ''))" 2>/dev/null)
if [ -z "$LOCK_TXID" ]; then
    echo "Lock failed! Exiting."
    exit 1
fi
RECEIPT="${LOCK_TXID}:1"
echo "Lock TXID: $LOCK_TXID"
echo "Receipt: $RECEIPT"

echo ""
echo "=== Step 2: Wait for lock confirmation (60s) ==="
sleep 60

echo ""
echo "=== Step 3: Verify lock confirmed ==="
ssh -i $SSH_KEY ubuntu@$OP1_IP "~/bathron-cli -testnet gettransaction $LOCK_TXID" 2>&1 | grep -E '(confirmations|txid)'

echo ""
echo "=== Step 4: Create HTLC ==="
HTLC_RESULT=$(ssh -i $SSH_KEY ubuntu@$OP1_IP "~/bathron-cli -testnet htlc_create_m1 '$RECEIPT' '$HASHLOCK' '$CLAIM_ADDR'" 2>&1)
echo "$HTLC_RESULT"

HTLC_TXID=$(echo "$HTLC_RESULT" | python3 -c "import sys, json; print(json.load(sys.stdin).get('txid', ''))" 2>/dev/null)
if [ -z "$HTLC_TXID" ]; then
    echo "HTLC creation failed!"
    exit 1
fi
HTLC_OUTPOINT="${HTLC_TXID}:0"
echo "HTLC TXID: $HTLC_TXID"

echo ""
echo "=== Step 5: Wait for HTLC confirmation (60s) ==="
sleep 60

echo ""
echo "=== Step 6: Verify HTLC in htlc_list ==="
ssh -i $SSH_KEY ubuntu@$OP1_IP "~/bathron-cli -testnet htlc_get '$HTLC_OUTPOINT'"

echo ""
echo "=== Step 7: Claim HTLC with preimage ==="
CLAIM_RESULT=$(ssh -i $SSH_KEY ubuntu@$OP1_IP "~/bathron-cli -testnet htlc_claim '$HTLC_OUTPOINT' '$PREIMAGE'" 2>&1)
echo "$CLAIM_RESULT"

CLAIM_TXID=$(echo "$CLAIM_RESULT" | python3 -c "import sys, json; print(json.load(sys.stdin).get('txid', ''))" 2>/dev/null)
if [ -z "$CLAIM_TXID" ]; then
    echo "Claim failed!"
    exit 1
fi

echo ""
echo "=== Step 8: Wait for claim confirmation (60s) ==="
sleep 60

echo ""
echo "=== Step 9: Verify claim confirmed ==="
ssh -i $SSH_KEY ubuntu@$OP1_IP "~/bathron-cli -testnet gettransaction $CLAIM_TXID" 2>&1 | grep -E '(confirmations|txid)'

echo ""
echo "=== Step 10: Final HTLC status ==="
ssh -i $SSH_KEY ubuntu@$OP1_IP "~/bathron-cli -testnet htlc_get '$HTLC_OUTPOINT'"

echo ""
echo "=== Step 11: Final wallet state ==="
ssh -i $SSH_KEY ubuntu@$OP1_IP "~/bathron-cli -testnet getwalletstate true" | python3 -c "
import sys, json
data = json.load(sys.stdin)
m1 = data.get('m1', {})
print(f'M1 Total: {m1.get(\"total\", 0)}')
receipts = m1.get('receipts', [])
print(f'Receipts: {len(receipts)}')
for r in receipts[:5]:
    print(f'  - {r.get(\"outpoint\")}: {r.get(\"amount\")}')
" 2>/dev/null

echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
if [ -n "$CLAIM_TXID" ]; then
    echo "║  ✓ SUCCESS! HTLC claim completed!                             ║"
else
    echo "║  ✗ FAILED: Claim not confirmed                                ║"
fi
echo "╚══════════════════════════════════════════════════════════════╝"
