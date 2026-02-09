#!/bin/bash
SSH_KEY="$HOME/.ssh/id_ed25519_vps"
SEED_IP="57.131.33.151"

ssh -i "$SSH_KEY" -o ConnectTimeout=10 -o StrictHostKeyChecking=no ubuntu@$SEED_IP 'bash -s' << 'REMOTE'
CLI="/home/ubuntu/bathron-cli -testnet"

echo "=== Known addresses hash160 ==="
echo "xyszqryssGaNw13qpjbxB4PVoRqGat7RPd:"
$CLI getaddressinfo "xyszqryssGaNw13qpjbxB4PVoRqGat7RPd" 2>/dev/null | jq -r '.scriptPubKey' | head -1

echo ""
echo "yJYD2bfYYBe6qAojSzMKX949H7QoQifNAo:"
$CLI getaddressinfo "yJYD2bfYYBe6qAojSzMKX949H7QoQifNAo" 2>/dev/null | jq -r '.scriptPubKey' | head -1

echo ""
echo "=== Burns hash160 (from genesis_burns.json) ==="
echo "D83FX2VUUc4snkrQA1JDKPikCSkT44atay -> 1fcd606d941ab567d9b247f9e5792dc537c4813f"
echo "DCxMaAtQegEDjX9dhwZwnw5zMaUzJhEtNP -> 55b8fac66bb5d2b1e4713701fa63cb14b8e8bb70"

echo ""
echo "=== Try to validate hash160 as testnet address ==="
# hash160 1fcd606d941ab567d9b247f9e5792dc537c4813f
# This should be the pubkeyhash
$CLI decodescript "76a9141fcd606d941ab567d9b247f9e5792dc537c4813f88ac" 2>/dev/null | jq '.addresses'

echo ""
$CLI decodescript "76a91455b8fac66bb5d2b1e4713701fa63cb14b8e8bb7088ac" 2>/dev/null | jq '.addresses'
REMOTE
