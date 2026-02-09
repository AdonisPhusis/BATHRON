#!/bin/bash
# Setup ecdsa on OP3 properly

SSH_KEY="$HOME/.ssh/id_ed25519_vps"
SSH_OPTS="-i $SSH_KEY -o StrictHostKeyChecking=no"
OP3_IP="51.75.31.44"

echo "=== Checking OP3 Python environment ==="

ssh $SSH_OPTS ubuntu@$OP3_IP "
echo 'Python version:'
python3 --version

echo ''
echo 'Pip location:'
which pip3 || echo 'pip3 not in PATH'

echo ''
echo 'User site-packages:'
python3 -m site --user-site

echo ''
echo 'Trying pip install with sudo...'
sudo pip3 install ecdsa --break-system-packages 2>&1 || sudo pip3 install ecdsa 2>&1

echo ''
echo 'Checking if ecdsa works now:'
python3 -c 'from ecdsa import SigningKey; print(\"ecdsa OK\")' 2>&1
"
