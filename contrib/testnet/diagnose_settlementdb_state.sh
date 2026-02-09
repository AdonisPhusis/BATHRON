#!/usr/bin/env bash
set -euo pipefail

SSH_KEY="$HOME/.ssh/id_ed25519_vps"
SSH_OPTS="-i $SSH_KEY -o StrictHostKeyChecking=no -o ConnectTimeout=10"
SEED_IP="57.131.33.151"
CLI="\$HOME/BATHRON-Core/src/bathron-cli"

echo "Diagnosing settlementdb state issue..."
echo ""

# 1. Check UTXO set
echo "1. Checking UTXO set for receipt..."
UTXO=$(ssh $SSH_OPTS ubuntu@$SEED_IP "$CLI -testnet gettxout c6782b33fef1f7e0bf01064ceca8ff9ef509403462a5cd98fa6b7721b6e7db47 1")
if [[ -z "$UTXO" ]]; then
    echo "   ✗ UTXO does not exist (spent or never existed)"
else
    echo "   ✓ UTXO exists:"
    echo "$UTXO" | jq '.'
fi
echo ""

# 2. Check if TX_LOCK is in blockchain
echo "2. Checking if TX_LOCK is confirmed..."
TX_LOCK=$(ssh $SSH_OPTS ubuntu@$SEED_IP "$CLI -testnet getrawtransaction c6782b33fef1f7e0bf01064ceca8ff9ef509403462a5cd98fa6b7721b6e7db47 1")
BLOCKHASH=$(echo "$TX_LOCK" | jq -r '.blockhash')
if [[ "$BLOCKHASH" != "null" && -n "$BLOCKHASH" ]]; then
    echo "   ✓ TX_LOCK is confirmed in block: $BLOCKHASH"
    BLOCK=$(ssh $SSH_OPTS ubuntu@$SEED_IP "$CLI -testnet getblock $BLOCKHASH")
    HEIGHT=$(echo "$BLOCK" | jq -r '.height')
    echo "   Block height: $HEIGHT"
else
    echo "   ✗ TX_LOCK not confirmed"
fi
echo ""

# 3. Check current chain height
echo "3. Current chain state..."
HEIGHT=$(ssh $SSH_OPTS ubuntu@$SEED_IP "$CLI -testnet getblockcount")
echo "   Height: $HEIGHT"
echo ""

# 4. Check settlementdb state
echo "4. Global settlement state..."
STATE=$(ssh $SSH_OPTS ubuntu@$SEED_IP "$CLI -testnet getstate")
echo "$STATE" | jq '.supply'
echo ""

# 5. Look for recent HTLC errors in debug.log
echo "5. Recent HTLC validation errors..."
ssh $SSH_OPTS ubuntu@$SEED_IP "grep -E 'bad-htlccreate|HTLC_CREATE' \$HOME/.bathron/testnet5/debug.log | tail -10"
echo ""

# 6. Check if there's a -rebuildsettlement flag needed
echo "6. Checking if settlementdb needs rebuild..."
echo "   Run: bathrond -testnet -rebuildsettlement -daemon"
echo "   This will reconstruct settlementdb from blockchain"
echo ""

echo "=========================================="
echo "DIAGNOSIS"
echo "=========================================="
echo ""
echo "Based on the checks:"
echo "1. If UTXO doesn't exist BUT TX_LOCK is confirmed → Receipt was spent"
echo "2. If UTXO exists BUT validation fails → settlementdb is out of sync"
echo ""
echo "Recommendation:"
if [[ -z "$UTXO" ]]; then
    echo "- Receipt was already spent. HTLC TX is invalid."
    echo "- Remove HTLC TX from mempool or let it expire."
else
    echo "- UTXO exists but settlementdb may be corrupt."
    echo "- Run: ./contrib/testnet/fix_seed_fork.sh"
    echo "- Or restart with -rebuildsettlement flag"
fi

