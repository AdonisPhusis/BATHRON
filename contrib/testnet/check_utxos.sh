#!/bin/bash
# Quick UTXO check on Seed

SSH_KEY="$HOME/.ssh/id_ed25519_vps"
SEED_IP="57.131.33.151"
SSH="ssh -i $SSH_KEY -o StrictHostKeyChecking=no -o ConnectTimeout=10"

echo "=== UTXO Check on Seed ==="

$SSH ubuntu@$SEED_IP 'bash -s' << 'REMOTE'
CLI="/home/ubuntu/BATHRON-Core/src/bathron-cli -testnet"

echo "Height: $($CLI getblockcount)"
echo ""

echo "=== All UTXOs ==="
$CLI listunspent 0 9999999 2>/dev/null | jq -c '.[] | {addr: .address[0:20], amt: .amount, conf: .confirmations, txid: .txid[0:12]}' | head -20

echo ""
echo "=== 1M UTXOs (MN collateral candidates) ==="
$CLI listunspent 0 9999999 2>/dev/null | jq -c '[.[] | select(.amount == 1000000)] | length'

echo ""
echo "=== Mempool ==="
$CLI getrawmempool 2>/dev/null | jq 'length'

echo ""
echo "=== Burn Claims ==="
$CLI listburnclaims 2>/dev/null | jq 'length'

echo ""
echo "=== protx_list ==="
$CLI protx_list 2>/dev/null | jq 'length' 2>/dev/null || echo "0"

echo ""
echo "=== Wallet Balance ==="
$CLI getbalance 2>/dev/null | jq -r '.total // 0'
REMOTE
