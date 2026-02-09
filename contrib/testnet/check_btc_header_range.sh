#!/usr/bin/env bash
# Check BTC header range in database

set -euo pipefail

SEED_IP="57.131.33.151"
SSH_KEY="$HOME/.ssh/id_ed25519_vps"
SSH="ssh -i $SSH_KEY -o StrictHostKeyChecking=no -o ConnectTimeout=10"

echo "=== Checking BTC Header Range ==="
echo ""

echo "Attempting to get header at 200000 (checkpoint):"
$SSH ubuntu@${SEED_IP} '~/bathron-cli -testnet getbtcheader 200000 2>&1 || echo "Header 200000 not found"'
echo ""

echo "Attempting to get header at 280000 (checkpoint):"
$SSH ubuntu@${SEED_IP} '~/bathron-cli -testnet getbtcheader 280000 2>&1 || echo "Header 280000 not found"'
echo ""

echo "Attempting to get header at 286000 (genesis checkpoint):"
$SSH ubuntu@${SEED_IP} '~/bathron-cli -testnet getbtcheader 286000 2>&1 || echo "Header 286000 not found"'
echo ""

echo "Attempting to get header at 289270 (current tip):"
$SSH ubuntu@${SEED_IP} '~/bathron-cli -testnet getbtcheader 289270 2>&1 || echo "Header 289270 not found"'
echo ""

echo "=== Diagnostic complete ==="
