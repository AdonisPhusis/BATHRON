#!/bin/bash
# Examine the invalid transaction

set -e

SEED_IP="57.131.33.151"
SSH_KEY="$HOME/.ssh/id_ed25519_vps"
SSH_OPTS="-o StrictHostKeyChecking=no -o ConnectTimeout=15 -o BatchMode=yes"
SSH="ssh -i $SSH_KEY $SSH_OPTS"

CLI_PATH="/home/ubuntu/BATHRON-Core/src/bathron-cli -testnet"

INVALID_TXID="801fdb2754816c788e220954774d32449604a555f6cdd47c67f7b10a9d9e4a27"
LOCK_TXID="484f0c1a5d11cd14e9c1ecc7d56bfc1a6f64ccf65575c6c598cbf7743b1a67d3"

echo "=== Examining INVALID unlock TX: $INVALID_TXID ==="
$SSH ubuntu@$SEED_IP "$CLI_PATH getrawtransaction $INVALID_TXID 1" | head -50

echo ""
echo "=== Examining LOCK TX: $LOCK_TXID ==="
$SSH ubuntu@$SEED_IP "$CLI_PATH getrawtransaction $LOCK_TXID 1" | head -50

echo ""
echo "=== Checking wallet state ==="
$SSH ubuntu@$SEED_IP "$CLI_PATH getwalletstate true" | head -30
