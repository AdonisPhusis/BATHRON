#!/bin/bash
# Try to force mine a block by generating to a specific address

set -e

SEED_IP="57.131.33.151"
SSH_KEY="$HOME/.ssh/id_ed25519_vps"
SSH_OPTS="-o StrictHostKeyChecking=no -o ConnectTimeout=15 -o BatchMode=yes"
SSH="ssh -i $SSH_KEY $SSH_OPTS"

CLI_PATH="/home/ubuntu/BATHRON-Core/src/bathron-cli -testnet"

echo "=== Attempting to force mine a block ==="

# Get a mining address
ADDR=$($SSH ubuntu@$SEED_IP "$CLI_PATH getnewaddress")
echo "Mining address: $ADDR"

# Try to generate 1 block
echo "Attempting to generate 1 block..."
$SSH ubuntu@$SEED_IP "$CLI_PATH generatetoaddress 1 \"$ADDR\"" || echo "Generate failed (expected - DMM consensus)"

echo ""
echo "=== Checking debug.log for block generation errors ==="
$SSH ubuntu@$SEED_IP "tail -100 ~/.bathron/testnet5/debug.log | grep -i 'generate\|ProcessNewBlock\|ERROR\|rejected' | tail -30"
