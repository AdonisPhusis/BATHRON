#!/bin/bash
SSH_KEY="$HOME/.ssh/id_ed25519_vps"
SSH="ssh -i $SSH_KEY -o StrictHostKeyChecking=no -o ConnectTimeout=10"
SEED="57.131.33.151"

echo "=== TX_LOCK mentions in bootstrap debug.log ==="
$SSH ubuntu@$SEED "grep -n 'TX_LOCK\|type=20\|CommitTransaction.*type=20' /tmp/bathron_bootstrap/testnet5/debug.log 2>/dev/null | head -30"

echo ""
echo "=== First CommitTransaction entries ==="
$SSH ubuntu@$SEED "grep -n 'CommitTransaction' /tmp/bathron_bootstrap/testnet5/debug.log 2>/dev/null | head -20"
