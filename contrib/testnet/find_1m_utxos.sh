#!/bin/bash
SSH_KEY="$HOME/.ssh/id_ed25519_vps"
SEED_IP="57.131.33.151"

ssh -i "$SSH_KEY" -o ConnectTimeout=10 -o StrictHostKeyChecking=no ubuntu@$SEED_IP 'bash -s' << 'REMOTE'
CLI="/home/ubuntu/bathron-cli -testnet"

echo "=== All UTXOs for xyszqryssGaNw13qpjbxB4PVoRqGat7RPd ==="
$CLI listunspent 0 9999999 '["xyszqryssGaNw13qpjbxB4PVoRqGat7RPd"]' 2>/dev/null | jq '.[] | {amount, txid: .txid[0:16], vout, confirmations}'

echo ""
echo "=== Locked UTXOs (used as collateral) ==="
$CLI listlockunspent 2>/dev/null | jq '.'

echo ""
echo "=== TX_MINT_M0BTC in blocks 2-10 ==="
for h in 2 3 4 5 6 7 8 9 10; do
    HASH=$($CLI getblockhash $h 2>/dev/null)
    BLOCK=$($CLI getblock "$HASH" 2 2>/dev/null)
    MINTS=$(echo "$BLOCK" | jq '[.tx[] | select(.type == 32)] | length')
    if [ "$MINTS" != "0" ] && [ "$MINTS" != "null" ]; then
        echo "Block $h: $MINTS TX_MINT_M0BTC"
        echo "$BLOCK" | jq '.tx[] | select(.type == 32) | {txid: .txid[0:16], vout_count: (.vout | length)}'
    fi
done
REMOTE
