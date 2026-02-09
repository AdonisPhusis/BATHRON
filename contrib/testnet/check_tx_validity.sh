#!/bin/bash
# Check why the unlock TX is invalid

set -e

SEED_IP="57.131.33.151"
SSH_KEY="$HOME/.ssh/id_ed25519_vps"
SSH_OPTS="-o StrictHostKeyChecking=no -o ConnectTimeout=15 -o BatchMode=yes"
SSH="ssh -i $SSH_KEY $SSH_OPTS"

CLI_PATH="/home/ubuntu/BATHRON-Core/src/bathron-cli -testnet"

INVALID_TXID="801fdb2754816c788e220954774d32449604a555f6cdd47c67f7b10a9d9e4a27"

echo "=== Checking TX validity ==="
echo "TXID: $INVALID_TXID"
echo ""

# Try to test mempool accept
echo "=== Testing mempool accept ==="
RAW_TX=$($SSH ubuntu@$SEED_IP "$CLI_PATH getrawtransaction $INVALID_TXID")
$SSH ubuntu@$SEED_IP "$CLI_PATH testmempoolaccept '[\"$RAW_TX\"]'" || true

echo ""
echo "=== Checking debug.log for errors ==="
$SSH ubuntu@$SEED_IP "tail -200 ~/.bathron/testnet5/debug.log | grep -A5 -B5 '801fdb2' || echo 'No errors found in recent logs'"

echo ""
echo "=== Checking for block assembly errors ==="
$SSH ubuntu@$SEED_IP "tail -500 ~/.bathron/testnet5/debug.log | grep -i 'CreateNewBlock\|bad-txns\|invalid' | tail -20"
