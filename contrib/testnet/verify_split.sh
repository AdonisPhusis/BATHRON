#!/usr/bin/env bash
SSH_KEY="$HOME/.ssh/id_ed25519_vps"
SSH_OPTS="-i $SSH_KEY -o StrictHostKeyChecking=no -o ConnectTimeout=10 -o BatchMode=yes"

TXID="50954931677cb13eada84cc23c1df5eb1389dd53a4098eaf9077f9cb1d247050"

echo "=== Waiting for split TX confirmation ==="
for i in $(seq 1 20); do
    CONF=$(ssh $SSH_OPTS ubuntu@57.131.33.152 "/home/ubuntu/bathron-cli -testnet gettransaction $TXID" 2>&1 | jq -r '.confirmations // 0' 2>/dev/null || echo "0")
    if [ "$CONF" -ge 1 ]; then
        echo "Confirmed! ($CONF confirmations)"
        break
    fi
    echo "  waiting... ($((i * 10))s)"
    sleep 10
done

echo ""
echo "=== Rescanning LP2 (dev) ==="
ssh $SSH_OPTS ubuntu@57.131.33.214 "/home/ubuntu/bathron-cli -testnet rescanblockchain 0" 2>&1 | jq '.' 2>/dev/null || true

echo ""
echo "=== LP1 (alice) wallet state ==="
ssh $SSH_OPTS ubuntu@57.131.33.152 "/home/ubuntu/bathron-cli -testnet getwalletstate true" 2>&1 | jq '{m0: .m0.balance, m1_total: .m1.total, m1_count: .m1.count, receipts: [.m1.receipts[]? | {outpoint: .outpoint, amount: .amount}]}' 2>/dev/null

echo ""
echo "=== LP2 (dev) wallet state ==="
ssh $SSH_OPTS ubuntu@57.131.33.214 "/home/ubuntu/bathron-cli -testnet getwalletstate true" 2>&1 | jq '{m0: .m0.balance, m1_total: .m1.total, m1_count: .m1.count, receipts: [.m1.receipts[]? | {outpoint: .outpoint, amount: .amount}]}' 2>/dev/null

echo ""
echo "=== Global Supply ==="
ssh $SSH_OPTS ubuntu@57.131.33.152 "/home/ubuntu/bathron-cli -testnet getstate" 2>&1 | jq '.supply' 2>/dev/null

echo ""
echo "=== Summary ==="
echo "LP1 (alice): 5,067,800 M1 (70%)"
echo "LP2 (dev):   2,172,000 M1 (30%)"
echo "Fee:         200 M1"
echo "Total M1:    7,239,800 (locked from 7,240,000 M0)"
