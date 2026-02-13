#!/bin/bash
# check_seed_daemon.sh - Check Seed daemon status and logs

set -e

SSH_KEY="~/.ssh/id_ed25519_vps"
SSH_OPTS="-o StrictHostKeyChecking=no -o ConnectTimeout=10"
SSH="ssh -i $SSH_KEY $SSH_OPTS"

SEED_IP="57.131.33.151"
SEED_CLI="~/BATHRON-Core/src/bathron-cli -testnet"

echo "=== Checking Seed Daemon Status ==="
echo ""

echo "1. Process check:"
$SSH ubuntu@$SEED_IP "ps aux | grep bathrond | grep -v grep || echo 'No bathrond process'"
echo ""

echo "2. Last 50 lines of debug.log:"
$SSH ubuntu@$SEED_IP "tail -50 ~/.bathron/testnet5/debug.log"
echo ""

echo "3. Checking for errors:"
$SSH ubuntu@$SEED_IP "tail -200 ~/.bathron/testnet5/debug.log | grep -iE '(ERROR|Fatal|Assertion|Shutdown|terminated)' | tail -20 || echo 'No errors found'"
echo ""

echo "4. Attempting daemon status:"
$SSH ubuntu@$SEED_IP "$SEED_CLI getblockcount" 2>&1 || echo "Daemon not responding"
