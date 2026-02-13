#!/usr/bin/env bash
set -euo pipefail

SEED_IP="57.131.33.151"
SSH_CMD="ssh -o StrictHostKeyChecking=no -i ~/.ssh/id_ed25519_vps ubuntu@$SEED_IP"

echo "=== Checking Seed Binary for Fee Recycling Code ==="
$SSH_CMD "strings /home/ubuntu/BATHRON-Core/src/bathrond | grep -c 'Coinbase receives' || echo '0'"
