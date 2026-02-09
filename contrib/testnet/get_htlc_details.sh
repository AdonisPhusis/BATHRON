#!/bin/bash
# Get full HTLC details

SSH_KEY=~/.ssh/id_ed25519_vps
OP1_IP="57.131.33.152"

HASHLOCK="01896bec29c0719e99294db65365dcbe492c15c6050a29300df959c47c1f8298"
PREIMAGE="53dda021db232a7063a1f3fe77e9e4627eccdd00f344188d494a34cad12efb4e"

echo "=== HTLCs matching our hashlock ==="
ssh -i $SSH_KEY ubuntu@$OP1_IP "~/bathron-cli -testnet htlc_list active $HASHLOCK" 2>&1

echo ""
echo "=== Let's try to claim ==="
# First get the full outpoint
HTLC_INFO=$(ssh -i $SSH_KEY ubuntu@$OP1_IP "~/bathron-cli -testnet htlc_list active $HASHLOCK" 2>&1)
echo "Raw HTLC info:"
echo "$HTLC_INFO"

# Parse the outpoint if we can
OUTPOINT=$(echo "$HTLC_INFO" | python3 -c "
import sys, json, re
data = json.load(sys.stdin)
if data and len(data) > 0:
    op = data[0].get('outpoint', '')
    # Parse COutPoint(txid, vout) format
    match = re.match(r'COutPoint\(([a-f0-9]+), (\d+)\)', op)
    if match:
        print(f'{match.group(1)}:{match.group(2)}')
" 2>/dev/null)

if [ -n "$OUTPOINT" ]; then
    echo ""
    echo "Attempting claim on: $OUTPOINT"
    ssh -i $SSH_KEY ubuntu@$OP1_IP "~/bathron-cli -testnet htlc_claim $OUTPOINT $PREIMAGE" 2>&1
else
    echo "Could not parse outpoint"
fi
