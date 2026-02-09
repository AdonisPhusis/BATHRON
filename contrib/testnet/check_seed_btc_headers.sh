#!/usr/bin/env bash
# Check Seed BTC headers database status

set -euo pipefail

SEED_IP="57.131.33.151"
SSH_KEY="$HOME/.ssh/id_ed25519_vps"
SSH="ssh -i $SSH_KEY -o StrictHostKeyChecking=no -o ConnectTimeout=10"

echo "=== Seed BTC Headers Status ==="
echo ""

echo "[1/3] BTC Headers Tip"
$SSH ubuntu@${SEED_IP} '~/bathron-cli -testnet getbtcheaderstip'
echo ""

echo "[2/3] BTC Headers Status (full)"
$SSH ubuntu@${SEED_IP} '~/bathron-cli -testnet getbtcheadersstatus'
echo ""

echo "[3/3] Check if btcheadersdb directory exists"
$SSH ubuntu@${SEED_IP} 'ls -lah ~/.bathron/testnet5/btcheadersdb/ | head -20 || echo "btcheadersdb does not exist"'
echo ""

echo "=== Diagnostic complete ==="
