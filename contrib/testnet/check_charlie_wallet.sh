#!/bin/bash
# Check charlie's wallet on OP3

SSH_KEY="$HOME/.ssh/id_ed25519_vps"
SSH_OPTS="-i $SSH_KEY -o StrictHostKeyChecking=no -o ConnectTimeout=10"
OP3_IP="51.75.31.44"
CLI="\$HOME/bathron-cli"

echo "=== Charlie Wallet (OP3 - $OP3_IP) ==="
echo ""

echo "1. getwalletstate true:"
ssh $SSH_OPTS ubuntu@$OP3_IP "$CLI -testnet getwalletstate true" 2>&1 | head -50
echo ""

echo "2. listunspent (all):"
ssh $SSH_OPTS ubuntu@$OP3_IP "$CLI -testnet listunspent" 2>&1 | head -30
echo ""

echo "3. getaccountaddress:"
ssh $SSH_OPTS ubuntu@$OP3_IP "$CLI -testnet getaccountaddress ''" 2>&1
echo ""

echo "4. getstate (global):"
ssh $SSH_OPTS ubuntu@$OP3_IP "$CLI -testnet getstate" 2>&1 | python3 -c "import json,sys; d=json.load(sys.stdin); print(json.dumps(d.get('supply', d), indent=2))"
