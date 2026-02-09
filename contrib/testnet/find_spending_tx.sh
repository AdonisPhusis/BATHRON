#!/usr/bin/env bash
set -euo pipefail

SSH_KEY="$HOME/.ssh/id_ed25519_vps"
SSH_OPTS="-i $SSH_KEY -o StrictHostKeyChecking=no -o ConnectTimeout=10"
SEED_IP="57.131.33.151"
CLI="\$HOME/BATHRON-Core/src/bathron-cli"

RECEIPT_TX="c6782b33fef1f7e0bf01064ceca8ff9ef509403462a5cd98fa6b7721b6e7db47"
RECEIPT_VOUT="1"
START_HEIGHT=5203
END_HEIGHT=5237

echo "Searching for TX that spent $RECEIPT_TX:$RECEIPT_VOUT..."
echo "Block range: $START_HEIGHT to $END_HEIGHT"
echo ""

for h in $(seq $START_HEIGHT $END_HEIGHT); do
    BLOCK_HASH=$(ssh $SSH_OPTS ubuntu@$SEED_IP "$CLI -testnet getblockhash $h")
    BLOCK_DATA=$(ssh $SSH_OPTS ubuntu@$SEED_IP "$CLI -testnet getblock $BLOCK_HASH 2")
    
    # Check each TX in block
    SPENDING_TXID=$(echo "$BLOCK_DATA" | jq -r ".tx[] | select(.vin[]? | (.txid == \"$RECEIPT_TX\" and .vout == $RECEIPT_VOUT)) | .txid" 2>/dev/null | head -1)
    
    if [[ -n "$SPENDING_TXID" ]]; then
        echo "✓ FOUND at block $h"
        echo "Spending TXID: $SPENDING_TXID"
        echo ""
        
        # Get full TX details
        TX_DATA=$(ssh $SSH_OPTS ubuntu@$SEED_IP "$CLI -testnet getrawtransaction $SPENDING_TXID 1")
        echo "TX Details:"
        echo "$TX_DATA" | jq '{
            txid,
            type,
            blockhash,
            confirmations,
            vin: [.vin[] | {txid, vout}],
            vout: [.vout[] | {n, value, asset, addresses: .scriptPubKey.addresses}]
        }'
        
        TYPE=$(echo "$TX_DATA" | jq -r '.type')
        echo ""
        echo "TX Type: $TYPE"
        case "$TYPE" in
            40) echo "(TX_HTLC_CREATE_M1 - HTLC creation)" ;;
            41) echo "(TX_HTLC_CLAIM - HTLC claim)" ;;
            42) echo "(TX_HTLC_REFUND - HTLC refund)" ;;
            20) echo "(TX_LOCK - M0 -> M1)" ;;
            21) echo "(TX_UNLOCK - M1 -> M0)" ;;
            22) echo "(TX_TRANSFER_M1 - M1 transfer)" ;;
            *) echo "(Type $TYPE)" ;;
        esac
        
        exit 0
    fi
done

echo "✗ No spending TX found in blocks $START_HEIGHT to $END_HEIGHT"
