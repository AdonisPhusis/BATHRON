#!/bin/bash
SSH_KEY="$HOME/.ssh/id_ed25519_vps"
SSH_OPTS="-i $SSH_KEY -o StrictHostKeyChecking=no -o ConnectTimeout=10"
OP1_IP="57.131.33.152"
BATHRON_CLI="/home/ubuntu/bathron-cli -testnet"

echo "=== Lock M0 → M1 on OP1 ==="

echo ""
echo "Step 1: Check current balance"
ssh $SSH_OPTS "ubuntu@$OP1_IP" "$BATHRON_CLI getbalance"

echo ""
echo "Step 2: Try lock 500000"
ssh $SSH_OPTS "ubuntu@$OP1_IP" "$BATHRON_CLI lock 500000" 2>&1

echo ""
echo "Step 3: Check wallet state after lock"
sleep 2
ssh $SSH_OPTS "ubuntu@$OP1_IP" "$BATHRON_CLI getwalletstate true"
