#!/usr/bin/env bash
set -euo pipefail

SSH_KEY="$HOME/.ssh/id_ed25519_vps"
SSH_OPTS="-i $SSH_KEY -o StrictHostKeyChecking=no -o ConnectTimeout=10"
SEED_IP="57.131.33.151"

echo "=== Checking HTLC TX Inputs for Conflicts ==="
echo ""

# Get mempool TXs
MEMPOOL=$(ssh $SSH_OPTS ubuntu@$SEED_IP "~/bathron-cli -testnet getrawmempool")
TX1=$(echo "$MEMPOOL" | jq -r '.[0]')
TX2=$(echo "$MEMPOOL" | jq -r '.[1]')

echo "TX1: $TX1"
echo "TX2: $TX2"
echo ""

echo "=== TX1 Details ==="
TX1_RAW=$(ssh $SSH_OPTS ubuntu@$SEED_IP "~/bathron-cli -testnet getrawtransaction $TX1 1")
echo "Type: $(echo $TX1_RAW | jq -r '.type')"
echo "Input: $(echo $TX1_RAW | jq -r '.vin[0] | "\(.txid):\(.vout)"')"
echo ""

echo "=== TX2 Details ==="
TX2_RAW=$(ssh $SSH_OPTS ubuntu@$SEED_IP "~/bathron-cli -testnet getrawtransaction $TX2 1")
echo "Type: $(echo $TX2_RAW | jq -r '.type')"
echo "Input: $(echo $TX2_RAW | jq -r '.vin[0] | "\(.txid):\(.vout)"')"
echo ""

# Check if inputs conflict
TX1_INPUT=$(echo $TX1_RAW | jq -r '.vin[0] | "\(.txid):\(.vout)"')
TX2_INPUT=$(echo $TX2_RAW | jq -r '.vin[0] | "\(.txid):\(.vout)"')

if [ "$TX1_INPUT" = "$TX2_INPUT" ]; then
    echo "⚠️  CONFLICT: Both TXs spend the same input!"
else
    echo "✓ No input conflict - different inputs"
fi

echo ""
echo "=== Checking if inputs exist in UTXO set ==="
# Check TX1 input
echo "TX1 input ($TX1_INPUT):"
INPUT_TXID=$(echo $TX1_INPUT | cut -d: -f1)
INPUT_VOUT=$(echo $TX1_INPUT | cut -d: -f2)
ssh $SSH_OPTS ubuntu@$SEED_IP "~/bathron-cli -testnet gettxout $INPUT_TXID $INPUT_VOUT" | jq '{value, confirmations, scriptPubKey: .scriptPubKey.type}' || echo "  NOT FOUND (already spent)"

echo ""
echo "TX2 input ($TX2_INPUT):"
INPUT_TXID=$(echo $TX2_INPUT | cut -d: -f1)
INPUT_VOUT=$(echo $TX2_INPUT | cut -d: -f2)
ssh $SSH_OPTS ubuntu@$SEED_IP "~/bathron-cli -testnet gettxout $INPUT_TXID $INPUT_VOUT" | jq '{value, confirmations, scriptPubKey: .scriptPubKey.type}' || echo "  NOT FOUND (already spent)"

echo ""
echo "=== Check if inputs are M1 receipts ==="
echo "Looking up settlement state for inputs..."
ssh $SSH_OPTS ubuntu@$SEED_IP "~/bathron-cli -testnet getstate" | jq '.supply'
