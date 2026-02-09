#!/bin/bash
SSH="ssh -i $HOME/.ssh/id_ed25519_vps -o StrictHostKeyChecking=no -o ConnectTimeout=10"

echo "=== CoreSDK M1 receipts ==="
$SSH ubuntu@162.19.251.75 "/home/ubuntu/BATHRON-Core/src/bathron-cli -testnet getwalletstate true" 2>&1 | python3 -c "
import sys, json
data = json.load(sys.stdin)
receipts = data.get('m1', {}).get('receipts', [])
total = data.get('m1', {}).get('total', 0)
print(f'Total: {total} sats ({len(receipts)} receipts)')
for r in receipts:
    print(f'  {r[\"outpoint\"]}: {r[\"amount\"]} sats')
"

echo ""
echo "=== OP1 (alice) M1 receipts ==="
$SSH ubuntu@57.131.33.152 "/home/ubuntu/bathron-cli -testnet getwalletstate true" 2>&1 | python3 -c "
import sys, json
data = json.load(sys.stdin)
receipts = data.get('m1', {}).get('receipts', [])
total = data.get('m1', {}).get('total', 0)
m0 = data.get('m0', {}).get('balance', 0)
print(f'M1: {total} sats ({len(receipts)} receipts)')
print(f'Free M0: {m0} sats')
for r in receipts:
    print(f'  {r[\"outpoint\"]}: {r[\"amount\"]} sats')
"
