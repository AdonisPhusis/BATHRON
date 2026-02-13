#!/usr/bin/env bash
SEED_IP="57.131.33.151"
SSH_CMD="ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 -i ~/.ssh/id_ed25519_vps ubuntu@$SEED_IP"

echo "=== Seed Quick Status ==="
echo ""
echo "Processes:"
$SSH_CMD "ps aux | grep -E '(bitcoin|bathron)' | grep -v grep || echo 'No daemons running'"
echo ""
echo "Recent log:"
$SSH_CMD "tail -20 ~/.bathron/testnet5/debug.log 2>/dev/null || echo 'No log found'"
