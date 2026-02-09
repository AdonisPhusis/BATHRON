#!/bin/bash
# Check M1 balances across all nodes
SSH_KEY="$HOME/.ssh/id_ed25519_vps"
SSH_OPTS="-o StrictHostKeyChecking=no -o ConnectTimeout=10"
SSH="ssh -i $SSH_KEY $SSH_OPTS"

for NODE in "seed:57.131.33.151:/home/ubuntu/BATHRON-Core/src/bathron-cli" \
            "coresdk:162.19.251.75:/home/ubuntu/BATHRON-Core/src/bathron-cli" \
            "op1:57.131.33.152:/home/ubuntu/bathron-cli" \
            "op2:57.131.33.214:/home/ubuntu/bathron/bin/bathron-cli" \
            "op3:51.75.31.44:/home/ubuntu/bathron-cli"; do

    NAME=$(echo $NODE | cut -d: -f1)
    IP=$(echo $NODE | cut -d: -f2)
    CLI=$(echo $NODE | cut -d: -f3)

    echo "=== $NAME ($IP) ==="

    # getbalance
    BAL=$($SSH ubuntu@${IP} "$CLI -testnet getbalance" 2>&1)
    echo "Balance: $BAL"

    # getwalletstate — just M1 fields
    WS=$($SSH ubuntu@${IP} "$CLI -testnet getwalletstate true" 2>&1)
    echo "$WS" | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    # Show all keys
    print(f'  Wallet state keys: {list(data.keys())}')
    m1 = data.get('m1_receipts', data.get('vaulted_receipts', data.get('receipts', [])))
    if isinstance(m1, list):
        total = sum(r.get('amount', 0) for r in m1)
        print(f'  M1 receipts: {len(m1)}, total: {total} sats')
        for r in m1[:3]:
            print(f'    {r}')
    else:
        print(f'  m1_receipts field: {type(m1).__name__} = {str(m1)[:200]}')
except Exception as e:
    print(f'  parse error: {e}')
    print(f'  raw (first 500): {sys.stdin.read()[:500]}')
" 2>/dev/null

    echo ""
done
