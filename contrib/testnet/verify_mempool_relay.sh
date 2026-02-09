#!/usr/bin/env bash
set -euo pipefail

TXID="0a72b136f3b9797d2e6be4f3b4935d9d66c7c0c877feeae935b12e0876648deb"
SEED_IP="57.131.33.151"
KEY="~/.ssh/id_ed25519_vps"

echo "Checking Seed mempool..."
ssh -i $KEY ubuntu@$SEED_IP "~/BATHRON-Core/src/bathron-cli -testnet getrawmempool" | grep -q "$TXID" && echo "✓ TX confirmed in Seed mempool" || echo "✗ TX still NOT in Seed mempool"

echo ""
echo "Checking all node mempools..."
for IP in 162.19.251.75 57.131.33.151 57.131.33.152 57.131.33.214 51.75.31.44; do
    COUNT=$(ssh -i $KEY ubuntu@$IP "~/BATHRON-Core/src/bathron-cli -testnet getrawmempool | grep -c '$TXID' || echo 0")
    if [ "$COUNT" = "1" ]; then
        echo "  $IP: ✓"
    else
        echo "  $IP: ✗"
    fi
done
