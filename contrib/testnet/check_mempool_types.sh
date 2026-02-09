#!/bin/bash
SSH_KEY="$HOME/.ssh/id_ed25519_vps"
SSH="ssh -i $SSH_KEY -o StrictHostKeyChecking=no -o ConnectTimeout=10"
SEED="57.131.33.151"
CLI="/home/ubuntu/bathron-cli -datadir=/tmp/bathron_bootstrap -testnet"

echo "=== Mempool TX types ==="
for TXID in $($SSH ubuntu@$SEED "timeout 5 $CLI getrawmempool 2>/dev/null | jq -r '.[]'"); do
    TYPE=$($SSH ubuntu@$SEED "timeout 5 $CLI getrawtransaction $TXID true 2>/dev/null | jq -r '.type'")
    echo "  $TXID: type=$TYPE"
done
