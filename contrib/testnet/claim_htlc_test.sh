#!/bin/bash
# Claim HTLC test

SSH_KEY=~/.ssh/id_ed25519_vps
OP1_IP="57.131.33.152"

HASHLOCK="01896bec29c0719e99294db65365dcbe492c15c6050a29300df959c47c1f8298"
PREIMAGE="53dda021db232a7063a1f3fe77e9e4627eccdd00f344188d494a34cad12efb4e"

echo "=== All active HTLCs ==="
ssh -i $SSH_KEY ubuntu@$OP1_IP "~/bathron-cli -testnet htlc_list active"

echo ""
echo "=== Finding HTLC with our hashlock ==="
HTLC_INFO=$(ssh -i $SSH_KEY ubuntu@$OP1_IP "~/bathron-cli -testnet htlc_list active" 2>&1)

# Find the HTLC with our hashlock
OUTPOINT=$(echo "$HTLC_INFO" | python3 -c "
import sys, json, re
data = json.load(sys.stdin)
target_hashlock = '$HASHLOCK'
for htlc in data:
    if htlc.get('hashlock') == target_hashlock:
        op = htlc.get('outpoint', '')
        # Parse COutPoint(txid, vout) format
        match = re.match(r'COutPoint\(([a-f0-9]+), (\d+)\)', op)
        if match:
            print(f'{match.group(1)}:{match.group(2)}')
            break
" 2>/dev/null)

if [ -n "$OUTPOINT" ]; then
    echo "Found HTLC: $OUTPOINT"
    echo ""
    echo "=== Attempting claim ==="
    ssh -i $SSH_KEY ubuntu@$OP1_IP "~/bathron-cli -testnet htlc_claim $OUTPOINT $PREIMAGE" 2>&1
else
    echo "No HTLC found with hashlock $HASHLOCK"
    echo "Creating new HTLC..."

    RECEIPT="f4429f0ec839d94077513fcfafdf3fcc4ff29f1ea2ed803ba11a01d6ea46326d:1"
    CLAIM_ADDR="yJYD2bfYYBe6qAojSzMKX949H7QoQifNAo"

    echo "Creating HTLC with receipt $RECEIPT"
    ssh -i $SSH_KEY ubuntu@$OP1_IP "~/bathron-cli -testnet htlc_create_m1 $RECEIPT $HASHLOCK $CLAIM_ADDR 288" 2>&1
fi
