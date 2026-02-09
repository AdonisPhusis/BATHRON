#!/bin/bash
# ==============================================================================
# verify_burn_tx.sh - Verify a specific burn TX on BTC Signet
# ==============================================================================

set -euo pipefail

# SSH config
SEED_IP="57.131.33.151"
SSH_KEY="$HOME/.ssh/id_ed25519_vps"
SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR"

# BTC CLI path on Seed
BTC_CLI="~/bitcoin-27.0/bin/bitcoin-cli -datadir=~/.bitcoin-signet"

if [ -z "${1:-}" ]; then
    echo "Usage: $0 <btc_txid>"
    exit 1
fi

TXID="$1"

echo "=========================================="
echo "Verifying BTC Burn Transaction"
echo "=========================================="
echo "TXID: $TXID"
echo ""

# Get raw TX
echo "Fetching TX from BTC Signet..."
TX_JSON=$(ssh -i "$SSH_KEY" $SSH_OPTS ubuntu@$SEED_IP "$BTC_CLI getrawtransaction '$TXID' true 2>/dev/null" || echo "{}")

if [ "$TX_JSON" == "{}" ]; then
    echo "ERROR: TX not found on BTC Signet"
    exit 1
fi

# Extract OP_RETURN
echo "OP_RETURN outputs:"
echo "$TX_JSON" | jq -r '.vout[] | select(.scriptPubKey.type == "nulldata") | {n: .n, hex: .scriptPubKey.hex}'
echo ""

# Extract P2WSH unspendable burn outputs
echo "Burn outputs (P2WSH unspendable):"
BURN_OUTPUTS=$(echo "$TX_JSON" | jq -r '.vout[] | select(.scriptPubKey.type == "witness_v0_scripthash" and .scriptPubKey.hex == "00206e340b9cffb37a989ca544e6bb780a2c78901d3fb33738768511a30617afa01d") | {n: .n, value: .value}')

if [ -z "$BURN_OUTPUTS" ]; then
    echo "  (none found)"
else
    echo "$BURN_OUTPUTS" | jq -s '.'
    
    # Calculate total
    TOTAL_BTC=$(echo "$TX_JSON" | jq '[.vout[] | select(.scriptPubKey.type == "witness_v0_scripthash" and .scriptPubKey.hex == "00206e340b9cffb37a989ca544e6bb780a2c78901d3fb33738768511a30617afa01d") | .value] | add // 0')
    TOTAL_SATS=$(printf "%.0f" $(echo "$TOTAL_BTC * 100000000" | bc -l))
    
    echo ""
    echo "Total burned: $TOTAL_BTC BTC = $TOTAL_SATS sats"
fi

echo ""
echo "Block info:"
echo "$TX_JSON" | jq -r '{blockhash, blocktime, confirmations}'
