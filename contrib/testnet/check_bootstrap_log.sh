#!/bin/bash
SSH_KEY="$HOME/.ssh/id_ed25519_vps"
SSH="ssh -i $SSH_KEY -o StrictHostKeyChecking=no -o ConnectTimeout=10"
SEED="57.131.33.151"

echo "=== Bootstrap debug.log last 50 lines ==="
$SSH ubuntu@$SEED "tail -50 /tmp/bathron_bootstrap/testnet5/debug.log 2>/dev/null || echo 'No bootstrap log found'"

echo ""
echo "=== Is bootstrap daemon running? ==="
$SSH ubuntu@$SEED "pgrep -a bathrond 2>/dev/null || echo 'NOT RUNNING'"
