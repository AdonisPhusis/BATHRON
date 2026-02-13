#!/usr/bin/env bash
SEED_IP="57.131.33.151"
SSH_CMD="ssh -o StrictHostKeyChecking=no -i ~/.ssh/id_ed25519_vps ubuntu@$SEED_IP"

echo "=== Checking Seed MN Configuration ==="
echo ""
echo "bathron.conf:"
$SSH_CMD "grep -E '(masternode=|mnoperatorprivatekey=)' ~/.bathron/bathron.conf | head -10"
echo ""
echo "MN list:"
$SSH_CMD "/home/ubuntu/BATHRON-Core/src/bathron-cli -testnet masternode list 2>&1" | head -20
echo ""
echo "MN count:"
$SSH_CMD "/home/ubuntu/BATHRON-Core/src/bathron-cli -testnet masternode count 2>&1"
