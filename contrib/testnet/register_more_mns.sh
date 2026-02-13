#!/bin/bash
SSH_KEY="$HOME/.ssh/id_ed25519_vps"
SEED_IP="57.131.33.151"

echo "=== Registering 3 more MNs ==="

ssh -i "$SSH_KEY" -o ConnectTimeout=10 -o StrictHostKeyChecking=no ubuntu@$SEED_IP 'bash -s' << 'REMOTE'
CLI="/home/ubuntu/bathron-cli -testnet"

echo "=== Current MN count ==="
$CLI protx_list 2>/dev/null | jq 'length'

echo ""
echo "=== Available 1M UTXOs (not locked) ==="
# The a70089f1... TX has vouts 2,3,4 with 1M each
UTXO_TX="a70089f1352d90458bf491f1f23f9723ada6aef0e7ff3107cd0f67edd4f19887"

for VOUT in 2 3 4; do
    echo "Checking $UTXO_TX vout $VOUT"
    $CLI gettxout "$UTXO_TX" $VOUT 2>/dev/null | jq '{value, address: .scriptPubKey.addresses[0]}'
done

echo ""
echo "=== Get operator pubkey ==="
OP_PUB=$(cat ~/.BathronKey/operators.json | jq -r '.operator.pubkey')
echo "Operator: $OP_PUB"

echo ""
echo "=== Registering MNs ==="

for VOUT in 2 3 4; do
    echo ""
    echo "--- MN for vout $VOUT ---"

    # Check if this UTXO is already used as collateral
    EXISTING=$($CLI protx_list 2>/dev/null | jq --arg tx "$UTXO_TX" --argjson vout $VOUT '[.[] | select(.collateralHash == $tx and .collateralIndex == $vout)] | length')
    if [ "$EXISTING" != "0" ]; then
        echo "  Already used as collateral, skipping"
        continue
    fi

    OWNER=$($CLI getnewaddress "owner_extra_$VOUT")
    VOTING=$($CLI getnewaddress "voting_extra_$VOUT")
    PAYOUT=$($CLI getnewaddress "payout_extra_$VOUT")

    echo "  Owner: $OWNER"
    echo "  Voting: $VOTING"
    echo "  Payout: $PAYOUT"

    RESULT=$($CLI protx_register "$UTXO_TX" "$VOUT" "57.131.33.151:27171" "$OWNER" "$OP_PUB" "$VOTING" "$PAYOUT" 2>&1)
    echo "  Result: $RESULT"
done

echo ""
echo "=== Final MN count ==="
sleep 2
$CLI protx_list 2>/dev/null | jq 'length'

echo ""
echo "=== Active MN status ==="
$CLI getactivemnstatus 2>/dev/null | jq '{state, managed_count}'
REMOTE
