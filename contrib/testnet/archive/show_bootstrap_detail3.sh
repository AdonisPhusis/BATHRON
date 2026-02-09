#!/bin/bash
SSH_KEY="$HOME/.ssh/id_ed25519_vps"
SSH="ssh -i $SSH_KEY -o StrictHostKeyChecking=no -o ConnectTimeout=10"
SEED="57.131.33.151"

echo "=== Lines 565-635 ==="
$SSH ubuntu@$SEED "sed -n '565,635p' /tmp/bathron_bootstrap/testnet5/debug.log 2>/dev/null"
