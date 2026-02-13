#!/usr/bin/env bash
SSH_KEY="$HOME/.ssh/id_ed25519_vps"
SSH_OPTS="-i $SSH_KEY -o StrictHostKeyChecking=no -o ConnectTimeout=10 -o BatchMode=yes"

echo "=== OP1 (alice) getwalletstate true ==="
ssh $SSH_OPTS ubuntu@57.131.33.152 "/home/ubuntu/bathron-cli -testnet getwalletstate true" 2>&1

echo ""
echo "=== OP1 (alice) getbalance ==="
ssh $SSH_OPTS ubuntu@57.131.33.152 "/home/ubuntu/bathron-cli -testnet getbalance" 2>&1

echo ""
echo "=== OP1 (alice) getstate (global) ==="
ssh $SSH_OPTS ubuntu@57.131.33.152 "/home/ubuntu/bathron-cli -testnet getstate" 2>&1 | jq '.supply' 2>/dev/null

echo ""
echo "=== Lock TX details ==="
ssh $SSH_OPTS ubuntu@57.131.33.152 "/home/ubuntu/bathron-cli -testnet gettransaction 2778640f8925a4c7536455a3b1ab2718ca1618fe73f2a93b9376db234a0a098f" 2>&1
