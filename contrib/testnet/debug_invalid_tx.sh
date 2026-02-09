#!/bin/bash
# Debug the invalid TX in mempool

SEED_IP="57.131.33.151"
CLI="/home/ubuntu/BATHRON-Core/src/bathron-cli -testnet"
TXID="801fdb2754816c788e220954774d32449604a555f6cdd47c67f7b10a9d9e4a27"

echo "=== Getting raw transaction from Seed ==="
ssh -i ~/.ssh/id_ed25519_vps ubuntu@$SEED_IP "$CLI getrawtransaction $TXID true"

echo ""
echo "=== Checking mempool info ==="
ssh -i ~/.ssh/id_ed25519_vps ubuntu@$SEED_IP "$CLI getmempoolentry $TXID"

echo ""
echo "=== Mempool stats ==="
ssh -i ~/.ssh/id_ed25519_vps ubuntu@$SEED_IP "$CLI getmempoolinfo"
