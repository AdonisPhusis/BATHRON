#!/bin/bash
SSH_KEY="$HOME/.ssh/id_ed25519_vps"
SSH="ssh -i $SSH_KEY -o StrictHostKeyChecking=no -o ConnectTimeout=10"
SEED="57.131.33.151"

echo "=== Killing bootstrap daemon ==="
$SSH ubuntu@$SEED "pkill -9 bathrond 2>/dev/null; echo 'Done'"

echo ""
echo "=== Full bootstrap debug.log ==="
$SSH ubuntu@$SEED "wc -l /tmp/bathron_bootstrap/testnet5/debug.log 2>/dev/null; echo '---'; grep -c 'TX_LOCK\|type=20\|CommitTransaction' /tmp/bathron_bootstrap/testnet5/debug.log 2>/dev/null; echo '---'; grep -n 'protx\|ProTxRegister\|FundSpecialTx\|FundTransaction\|collateral' /tmp/bathron_bootstrap/testnet5/debug.log 2>/dev/null | tail -20"
