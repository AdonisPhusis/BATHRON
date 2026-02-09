#!/usr/bin/env bash
set -euo pipefail

SSH_KEY="$HOME/.ssh/id_ed25519_vps"
SSH_OPTS="-i $SSH_KEY -o StrictHostKeyChecking=no -o ConnectTimeout=10"
SEED_IP="57.131.33.151"
CLI="\$HOME/BATHRON-Core/src/bathron-cli"

RECEIPT_OUTPOINT="c6782b33fef1f7e0bf01064ceca8ff9ef509403462a5cd98fa6b7721b6e7db47:1"

echo "Checking M1 receipt state on Seed node..."
echo "Receipt: $RECEIPT_OUTPOINT"
echo ""

# Get wallet state
echo "1. Wallet state (M1 receipts):"
ssh $SSH_OPTS ubuntu@$SEED_IP "$CLI -testnet getwalletstate true" > /tmp/wallet_state.json
cat /tmp/wallet_state.json | jq -r '.m1_receipts'
echo ""

# Check if this specific receipt exists
echo "2. Looking for specific receipt: $RECEIPT_OUTPOINT"
RECEIPT_FOUND=$(cat /tmp/wallet_state.json | jq -r ".m1_receipts[] | select(.outpoint == \"$RECEIPT_OUTPOINT\")" || echo "")
if [[ -z "$RECEIPT_FOUND" ]]; then
    echo "   ✗ Receipt NOT found in wallet state"
    echo "   This means it may have been spent already!"
else
    echo "   ✓ Receipt found:"
    echo "$RECEIPT_FOUND" | jq '.'
fi
echo ""

# Check if receipt has been spent
echo "3. Checking UTXO status of receipt..."
UTXO_INFO=$(ssh $SSH_OPTS ubuntu@$SEED_IP "$CLI -testnet gettxout c6782b33fef1f7e0bf01064ceca8ff9ef509403462a5cd98fa6b7721b6e7db47 1" 2>&1 || echo "SPENT")
if [[ "$UTXO_INFO" == *"SPENT"* ]] || [[ -z "$UTXO_INFO" ]]; then
    echo "   ✗ UTXO is SPENT or doesn't exist"
else
    echo "   ✓ UTXO exists (unspent):"
    echo "$UTXO_INFO" | jq '.'
fi
echo ""

# Check debug log for settlement DB operations
echo "4. Checking debug.log for settlement DB operations on this receipt..."
ssh $SSH_OPTS ubuntu@$SEED_IP "grep -i 'c6782b33fef1f7e0bf01064ceca8ff9ef509403462a5cd98fa6b7721b6e7db47' \$HOME/.bathron/testnet5/debug.log | tail -20" || echo "(No log entries found)"
echo ""

# Check if there are any conflicting TXs in mempool
echo "5. Checking for conflicting TXs in mempool..."
MEMPOOL=$(ssh $SSH_OPTS ubuntu@$SEED_IP "$CLI -testnet getrawmempool true")
echo "$MEMPOOL" | jq -r 'to_entries[] | select(.value.vin[0].txid == "c6782b33fef1f7e0bf01064ceca8ff9ef509403462a5cd98fa6b7721b6e7db47" and .value.vin[0].vout == 1) | .key' > /tmp/conflicting_txs.txt

CONFLICTS=$(cat /tmp/conflicting_txs.txt | wc -l)
if [[ "$CONFLICTS" -gt 1 ]]; then
    echo "   ⚠ Multiple TXs trying to spend same receipt!"
    cat /tmp/conflicting_txs.txt
else
    echo "   ✓ No conflicts (only our HTLC TX)"
fi
echo ""

echo "6. Global settlement state:"
ssh $SSH_OPTS ubuntu@$SEED_IP "$CLI -testnet getstate" | jq '.'

