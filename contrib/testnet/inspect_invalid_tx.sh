#!/bin/bash
# inspect_invalid_tx.sh - Inspect the suspicious unlock transaction

set -e

SSH_KEY="$HOME/.ssh/id_ed25519_vps"
SSH_OPTS="-i $SSH_KEY -o StrictHostKeyChecking=no -o ConnectTimeout=10"
SEED_IP="57.131.33.151"
CLI="/home/ubuntu/BATHRON-Core/src/bathron-cli -testnet"

TX2="801fdb2754816c788e220954774d32449604a555f6cdd47c67f7b10a9d9e4a27"

echo "=== Suspicious TX_UNLOCK Details ==="
echo ""
echo "TXID: $TX2"
echo ""

ssh $SSH_OPTS ubuntu@$SEED_IP "$CLI getrawtransaction $TX2 1"
echo ""

echo "=== END INSPECTION ==="
