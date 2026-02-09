#!/bin/bash
# Analyze mempool transactions

SSH_KEY=~/.ssh/id_ed25519_vps
SEED_IP="57.131.33.151"

echo "=== Mempool info ==="
ssh -i $SSH_KEY ubuntu@$SEED_IP "~/bathron-cli -testnet getmempoolinfo"

echo ""
echo "=== All mempool TXs with types ==="
for txid in $(ssh -i $SSH_KEY ubuntu@$SEED_IP "~/bathron-cli -testnet getrawmempool" 2>/dev/null | grep -o '"[a-f0-9]\{64\}"' | tr -d '"'); do
    type=$(ssh -i $SSH_KEY ubuntu@$SEED_IP "~/bathron-cli -testnet getrawtransaction $txid true" 2>/dev/null | grep '"type":' | head -1 | grep -o '[0-9]*')
    size=$(ssh -i $SSH_KEY ubuntu@$SEED_IP "~/bathron-cli -testnet getrawtransaction $txid true" 2>/dev/null | grep '"size":' | head -1 | grep -o '[0-9]*')
    echo "  $txid type=$type size=$size"
done

echo ""
echo "=== Block height ==="
ssh -i $SSH_KEY ubuntu@$SEED_IP "~/bathron-cli -testnet getblockcount"

echo ""
echo "=== Try to manually test block creation ==="
ssh -i $SSH_KEY ubuntu@$SEED_IP "~/bathron-cli -testnet generate 1" 2>&1 || echo "generate failed (expected on DMM)"
