#!/bin/bash
# Check LP liquidity for both BATHRON (M0/M1) and BTC

SSH_KEY="$HOME/.ssh/id_ed25519_vps"
SSH_OPTS="-i $SSH_KEY -o StrictHostKeyChecking=no -o ConnectTimeout=10"
OP1_IP="57.131.33.152"

echo "=========================================="
echo "   LP LIQUIDITY REPORT (OP1 - alice)"
echo "=========================================="
echo ""

# 1. BATHRON Wallet State
echo "=== 1. BATHRON WALLET (M0 + M1) ==="
M1_STATE=$(ssh $SSH_OPTS ubuntu@$OP1_IP '/home/ubuntu/bathron-cli -testnet getwalletstate true' 2>&1)

if echo "$M1_STATE" | grep -q "schema"; then
    M0_BALANCE=$(echo "$M1_STATE" | grep -A 2 '"m0"' | grep '"balance"' | awk '{print $2}' | tr -d ',')
    M1_TOTAL=$(echo "$M1_STATE" | grep -A 4 '"m1"' | grep '"total"' | awk '{print $2}' | tr -d ',')
    M1_COUNT=$(echo "$M1_STATE" | grep -A 4 '"m1"' | grep '"count"' | awk '{print $2}' | tr -d ',')
    TOTAL_VALUE=$(echo "$M1_STATE" | grep '"total_value"' | awk '{print $2}' | tr -d ',')
    
    echo "  M0 Balance:      $M0_BALANCE sats (liquid)"
    echo "  M1 Locked:       $M1_TOTAL sats ($M1_COUNT receipts)"
    echo "  Total Value:     $TOTAL_VALUE sats"
    echo ""
    
    # Show M1 receipts
    echo "  M1 Receipts:"
    echo "$M1_STATE" | grep -A 6 '"outpoint"' | grep -E '(outpoint|amount|settlement_status)' | \
        sed 's/^[ \t]*/    /'
else
    echo "  ERROR: Could not fetch wallet state"
    echo "$M1_STATE" | head -5
fi

echo ""

# 2. BTC Wallet
echo "=== 2. BTC SIGNET WALLET ==="
BTC_BALANCE=$(ssh $SSH_OPTS ubuntu@$OP1_IP '/home/ubuntu/bitcoin/bin/bitcoin-cli -signet getbalance' 2>&1)
BTC_UNCONF=$(ssh $SSH_OPTS ubuntu@$OP1_IP '/home/ubuntu/bitcoin/bin/bitcoin-cli -signet getunconfirmedbalance' 2>&1)
BTC_HEIGHT=$(ssh $SSH_OPTS ubuntu@$OP1_IP '/home/ubuntu/bitcoin/bin/bitcoin-cli -signet getblockcount' 2>&1)

if [[ "$BTC_BALANCE" =~ ^[0-9.]+$ ]]; then
    echo "  Balance:         $BTC_BALANCE BTC"
    echo "  Unconfirmed:     $BTC_UNCONF BTC"
    echo "  Chain Height:    $BTC_HEIGHT"
    
    # Get receiving address
    BTC_ADDR=$(ssh $SSH_OPTS ubuntu@$OP1_IP '/home/ubuntu/bitcoin/bin/bitcoin-cli -signet getrawchangeaddress' 2>&1)
    if [[ "$BTC_ADDR" =~ ^tb1 ]]; then
        echo "  LP Address:      $BTC_ADDR"
    fi
else
    echo "  ERROR: Could not fetch BTC balance"
    echo "  $BTC_BALANCE"
fi

echo ""

# 3. Active HTLCs (locked in swaps)
echo "=== 3. ACTIVE HTLCs (Locked in Swaps) ==="
HTLC_LIST=$(ssh $SSH_OPTS ubuntu@$OP1_IP '/home/ubuntu/bathron-cli -testnet htlc_list active' 2>&1)

if echo "$HTLC_LIST" | grep -q "outpoint"; then
    HTLC_COUNT=$(echo "$HTLC_LIST" | grep -c '"outpoint"')
    HTLC_TOTAL=$(echo "$HTLC_LIST" | grep '"amount"' | awk '{sum+=$2} END {print sum}')
    
    echo "  Active HTLCs:    $HTLC_COUNT contracts"
    echo "  Locked Amount:   $HTLC_TOTAL sats"
    echo ""
    echo "  Top 5 HTLCs:"
    echo "$HTLC_LIST" | grep -A 5 '"outpoint"' | head -30 | \
        grep -E '(amount|expiry_height|status)' | sed 's/^[ \t]*/    /'
else
    echo "  No active HTLCs"
fi

echo ""

# 4. Summary
echo "=========================================="
echo "   LIQUIDITY SUMMARY"
echo "=========================================="

if [[ -n "$M0_BALANCE" ]] && [[ -n "$M1_TOTAL" ]] && [[ -n "$BTC_BALANCE" ]]; then
    AVAILABLE_M0=$M0_BALANCE
    LOCKED_M1=$M1_TOTAL
    LOCKED_HTLC=${HTLC_TOTAL:-0}
    
    echo "  Available for Swaps:"
    echo "    - M0 (liquid):      $AVAILABLE_M0 sats"
    echo "    - M1 (can unlock):  $LOCKED_M1 sats"
    echo "    - BTC (liquid):     $BTC_BALANCE BTC"
    echo ""
    echo "  Temporarily Locked:"
    echo "    - HTLCs:            $LOCKED_HTLC sats"
    echo ""
    echo "  TOTAL M0 POWER:       $TOTAL_VALUE sats"
fi

echo "=========================================="
