#!/bin/bash
# Claim the new HTLC

SSH_KEY=~/.ssh/id_ed25519_vps
OP1_IP="57.131.33.152"

HTLC_OUTPOINT="59a384a0d9857ea99caf330e90c3f937109514300cb6fca165b7dccace7dbd2e:0"
PREIMAGE="53dda021db232a7063a1f3fe77e9e4627eccdd00f344188d494a34cad12efb4e"

echo "=== Attempting to claim HTLC ==="
echo "HTLC: $HTLC_OUTPOINT"
echo "Preimage: $PREIMAGE"
echo ""

echo "=== Step 1: Verify HTLC exists ==="
ssh -i $SSH_KEY ubuntu@$OP1_IP "~/bathron-cli -testnet htlc_get '$HTLC_OUTPOINT'"

echo ""
echo "=== Step 2: Claim HTLC ==="
CLAIM_RESULT=$(ssh -i $SSH_KEY ubuntu@$OP1_IP "~/bathron-cli -testnet htlc_claim '$HTLC_OUTPOINT' '$PREIMAGE'" 2>&1)
echo "$CLAIM_RESULT"

# Check if it was successful
if echo "$CLAIM_RESULT" | grep -q '"txid"'; then
    echo ""
    echo "=== SUCCESS! ==="
    CLAIM_TXID=$(echo "$CLAIM_RESULT" | python3 -c "import sys, json; print(json.load(sys.stdin).get('txid', ''))" 2>/dev/null)
    echo "Claim TX: $CLAIM_TXID"

    echo ""
    echo "=== Waiting 30s for confirmation ==="
    sleep 30

    echo ""
    echo "=== Final HTLC list ==="
    ssh -i $SSH_KEY ubuntu@$OP1_IP "~/bathron-cli -testnet htlc_list"
else
    echo ""
    echo "=== CLAIM FAILED ==="
    echo "Error: $CLAIM_RESULT"
fi
