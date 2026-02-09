#!/bin/bash
# analyze_mempool_fees.sh - Analyze mempool transactions and fees

set -e

SSH_KEY="$HOME/.ssh/id_ed25519_vps"
SSH_OPTS="-i $SSH_KEY -o StrictHostKeyChecking=no -o ConnectTimeout=10"
SEED_IP="57.131.33.151"
CLI="/home/ubuntu/BATHRON-Core/src/bathron-cli -testnet"

echo "=== Mempool Fee Analysis ==="
echo ""

# Get both transactions
TX1="484f0c1a5d11cd14e9c1ecc7d56bfc1a6f64ccf65575c6c598cbf7743b1a67d3"
TX2="801fdb2754816c788e220954774d32449604a555f6cdd47c67f7b10a9d9e4a27"

echo "Transaction 1: $TX1"
ssh $SSH_OPTS ubuntu@$SEED_IP "$CLI getrawtransaction $TX1 1" | grep -A 10 'm0_fee_info'
echo ""

echo "Transaction 2: $TX2"
ssh $SSH_OPTS ubuntu@$SEED_IP "$CLI getrawtransaction $TX2 1" | grep -A 10 'm0_fee_info'
echo ""

echo "=== END ANALYSIS ==="
