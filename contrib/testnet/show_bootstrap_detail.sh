#!/bin/bash
SSH_KEY="$HOME/.ssh/id_ed25519_vps"
SSH="ssh -i $SSH_KEY -o StrictHostKeyChecking=no -o ConnectTimeout=10"
SEED="57.131.33.151"

echo "=== Lines 140-200 of bootstrap debug.log ==="
$SSH ubuntu@$SEED "sed -n '140,200p' /tmp/bathron_bootstrap/testnet5/debug.log 2>/dev/null"

echo ""
echo "=== First TX_LOCK mentions ==="
$SSH ubuntu@$SEED "grep -n 'type=20' /tmp/bathron_bootstrap/testnet5/debug.log 2>/dev/null | head -5"
