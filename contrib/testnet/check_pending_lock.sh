#!/bin/bash
# check_pending_lock.sh - Check details of pending lock transaction

set -e

SSH_KEY="$HOME/.ssh/id_ed25519_vps"
SSH_OPTS="-i $SSH_KEY -o StrictHostKeyChecking=no -o ConnectTimeout=10"
OP1_IP="57.131.33.152"
CLI="/home/ubuntu/bathron-cli -testnet"

TXID="484f0c1a5d11cd14e9c1ecc7d56bfc1a6f64ccf65575c6c598cbf7743b1a67d3"

echo "=== Pending Lock Transaction Details ==="
echo ""
echo "TXID: $TXID"
echo ""

echo "1. Transaction Details (decoded):"
ssh $SSH_OPTS ubuntu@$OP1_IP "$CLI getrawtransaction $TXID 1"
echo ""

echo "2. Mempool Entry:"
ssh $SSH_OPTS ubuntu@$OP1_IP "$CLI getmempoolentry $TXID"
echo ""

echo "=== END DETAILS ==="
