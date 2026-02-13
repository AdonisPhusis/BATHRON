#!/bin/bash
# check_seed_finality.sh - Check finality database status

SSH_KEY="~/.ssh/id_ed25519_vps"
SSH_OPTS="-o StrictHostKeyChecking=no -o ConnectTimeout=10"
SSH="ssh -i $SSH_KEY $SSH_OPTS"

SEED_IP="57.131.33.151"
SEED_CLI="~/BATHRON-Core/src/bathron-cli -testnet"

echo "=== Checking Seed Finality Status ==="
echo ""

echo "1. Directory listing:"
$SSH ubuntu@$SEED_IP "ls -la ~/.bathron/testnet5/ | grep -E 'hu_finality|khu|finality' || echo 'No finality dirs found'"
echo ""

echo "2. Finality status from RPC:"
$SSH ubuntu@$SEED_IP "$SEED_CLI getfinalitystatus" 2>&1 || echo "getfinalitystatus failed"
echo ""

echo "3. Recent finality logs:"
$SSH ubuntu@$SEED_IP "tail -100 ~/.bathron/testnet5/debug.log | grep -i finality | tail -10"
