#!/usr/bin/env bash
set -euo pipefail

SSH_KEY="$HOME/.ssh/id_ed25519_vps"
SSH_OPTS="-i $SSH_KEY -o StrictHostKeyChecking=no -o ConnectTimeout=10"
SEED_IP="57.131.33.151"
CLI="\$HOME/BATHRON-Core/src/bathron-cli"

echo "Tracing HTLC TX origin and M1 receipt history..."
echo ""

# The M1 receipt that HTLC is trying to spend
RECEIPT_TX="c6782b33fef1f7e0bf01064ceca8ff9ef509403462a5cd98fa6b7721b6e7db47"
RECEIPT_VOUT="1"

echo "1. M1 Receipt TX (TX_LOCK):"
echo "   TXID: $RECEIPT_TX"
echo "   This created the M1 receipt at output $RECEIPT_VOUT"
echo ""

# Get the TX_LOCK details
TX_LOCK_DATA=$(ssh $SSH_OPTS ubuntu@$SEED_IP "$CLI -testnet getrawtransaction $RECEIPT_TX 1")
echo "$TX_LOCK_DATA" | jq '{txid, type, blockhash, confirmations, vout: [.vout[] | {n, value, asset, addresses: .scriptPubKey.addresses}]}'
echo ""

# Check if this output has been spent in a confirmed block
echo "2. Checking if M1 receipt has been spent..."
SPENT_CHECK=$(ssh $SSH_OPTS ubuntu@$SEED_IP "$CLI -testnet gettxout $RECEIPT_TX $RECEIPT_VOUT")

if [[ -z "$SPENT_CHECK" ]]; then
    echo "   ✗ UTXO is SPENT (confirmed in a block)"
    echo ""
    echo "   Searching for spending TX in blockchain..."
    
    # Get current height
    HEIGHT=$(ssh $SSH_OPTS ubuntu@$SEED_IP "$CLI -testnet getblockcount")
    TX_LOCK_BLOCK=$(echo "$TX_LOCK_DATA" | jq -r '.blockhash')
    
    if [[ "$TX_LOCK_BLOCK" != "null" ]]; then
        TX_LOCK_HEIGHT=$(ssh $SSH_OPTS ubuntu@$SEED_IP "$CLI -testnet getblock $TX_LOCK_BLOCK" | jq -r '.height')
        echo "   M1 receipt created at height: $TX_LOCK_HEIGHT"
        echo "   Current height: $HEIGHT"
        echo ""
        
        # Search for spending TX (this is slow but comprehensive)
        echo "   Scanning blocks from $TX_LOCK_HEIGHT to $HEIGHT for spending TX..."
        for h in $(seq $((TX_LOCK_HEIGHT + 1)) $HEIGHT); do
            BLOCK_HASH=$(ssh $SSH_OPTS ubuntu@$SEED_IP "$CLI -testnet getblockhash $h")
            BLOCK_DATA=$(ssh $SSH_OPTS ubuntu@$SEED_IP "$CLI -testnet getblock $BLOCK_HASH 2")
            
            # Check if any TX in this block spends our UTXO
            SPENDING_TX=$(echo "$BLOCK_DATA" | jq -r ".tx[] | select(.vin[]? | select(.txid == \"$RECEIPT_TX\" and .vout == $RECEIPT_VOUT)) | .txid" | head -1)
            
            if [[ -n "$SPENDING_TX" ]]; then
                echo ""
                echo "   ✓ FOUND spending TX in block $h:"
                echo "   TXID: $SPENDING_TX"
                echo ""
                
                # Get details of spending TX
                SPENDING_TX_DATA=$(ssh $SSH_OPTS ubuntu@$SEED_IP "$CLI -testnet getrawtransaction $SPENDING_TX 1")
                echo "$SPENDING_TX_DATA" | jq '{txid, type, blockhash, confirmations}'
                break
            fi
            
            # Progress indicator every 100 blocks
            if [[ $((h % 100)) -eq 0 ]]; then
                echo "   ... checked up to block $h"
            fi
        done
    fi
else
    echo "   ✓ UTXO is UNSPENT"
    echo "$SPENT_CHECK" | jq '.'
fi
echo ""

echo "3. HTLC TX in mempool:"
HTLC_TXID="0a72b136f3b9797d2e6be4f3b4935d9d66c7c0c877feeae935b12e0876648deb"
echo "   TXID: $HTLC_TXID"
echo "   Status: In mempool (not mined)"
echo "   Reason: bad-htlccreate-amount-mismatch"
echo ""

echo "=========================================="
echo "Summary"
echo "=========================================="
echo "The HTLC TX is trying to spend an M1 receipt that:"
if [[ -z "$SPENT_CHECK" ]]; then
    echo "- Was already spent in a confirmed block"
    echo "- This is a DOUBLE-SPEND attempt (invalid)"
else
    echo "- Still exists as UTXO (should be valid)"
    echo "- Something else is wrong with validation"
fi

