#!/bin/bash
SEED_IP="57.131.33.151"
SSH_KEY="$HOME/.ssh/id_ed25519_vps"
SSH="ssh -i $SSH_KEY -o StrictHostKeyChecking=no -o ConnectTimeout=10"

$SSH ubuntu@$SEED_IP 'tail -100 /tmp/bathron_bootstrap/testnet5/debug.log | grep -E "ERROR|error|FATAL|assert|exception|terminate" | head -20'
