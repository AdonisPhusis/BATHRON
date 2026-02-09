#!/bin/bash
# Check Bitcoin wallet type on OP1 (legacy vs descriptor)

OP1_IP="57.131.33.152"
SSH_KEY="$HOME/.ssh/id_ed25519_vps"
SSH_OPTS="-o StrictHostKeyChecking=no -o ConnectTimeout=15 -o BatchMode=yes"
SSH="ssh -i $SSH_KEY $SSH_OPTS"

echo "=== Bitcoin Wallet Info on OP1 ==="
$SSH ubuntu@$OP1_IP "/home/ubuntu/bitcoin/bin/bitcoin-cli -signet getwalletinfo" 2>&1
