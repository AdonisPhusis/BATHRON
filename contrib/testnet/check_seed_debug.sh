#!/bin/bash

NODE="57.131.33.151"
SSH_KEY="$HOME/.ssh/id_ed25519_vps"

echo "=== SEED DEBUG LOG (last 150 lines) ==="
ssh -i "$SSH_KEY" ubuntu@$NODE 'tail -150 ~/.bathron/testnet5/debug.log'

echo ""
echo "=== FILTERING FOR CRITICAL ERRORS ==="
ssh -i "$SSH_KEY" ubuntu@$NODE 'tail -500 ~/.bathron/testnet5/debug.log | grep -E "(ERROR|REJECT|invalid|failed|stuck|stall)" | tail -50'

echo ""
echo "=== CURRENT STATUS ==="
ssh -i "$SSH_KEY" ubuntu@$NODE '~/bathron-cli -testnet getblockcount' 2>&1 | head -1
ssh -i "$SSH_KEY" ubuntu@$NODE '~/bathron-cli -testnet getpeerinfo | grep -c "addr"' 2>&1 | head -1
ssh -i "$SSH_KEY" ubuntu@$NODE '~/bathron-cli -testnet getbtcheadersstatus 2>&1 | head -20'
