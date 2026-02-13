#!/bin/bash
SSH_KEY="$HOME/.ssh/id_ed25519_vps"
SSH="ssh -i $SSH_KEY -o StrictHostKeyChecking=no -o ConnectTimeout=10"
SEED="57.131.33.151"
CLI="/home/ubuntu/bathron-cli -datadir=/tmp/bathron_bootstrap -testnet"

MINT_TXID="188e6b6ed39db974559ada8e21ab4f9b7458708d84332b816caed7382e08c39e"

echo "=== Height ==="
$SSH ubuntu@$SEED "timeout 5 $CLI getblockcount"

echo ""
echo "=== Check first few mint vouts ==="
for VOUT in 0 1 2 3 4 5; do
    echo "--- vout $VOUT ---"
    $SSH ubuntu@$SEED "timeout 5 $CLI gettxout '$MINT_TXID' $VOUT true 2>&1 | jq '{value, scriptPubKey: .scriptPubKey.type, addresses: .scriptPubKey.addresses}' 2>/dev/null || echo 'NOT FOUND'"
done

echo ""
echo "=== Operator key ==="
$SSH ubuntu@$SEED "cat ~/.BathronKey/operators.json 2>/dev/null || echo 'NO KEY'"

echo ""
echo "=== protx_list ==="
$SSH ubuntu@$SEED "timeout 5 $CLI protx_list 2>&1 | head -5"
