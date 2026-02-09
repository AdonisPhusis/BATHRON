#!/usr/bin/env bash
set -euo pipefail

TXID="$1"
KEY="~/.ssh/id_ed25519_vps"

if [ -z "$TXID" ]; then
    echo "Usage: $0 <txid>"
    exit 1
fi

echo "Checking mempool for TX: $TXID"
echo ""

# Core + Seed (repo nodes)
for IP in 162.19.251.75 57.131.33.151; do
    COUNT=$(ssh -i $KEY ubuntu@$IP "~/BATHRON-Core/src/bathron-cli -testnet getrawmempool | grep -c '$TXID' || echo 0")
    if [ "$COUNT" = "1" ]; then
        echo "  $IP (repo): ✓"
    else
        echo "  $IP (repo): ✗"
    fi
done

# Bin-only nodes
for IP in 57.131.33.152 57.131.33.214 51.75.31.44; do
    COUNT=$(ssh -i $KEY ubuntu@$IP "~/bathron-cli -testnet getrawmempool | grep -c '$TXID' || echo 0")
    if [ "$COUNT" = "1" ]; then
        echo "  $IP (bin): ✓"
    else
        echo "  $IP (bin): ✗"
    fi
done
