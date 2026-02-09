#!/bin/bash
SSH_KEY="$HOME/.ssh/id_ed25519_vps"
SSH_OPTS="-i $SSH_KEY -o StrictHostKeyChecking=no -o ConnectTimeout=10"
OP1_IP="57.131.33.152"

echo "=== OP1 Bitcoin Config ==="

echo "1. ~/.bitcoin/bitcoin.conf:"
ssh $SSH_OPTS ubuntu@$OP1_IP "cat ~/.bitcoin/bitcoin.conf"

echo ""
echo "2. ~/bitcoin/bitcoin.conf:"
ssh $SSH_OPTS ubuntu@$OP1_IP "cat ~/bitcoin/bitcoin.conf"

echo ""
echo "3. Try CLI without explicit datadir:"
ssh $SSH_OPTS ubuntu@$OP1_IP "/home/ubuntu/bitcoin/bin/bitcoin-cli -signet getblockcount 2>&1"

echo ""
echo "4. Try CLI with ~/.bitcoin:"
ssh $SSH_OPTS ubuntu@$OP1_IP "/home/ubuntu/bitcoin/bin/bitcoin-cli -signet -datadir=/home/ubuntu/.bitcoin getblockcount 2>&1"

echo ""
echo "5. List ~/.bitcoin contents:"
ssh $SSH_OPTS ubuntu@$OP1_IP "ls -la ~/.bitcoin/"
