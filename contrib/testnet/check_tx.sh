#!/usr/bin/env bash
set -euo pipefail

SEED_IP="57.131.33.151"
CORESDK_IP="162.19.251.75"
SSH_KEY="$HOME/.ssh/id_ed25519_vps"
SSH="ssh -i $SSH_KEY -o StrictHostKeyChecking=no -o ConnectTimeout=10"

TXID_SHORT="${1:?Usage: $0 <txid_short>}"

echo "[$(date +%H:%M:%S)] Checking TX: $TXID_SHORT..."
echo ""

for NAME in "Seed:$SEED_IP" "Core:$CORESDK_IP"; do
    NODE_NAME="${NAME%:*}"
    IP="${NAME#*:}"
    
    echo "=== $NODE_NAME ($IP) ==="
    
    # Find full TXID
    FULL_TXID=$($SSH ubuntu@$IP "~/bathron-cli -testnet getrawmempool | jq -r '.[] | select(. | startswith(\"$TXID_SHORT\"))' | head -1")
    
    if [ -z "$FULL_TXID" ]; then
        echo "  Not in mempool, checking blockchain..."
        FULL_TXID=$($SSH ubuntu@$IP "grep -i '$TXID_SHORT' ~/.bathron/testnet5/debug.log | grep -oE '[a-f0-9]{64}' | grep -i '^$TXID_SHORT' | head -1" || echo "")
    fi
    
    if [ -n "$FULL_TXID" ]; then
        echo "  Full TXID: $FULL_TXID"
        $SSH ubuntu@$IP "~/bathron-cli -testnet getrawtransaction $FULL_TXID 1 2>&1 || echo 'TX not found in chain'"
    else
        echo "  TX not found"
    fi
    
    echo ""
done

echo "[$(date +%H:%M:%S)] Check complete"
