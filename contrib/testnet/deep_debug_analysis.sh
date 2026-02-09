#!/bin/bash
# Deep analysis of why blocks aren't being produced

set -e

SEED_IP="57.131.33.151"
SSH_KEY="$HOME/.ssh/id_ed25519_vps"
SSH_OPTS="-o StrictHostKeyChecking=no -o ConnectTimeout=15 -o BatchMode=yes"
SSH="ssh -i $SSH_KEY $SSH_OPTS"

CLI_PATH="/home/ubuntu/BATHRON-Core/src/bathron-cli -testnet"

echo "=== Looking for ProcessNewBlock logs ==="
$SSH ubuntu@$SEED_IP "tail -1000 ~/.bathron/testnet5/debug.log | grep -i 'ProcessNewBlock' | tail -20"

echo ""
echo "=== Looking for block rejection/validation errors ==="
$SSH ubuntu@$SEED_IP "tail -1000 ~/.bathron/testnet5/debug.log | grep -E 'invalid|bad-|reject' | tail -30"

echo ""
echo "=== Looking for settlement/unlock errors ==="
$SSH ubuntu@$SEED_IP "tail -1000 ~/.bathron/testnet5/debug.log | grep -iE 'settlement|unlock|TX_UNLOCK|801fdb2' | tail -30"

echo ""
echo "=== Checking if blocks are being created at all ==="
$SSH ubuntu@$SEED_IP "tail -500 ~/.bathron/testnet5/debug.log | grep 'CreateNewBlock(): total size' | tail -10"

echo ""
echo "=== Checking DMM scheduling ==="
$SSH ubuntu@$SEED_IP "tail -500 ~/.bathron/testnet5/debug.log | grep -i 'DMM\|masternode.*produce\|scheduling' | tail -20"
