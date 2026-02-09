#!/usr/bin/env bash
set -euo pipefail

CORESDK_IP="162.19.251.75"
SSH_KEY="$HOME/.ssh/id_ed25519_vps"
SSH="ssh -i $SSH_KEY -o StrictHostKeyChecking=no -o ConnectTimeout=10"

echo "[$(date +%H:%M:%S)] Checking HTLC receipt details..."
echo ""

# Get the HTLC TX
HTLC_TXID="0a72b136f3b9797d2e6be4f3b4935d9d66c7c0c877feeae935b12e0876648deb"

echo "=== HTLC Transaction ==="
HTLC_TX=$($SSH ubuntu@$CORESDK_IP "~/bathron-cli -testnet getrawtransaction $HTLC_TXID 1")
echo "$HTLC_TX" | jq '{type, vin: .vin[0], vout: .vout[0]}'

# Get the input (M1 receipt)
RECEIPT_TXID=$(echo "$HTLC_TX" | jq -r '.vin[0].txid')
RECEIPT_VOUT=$(echo "$HTLC_TX" | jq -r '.vin[0].vout')

echo ""
echo "=== M1 Receipt Transaction ($RECEIPT_TXID vout $RECEIPT_VOUT) ==="
RECEIPT_TX=$($SSH ubuntu@$CORESDK_IP "~/bathron-cli -testnet getrawtransaction $RECEIPT_TXID 1")
echo "$RECEIPT_TX" | jq "{type, vout: .vout[$RECEIPT_VOUT]}"

# Check wallet state for this receipt
echo ""
echo "=== Wallet State (M1 Receipts) ==="
$SSH ubuntu@$CORESDK_IP '~/bathron-cli -testnet getwalletstate true' | jq '.m1_receipts[] | select(.outpoint | contains("'$RECEIPT_TXID'"))'

echo ""
echo "[$(date +%H:%M:%S)] Check complete"
