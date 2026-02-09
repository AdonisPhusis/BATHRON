#!/usr/bin/env bash
set -euo pipefail

# check_op1_htlc_ready.sh
# Verify OP1 is ready for HTLC swaps

SSH_KEY="$HOME/.ssh/id_ed25519_vps"
SSH_OPTS="-i $SSH_KEY -o StrictHostKeyChecking=no -o ConnectTimeout=10"
OP1_IP="57.131.33.152"

echo "========================================"
echo "OP1 HTLC Readiness Check"
echo "========================================"
echo ""

echo "1. Block height and sync status..."
echo "------------------------------------"
ssh $SSH_OPTS ubuntu@$OP1_IP "~/bathron-cli -testnet getblockcount && ~/bathron-cli -testnet getblockchaininfo | jq '{blocks, headers, verificationprogress}'"
echo ""

echo "2. Global state (M0/M1 supply)..."
echo "-----------------------------------"
ssh $SSH_OPTS ubuntu@$OP1_IP "~/bathron-cli -testnet getstate"
echo ""

echo "3. Wallet state (balance + M1 receipts)..."
echo "--------------------------------------------"
ssh $SSH_OPTS ubuntu@$OP1_IP "~/bathron-cli -testnet getwalletstate true"
echo ""

echo "4. Testing htlc_generate RPC..."
echo "---------------------------------"
ssh $SSH_OPTS ubuntu@$OP1_IP "~/bathron-cli -testnet htlc_generate" 2>&1 || echo "HTLC RPC not available"
echo ""

echo "5. Existing HTLCs..."
echo "---------------------"
ssh $SSH_OPTS ubuntu@$OP1_IP "~/bathron-cli -testnet htlc_list 2>/dev/null || echo 'No htlc_list RPC or empty'"
echo ""

echo "6. SDK server status..."
echo "------------------------"
curl -s --connect-timeout 3 "http://$OP1_IP:8080/api/status" | jq . 2>/dev/null || echo "SDK not responding"
echo ""

echo "========================================"
echo "Check complete"
echo "========================================"
