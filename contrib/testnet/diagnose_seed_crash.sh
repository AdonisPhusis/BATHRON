#!/bin/bash
set -e

SEED_IP="57.131.33.151"
SSH_KEY="$HOME/.ssh/id_ed25519_vps"

echo "=== SEED NODE CRASH DIAGNOSTIC ==="
echo "Fetching last 50 lines of debug.log..."
echo ""

ssh -i "$SSH_KEY" ubuntu@$SEED_IP 'tail -50 ~/.bathron/testnet5/debug.log'

echo ""
echo "=== END DIAGNOSTIC ==="
