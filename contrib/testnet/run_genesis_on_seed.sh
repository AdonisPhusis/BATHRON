#!/usr/bin/env bash
set -euo pipefail

SEED_IP="57.131.33.151"
SSH_KEY="~/.ssh/id_ed25519_vps"

echo "=== Copying genesis bootstrap script to Seed ==="
scp -i $SSH_KEY -o StrictHostKeyChecking=no \
    contrib/testnet/genesis_bootstrap_seed.sh \
    ubuntu@$SEED_IP:/home/ubuntu/

echo ""
echo "=== Running genesis bootstrap ON Seed (daemon-only flow) ==="
echo "This will take 5-10 minutes..."
echo ""

ssh -i $SSH_KEY -o StrictHostKeyChecking=no ubuntu@$SEED_IP \
    "cd /home/ubuntu && bash genesis_bootstrap_seed.sh 2>&1"

echo ""
echo "=== Genesis bootstrap complete! ==="
