#!/bin/bash
# Check mempool TX fees

SSH_KEY=~/.ssh/id_ed25519_vps
SEED_IP="57.131.33.151"

echo "=== Mempool TXs with fees ==="
ssh -i $SSH_KEY ubuntu@$SEED_IP '
for txid in $(~/bathron-cli -testnet getrawmempool 2>/dev/null | grep -o "[a-f0-9]\{64\}" | head -10); do
    info=$(~/bathron-cli -testnet getrawtransaction $txid true 2>/dev/null)
    type=$(echo "$info" | jq -r ".type")
    fee_info=$(echo "$info" | jq -r ".m0_fee_info")
    m0_fee=$(echo "$info" | jq -r ".m0_fee_info.m0_fee // 0")
    echo "TX: ${txid:0:16}... type=$type fee=$m0_fee"
done
'

echo ""
echo "=== What types should be feeless in block assembly? ==="
echo "TX_BURN_CLAIM, TX_MINT_M0BTC, TX_BTC_HEADERS, HTLC_CREATE_M1, HTLC_CLAIM, HTLC_REFUND"
echo ""
echo "Missing from feeless list: TX_LOCK (20), TX_UNLOCK (21), TX_TRANSFER_M1 (22)"
