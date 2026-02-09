#!/bin/bash
# Setup ecdsa on OP3 using python3 -m pip

SSH_KEY="$HOME/.ssh/id_ed25519_vps"
SSH_OPTS="-i $SSH_KEY -o StrictHostKeyChecking=no"
OP3_IP="51.75.31.44"

echo "=== Installing ecdsa on OP3 ==="

ssh $SSH_OPTS ubuntu@$OP3_IP "
echo '[1/3] Installing pip if needed...'
sudo apt-get update -qq
sudo apt-get install -y -qq python3-pip 2>/dev/null || echo 'pip may be installed'

echo ''
echo '[2/3] Installing ecdsa...'
python3 -m pip install --user --break-system-packages ecdsa 2>&1 || python3 -m pip install --user ecdsa 2>&1

echo ''
echo '[3/3] Testing...'
python3 -c 'from ecdsa import SigningKey; print(\"ecdsa installed successfully\")'
"
