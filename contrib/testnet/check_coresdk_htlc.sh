#!/usr/bin/env bash
set -euo pipefail

CORESDK_IP="162.19.251.75"
SSH_KEY="$HOME/.ssh/id_ed25519_vps"
SSH="ssh -i $SSH_KEY -o StrictHostKeyChecking=no -o ConnectTimeout=10"

echo "[$(date +%H:%M:%S)] Checking Core+SDK HTLC status..."
echo ""

# Check mempool
echo "=== Mempool ==="
MEMPOOL=$($SSH ubuntu@$CORESDK_IP '~/bathron-cli -testnet getrawmempool')
echo "$MEMPOOL"

if [ "$MEMPOOL" != "[]" ]; then
    TXID=$(echo "$MEMPOOL" | jq -r '.[0]')
    echo ""
    echo "=== Transaction Details ==="
    $SSH ubuntu@$CORESDK_IP "~/bathron-cli -testnet getrawtransaction $TXID 1"
fi

echo ""
echo "=== Recent HTLC logs ==="
$SSH ubuntu@$CORESDK_IP "grep -iE 'htlc|bad-htlc' ~/.bathron/testnet5/debug.log | tail -30"

echo ""
echo "[$(date +%H:%M:%S)] Check complete"
