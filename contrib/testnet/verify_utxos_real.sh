#!/bin/bash
SSH_KEY="$HOME/.ssh/id_ed25519_vps"
SEED_IP="57.131.33.151"

ssh -i "$SSH_KEY" -o ConnectTimeout=10 -o StrictHostKeyChecking=no ubuntu@$SEED_IP 'bash -s' << 'REMOTE'
CLI="/home/ubuntu/bathron-cli -testnet"

echo "=== Wallet balance breakdown ==="
$CLI getbalance

echo ""
echo "=== ALL UTXOs on xyszqryssGaNw13qpjbxB4PVoRqGat7RPd ==="
$CLI listunspent 0 9999999 '["xyszqryssGaNw13qpjbxB4PVoRqGat7RPd"]' 2>/dev/null | jq -c '.[] | {amt: .amount, tx: .txid[0:12], v: .vout}'

echo ""
echo "=== ALL UTXOs on yJYD2bfYYBe6qAojSzMKX949H7QoQifNAo ==="
$CLI listunspent 0 9999999 '["yJYD2bfYYBe6qAojSzMKX949H7QoQifNAo"]' 2>/dev/null | jq -c '.[] | {amt: .amount, tx: .txid[0:12], v: .vout}'

echo ""
echo "=== Locked (collaterals) ==="
$CLI listlockunspent 2>/dev/null | jq -c '.transparent[] | {tx: .txid[0:12], v: .vout}'

echo ""
echo "=== Count of 1M UTXOs (exactly 1000000 sats) ==="
$CLI listunspent 0 9999999 2>/dev/null | jq '[.[] | select(.amount == 1000000)] | length'

echo ""
echo "=== Summary ==="
TOTAL_1M=$($CLI listunspent 0 9999999 2>/dev/null | jq '[.[] | select(.amount == 1000000)] | length')
LOCKED=$($CLI listlockunspent 2>/dev/null | jq '.transparent | length')
echo "Total 1M UTXOs: $TOTAL_1M"
echo "Locked (MN collateral): $LOCKED"
echo "Available for new MNs: $((TOTAL_1M - LOCKED))"
REMOTE
