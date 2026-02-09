#!/usr/bin/env bash
set -euo pipefail

# check_coresdk_m1_receipts.sh
# Check M1 receipts on Core+SDK node

SSH_KEY="$HOME/.ssh/id_ed25519_vps"
SSH_OPTS="-i $SSH_KEY -o StrictHostKeyChecking=no -o ConnectTimeout=10"
CORESDK_IP="162.19.251.75"
CORESDK_CLI="\$HOME/BATHRON-Core/src/bathron-cli"

echo "=========================================="
echo "Core+SDK M1 Receipts Check"
echo "=========================================="
echo ""

echo "1. Wallet state (M1 receipts)..."
echo "----------------------------------"
ssh $SSH_OPTS ubuntu@$CORESDK_IP "$CORESDK_CLI -testnet getwalletstate true" 2>/dev/null
echo ""

echo "2. HTLC list..."
echo "----------------"
ssh $SSH_OPTS ubuntu@$CORESDK_IP "$CORESDK_CLI -testnet htlc_list" 2>/dev/null || echo "No HTLCs"
echo ""

echo "3. Recent debug.log (HTLC/settlement errors)..."
echo "--------------------------------------------------"
ssh $SSH_OPTS ubuntu@$CORESDK_IP "tail -200 \$HOME/.bathron/testnet5/debug.log | grep -iE 'bad-htlc|amount-mismatch|HTLC.*failed' | tail -20" 2>/dev/null || echo "No errors"
echo ""

