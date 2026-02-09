#!/bin/bash
# Verify HTLC exists on BATHRON blockchain

set -e

TXID="${1:-31ea186b4a59f89d99bc93fe57cabe829e3c68e4df00cef74fa36c5a55651063}"
OUTPOINT="${2:-${TXID}:0}"

# Use OP1 node (alice - LP)
NODE_IP="57.131.33.152"
CLI="/home/ubuntu/bathron-cli -testnet"

echo "=== HTLC Verification ==="
echo "TXID: $TXID"
echo "Outpoint: $OUTPOINT"
echo ""

echo "--- 1. Raw Transaction Details ---"
ssh -i ~/.ssh/id_ed25519_vps ubuntu@$NODE_IP "$CLI getrawtransaction $TXID 1" || {
    echo "ERROR: Transaction not found or not yet propagated"
    exit 1
}

echo ""
echo "--- 2. Active HTLCs List ---"
ssh -i ~/.ssh/id_ed25519_vps ubuntu@$NODE_IP "$CLI htlc_list" || {
    echo "ERROR: Could not retrieve HTLC list"
}

echo ""
echo "--- 3. Current Block Height ---"
CURRENT_HEIGHT=$(ssh -i ~/.ssh/id_ed25519_vps ubuntu@$NODE_IP "$CLI getblockcount")
echo "Current height: $CURRENT_HEIGHT"
echo "HTLC expires at: 1791"
if [ "$CURRENT_HEIGHT" -lt 1791 ]; then
    BLOCKS_UNTIL_EXPIRY=$((1791 - CURRENT_HEIGHT))
    echo "Blocks until expiry: $BLOCKS_UNTIL_EXPIRY"
else
    echo "WARNING: HTLC has expired!"
fi

echo ""
echo "--- 4. HTLC Status Summary ---"
ssh -i ~/.ssh/id_ed25519_vps ubuntu@$NODE_IP "$CLI getrawtransaction $TXID 1" | grep -E '"confirmations"|"blockhash"|"blocktime"' || true

