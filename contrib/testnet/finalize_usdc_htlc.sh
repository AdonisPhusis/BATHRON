#!/bin/bash
set -e

OP3_IP="51.75.31.44"
SWAP_ID="full_be88561492ca4427"

echo "=== Retrieving USDC HTLC Result ==="
scp -i ~/.ssh/id_ed25519_vps ubuntu@$OP3_IP:/tmp/usdc_htlc_result.json /tmp/usdc_htlc_result.json

cat /tmp/usdc_htlc_result.json

TX_HASH=$(jq -r '.tx_hash' /tmp/usdc_htlc_result.json)
HTLC_ID=$(jq -r '.htlc_id' /tmp/usdc_htlc_result.json)

echo ""
echo "=== Registering HTLC with LP ==="
curl -X POST "http://57.131.33.152:8080/api/swap/full/${SWAP_ID}/register-htlc?htlc_id=${HTLC_ID}" \
     -H "Content-Type: application/json" | jq .

echo ""
echo "=== USDC HTLC CREATED ==="
echo "TX Hash: $TX_HASH"
echo "HTLC ID: $HTLC_ID"
echo "Explorer: https://sepolia.basescan.org/tx/$TX_HASH"
echo ""
echo "Next steps:"
echo "1. LP will claim the M1 HTLC (HTLC-3)"
echo "2. LP will claim the BTC HTLC (HTLC-1)"
echo "3. User (charlie) claims this USDC HTLC (HTLC-4) with the revealed secret"
