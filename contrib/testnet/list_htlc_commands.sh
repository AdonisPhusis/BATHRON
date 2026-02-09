#!/bin/bash
# List available HTLC commands

SSH_KEY="$HOME/.ssh/id_ed25519_vps"
SSH_OPTS="-i $SSH_KEY -o StrictHostKeyChecking=no -o ConnectTimeout=10"

OP1_IP="57.131.33.152"   # Alice (LP)
M1_CLI="\$HOME/bathron-cli -testnet"

echo "=== AVAILABLE HTLC COMMANDS ==="
echo ""

ssh $SSH_OPTS ubuntu@$OP1_IP "$M1_CLI help" 2>&1 | grep -i htlc
