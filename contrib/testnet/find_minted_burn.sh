#!/bin/bash
# Find which burn was actually minted (1M sats)

set -e

SEED_IP="57.131.33.151"
SSH_KEY="$HOME/.ssh/id_ed25519_vps"
SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=15 -o BatchMode=yes"
SSH="ssh -i $SSH_KEY $SSH_OPTS"
CLI="~/BATHRON-Core/src/bathron-cli -testnet"

echo "=========================================="
echo "Finding Which Burn Was Minted"
echo "=========================================="
echo ""

GENESIS_BURNS="/home/ubuntu/BATHRON/contrib/testnet/genesis_burns.json"

echo "Checking all 1M sat burns from genesis_burns.json:"
echo ""

# Find all 1M sat burns
while IFS= read -r line; do
    TXID=$(echo "$line" | jq -r '.btc_txid')
    HEIGHT=$(echo "$line" | jq -r '.btc_height')
    AMOUNT=$(echo "$line" | jq -r '.amount')
    
    if [ "$AMOUNT" == "1000000" ]; then
        # Check detailed status
        RESULT=$($SSH ubuntu@$SEED_IP "$CLI checkburnclaim $TXID 2>/dev/null" || echo "{}")
        
        echo "TXID: $TXID"
        echo "  Height: $HEIGHT"
        echo "  Amount: $AMOUNT sats"
        echo "  Status:"
        echo "$RESULT" | jq . | sed 's/^/    /'
        echo ""
    fi
    
done < <(jq -c '.burns[]' "$GENESIS_BURNS")

echo "=========================================="
