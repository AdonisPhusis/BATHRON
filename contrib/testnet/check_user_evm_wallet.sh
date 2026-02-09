#!/bin/bash
# Check fake user EVM wallet on OP3
SSH_KEY=~/.ssh/id_ed25519_vps
OP3_IP="51.75.31.44"

echo "=== Fake User EVM Wallet (OP3) ==="
ssh -i $SSH_KEY ubuntu@$OP3_IP 'cat ~/.keys/user_evm.json 2>/dev/null || echo "Wallet not found"'
