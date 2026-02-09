#!/bin/bash
# Check HU Finality and MN status

set -e

SEED_IP="57.131.33.151"
SSH_KEY="$HOME/.ssh/id_ed25519_vps"
SSH_OPTS="-o StrictHostKeyChecking=no -o ConnectTimeout=15 -o BatchMode=yes"
SSH="ssh -i $SSH_KEY $SSH_OPTS"

CLI_PATH="/home/ubuntu/BATHRON-Core/src/bathron-cli -testnet"

echo "=== Finality Status ==="
$SSH ubuntu@$SEED_IP "$CLI_PATH getfinalitystatus"

echo ""
echo "=== Masternode Status ==="
$SSH ubuntu@$SEED_IP "$CLI_PATH getactivemnstatus"

echo ""
echo "=== Masternode List ==="
$SSH ubuntu@$SEED_IP "$CLI_PATH masternode list status" | head -20

echo ""
echo "=== Recent finality logs ==="
$SSH ubuntu@$SEED_IP "tail -500 ~/.bathron/testnet5/debug.log | grep -i 'finality\|quorum\|signature' | tail -20"
