#!/bin/bash
# Verify claim success

SSH_KEY=~/.ssh/id_ed25519_vps
OP1_IP="57.131.33.152"

HTLC_OUTPOINT="59a384a0d9857ea99caf330e90c3f937109514300cb6fca165b7dccace7dbd2e:0"
CLAIM_TXID="828713fc1f58655a10ca4d6c7930c12c9a8d9809a6feb1cd8c5c10b1e6e91691"
RECEIPT_OUTPOINT="${CLAIM_TXID}:0"

echo "=== Block height ==="
ssh -i $SSH_KEY ubuntu@$OP1_IP "~/bathron-cli -testnet getblockcount"

echo ""
echo "=== Claim TX confirmation ==="
ssh -i $SSH_KEY ubuntu@$OP1_IP "~/bathron-cli -testnet gettransaction $CLAIM_TXID 2>/dev/null" | grep -E '(confirmations|txid)'

echo ""
echo "=== HTLC status after claim ==="
ssh -i $SSH_KEY ubuntu@$OP1_IP "~/bathron-cli -testnet htlc_get '$HTLC_OUTPOINT'"

echo ""
echo "=== New M1 Receipt ==="
ssh -i $SSH_KEY ubuntu@$OP1_IP "~/bathron-cli -testnet getwalletstate true" 2>&1 | python3 -c "
import sys, json
data = json.load(sys.stdin)
m1 = data.get('m1', {})
print(f'M1 Total: {m1.get(\"total\", 0)}')
receipts = m1.get('receipts', [])
print(f'Receipts: {len(receipts)}')
for r in receipts[:5]:
    print(f'  - {r.get(\"outpoint\")}: {r.get(\"amount\")} (confirmations: {r.get(\"confirmations\", \"?\")})')
" 2>/dev/null

echo ""
echo "=== HTLC list (all) ==="
ssh -i $SSH_KEY ubuntu@$OP1_IP "~/bathron-cli -testnet htlc_list" | python3 -c "
import sys, json
data = json.load(sys.stdin)
for h in data:
    op = h.get('outpoint', '')
    status = h.get('status', '')
    if '59a384a0d9' in op:
        print(f'*** OUR HTLC: {op} -> STATUS: {status} ***')
    else:
        print(f'{op}: {status}')
"
