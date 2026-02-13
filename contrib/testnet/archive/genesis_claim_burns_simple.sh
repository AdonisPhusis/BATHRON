#!/bin/bash
# ==============================================================================
# DEPRECATED: genesis_claim_burns_simple.sh
# Burns are now auto-discovered from BTC Signet by genesis_bootstrap_seed.sh.
# This script is no longer needed for genesis. Kept for reference only.
# ==============================================================================
# genesis_claim_burns_simple.sh - Submit ALL burn claims from proofs file
# ==============================================================================
#
# Reads burn_proofs.json (collected by collect_burn_proofs.sh) and submits
# each burn claim to BATHRON via submitburnclaimproof.
#
# The proofs file contains raw_tx + merkleblock for each burn.
# No BTC Signet needed on this machine - proofs are self-contained.
#
# Called by genesis_bootstrap_seed.sh during genesis.
# ==============================================================================

set +e

BATHRON_CLI="${BATHRON_CMD:-/home/ubuntu/bathron-cli -datadir=/tmp/bathron_bootstrap -testnet}"
PROOFS_FILE="${PROOFS_FILE:-$HOME/burn_proofs.json}"

# --- Pre-checks ---

if [ ! -f "$PROOFS_FILE" ]; then
    echo "[FATAL] Burn proofs file not found: $PROOFS_FILE"
    echo "  Run collect_burn_proofs.sh first to collect proofs from a synced BTC Signet."
    exit 1
fi

BURN_COUNT=$(jq '.burns | length' "$PROOFS_FILE" 2>/dev/null)
SCAN_END=$(jq '.scan_end' "$PROOFS_FILE" 2>/dev/null)
BTC_TIP=$(jq '.btc_tip' "$PROOFS_FILE" 2>/dev/null)

if [ -z "$BURN_COUNT" ] || [ "$BURN_COUNT" -eq 0 ]; then
    echo "[FATAL] Proofs file empty or invalid: $PROOFS_FILE"
    exit 1
fi

echo "════════════════════════════════════════════════════"
echo "  Genesis Burn Claims"
echo "════════════════════════════════════════════════════"
echo "Proofs file: $PROOFS_FILE"
echo "Burns:       $BURN_COUNT"
echo "BTC tip:     $BTC_TIP"
echo "Scan end:    $SCAN_END"
echo ""

# --- Submit each claim ---

SUBMITTED=0
SKIPPED=0
FAILED=0

for i in $(seq 0 $((BURN_COUNT - 1))); do
    TXID=$(jq -r ".burns[$i].txid" "$PROOFS_FILE")
    HEIGHT=$(jq -r ".burns[$i].height" "$PROOFS_FILE")
    RAW_TX=$(jq -r ".burns[$i].raw_tx" "$PROOFS_FILE")
    MERKLE=$(jq -r ".burns[$i].merkleblock" "$PROOFS_FILE")

    echo "  [$((i+1))/$BURN_COUNT] $TXID  height=$HEIGHT"

    # Already claimed?
    CLAIMED=$($BATHRON_CLI checkburnclaim "$TXID" 2>/dev/null | jq -r '.exists // false' 2>/dev/null)
    if [ "$CLAIMED" = "true" ]; then
        echo "    skip (already claimed)"
        SKIPPED=$((SKIPPED + 1))
        continue
    fi

    RESULT=$($BATHRON_CLI submitburnclaimproof "$RAW_TX" "$MERKLE" 2>&1)
    if echo "$RESULT" | grep -q '"txid"'; then
        BATHRON_TXID=$(echo "$RESULT" | jq -r '.txid')
        echo "    OK → ${BATHRON_TXID:0:16}..."
        SUBMITTED=$((SUBMITTED + 1))
    elif echo "$RESULT" | grep -qi "duplicate\|already\|exists"; then
        echo "    skip (duplicate)"
        SKIPPED=$((SKIPPED + 1))
    else
        echo "    FAILED: $RESULT"
        FAILED=$((FAILED + 1))
    fi
done

echo ""
echo "════════════════════════════════════════════════════"
echo "  Done: $BURN_COUNT burns, $SUBMITTED submitted"
echo "  Skipped: $SKIPPED  Failed: $FAILED"
echo "  Scan end: $SCAN_END (BTC tip: $BTC_TIP)"
echo "════════════════════════════════════════════════════"

# Set scan progress so burn daemon starts from here
# Use SPV hash from BATHRON btcheadersdb (not BTC Signet)
SCAN_HASH=$($BATHRON_CLI getbtcheader "$SCAN_END" 2>/dev/null | jq -r '.hash // empty')
if [ -n "$SCAN_HASH" ]; then
    $BATHRON_CLI setburnscanprogress "$SCAN_END" "$SCAN_HASH" 2>/dev/null || true
    echo "$SCAN_END" > /tmp/btc_burn_claim_daemon.state 2>/dev/null || true
    echo "Burn daemon will start from BTC height $SCAN_END"
else
    echo "[WARN] Cannot get SPV hash for height $SCAN_END"
    echo "$SCAN_END" > /tmp/btc_burn_claim_daemon.state 2>/dev/null || true
fi

# Export for genesis_bootstrap_seed.sh
export GENESIS_BTC_HEIGHT="$SCAN_END"
