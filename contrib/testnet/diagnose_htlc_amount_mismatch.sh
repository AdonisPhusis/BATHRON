#!/usr/bin/env bash
set -euo pipefail

# diagnose_htlc_amount_mismatch.sh
# Deep dive into HTLC amount validation failure

SSH_KEY="$HOME/.ssh/id_ed25519_vps"
SSH_OPTS="-i $SSH_KEY -o StrictHostKeyChecking=no -o ConnectTimeout=10"
SEED_IP="57.131.33.151"
SEED_CLI="\$HOME/BATHRON-Core/src/bathron-cli"

echo "=========================================="
echo "HTLC Amount Mismatch Deep Diagnostic"
echo "=========================================="
echo ""

# Get all M1 receipts on Seed
echo "1. M1 receipts in Seed wallet..."
echo "---------------------------------"
RECEIPTS=$(ssh $SSH_OPTS ubuntu@$SEED_IP "$SEED_CLI -testnet getwalletstate true" 2>/dev/null || echo "ERROR")

if [[ "$RECEIPTS" == "ERROR" ]]; then
    echo "Failed to get wallet state"
    exit 1
fi

echo "$RECEIPTS" | grep -A 20 '"receipts"' || echo "No receipts found"
echo ""

# Check recent debug.log for amount mismatches
echo "2. Recent HTLC errors in debug.log..."
echo "---------------------------------------"
ssh $SSH_OPTS ubuntu@$SEED_IP "tail -500 \$HOME/.bathron/testnet5/debug.log | grep -E 'bad-htlccreate|HTLC|amount|receipt' | tail -30" 2>/dev/null || echo "No errors found"
echo ""

# Check if there are any HTLCs in the HTLC DB
echo "3. Current HTLCs (if any)..."
echo "----------------------------"
HTLC_LIST=$(ssh $SSH_OPTS ubuntu@$SEED_IP "$SEED_CLI -testnet htlc_list" 2>/dev/null || echo "[]")
echo "$HTLC_LIST"
echo ""

# Get global state
echo "4. Global M0/M1 state..."
echo "-------------------------"
STATE=$(ssh $SSH_OPTS ubuntu@$SEED_IP "$SEED_CLI -testnet getstate" 2>/dev/null || echo "ERROR")
echo "$STATE"
echo ""

# Check mempool for rejected TXes
echo "5. Mempool status..."
echo "---------------------"
MEMPOOL_INFO=$(ssh $SSH_OPTS ubuntu@$SEED_IP "$SEED_CLI -testnet getmempoolinfo" 2>/dev/null || echo "ERROR")
echo "$MEMPOOL_INFO"
echo ""

echo "=========================================="
echo "Analysis"
echo "=========================================="
echo ""
echo "The error 'bad-htlccreate-amount-mismatch' means:"
echo "  htlcOut.nValue != receipt.amount"
echo ""
echo "This can happen if:"
echo "1. The RPC constructs output with wrong amount"
echo "2. Settlementdb has stale/incorrect receipt amount"
echo "3. The receipt was modified somehow"
echo ""
echo "Next steps:"
echo "- Check if M1 receipts exist and have correct amounts"
echo "- Try creating a NEW receipt with 'lock' RPC"
echo "- Try creating HTLC with the new receipt"
echo ""

