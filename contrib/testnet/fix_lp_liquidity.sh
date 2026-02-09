#!/bin/bash
set -e

OP1_IP="57.131.33.152"
OP1_SSH="ssh -i ~/.ssh/id_ed25519_vps -o StrictHostKeyChecking=no ubuntu@$OP1_IP"
OP1_CLI="/home/ubuntu/bathron-cli -testnet"

echo "=========================================="
echo "   FIX LP LIQUIDITY (OP1 - alice)"
echo "=========================================="
echo

# Get current block height
echo "[1/3] Checking current status..."
HEIGHT=$($OP1_SSH "$OP1_CLI getblockcount")
echo "  Current block height: $HEIGHT"

# Get wallet state
WALLET=$($OP1_SSH "$OP1_CLI getwalletstate true")
M0_BALANCE=$(echo "$WALLET" | jq -r '.m0.balance')
M1_BALANCE=$(echo "$WALLET" | jq -r '.m1.total')
M1_UNLOCKABLE=$(echo "$WALLET" | jq -r '.m1.unlockable')
echo "  M0 Balance: $M0_BALANCE sats (liquid)"
echo "  M1 Balance: $M1_BALANCE sats ($M1_UNLOCKABLE unlockable)"
echo

# Check HTLCs
echo "[2/3] Checking HTLCs..."
HTLCS=$($OP1_SSH "$OP1_CLI htlc_list" || echo "[]")
if [ "$HTLCS" = "[]" ]; then
    HTLC_COUNT=0
    TOTAL_LOCKED=0
else
    HTLC_COUNT=$(echo "$HTLCS" | jq 'length')
    TOTAL_LOCKED=$(echo "$HTLCS" | jq '[.[].amount] | add // 0')
fi
echo "  Active HTLCs: $HTLC_COUNT contracts"
echo "  Locked amount: $TOTAL_LOCKED sats"

# Check expired HTLCs
if [ "$HTLC_COUNT" -gt 0 ]; then
    EXPIRED=$(echo "$HTLCS" | jq "[.[] | select(.expiry_height < $HEIGHT)]")
    EXPIRED_COUNT=$(echo "$EXPIRED" | jq 'length')
    EXPIRED_AMOUNT=$(echo "$EXPIRED" | jq '[.[].amount] | add // 0')
    
    if [ "$EXPIRED_COUNT" -gt 0 ]; then
        echo "  [FOUND] $EXPIRED_COUNT expired HTLCs ($EXPIRED_AMOUNT sats)"
        echo "  [INFO] These can be refunded with htlc_refund RPC"
    fi
fi
echo

# Lock more M0 → M1 if available
if [ "$M0_BALANCE" -gt 100000 ]; then
    LOCK_AMOUNT=$((M0_BALANCE - 50000))  # Leave 50k for fees
    echo "[3/3] Locking M0 → M1..."
    echo "  Amount: $LOCK_AMOUNT sats (leaving 50k M0 for fees)"
    
    LOCK_TX=$($OP1_SSH "$OP1_CLI lock $LOCK_AMOUNT")
    TXID=$(echo "$LOCK_TX" | jq -r .txid)
    echo "  [OK] Lock TX: $TXID"
    
    # Wait for confirmation
    echo "  Waiting for 1 block confirmation..."
    sleep 65
    
    # Verify new state
    NEW_WALLET=$($OP1_SSH "$OP1_CLI getwalletstate true")
    NEW_M1=$(echo "$NEW_WALLET" | jq -r '.m1.total')
    NEW_M0=$(echo "$NEW_WALLET" | jq -r '.m0.balance')
    echo "  [SUCCESS] New M0: $NEW_M0 sats"
    echo "  [SUCCESS] New M1: $NEW_M1 sats"
else
    echo "[3/3] Skipping M0 → M1 lock"
    echo "  [WARN] Insufficient M0 balance: $M0_BALANCE sats (need >100k)"
fi
echo

echo "=========================================="
echo "   FINAL WALLET STATE"
echo "=========================================="
$OP1_SSH "$OP1_CLI getwalletstate true" | jq '{
  m0_liquid: .m0.balance,
  m1_total: .m1.total,
  m1_unlockable: .m1.unlockable,
  total_value: .total_value
}'
echo
echo "[INFO] LP now has more M1 available for swaps"
echo "[NEXT] Check full status: ./check_lp_liquidity.sh"
echo "=========================================="
