#!/usr/bin/env bash
# Diagnose Seed node sync issues

set -euo pipefail

SEED_IP="57.131.33.151"
SSH_KEY="$HOME/.ssh/id_ed25519_vps"
SSH="ssh -i $SSH_KEY -o StrictHostKeyChecking=no -o ConnectTimeout=10"

echo "=== Seed Node Sync Diagnostic ==="
echo "Time: $(date)"
echo ""

echo "[1/5] Blockchain info"
$SSH ubuntu@${SEED_IP} '~/bathron-cli -testnet getblockchaininfo' | grep -E '"blocks"|"headers"|"bestblockhash"|"verificationprogress"' || true
echo ""

echo "[2/5] Peer info (synced heights)"
$SSH ubuntu@${SEED_IP} '~/bathron-cli -testnet getpeerinfo' | grep -E '"addr"|"synced_headers"|"synced_blocks"|"startingheight"' || true
echo ""

echo "[3/5] Recent debug.log (last 100 lines)"
$SSH ubuntu@${SEED_IP} 'tail -100 ~/.bathron/testnet5/debug.log'
echo ""

echo "[4/5] Errors/Warnings in last 200 lines"
$SSH ubuntu@${SEED_IP} 'tail -200 ~/.bathron/testnet5/debug.log | grep -iE "(error|warning|rejected|invalid|failed|bad-)" || echo "No errors/warnings found"'
echo ""

echo "[5/5] Block validation attempts"
$SSH ubuntu@${SEED_IP} 'tail -200 ~/.bathron/testnet5/debug.log | grep -E "(UpdateTip|ProcessNewBlock|AcceptBlock|ConnectBlock)" || echo "No block processing logs found"'
echo ""

echo "=== Diagnostic complete ==="
