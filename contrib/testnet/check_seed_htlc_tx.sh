#!/bin/bash
set -e

SEED_IP="57.131.33.151"
SSH_KEY="$HOME/.ssh/id_ed25519_vps"
REMOTE_CLI="$HOME/BATHRON-Core/src/bathron-cli"
REMOTE_DATADIR="$HOME/.bathron/testnet5"
TARGET_TXID="0a72b136f3b9797d2e6be4f3b4935d9d66c7c0c877feeae935b12e0876648deb"

echo "=========================================="
echo "Checking Seed for HTLC TX"
echo "Target TXID: $TARGET_TXID"
echo "=========================================="
echo

echo "1. Checking mempool for target TX..."
ssh -i "$SSH_KEY" ubuntu@$SEED_IP "$REMOTE_CLI -testnet getrawmempool" > /tmp/seed_mempool.txt
if grep -q "$TARGET_TXID" /tmp/seed_mempool.txt; then
    echo "✓ TX FOUND in mempool"
else
    echo "✗ TX NOT in mempool"
fi
echo

echo "2. Full mempool contents:"
cat /tmp/seed_mempool.txt
echo

echo "3. Checking debug.log for HTLC/bad- errors (last 50 lines)..."
ssh -i "$SSH_KEY" ubuntu@$SEED_IP "tail -50 $REMOTE_DATADIR/debug.log | grep -iE 'htlc|bad-'" || echo "(No HTLC/bad- errors found in last 50 lines)"
echo

echo "4. Checking if TX exists on chain..."
TX_INFO=$(ssh -i "$SSH_KEY" ubuntu@$SEED_IP "$REMOTE_CLI -testnet getrawtransaction $TARGET_TXID 1 2>&1" || echo "NOT_FOUND")
if [[ "$TX_INFO" == *"NOT_FOUND"* ]] || [[ "$TX_INFO" == *"No such mempool"* ]]; then
    echo "✗ TX not found on chain or in mempool"
else
    echo "✓ TX found on chain/mempool:"
    echo "$TX_INFO"
fi
echo

echo "=========================================="
echo "Summary:"
echo "=========================================="
echo "Check complete. See above for details."
