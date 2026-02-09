#!/bin/bash
# Wait for claim transaction to be mined and verify

set -e

SSH_KEY=~/.ssh/id_ed25519_vps
OP1_IP="57.131.33.152"  # alice (LP)
OP3_IP="51.75.31.44"    # charlie

HTLC_OUTPOINT="31ea186b4a59f89d99bc93fe57cabe829e3c68e4df00cef74fa36c5a55651063:0"
CLAIM_TXID="77f90ce620788d58c172c117f5285921ef49aed151901f852bb58234389cbebe"

echo "==== Waiting for Claim Transaction to be Mined ===="
echo ""

# Wait for transaction to be mined (up to 5 minutes)
for i in {1..50}; do
    CONFIRMATIONS=$(ssh -i $SSH_KEY ubuntu@$OP3_IP "/home/ubuntu/bathron-cli -testnet getrawtransaction \"$CLAIM_TXID\" 1 2>/dev/null" | python3 -c "import sys, json; print(json.load(sys.stdin).get('confirmations', 0))" 2>/dev/null || echo "0")
    
    if [ "$CONFIRMATIONS" -gt 0 ]; then
        echo "✓ Transaction mined! ($CONFIRMATIONS confirmations)"
        break
    fi
    
    echo "Waiting... attempt $i/50 (confirmations: $CONFIRMATIONS)"
    sleep 6
done

echo ""
echo "=== 1. Final HTLC Status ==="
ssh -i $SSH_KEY ubuntu@$OP1_IP "/home/ubuntu/bathron-cli -testnet htlc_get \"$HTLC_OUTPOINT\"" | python3 -c "
import sys, json
data = json.load(sys.stdin)
status = data.get('status', 'unknown')
preimage = data.get('preimage', '')
resolve_txid = data.get('resolve_txid', '')
print(f'Status: {status}')
print(f'Resolved by TX: {resolve_txid}')
print(f'Preimage: {preimage}')
if status == 'claimed':
    print('✓ HTLC successfully claimed!')
else:
    print(f'⚠ HTLC status: {status}')
"
echo ""

echo "=== 2. Charlie's Final M1 Balance ==="
ssh -i $SSH_KEY ubuntu@$OP3_IP "/home/ubuntu/bathron-cli -testnet getwalletstate true" | python3 -c "
import sys, json
data = json.load(sys.stdin)
m1_balance = data.get('m1_balance', 0)
m1_receipts = data.get('m1_receipts', [])
print(f'M1 Balance: {m1_balance}')
print(f'M1 Receipts: {len(m1_receipts)}')
if m1_balance > 0:
    print(f'✓ Charlie received {m1_balance} M1')
"
echo ""

echo "=== Complete ==="
