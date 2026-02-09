#!/usr/bin/env bash
set -euo pipefail

CORE_IP="162.19.251.75"
SEED_IP="57.131.33.151"
KEY="~/.ssh/id_ed25519_vps"

echo "=== P2P Relay Diagnostic ==="
echo ""

echo "[1] Core peer connections:"
ssh -i $KEY ubuntu@$CORE_IP "~/BATHRON-Core/src/bathron-cli -testnet getpeerinfo | grep -E 'addr|inbound|subver' | head -24"

echo ""
echo "[2] Is Seed in Core's peer list?"
ssh -i $KEY ubuntu@$CORE_IP "~/BATHRON-Core/src/bathron-cli -testnet getpeerinfo | grep '$SEED_IP' && echo '✓ Seed is connected' || echo '✗ Seed NOT in peer list'"

echo ""
echo "[3] Seed peer connections:"
ssh -i $KEY ubuntu@$SEED_IP "~/BATHRON-Core/src/bathron-cli -testnet getpeerinfo | grep -E 'addr|inbound|subver' | head -12"

echo ""
echo "[4] Is Core in Seed's peer list?"
ssh -i $KEY ubuntu@$SEED_IP "~/BATHRON-Core/src/bathron-cli -testnet getpeerinfo | grep '$CORE_IP' && echo '✓ Core is connected' || echo '✗ Core NOT in peer list'"

echo ""
echo "[5] Checking TX relay settings..."
echo "  Core:"
ssh -i $KEY ubuntu@$CORE_IP "~/BATHRON-Core/src/bathron-cli -testnet getpeerinfo | grep -A 2 '$SEED_IP' | grep -E 'relaytxes|minfeefilter' || echo '  (peer not found)'"

echo ""
echo "[6] Recent mempool rejections on Seed:"
ssh -i $KEY ubuntu@$SEED_IP "tail -50 ~/.bathron/testnet5/debug.log | grep -iE 'reject|bad-tx' | tail -5 || echo '  (none)'"
