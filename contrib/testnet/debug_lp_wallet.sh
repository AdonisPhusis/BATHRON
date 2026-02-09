#!/bin/bash
# debug_lp_wallet.sh - Diagnose LP wallet M1 balance issue

set -e

KEY="~/.ssh/id_ed25519_vps"
OP1_IP="57.131.33.152"
OP1_USER="ubuntu"

echo "=== LP Wallet Diagnostic (OP1) ==="
echo

echo "1. Checking wallet state (M1 receipts)..."
ssh -i $KEY $OP1_USER@$OP1_IP '/home/ubuntu/bathron-cli -testnet getwalletstate true'
echo

echo "2. Checking alice address..."
ssh -i $KEY $OP1_USER@$OP1_IP 'cat ~/.BathronKey/wallet.json | grep -E "(name|address)"'
echo

echo "3. Checking pna-lp server logs (last 50 lines)..."
ssh -i $KEY $OP1_USER@$OP1_IP 'journalctl -u pna-lp -n 50 --no-pager'
echo

echo "4. Checking pna-lp process..."
ssh -i $KEY $OP1_USER@$OP1_IP 'systemctl status pna-lp --no-pager | head -20'
echo

echo "5. Checking M0 balance..."
ssh -i $KEY $OP1_USER@$OP1_IP '/home/ubuntu/bathron-cli -testnet getbalance'
echo

echo "6. Checking global settlement state..."
ssh -i $KEY $OP1_USER@$OP1_IP '/home/ubuntu/bathron-cli -testnet getstate'
echo

echo "=== DIAGNOSTIC COMPLETE ==="
