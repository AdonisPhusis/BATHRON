#!/bin/bash
SEED_IP="57.131.33.151"
SSH_KEY="$HOME/.ssh/id_ed25519_vps"
SSH="ssh -i $SSH_KEY -o StrictHostKeyChecking=no -o ConnectTimeout=10"

$SSH ubuntu@$SEED_IP 'cat /tmp/genesis_bootstrap.log 2>/dev/null || echo "Log not found"'
