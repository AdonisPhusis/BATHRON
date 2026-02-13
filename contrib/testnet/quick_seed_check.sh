#!/usr/bin/env bash
SEED_IP="57.131.33.151"
SSH_CMD="ssh -o StrictHostKeyChecking=no -i ~/.ssh/id_ed25519_vps ubuntu@$SEED_IP"
CLI="$SSH_CMD /home/ubuntu/BATHRON-Core/src/bathron-cli -testnet"

echo "=== Starting Seed daemon if not running ==="
$SSH_CMD "pgrep bathrond || /home/ubuntu/BATHRON-Core/src/bathrond -testnet -daemon"
sleep 10

echo ""
echo "=== Checking MN count ==="
$CLI masternode count 2>&1 || echo "Error getting MN count"

echo ""
echo "=== Checking block height ==="
$CLI getblockcount 2>&1 || echo "Daemon not ready"

echo ""
echo "=== Checking peers ==="
$CLI getconnectioncount 2>&1 || echo "Error getting peers"
