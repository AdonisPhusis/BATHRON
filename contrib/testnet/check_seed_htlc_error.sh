#!/usr/bin/env bash
set -euo pipefail

SEED_IP="57.131.33.151"
SSH_KEY="$HOME/.ssh/id_ed25519_vps"
SSH="ssh -i $SSH_KEY -o StrictHostKeyChecking=no -o ConnectTimeout=10"

echo "[$(date +%H:%M:%S)] Checking Seed HTLC errors..."
echo ""

echo "=== HTLC Processing Errors ==="
$SSH ubuntu@$SEED_IP "grep -E 'HTLC.*Processing|bad-htlc|ERROR.*HTLC' ~/.bathron/testnet5/debug.log | tail -30"

echo ""
echo "=== Block 5114 Details ==="
BLOCK_HASH=$($SSH ubuntu@$SEED_IP '~/bathron-cli -testnet getblockhash 5114 2>&1' || echo "Block not found")
echo "Block hash: $BLOCK_HASH"

if [ "$BLOCK_HASH" != "Block not found" ] && [ ! -z "$BLOCK_HASH" ]; then
    echo ""
    echo "Block info:"
    $SSH ubuntu@$SEED_IP "~/bathron-cli -testnet getblock $BLOCK_HASH 2 2>&1 | jq '{height, hash, tx: [.tx[] | {txid, type, vin: .vin[0], vout: .vout[0]}]}'" || echo "Failed to get block"
fi

echo ""
echo "[$(date +%H:%M:%S)] Check complete"
