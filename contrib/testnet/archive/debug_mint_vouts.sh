#!/bin/bash
SSH_KEY="$HOME/.ssh/id_ed25519_vps"
SSH="ssh -i $SSH_KEY -o StrictHostKeyChecking=no -o ConnectTimeout=10"
SEED="57.131.33.151"
CLI="/home/ubuntu/bathron-cli -datadir=/tmp/bathron_bootstrap -testnet"

MINT_TXID="188e6b6ed39db974559ada8e21ab4f9b7458708d84332b816caed7382e08c39e"

echo "=== All 31 mint vouts ==="
for VOUT in $(seq 0 30); do
    RESULT=$($SSH ubuntu@$SEED "timeout 5 $CLI gettxout '$MINT_TXID' $VOUT true 2>&1")
    if [ -z "$RESULT" ] || [ "$RESULT" = "null" ]; then
        echo "  vout $VOUT: SPENT/MISSING"
    else
        VAL=$(echo "$RESULT" | jq -r '.value')
        ADDR=$(echo "$RESULT" | jq -r '.scriptPubKey.addresses[0] // "N/A"')
        echo "  vout $VOUT: $VAL sats -> $ADDR"
    fi
done
