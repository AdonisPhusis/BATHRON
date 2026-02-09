#!/bin/bash
# Analyze the claim transaction output type

set -e

SSH_KEY=~/.ssh/id_ed25519_vps
OP3_IP="51.75.31.44"    # charlie

CLAIM_TXID="77f90ce620788d58c172c117f5285921ef49aed151901f852bb58234389cbebe"

echo "==== Analyze Claim Transaction Output ===="
echo ""

echo "=== 1. Full transaction details ==="
ssh -i $SSH_KEY ubuntu@$OP3_IP "/home/ubuntu/bathron-cli -testnet getrawtransaction \"$CLAIM_TXID\" 1" | python3 << 'PYTHON_EOF'
import sys, json

data = json.load(sys.stdin)

print(f"TXID: {data.get('txid', '')}")
print(f"Type: {data.get('type', '')} (41 = TX_HTLC_CLAIM)")
print(f"Size: {data.get('size', 0)} bytes")
print(f"Confirmations: {data.get('confirmations', 0)}")
print()

print("=== Inputs ===")
for vin in data.get('vin', []):
    print(f"  - {vin.get('txid', '')}:{vin.get('vout', '')}")
    if 'scriptSig' in vin:
        asm = vin['scriptSig'].get('asm', '')
        print(f"    scriptSig (first 100 chars): {asm[:100]}")
print()

print("=== Outputs ===")
for vout in data.get('vout', []):
    n = vout.get('n', 0)
    value = vout.get('value', 0)
    asset = vout.get('asset', 'M0')
    spk = vout.get('scriptPubKey', {})
    addresses = spk.get('addresses', [])
    script_type = spk.get('type', '')
    
    print(f"  vout {n}:")
    print(f"    Amount: {value} {asset}")
    print(f"    Type: {script_type}")
    print(f"    Addresses: {', '.join(addresses)}")
print()

print("=== Fee Info ===")
if 'm0_fee_info' in data:
    fee_info = data['m0_fee_info']
    print(f"  TX Type: {fee_info.get('tx_type', '')}")
    print(f"  Complete: {fee_info.get('complete', False)}")
    print(f"  M0 In: {fee_info.get('m0_in', 0)}")
    print(f"  M0 Out: {fee_info.get('m0_out', 0)}")
    print(f"  M0 Fee: {fee_info.get('m0_fee', 0)}")
    if 'vault_in' in fee_info:
        print(f"  Vault In: {fee_info.get('vault_in', 0)}")
    if 'vault_out' in fee_info:
        print(f"  Vault Out: {fee_info.get('vault_out', 0)}")
else:
    print("  (no fee info)")

PYTHON_EOF
echo ""

echo "=== 2. Check if output is M1 receipt ==="
ssh -i $SSH_KEY ubuntu@$OP3_IP "/home/ubuntu/bathron-cli -testnet htlc_receipt_info \"${CLAIM_TXID}:0\"" 2>&1 || echo "(not an M1 receipt)"
echo ""

echo "=== 3. Check Charlie's wallet state ==="
ssh -i $SSH_KEY ubuntu@$OP3_IP "/home/ubuntu/bathron-cli -testnet getwalletinfo" | python3 -c "
import sys, json
data = json.load(sys.stdin)
print(f\"Balance M0: {data.get('balance', 0)}\")
print(f\"Immature M0: {data.get('immature_balance', 0)}\")
print(f\"Unconfirmed M0: {data.get('unconfirmed_balance', 0)}\")
"
echo ""

echo "=== Analysis Complete ==="
