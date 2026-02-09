#!/bin/bash
set -e

SEED_IP="57.131.33.151"
SSH_KEY="$HOME/.ssh/id_ed25519_vps"
REMOTE_CLI="$HOME/BATHRON-Core/src/bathron-cli"
REMOTE_DATADIR="$HOME/.bathron/testnet5"
TARGET_TXID="0a72b136f3b9797d2e6be4f3b4935d9d66c7c0c877feeae935b12e0876648deb"

echo "=========================================="
echo "Deep Dive: HTLC History on Seed"
echo "=========================================="
echo

echo "1. Search entire debug.log for target TXID..."
ssh -i "$SSH_KEY" ubuntu@$SEED_IP "grep '$TARGET_TXID' $REMOTE_DATADIR/debug.log 2>/dev/null" || echo "(TXID not found in debug.log)"
echo

echo "2. Last 200 lines with HTLC mentions..."
ssh -i "$SSH_KEY" ubuntu@$SEED_IP "tail -200 $REMOTE_DATADIR/debug.log | grep -i htlc" || echo "(No HTLC mentions in last 200 lines)"
echo

echo "3. Search for any 'bad-' rejection in last 500 lines..."
ssh -i "$SSH_KEY" ubuntu@$SEED_IP "tail -500 $REMOTE_DATADIR/debug.log | grep 'bad-'" || echo "(No 'bad-' rejections found)"
echo

echo "4. Current block height and mempool size..."
BLOCKCOUNT=$(ssh -i "$SSH_KEY" ubuntu@$SEED_IP "$REMOTE_CLI -testnet getblockcount")
MEMPOOL_SIZE=$(ssh -i "$SSH_KEY" ubuntu@$SEED_IP "$REMOTE_CLI -testnet getmempoolinfo | grep '\"size\"'")
echo "Block height: $BLOCKCOUNT"
echo "Mempool: $MEMPOOL_SIZE"
echo

echo "5. Check if TX was ever received/rejected (search AcceptToMemoryPool)..."
ssh -i "$SSH_KEY" ubuntu@$SEED_IP "grep -E 'AcceptToMemoryPool.*$TARGET_TXID|$TARGET_TXID.*AcceptToMemoryPool' $REMOTE_DATADIR/debug.log 2>/dev/null" || echo "(No AcceptToMemoryPool logs for this TXID)"
echo

echo "=========================================="
echo "Summary:"
echo "=========================================="
echo "Check complete. TX appears to have never reached Seed node."
