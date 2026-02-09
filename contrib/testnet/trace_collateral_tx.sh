#!/bin/bash
SSH_KEY="$HOME/.ssh/id_ed25519_vps"
SEED_IP="57.131.33.151"

ssh -i "$SSH_KEY" -o ConnectTimeout=10 -o StrictHostKeyChecking=no ubuntu@$SEED_IP 'bash -s' << 'REMOTE'
CLI="/home/ubuntu/bathron-cli -testnet"

echo "=== Current collateral TX ==="
COLL_TX="a47436c623c8e41dae0f36c7b7facc0d9434d617a38068de20702142cdd55321"
$CLI getrawtransaction "$COLL_TX" true 2>/dev/null | jq '{txid: .txid[0:16], blockhash: .blockhash[0:16], vout: [.vout[] | {n, value, address: .scriptPubKey.addresses[0]}]}'

echo ""
echo "=== TX a70089f1 (shows in listunspent) ==="
TX2="a70089f1352d90458bf491f1f23f9723ada6aef0e7ff3107cd0f67edd4f19887"
$CLI getrawtransaction "$TX2" true 2>/dev/null | jq '{txid: .txid[0:16], blockhash: .blockhash[0:16], vout: [.vout[] | {n, value, address: .scriptPubKey.addresses[0]}]}' || echo "TX not found"

echo ""
echo "=== Check amount format ==="
echo "listunspent amounts are in BATHRON (not sats):"
$CLI listunspent 0 9999999 '["xyszqryssGaNw13qpjbxB4PVoRqGat7RPd"]' 2>/dev/null | jq '.[0:2] | .[] | {amount_bathron: .amount, amount_sats: (.amount * 100000000)}'
REMOTE
