#!/bin/bash
set -euo pipefail

SSH_KEY="$HOME/.ssh/id_ed25519_vps"
SSH_OPTS="-i $SSH_KEY -o StrictHostKeyChecking=no -o ConnectTimeout=10"
SEED_IP="57.131.33.151"
BATHRON_CLI="/home/ubuntu/bathron-cli -testnet"
ALICE_ADDR="yJYD2bfYYBe6qAojSzMKX949H7QoQifNAo"

echo "=== Debug send to Alice ==="
echo ""
echo "Balance:"
ssh $SSH_OPTS "ubuntu@$SEED_IP" "$BATHRON_CLI getbalance" 2>&1

echo ""
echo "Trying sendtoaddress 1.0 BATH:"
ssh $SSH_OPTS "ubuntu@$SEED_IP" "$BATHRON_CLI sendtoaddress \"$ALICE_ADDR\" 1.0" 2>&1 || true

echo ""
echo "Trying sendtoaddress 0.001 BATH:"
ssh $SSH_OPTS "ubuntu@$SEED_IP" "$BATHRON_CLI sendtoaddress \"$ALICE_ADDR\" 0.001" 2>&1 || true

echo ""
echo "Trying sendmany:"
ssh $SSH_OPTS "ubuntu@$SEED_IP" "$BATHRON_CLI sendmany \"\" '{\"$ALICE_ADDR\":0.001}'" 2>&1 || true

echo ""
echo "List unspent (first 3):"
ssh $SSH_OPTS "ubuntu@$SEED_IP" "$BATHRON_CLI listunspent 1 9999999 '[]' true" 2>&1 | python3 -c "
import sys, json
d = json.load(sys.stdin)
print(f'Total UTXOs: {len(d)}')
for u in d[:3]:
    print(f'  {u[\"txid\"][:16]}:{u[\"vout\"]} = {u[\"amount\"]} (spendable: {u.get(\"spendable\", \"?\")})')
" 2>&1 || echo "Error parsing"
