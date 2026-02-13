#!/bin/bash
# List all burn claims from burnclaimdb

set -e

SEED_IP="57.131.33.151"
SSH_KEY="$HOME/.ssh/id_ed25519_vps"
SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=15 -o BatchMode=yes"

echo "=== All Burn Claims ==="
ssh -i "$SSH_KEY" $SSH_OPTS ubuntu@$SEED_IP '~/BATHRON-Core/src/bathron-cli -testnet listburnclaims 2>/dev/null'
