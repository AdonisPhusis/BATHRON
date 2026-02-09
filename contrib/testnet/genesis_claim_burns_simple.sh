#!/bin/bash
# ==============================================================================
# genesis_claim_burns_simple.sh - Dynamic burn claiming for genesis
# ==============================================================================
# Claims BTC burns from:
#   1. genesis_burns.json (if available) - fast, reliable
#   2. Dynamic scan of BTC Signet (fallback) - slow but no data needed
#
# NO HARDCODED TXIDs IN THIS SCRIPT!
# ==============================================================================

# NOTE: NOT using set -e because jq/grep may return empty results
set +e

# Configuration
BATHRON_CLI="${BATHRON_CMD:-/home/ubuntu/bathron-cli -datadir=/tmp/bathron_bootstrap -testnet}"
BTC_CLI="${BTC_CLI:-/home/ubuntu/bitcoin-27.0/bin/bitcoin-cli}"
BTC_DATADIR="${BTC_DATADIR:-/home/ubuntu/.bitcoin-signet}"
BTC_CMD="$BTC_CLI -datadir=$BTC_DATADIR"

# Genesis burns file (data source, NOT hardcoded)
# Check multiple locations (deployed to ~/ on Seed, or local path)
GENESIS_BURNS_FILE="${GENESIS_BURNS_FILE:-}"
if [ -z "$GENESIS_BURNS_FILE" ]; then
    if [ -f "$HOME/genesis_burns.json" ]; then
        GENESIS_BURNS_FILE="$HOME/genesis_burns.json"
    elif [ -f "/home/ubuntu/BATHRON/contrib/testnet/genesis_burns.json" ]; then
        GENESIS_BURNS_FILE="/home/ubuntu/BATHRON/contrib/testnet/genesis_burns.json"
    fi
fi

# BATHRON magic in OP_RETURN (hex: "BATHRON")
BATHRON_MAGIC="42415448524f4e"

echo "════════════════════════════════════════════════════════════════"
echo "  Burn Claimer for Genesis (NO HARDCODED DATA)"
echo "════════════════════════════════════════════════════════════════"
echo "BTC CLI: $BTC_CMD"
echo "BATHRON CLI: $BATHRON_CLI"
echo ""

# Get BTC tip
BTC_TIP=$($BTC_CMD getblockcount 2>/dev/null || echo "-1")
if [ "$BTC_TIP" == "-1" ]; then
    echo "[FATAL] Cannot reach BTC Signet"
    exit 1
fi
echo "BTC Signet tip: $BTC_TIP"

# Track results
BURNS_FOUND=0
BURNS_SUBMITTED=0
BURNS_SKIPPED=0
BURNS_FAILED=0

# Function to submit a single burn
submit_burn() {
    local TXID="$1"

    # Get raw TX
    RAW_TX=$($BTC_CMD getrawtransaction "$TXID" 2>/dev/null)
    if [ -z "$RAW_TX" ]; then
        echo "    [ERROR] TX not found on Signet"
        return 1
    fi

    # Check if already claimed
    CLAIMED=$($BATHRON_CLI checkburnclaim "$TXID" 2>/dev/null | jq -r '.exists // false' 2>/dev/null)
    if [ "$CLAIMED" = "true" ]; then
        echo "    [SKIP] Already claimed"
        BURNS_SKIPPED=$((BURNS_SKIPPED + 1))
        return 0
    fi

    # Get merkle proof
    MERKLEBLOCK=$($BTC_CMD gettxoutproof "[\"$TXID\"]" 2>/dev/null)
    if [ -z "$MERKLEBLOCK" ]; then
        echo "    [ERROR] No merkle proof (not confirmed?)"
        return 1
    fi

    # Submit to BATHRON
    RESULT=$($BATHRON_CLI submitburnclaimproof "$RAW_TX" "$MERKLEBLOCK" 2>&1)
    if echo "$RESULT" | grep -q '"txid"'; then
        BATHRON_TXID=$(echo "$RESULT" | jq -r '.txid')
        echo "    [OK] Submitted: ${BATHRON_TXID:0:16}..."
        BURNS_SUBMITTED=$((BURNS_SUBMITTED + 1))
        return 0
    else
        if echo "$RESULT" | grep -qi "duplicate\|already\|exists"; then
            echo "    [SKIP] Already in mempool/claimed"
            BURNS_SKIPPED=$((BURNS_SKIPPED + 1))
            return 0
        else
            echo "    [ERROR] $RESULT"
            BURNS_FAILED=$((BURNS_FAILED + 1))
            return 1
        fi
    fi
}

# ============================================================================
# METHOD 1: Use genesis_burns.json if available (FAST)
# ============================================================================
if [ -f "$GENESIS_BURNS_FILE" ]; then
    echo ""
    echo "═══ Using genesis_burns.json (data file, not hardcoded) ═══"

    TXIDS=$(jq -r '.burns[].btc_txid' "$GENESIS_BURNS_FILE" 2>/dev/null)
    TOTAL=$(echo "$TXIDS" | wc -l)
    echo "Found $TOTAL burns in data file"
    echo ""

    for TXID in $TXIDS; do
        [ -z "$TXID" ] && continue
        BURNS_FOUND=$((BURNS_FOUND + 1))
        echo "  [$BURNS_FOUND/$TOTAL] $TXID"
        submit_burn "$TXID"
    done

# ============================================================================
# METHOD 2: Dynamic scan (SLOW FALLBACK)
# ============================================================================
else
    echo ""
    echo "═══ Dynamic scan (no genesis_burns.json found) ═══"
    echo "[WARN] This will be SLOW - scanning BTC Signet for BATHRON burns"

    SCAN_START="${SCAN_START:-286300}"
    K_CONFIRMATIONS=6
    SCAN_END=$((BTC_TIP - K_CONFIRMATIONS))

    echo "Scanning blocks $SCAN_START to $SCAN_END..."
    echo ""

    for HEIGHT in $(seq $SCAN_START $SCAN_END); do
        # Progress every 500 blocks
        if [ $((HEIGHT % 500)) -eq 0 ]; then
            echo "  Scanning height $HEIGHT... (found $BURNS_FOUND burns so far)"
        fi

        BLOCK_HASH=$($BTC_CMD getblockhash "$HEIGHT" 2>/dev/null)
        [ -z "$BLOCK_HASH" ] && continue

        # Get all TXIDs with OP_RETURN
        TXIDS=$($BTC_CMD getblock "$BLOCK_HASH" 2 2>/dev/null | jq -r '.tx[] | select(.vout[]?.scriptPubKey.asm | startswith("OP_RETURN")) | .txid' 2>/dev/null)

        for TXID in $TXIDS; do
            [ -z "$TXID" ] && continue

            # Get raw TX and check for BATHRON magic
            RAW_TX=$($BTC_CMD getrawtransaction "$TXID" 2>/dev/null)
            [ -z "$RAW_TX" ] && continue

            # Check if contains BATHRON magic
            if echo "$RAW_TX" | grep -qi "6a.*$BATHRON_MAGIC"; then
                BURNS_FOUND=$((BURNS_FOUND + 1))
                echo "  [BURN] Found: $TXID (height $HEIGHT)"
                submit_burn "$TXID"
            fi
        done
    done
fi

echo ""
echo "════════════════════════════════════════════════════════════════"
echo "  Burn Claiming Complete"
echo "════════════════════════════════════════════════════════════════"
echo "Burns found: $BURNS_FOUND"
echo "Submitted: $BURNS_SUBMITTED"
echo "Skipped: $BURNS_SKIPPED"
echo "Failed: $BURNS_FAILED"
echo ""
