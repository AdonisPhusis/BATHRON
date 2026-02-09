#!/bin/bash
# Get full HTLC details including claim_address

set -e

SSH_KEY=~/.ssh/id_ed25519_vps
OP1_IP="57.131.33.152"  # alice (LP)

HTLC_OUTPOINT="31ea186b4a59f89d99bc93fe57cabe829e3c68e4df00cef74fa36c5a55651063:0"

echo "=== Full HTLC Details ==="
ssh -i $SSH_KEY ubuntu@$OP1_IP "/home/ubuntu/bathron-cli -testnet htlc_get \"$HTLC_OUTPOINT\"" | python3 -c "
import sys, json
data = json.load(sys.stdin)
print(json.dumps(data, indent=2))
print()
print('Key Fields:')
print(f\"  Hashlock: {data.get('hashlock', 'N/A')}\")
print(f\"  Amount: {data.get('amount', 'N/A')}\")
print(f\"  Status: {data.get('status', 'N/A')}\")
print(f\"  Claim Address: {data.get('claim_address', 'NOT SET - THIS IS THE PROBLEM!')}\")
print(f\"  Source Receipt: {data.get('source_receipt', 'N/A')}\")
print(f\"  Create Height: {data.get('create_height', 'N/A')}\")
print(f\"  Expiry Height: {data.get('expiry_height', 'N/A')}\")
"

echo ""
echo "=== Transaction Details ==="
TXID="${HTLC_OUTPOINT%:*}"
ssh -i $SSH_KEY ubuntu@$OP1_IP "/home/ubuntu/bathron-cli -testnet getrawtransaction \"$TXID\" 1"
