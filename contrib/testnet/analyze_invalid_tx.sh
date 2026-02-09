#!/bin/bash
# Analyze why invalid TX was accepted

SEED_IP="57.131.33.151"
CLI="/home/ubuntu/BATHRON-Core/src/bathron-cli -testnet"
TXID="801fdb2754816c788e220954774d32449604a555f6cdd47c67f7b10a9d9e4a27"

echo "=== Check if vin[1] prevout is a VAULT ==="
PREVOUT_TXID="24e73cf07897a4b88ae7432c3b1a70f3e2c936d94d017bf0cbd353c03ed08e99"
PREVOUT_VOUT=0

echo "Getting prevout TX..."
ssh -i ~/.ssh/id_ed25519_vps ubuntu@$SEED_IP "$CLI getrawtransaction $PREVOUT_TXID true" | head -100
