#!/bin/bash
# Lock M0 → M1 on OP3 (charlie wallet)
# Usage: ./lock_m0_op3.sh <amount>

set -e

SSH_KEY="$HOME/.ssh/id_ed25519_vps"
SSH_OPTS="-i $SSH_KEY -o StrictHostKeyChecking=no -o ConnectTimeout=10"
OP3_IP="51.75.31.44"
CLI="\$HOME/bathron-cli"

AMOUNT="${1:-500000}"

echo "=== Lock M0 → M1 on OP3 (charlie) ==="
echo "Amount: $AMOUNT sats"
echo ""

# Check current state before
echo "1. Current wallet state:"
ssh $SSH_OPTS ubuntu@$OP3_IP "$CLI -testnet getwalletstate true" 2>&1 | python3 -c "
import json, sys
try:
    d = json.load(sys.stdin)
    print(f\"  M0 balance: {d.get('balance', 'N/A')} sats\")
    m1 = d.get('m1_receipts', [])
    m1_total = sum(r.get('amount', 0) for r in m1)
    print(f\"  M1 receipts: {len(m1)} (total: {m1_total} sats)\")
except Exception as e:
    print(f'  Error parsing: {e}')
"
echo ""

# Execute lock
echo "2. Executing lock $AMOUNT..."
RESULT=$(ssh $SSH_OPTS ubuntu@$OP3_IP "$CLI -testnet lock $AMOUNT" 2>&1)
echo "  Result: $RESULT"
echo ""

# Wait for confirmation
echo "3. Waiting for block confirmation..."
sleep 5

# Check state after
echo "4. Wallet state after lock:"
ssh $SSH_OPTS ubuntu@$OP3_IP "$CLI -testnet getwalletstate true" 2>&1

echo ""
echo "5. Transaction status:"
TXID=$(echo "$RESULT" | python3 -c "import json,sys; print(json.load(sys.stdin).get('txid',''))" 2>/dev/null || echo "")
if [ -n "$TXID" ]; then
    ssh $SSH_OPTS ubuntu@$OP3_IP "$CLI -testnet gettransaction $TXID" 2>&1 | python3 -c "
import json, sys
try:
    d = json.load(sys.stdin)
    print(f\"  Confirmations: {d.get('confirmations', 0)}\")
    print(f\"  Block: {d.get('blockhash', 'mempool')[:16]}...\") if d.get('blockhash') else print('  Block: (mempool)')
except Exception as e:
    print(f'  Error: {e}')
"
fi

echo ""
echo "=== Done ==="
