#!/usr/bin/env bash
SEED_IP="57.131.33.151"
SSH_KEY="~/.ssh/id_ed25519_vps"

echo "=== Checking Bootstrap Data on Seed ==="
ssh -i $SSH_KEY -o StrictHostKeyChecking=no ubuntu@$SEED_IP << 'REMOTE'
if [ -d /tmp/bathron_bootstrap/testnet5/blocks ]; then
    echo "[OK] Bootstrap data exists"
    cd /tmp/bathron_bootstrap/testnet5
    tar czf /tmp/genesis_bootstrap.tar.gz blocks chainstate evodb llmq btcheadersdb settlementdb burnclaimdb 2>/dev/null
    ls -lh /tmp/genesis_bootstrap.tar.gz
else
    echo "[ERROR] Bootstrap data missing!"
    exit 1
fi
REMOTE
