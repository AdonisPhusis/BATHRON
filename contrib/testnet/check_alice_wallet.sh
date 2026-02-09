#!/bin/bash
OP1_IP="57.131.33.152"
SSH_KEY="$HOME/.ssh/id_ed25519_vps"
SSH_OPTS="-o StrictHostKeyChecking=no -o ConnectTimeout=15 -o BatchMode=yes"
SSH="ssh -i $SSH_KEY $SSH_OPTS"

echo "=== Alice M1 Wallet (OP1) ==="
$SSH ubuntu@$OP1_IP "/home/ubuntu/bathron/bin/bathron-cli -testnet getwalletinfo" | grep -E '"balance"|"unconfirmed"|"txcount"'

echo ""
echo "=== Alice M1 State ==="
$SSH ubuntu@$OP1_IP "/home/ubuntu/bathron/bin/bathron-cli -testnet getwalletstate true" | head -20
