#!/bin/bash
# Check HTLC test state on OP1

SSH_KEY=~/.ssh/id_ed25519_vps
OP1_IP="57.131.33.152"

LOCK_TXID="f4429f0ec839d94077513fcfafdf3fcc4ff29f1ea2ed803ba11a01d6ea46326d"

echo "=== Block height ==="
ssh -i $SSH_KEY ubuntu@$OP1_IP "~/bathron-cli -testnet getblockcount"

echo ""
echo "=== Lock TX confirmation ==="
ssh -i $SSH_KEY ubuntu@$OP1_IP "~/bathron-cli -testnet gettransaction $LOCK_TXID" 2>&1 | grep -E '(confirmations|txid)'

echo ""
echo "=== Wallet State (M1 receipts) ==="
ssh -i $SSH_KEY ubuntu@$OP1_IP "~/bathron-cli -testnet getwalletstate true" 2>&1 | python3 -c "
import sys, json
data = json.load(sys.stdin)
m1 = data.get('m1', {})
print(f'M1 total: {m1.get(\"total\", 0)}')
receipts = m1.get('receipts', [])
print(f'Receipts: {len(receipts)}')
for r in receipts[:5]:
    print(f'  - {r.get(\"outpoint\")}: {r.get(\"amount\")} (confirmations: {r.get(\"confirmations\", \"?\")})')
" 2>&1 || echo "JSON parse failed"

echo ""
echo "=== Active HTLCs ==="
ssh -i $SSH_KEY ubuntu@$OP1_IP "~/bathron-cli -testnet htlc_list active" 2>&1 | head -20
