#!/bin/bash
# Check if HTLC has expired

SSH_KEY="$HOME/.ssh/id_ed25519_vps"
SSH_OPTS="-i $SSH_KEY -o StrictHostKeyChecking=no -o ConnectTimeout=10"

OP1_IP="57.131.33.152"   # Alice (LP)
M1_CLI="\$HOME/bathron-cli -testnet"

HTLC_OUTPOINT="31ea186b4a59f89d99bc93fe57cabe829e3c68e4df00cef74fa36c5a55651063:0"

echo "=== HTLC EXPIRY CHECK ==="
echo ""

echo "Current block height:"
CURRENT_HEIGHT=$(ssh $SSH_OPTS ubuntu@$OP1_IP "$M1_CLI getblockcount" 2>&1)
echo "  $CURRENT_HEIGHT"
echo ""

echo "HTLC expiry height: 1791"
echo "HTLC create height: 1504"
echo ""

if [ "$CURRENT_HEIGHT" -ge 1791 ]; then
    echo "✅ HTLC HAS EXPIRED (current: $CURRENT_HEIGHT >= expiry: 1791)"
    echo ""
    echo "Alice can now refund the HTLC:"
    echo "  bathron-cli -testnet htlc_refund '$HTLC_OUTPOINT'"
    echo ""
    echo "Attempting refund..."
    ssh $SSH_OPTS ubuntu@$OP1_IP "$M1_CLI htlc_refund '$HTLC_OUTPOINT'" 2>&1
else
    BLOCKS_LEFT=$((1791 - CURRENT_HEIGHT))
    echo "⏳ HTLC NOT YET EXPIRED (need $BLOCKS_LEFT more blocks)"
    echo ""
    echo "Current HTLC status:"
    ssh $SSH_OPTS ubuntu@$OP1_IP "$M1_CLI htlc_get '$HTLC_OUTPOINT'" 2>&1
fi
