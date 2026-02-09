#!/bin/bash
SSH_KEY="$HOME/.ssh/id_ed25519_vps"
SEED_IP="57.131.33.151"

ssh -i "$SSH_KEY" -o ConnectTimeout=10 -o StrictHostKeyChecking=no ubuntu@$SEED_IP 'bash -s' << 'REMOTE'
CLI="/home/ubuntu/bathron-cli -datadir=/home/ubuntu/.bathron -testnet"

echo "=== Burns Claimed (with amounts) ==="
$CLI listburnclaims 2>/dev/null | jq -c '.[] | {btc_txid: .btc_txid[0:16], bathron_dest: .bathron_dest[0:20], burned_sats, finalized}'

echo ""
echo "=== Burns >= 1M sats ==="
$CLI listburnclaims 2>/dev/null | jq '[.[] | select(.burned_sats >= 1000000)]'

echo ""
echo "=== All UTXOs (confirmations + amount) ==="
$CLI listunspent 0 9999999 2>/dev/null | jq -c '.[] | {address: .address[0:20], amount, conf: .confirmations, txid: .txid[0:16]}'

echo ""
echo "=== UTXOs exactly 1M sats ==="
$CLI listunspent 0 9999999 2>/dev/null | jq '[.[] | select(.amount == 1000000)] | length'
echo "found"

echo ""
echo "=== Mempool ==="
$CLI getmempoolinfo 2>/dev/null | jq '{size, bytes}'
REMOTE
