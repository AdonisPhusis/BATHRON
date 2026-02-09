#!/bin/bash
# Fee Validation Gate - Tests that TX fees stay within acceptable bounds
# Uses the new m0_fee_info field for accurate M0-only fee calculation
#
# BP30 v2.6: Now checks m0_fee_info.complete field to ensure reliable fee data
#
# Usage: ./fee_gate.sh [--verbose]
#
# Exit codes:
#   0 = All tests pass
#   1 = At least one test failed

set -e

VERBOSE="${1:-}"
CLI="${CLI:-bathron-cli -testnet}"
MAX_RATE_NORMAL=1.0      # Max 1 sat/vB for normal TXs
MAX_RATE_SETTLEMENT=2.0  # Max 2 sat/vB for settlement TXs

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

pass() { echo -e "${GREEN}PASS${NC}: $1"; }
fail() { echo -e "${RED}FAIL${NC}: $1"; FAILURES=$((FAILURES+1)); }
warn() { echo -e "${YELLOW}WARN${NC}: $1"; WARNINGS=$((WARNINGS+1)); }

FAILURES=0
WARNINGS=0

# Helper: Check if fee info is complete, warn if not
check_complete() {
    local FEE_INFO="$1"
    local TX_TYPE="$2"
    local COMPLETE=$(echo "$FEE_INFO" | jq -r ".complete // true")
    local MISSING=$(echo "$FEE_INFO" | jq -r ".missing_inputs // 0")

    if [ "$COMPLETE" != "true" ]; then
        warn "$TX_TYPE: m0_fee_info.complete=false (missing_inputs=$MISSING)"
        return 1
    fi
    return 0
}

echo "=== Fee Validation Gate ==="
echo "Dust threshold: DUST_RELAY_TX_FEE = 1000 sat/kB (~182 M0)"
echo "Max rate (normal): $MAX_RATE_NORMAL sat/vB"
echo "Max rate (settlement): $MAX_RATE_SETTLEMENT sat/vB"
echo ""

# Test 1: Normal sendmany
echo "--- Test 1: NORMAL TX (sendmany) ---"
ADDR=$($CLI getnewaddress 2>/dev/null)
TXID=$($CLI sendmany "" "{\"$ADDR\":10000}" 2>&1)
if [[ "$TXID" =~ ^[a-f0-9]{64}$ ]]; then
    RAW=$($CLI getrawtransaction "$TXID" true 2>/dev/null)
    FEE_INFO=$(echo "$RAW" | jq -r ".m0_fee_info // empty")

    if [ -n "$FEE_INFO" ]; then
        TX_TYPE=$(echo "$FEE_INFO" | jq -r ".tx_type")
        M0_FEE=$(echo "$FEE_INFO" | jq -r ".m0_fee")
        RATE=$(echo "$FEE_INFO" | jq -r ".m0_feerate_satvb // \"N/A\"")

        [ -n "$VERBOSE" ] && echo "  TX Type: $TX_TYPE, M0 Fee: $M0_FEE, Rate: $RATE sat/vB"

        # Check completeness first
        check_complete "$FEE_INFO" "NORMAL TX"

        if [ "$M0_FEE" -lt 0 ] 2>/dev/null; then
            fail "NORMAL TX has negative m0_fee: $M0_FEE"
        elif [ "$RATE" != "N/A" ] && (( $(echo "$RATE <= $MAX_RATE_NORMAL" | bc -l) )); then
            pass "NORMAL TX fee rate $RATE sat/vB <= $MAX_RATE_NORMAL"
        elif [ "$RATE" == "N/A" ]; then
            warn "NORMAL TX fee rate not available (incomplete)"
        else
            fail "NORMAL TX fee rate $RATE sat/vB > $MAX_RATE_NORMAL"
        fi
    else
        fail "NORMAL TX missing m0_fee_info field"
    fi
else
    fail "sendmany failed: $TXID"
fi

# Test 2: TX_LOCK
echo "--- Test 2: TX_LOCK ---"
LOCK=$($CLI lock 5000 2>&1)
if [[ "$LOCK" == "{"* ]]; then
    TXID=$(echo "$LOCK" | jq -r ".txid")
    RAW=$($CLI getrawtransaction "$TXID" true 2>/dev/null)
    FEE_INFO=$(echo "$RAW" | jq -r ".m0_fee_info // empty")

    if [ -n "$FEE_INFO" ]; then
        TX_TYPE=$(echo "$FEE_INFO" | jq -r ".tx_type")
        M0_FEE=$(echo "$FEE_INFO" | jq -r ".m0_fee")
        M1_OUT=$(echo "$FEE_INFO" | jq -r ".m1_out // 0")
        VAULT_OUT=$(echo "$FEE_INFO" | jq -r ".vault_out // 0")
        RATE=$(echo "$FEE_INFO" | jq -r ".m0_feerate_satvb // \"N/A\"")

        [ -n "$VERBOSE" ] && echo "  TX Type: $TX_TYPE, M0 Fee: $M0_FEE, M1 Created: $M1_OUT, Vault: $VAULT_OUT, Rate: $RATE sat/vB"

        # Check completeness first
        check_complete "$FEE_INFO" "TX_LOCK"

        if [ "$TX_TYPE" != "TX_LOCK" ]; then
            fail "TX_LOCK not detected as TX_LOCK (got: $TX_TYPE)"
        elif [ "$M0_FEE" -lt 0 ] 2>/dev/null; then
            fail "TX_LOCK has negative m0_fee: $M0_FEE"
        elif [ "$RATE" != "N/A" ] && (( $(echo "$RATE <= $MAX_RATE_SETTLEMENT" | bc -l) )); then
            pass "TX_LOCK fee rate $RATE sat/vB <= $MAX_RATE_SETTLEMENT"
        elif [ "$RATE" == "N/A" ]; then
            warn "TX_LOCK fee rate not available (incomplete)"
        else
            fail "TX_LOCK fee rate $RATE sat/vB > $MAX_RATE_SETTLEMENT"
        fi
    else
        fail "TX_LOCK missing m0_fee_info field"
    fi
else
    fail "TX_LOCK failed: $LOCK"
fi

# Test 3: TX_UNLOCK (if M1 available)
echo "--- Test 3: TX_UNLOCK ---"
UNLOCK=$($CLI unlock 1000 2>&1)
if [[ "$UNLOCK" == "{"* ]]; then
    TXID=$(echo "$UNLOCK" | jq -r ".txid")
    RAW=$($CLI getrawtransaction "$TXID" true 2>/dev/null)
    FEE_INFO=$(echo "$RAW" | jq -r ".m0_fee_info // empty")

    if [ -n "$FEE_INFO" ]; then
        TX_TYPE=$(echo "$FEE_INFO" | jq -r ".tx_type")
        M0_FEE=$(echo "$FEE_INFO" | jq -r ".m0_fee")
        M1_IN=$(echo "$FEE_INFO" | jq -r ".m1_in // 0")
        M1_OUT=$(echo "$FEE_INFO" | jq -r ".m1_out // 0")
        VAULT_IN=$(echo "$FEE_INFO" | jq -r ".vault_in // 0")
        RATE=$(echo "$FEE_INFO" | jq -r ".m0_feerate_satvb // \"N/A\"")

        [ -n "$VERBOSE" ] && echo "  TX Type: $TX_TYPE, M0 Fee: $M0_FEE, M1 Burned: $(($M1_IN - $M1_OUT)), Vault In: $VAULT_IN, Rate: $RATE sat/vB"

        # Check completeness first
        check_complete "$FEE_INFO" "TX_UNLOCK"

        if [ "$TX_TYPE" != "TX_UNLOCK" ]; then
            fail "TX_UNLOCK not detected as TX_UNLOCK (got: $TX_TYPE)"
        elif [ "$M0_FEE" -lt 0 ] 2>/dev/null; then
            fail "TX_UNLOCK has negative m0_fee: $M0_FEE"
        elif [ "$RATE" != "N/A" ]; then
            pass "TX_UNLOCK fee rate $RATE sat/vB (M0 fee: $M0_FEE)"
        else
            warn "TX_UNLOCK fee rate not available (incomplete)"
        fi
    else
        fail "TX_UNLOCK missing m0_fee_info field"
    fi
else
    warn "TX_UNLOCK skipped (no M1 available or error: ${UNLOCK:0:50}...)"
fi

# Test 4: Verify no negative fees in recent TXs
echo "--- Test 4: No negative fees in last 10 TXs ---"
NEGATIVE_COUNT=0
INCOMPLETE_COUNT=0
for TXID in $($CLI listtransactions "*" 10 2>/dev/null | jq -r ".[].txid" | sort -u | head -10); do
    RAW=$($CLI getrawtransaction "$TXID" true 2>/dev/null)
    FEE_INFO=$(echo "$RAW" | jq -r ".m0_fee_info // empty")
    if [ -n "$FEE_INFO" ]; then
        M0_FEE=$(echo "$FEE_INFO" | jq -r ".m0_fee // 0")
        COMPLETE=$(echo "$FEE_INFO" | jq -r ".complete // true")

        if [ "$M0_FEE" -lt 0 ] 2>/dev/null; then
            [ -n "$VERBOSE" ] && echo "  Negative fee in ${TXID:0:12}...: $M0_FEE"
            NEGATIVE_COUNT=$((NEGATIVE_COUNT+1))
        fi
        if [ "$COMPLETE" != "true" ]; then
            [ -n "$VERBOSE" ] && echo "  Incomplete in ${TXID:0:12}..."
            INCOMPLETE_COUNT=$((INCOMPLETE_COUNT+1))
        fi
    fi
done
if [ "$NEGATIVE_COUNT" -eq 0 ]; then
    pass "No negative m0_fee found in recent transactions"
else
    fail "$NEGATIVE_COUNT transaction(s) with negative m0_fee"
fi
if [ "$INCOMPLETE_COUNT" -gt 0 ]; then
    warn "$INCOMPLETE_COUNT transaction(s) with incomplete m0_fee_info"
fi

# Summary
echo ""
echo "=== Summary ==="
if [ "$FAILURES" -eq 0 ] && [ "$WARNINGS" -eq 0 ]; then
    echo -e "${GREEN}All tests passed!${NC}"
    exit 0
elif [ "$FAILURES" -eq 0 ]; then
    echo -e "${YELLOW}All tests passed with $WARNINGS warning(s)${NC}"
    exit 0
else
    echo -e "${RED}$FAILURES test(s) failed, $WARNINGS warning(s)${NC}"
    exit 1
fi
