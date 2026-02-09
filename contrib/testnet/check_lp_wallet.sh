#!/bin/bash
# Check LP (alice) wallet on OP1

SSH_KEY="$HOME/.ssh/id_ed25519_vps"
SSH_OPTS="-i $SSH_KEY -o StrictHostKeyChecking=no -o ConnectTimeout=10"
OP1_IP="57.131.33.152"
M1_CLI="\$HOME/bathron-cli -testnet"
BTC_CLI="\$HOME/bitcoin/bin/bitcoin-cli -signet -datadir=/home/ubuntu/.bitcoin-signet"

echo "=== LP Wallet (OP1 - $OP1_IP) ==="
echo ""

echo "1. M1 State (getwalletstate):"
ssh $SSH_OPTS ubuntu@$OP1_IP "$M1_CLI getwalletstate true" 2>&1 | head -40
echo ""

echo "2. BTC Balance:"
ssh $SSH_OPTS ubuntu@$OP1_IP "$BTC_CLI getbalance" 2>&1
echo ""

echo "3. BTC Addresses:"
ssh $SSH_OPTS ubuntu@$OP1_IP "$BTC_CLI listreceivedbyaddress 0 true" 2>&1 | head -30
echo ""

echo "4. Active HTLCs:"
ssh $SSH_OPTS ubuntu@$OP1_IP "$M1_CLI htlc_list active" 2>&1
echo ""
