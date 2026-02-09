#!/bin/bash
set -e

SEED_IP="57.131.33.151"
SSH_KEY="$HOME/.ssh/id_ed25519_vps"

echo "=== SEED NODE STATE CHECK ==="
echo ""

echo "1. Full State (getstate):"
ssh -i "$SSH_KEY" ubuntu@$SEED_IP '~/bathron-cli -testnet getstate'
echo ""

echo "2. Sum of Finalized Burns:"
ssh -i "$SSH_KEY" ubuntu@$SEED_IP "~/bathron-cli -testnet listburnclaims final 50 | jq '[.[].amount] | add'"
echo ""

echo "3. Total Burn Claims Count:"
ssh -i "$SSH_KEY" ubuntu@$SEED_IP "~/bathron-cli -testnet listburnclaims all 50 | jq 'length'"
echo ""
