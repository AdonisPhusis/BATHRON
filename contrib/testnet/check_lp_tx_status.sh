#!/bin/bash
# check_lp_tx_status.sh - Check LP wallet transaction status and mempool on OP1

set -e

SSH_KEY="$HOME/.ssh/id_ed25519_vps"
SSH_OPTS="-i $SSH_KEY -o StrictHostKeyChecking=no -o ConnectTimeout=10"
OP1_IP="57.131.33.152"
CLI="/home/ubuntu/bathron-cli -testnet"

echo "=== LP Wallet TX Status (OP1 - $OP1_IP) ==="
echo ""

echo "1. Current Block Height:"
ssh $SSH_OPTS ubuntu@$OP1_IP "$CLI getblockcount"
echo ""

echo "2. Mempool Info:"
ssh $SSH_OPTS ubuntu@$OP1_IP "$CLI getmempoolinfo"
echo ""

echo "3. Wallet State (M1 Receipts):"
ssh $SSH_OPTS ubuntu@$OP1_IP "$CLI getwalletstate true"
echo ""

echo "4. M0 Balance:"
ssh $SSH_OPTS ubuntu@$OP1_IP "$CLI getbalance"
echo ""

echo "5. List Unspent (M0):"
ssh $SSH_OPTS ubuntu@$OP1_IP "$CLI listunspent" | head -50
echo ""

echo "6. Recent Transactions:"
ssh $SSH_OPTS ubuntu@$OP1_IP "$CLI listtransactions '*' 10"
echo ""

echo "7. Mempool Transactions:"
ssh $SSH_OPTS ubuntu@$OP1_IP "$CLI getrawmempool" | head -20
echo ""

echo "=== DIAGNOSTIC COMPLETE ==="
