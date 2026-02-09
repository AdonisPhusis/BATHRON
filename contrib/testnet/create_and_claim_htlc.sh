#!/bin/bash
# Create new HTLC and claim it - full atomic test

SSH_KEY=~/.ssh/id_ed25519_vps
OP1_IP="57.131.33.152"

HASHLOCK="01896bec29c0719e99294db65365dcbe492c15c6050a29300df959c47c1f8298"
PREIMAGE="53dda021db232a7063a1f3fe77e9e4627eccdd00f344188d494a34cad12efb4e"
RECEIPT="f4429f0ec839d94077513fcfafdf3fcc4ff29f1ea2ed803ba11a01d6ea46326d:1"
CLAIM_ADDR="yJYD2bfYYBe6qAojSzMKX949H7QoQifNAo"

echo "=== Pre-test verification ==="
echo "Hashlock: $HASHLOCK"
echo "Preimage: $PREIMAGE"
echo "Receipt:  $RECEIPT"
echo ""

# Verify the preimage matches hashlock
echo "=== Step 0: Verify preimage (should be valid:true) ==="
ssh -i $SSH_KEY ubuntu@$OP1_IP "~/bathron-cli -testnet htlc_verify $PREIMAGE $HASHLOCK"

echo ""
echo "=== Step 1: Check receipt exists ==="
ssh -i $SSH_KEY ubuntu@$OP1_IP "~/bathron-cli -testnet getwalletstate true" 2>&1 | python3 -c "
import sys, json
data = json.load(sys.stdin)
m1 = data.get('m1', {})
receipts = m1.get('receipts', [])
for r in receipts:
    if r.get('outpoint') == '$RECEIPT':
        print(f'Receipt found: {r}')
        break
else:
    print('Receipt NOT found!')
"

echo ""
echo "=== Step 2: Create HTLC (without expiry param - defaults to 288) ==="
HTLC_RESULT=$(ssh -i $SSH_KEY ubuntu@$OP1_IP "~/bathron-cli -testnet htlc_create_m1 '$RECEIPT' '$HASHLOCK' '$CLAIM_ADDR'" 2>&1)
echo "$HTLC_RESULT"

HTLC_TXID=$(echo "$HTLC_RESULT" | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    print(data.get('txid', ''))
except:
    pass
" 2>/dev/null)

if [ -z "$HTLC_TXID" ]; then
    echo "HTLC creation failed!"
    exit 1
fi

echo ""
echo "HTLC created: $HTLC_TXID:0"

echo ""
echo "=== Step 3: Wait for confirmation (30s) ==="
sleep 30

echo ""
echo "=== Step 4: Check HTLC status ==="
ssh -i $SSH_KEY ubuntu@$OP1_IP "~/bathron-cli -testnet htlc_get ${HTLC_TXID}:0"

echo ""
echo "=== Step 5: Claim HTLC with preimage ==="
CLAIM_RESULT=$(ssh -i $SSH_KEY ubuntu@$OP1_IP "~/bathron-cli -testnet htlc_claim ${HTLC_TXID}:0 $PREIMAGE" 2>&1)
echo "$CLAIM_RESULT"

CLAIM_TXID=$(echo "$CLAIM_RESULT" | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    print(data.get('txid', ''))
except:
    pass
" 2>/dev/null)

if [ -n "$CLAIM_TXID" ]; then
    echo ""
    echo "=== SUCCESS! ==="
    echo "HTLC claimed! Claim txid: $CLAIM_TXID"
else
    echo ""
    echo "=== CLAIM FAILED ==="
fi

echo ""
echo "=== Final state ==="
ssh -i $SSH_KEY ubuntu@$OP1_IP "~/bathron-cli -testnet htlc_list" | head -20
