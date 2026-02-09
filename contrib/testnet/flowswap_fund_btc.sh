#!/bin/bash
# FlowSwap: Fund BTC HTLC from OP3 (charlie)
# Usage: ./contrib/testnet/flowswap_fund_btc.sh <btc_address> <amount_btc>
set -euo pipefail

OP3="51.75.31.44"
SSH="ssh -i ~/.ssh/id_ed25519_vps -o StrictHostKeyChecking=no -o ConnectTimeout=10 ubuntu@${OP3}"
BTC_CLI="/home/ubuntu/bitcoin/bin/bitcoin-cli -signet -datadir=/home/ubuntu/.bitcoin-signet"

BTC_ADDR="${1:?Usage: $0 <btc_address> <amount_btc>}"
AMOUNT="${2:?Usage: $0 <btc_address> <amount_btc>}"

echo "=== FlowSwap: Fund BTC HTLC ==="
echo "  To:     $BTC_ADDR"
echo "  Amount: $AMOUNT BTC"
echo ""

# Check balance first
echo "--- Charlie BTC balance ---"
BAL=$($SSH "$BTC_CLI -rpcwallet=fake_user getbalance" 2>/dev/null || echo "0")
echo "  Balance: $BAL BTC"

if [ "$BAL" = "0" ] || [ "$BAL" = "0.00000000" ]; then
    echo "ERROR: Charlie has no BTC. Fund via signetfaucet.com"
    exit 1
fi

# Send BTC to HTLC address
echo ""
echo "--- Sending $AMOUNT BTC to HTLC ---"
TXID=$($SSH "$BTC_CLI -rpcwallet=fake_user sendtoaddress $BTC_ADDR $AMOUNT" 2>&1)

if [[ "$TXID" =~ ^[0-9a-f]{64}$ ]]; then
    echo "  TX sent: $TXID"
    echo "  Explorer: https://mempool.space/signet/tx/$TXID"
    echo ""
    echo "=== SUCCESS: BTC funded. Wait for 1 confirmation, then call presign. ==="
else
    echo "  ERROR: $TXID"
    exit 1
fi
