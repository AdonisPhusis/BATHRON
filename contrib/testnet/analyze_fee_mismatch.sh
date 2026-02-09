#!/bin/bash
# Analyze the fee mismatch

set -e

SEED_IP="57.131.33.151"
SSH_KEY="$HOME/.ssh/id_ed25519_vps"
SSH_OPTS="-o StrictHostKeyChecking=no -o ConnectTimeout=15 -o BatchMode=yes"
SSH="ssh -i $SSH_KEY $SSH_OPTS"

CLI_PATH="/home/ubuntu/BATHRON-Core/src/bathron-cli -testnet"

echo "=== Analyzing fee mismatch ==="
echo "Block assembler calculated: 426 sats"
echo "Block validator expected: 1068 sats"
echo "Difference: 642 sats"
echo ""

LOCK_TX="484f0c1a5d11cd14e9c1ecc7d56bfc1a6f64ccf65575c6c598cbf7743b1a67d3"
UNLOCK_TX="801fdb2754816c788e220954774d32449604a555f6cdd47c67f7b10a9d9e4a27"

echo "=== LOCK TX fee info ==="
$SSH ubuntu@$SEED_IP "$CLI_PATH getrawtransaction $LOCK_TX 1" | grep -A10 'm0_fee_info'

echo ""
echo "=== UNLOCK TX fee info ==="
$SSH ubuntu@$SEED_IP "$CLI_PATH getrawtransaction $UNLOCK_TX 1" | grep -A10 'm0_fee_info'

echo ""
echo "=== UNLOCK TX inputs (checking if receipt exists) ==="
$SSH ubuntu@$SEED_IP "$CLI_PATH getrawtransaction $UNLOCK_TX 1" | grep -A3 '"vin"' | head -20
