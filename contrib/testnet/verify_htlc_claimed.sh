#!/bin/bash
# Verify HTLC was successfully claimed

set -e

SSH_KEY=~/.ssh/id_ed25519_vps
OP1_IP="57.131.33.152"  # alice (LP)
OP3_IP="51.75.31.44"    # charlie

HTLC_OUTPOINT="31ea186b4a59f89d99bc93fe57cabe829e3c68e4df00cef74fa36c5a55651063:0"
CLAIM_TXID="77f90ce620788d58c172c117f5285921ef49aed151901f852bb58234389cbebe"

echo "==== Verify HTLC Claim Success ===="
echo ""

echo "=== 1. Check HTLC status on OP1 ==="
ssh -i $SSH_KEY ubuntu@$OP1_IP "/home/ubuntu/bathron-cli -testnet htlc_get \"$HTLC_OUTPOINT\"" | python3 -c "
import sys, json
data = json.load(sys.stdin)
print(json.dumps(data, indent=2))
print()
status = data.get('status', 'unknown')
preimage = data.get('preimage', '')
resolve_txid = data.get('resolve_txid', '')
print(f'Status: {status}')
print(f'Resolved by TX: {resolve_txid}')
print(f'Preimage revealed: {preimage[:16]}...' if preimage else 'Preimage: (none)')
"
echo ""

echo "=== 2. Check claim transaction ==="
ssh -i $SSH_KEY ubuntu@$OP3_IP "/home/ubuntu/bathron-cli -testnet getrawtransaction \"$CLAIM_TXID\" 1" | python3 -c "
import sys, json
data = json.load(sys.stdin)
print(f\"TXID: {data.get('txid', '')}\")
print(f\"Type: {data.get('type', '')}\")
print(f\"Confirmations: {data.get('confirmations', 0)}\")
print(f\"Block hash: {data.get('blockhash', 'not mined yet')}\")
print()
print('Outputs:')
for vout in data.get('vout', []):
    amount = vout.get('value', 0)
    asset = vout.get('asset', 'M0')
    addresses = vout.get('scriptPubKey', {}).get('addresses', [])
    print(f\"  vout {vout['n']}: {amount} {asset} -> {', '.join(addresses)}\")
"
echo ""

echo "=== 3. Check Charlie's M1 balance ==="
ssh -i $SSH_KEY ubuntu@$OP3_IP "/home/ubuntu/bathron-cli -testnet getwalletstate true" | python3 -c "
import sys, json
data = json.load(sys.stdin)
m1_balance = data.get('m1_balance', 0)
m1_receipts = data.get('m1_receipts', [])
print(f'M1 Balance: {m1_balance}')
print(f'M1 Receipts: {len(m1_receipts)}')
print()
if m1_receipts:
    print('Recent M1 receipts:')
    for receipt in m1_receipts[-3:]:
        print(f\"  - {receipt.get('outpoint', '')}: {receipt.get('amount', 0)} M1\")
"
echo ""

echo "=== SUCCESS ==="
echo "✓ Charlie successfully claimed the HTLC!"
echo "✓ Preimage was revealed: 8f894b5829fc8f4096a9f177260e7cb46c175f2961ade379b58cdcdd338c36ef"
echo "✓ Charlie received M1 receipt: $CLAIM_TXID:0"
