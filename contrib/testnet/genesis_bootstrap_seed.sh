#!/bin/bash
# genesis_bootstrap_seed.sh - Run directly on Seed node
# Creates genesis bootstrap blocks with DAEMON-ONLY burn detection
#
# TRUE DAEMON-ONLY FLOW (no genesis_burns*.json):
# 1. Block 1: TX_BTC_HEADERS only
# 2. btc_burn_claim_daemon scans BTC Signet LIVE for all burns with 6+ confs
# 3. submitburnclaim for each detected burn
# 4. K blocks later, TX_MINT_M0BTC finalizes
# 5. MNs registered with minted funds
#
# Requirements:
# - Bitcoin Core running on Signet with txindex=1
# - btc_burn_claim_daemon.sh in ~/
# - btcspv backup for TX_BTC_HEADERS

# Robust error handling - don't exit on non-critical errors
# Use explicit error checking for critical operations
set +e

# Fatal error handler
fatal() {
    echo "[FATAL] $1"
    echo "[FATAL] Check logs: $TESTNET_DIR/debug.log"
    # Cleanup daemon before exit
    $CLI stop 2>/dev/null || true
    pkill -9 -u ubuntu bathrond 2>/dev/null || true
    exit 1
}

# Cleanup on exit (normal or error)
cleanup_on_exit() {
    echo ""
    echo "[CLEANUP] Stopping any running daemon..."
    $CLI stop 2>/dev/null || true
    sleep 2
    pkill -9 -u ubuntu -f "bathrond.*bathron_bootstrap" 2>/dev/null || true
}
trap cleanup_on_exit EXIT

# Validate numeric value
is_numeric() {
    [[ "$1" =~ ^[0-9]+$ ]]
}

DATADIR=/tmp/bathron_bootstrap
TESTNET_DIR=$DATADIR/testnet5
CLI="/home/ubuntu/bathron-cli -datadir=$DATADIR -testnet"
DAEMON="/home/ubuntu/bathrond -datadir=$DATADIR -testnet"
K_FINALITY=20
BTC_CHECKPOINT=286300  # First burn at 286326 - start scan just before

echo "════════════════════════════════════════════════════════════════"
echo "  Genesis Bootstrap - DAEMON-ONLY Flow"
echo "════════════════════════════════════════════════════════════════"
echo "Datadir: $DATADIR"
echo "K_FINALITY: $K_FINALITY"
echo "BTC Checkpoint: $BTC_CHECKPOINT"
echo ""

# Ensure latest binary
if [ -x /home/ubuntu/BATHRON-Core/src/bathrond ]; then
    cp -f /home/ubuntu/BATHRON-Core/src/bathrond /home/ubuntu/bathrond
    cp -f /home/ubuntu/BATHRON-Core/src/bathron-cli /home/ubuntu/bathron-cli
    echo "[OK] Binary updated from BATHRON-Core"
fi

# Kill any existing
pkill -9 bathrond 2>/dev/null || true
sleep 2

# Wipe and setup
rm -rf $DATADIR
mkdir -p $TESTNET_DIR

# Restore btcspv (needed for Block 1 TX_BTC_HEADERS)
if [ -f /home/ubuntu/btcspv_backup_latest.tar.gz ]; then
    cd $TESTNET_DIR && tar xzf /home/ubuntu/btcspv_backup_latest.tar.gz
    echo "[OK] btcspv restored"
else
    fatal "No btcspv backup found at /home/ubuntu/btcspv_backup_latest.tar.gz"
fi

# Config
cat > $DATADIR/bathron.conf << EOF
testnet=1
server=1
rpcuser=testuser
rpcpassword=testpass123
listen=0
txindex=1
EOF

# Start daemon
echo ""
echo "Starting daemon..."
$DAEMON -daemon -noconnect -listen=0
sleep 15

# ═══════════════════════════════════════════════════════════════════════════
# Block 1: TX_BTC_HEADERS only (NO burns at this stage)
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "═══ Block 1: TX_BTC_HEADERS ═══"
BLOCK1=$($CLI generatebootstrap 1 2>/dev/null | jq -r ".[0]")
echo "Block 1: $BLOCK1"
H1=$($CLI getblockcount)
echo "Height: $H1"

# Verify BTC headers in Block 1
HEADER_COUNT=$($CLI getblock "$BLOCK1" 2 2>/dev/null | jq "[.tx[] | select(.type == 33)] | length" 2>/dev/null)
echo "TX_BTC_HEADERS: $HEADER_COUNT"

# Validate HEADER_COUNT is numeric and > 0
if ! is_numeric "$HEADER_COUNT"; then
    fatal "Failed to count BTC headers (jq parse error or daemon not responding)"
fi
if [ "$HEADER_COUNT" -eq 0 ]; then
    fatal "No BTC headers in Block 1 - btcspv may be corrupted or empty"
fi

# Verify NO TX_BURN_CLAIM at Block 1 (daemon-only flow)
CLAIM_COUNT=$($CLI getblock "$BLOCK1" 2 2>/dev/null | jq "[.tx[] | select(.type == 31)] | length" 2>/dev/null || echo "0")
if [ "$CLAIM_COUNT" != "0" ]; then
    echo "[WARN] Block 1 has $CLAIM_COUNT TX_BURN_CLAIM - expected 0 for daemon-only flow"
fi

# Import burn destination keys (if available)
if [ -f /tmp/burn_dest_keys.json ]; then
    IMPORTED=0
    for ADDR in $(jq -r "keys[]" /tmp/burn_dest_keys.json 2>/dev/null); do
        WIF=$(jq -r ".\"$ADDR\"" /tmp/burn_dest_keys.json)
        if [ -n "$WIF" ] && [ "$WIF" != "null" ]; then
            $CLI importprivkey "$WIF" "burn_$ADDR" false 2>/dev/null || true
            IMPORTED=$((IMPORTED + 1))
        fi
    done
    echo "[OK] Imported $IMPORTED burn destination keys"
fi

# ═══════════════════════════════════════════════════════════════════════════
# Detect and submit burns via btc_burn_claim_daemon (LIVE scan)
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "═══ Burn Detection (SIMPLIFIED for genesis) ═══"

# Check if BTC Signet is available
BTC_CLI="${BTC_CLI:-$HOME/bitcoin-27.0/bin/bitcoin-cli}"
BTC_DATADIR="${BTC_DATADIR:-$HOME/.bitcoin-signet}"
BTC_CMD="$BTC_CLI -datadir=$BTC_DATADIR"

if $BTC_CMD getblockcount >/dev/null 2>&1; then
    BTC_TIP=$($BTC_CMD getblockcount)
    echo "BTC Signet tip: $BTC_TIP"

    # Use simple burn claim script (no progress spam)
    export BATHRON_CMD="$CLI"
    export BTC_CLI="$BTC_CLI"
    export BTC_DATADIR="$BTC_DATADIR"
    # Run burn claimer - show ALL output (no grep filter)
    ~/genesis_claim_burns_simple.sh 2>&1

    # Wait for claims to reach mempool
    echo "Waiting 5s for claims..."
    sleep 5

    # Check daemon is still alive
    if ! $CLI getblockcount >/dev/null 2>&1; then
        tail -30 $TESTNET_DIR/debug.log 2>/dev/null || true
        fatal "Daemon died during burn claiming"
    fi

    # Mine claims block (wait for time slot to avoid time-too-new)
    echo "Mining claims block (waiting 16s for time slot)..."
    sleep 16
    CLAIM_BLOCK=$($CLI generatebootstrap 1 2>/dev/null | jq -r ".[0]")
    echo "Claims block: ${CLAIM_BLOCK:0:16}..."

    # Check results
    PENDING=$($CLI listburnclaims pending 100 2>/dev/null | jq length 2>/dev/null || echo "0")
    FINAL=$($CLI listburnclaims final 100 2>/dev/null | jq length 2>/dev/null || echo "0")
    echo "PENDING: $PENDING, FINAL: $FINAL"
else
    echo "[WARN] BTC Signet not available"
    PENDING=0
    FINAL=0
fi
# Wait for timestamp
echo "Waiting 5s..."
sleep 5

# ═══════════════════════════════════════════════════════════════════════════
# Generate K_FINALITY blocks
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "═══ Generating $K_FINALITY blocks ═══"
for i in $(seq 1 $K_FINALITY); do
    # CRITICAL: Block spacing requires at least one time slot (15s) between blocks
    # (time-too-new consensus rule). Using 16s for safety margin.
    sleep 16

    # Check daemon is still alive
    if ! $CLI getblockcount >/dev/null 2>&1; then
        tail -30 $TESTNET_DIR/debug.log 2>/dev/null || true
        fatal "Daemon died at K-block iteration $i"
    fi

    BLOCK_RESULT=$($CLI generatebootstrap 1 2>&1)
    if echo "$BLOCK_RESULT" | grep -qE "error|Error"; then
        tail -30 $TESTNET_DIR/debug.log 2>/dev/null || true
        fatal "Block generation error at iteration $i: $BLOCK_RESULT"
    fi

    BLOCK=$(echo "$BLOCK_RESULT" | jq -r ".[0]" 2>/dev/null || echo "")
    HEIGHT=$($CLI getblockcount 2>/dev/null || echo "?")

    if [ -z "$BLOCK" ] || [ "$BLOCK" = "null" ]; then
        tail -30 $TESTNET_DIR/debug.log 2>/dev/null || true
        fatal "Block generation failed at iteration $i (result: $BLOCK_RESULT)"
    fi

    if [ $((i % 5)) -eq 0 ] || [ $i -eq 1 ]; then
        echo "  Block $((i+1)) (h=$HEIGHT): ${BLOCK:0:16}..."
    fi
done

FINAL_H=$($CLI getblockcount)
echo "Height after K blocks: $FINAL_H"

# ═══════════════════════════════════════════════════════════════════════════
# Block K+2: Mints (always try, CreateMintM0BTC handles eligibility)
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "═══ Block $((FINAL_H + 1)): Mints ═══"

# Debug: show all claims before mint attempt
echo "Claims before mint:"
$CLI listburnclaims all 50 2>/dev/null | jq -c ".[] | {txid: .btc_txid[:16], status, h: .claim_height}" 2>/dev/null | head -10

echo "Waiting 16s for time slot..."
sleep 16
MINT_BLOCK=$($CLI generatebootstrap 1 2>/dev/null | jq -r ".[0]")
echo "Mint block: $MINT_BLOCK"

MINT_TXID=$($CLI getblock "$MINT_BLOCK" 2 2>/dev/null | jq -r ".tx[] | select(.type == 32) | .txid" | head -1)
echo "Mint TXID: ${MINT_TXID:-NONE}"

# Check debug log for mint info
grep -i "CreateMintM0BTC\|eligible\|pending" $TESTNET_DIR/debug.log 2>/dev/null | tail -5

PENDING=$($CLI listburnclaims pending 100 2>/dev/null | jq length 2>/dev/null || echo "0")
FINAL=$($CLI listburnclaims final 100 2>/dev/null | jq length 2>/dev/null || echo "0")
echo "After mint: PENDING=$PENDING, FINAL=$FINAL"

if [ "$FINAL" -eq 0 ] && [ "$PENDING" -gt 0 ]; then
    echo "[WARN] No mints yet, generating one more block..."
    MINT_BLOCK2=$($CLI generatebootstrap 1 2>/dev/null | jq -r ".[0]")
    FINAL=$($CLI listburnclaims final 100 2>/dev/null | jq length 2>/dev/null || echo "0")
    echo "After extra block: FINAL=$FINAL"
fi

if [ "$FINAL" -eq 0 ]; then
    echo "[ERROR] No burns finalized - cannot register MNs!"
    echo "Burns status:"
    $CLI listburnclaims all 10 2>/dev/null | jq -c ".[] | {txid: .btc_txid[:16], status, h: .claim_height}"
    echo "Debug log (last 30 lines with mint/claim/burn):"
    tail -30 $TESTNET_DIR/debug.log | grep -iE "mint|claim|burn|pending"
    fatal "Zero burns finalized - cannot create genesis MNs"
fi

if [ "$FINAL" -gt 0 ]; then
    echo "FINAL burns: $FINAL"

    # Find MN-eligible collaterals (1M sats = MN collateral)
    # NOTE: BATHRON getrawtransaction returns values in SATOSHIS, not BTC!
    echo ""
    echo "═══ Finding MN Collaterals ═══"
    MINT_TX_JSON=$($CLI getrawtransaction "$MINT_TXID" true 2>/dev/null)
    MN_COLLATERALS=""
    MN_COUNT=0
    # Filter: 900000 sats <= value <= 1100000 sats (MN collateral with margin)
    for VOUT in $(echo "$MINT_TX_JSON" | jq -r '.vout[] | select(.value >= 900000 and .value <= 1100000) | .n' 2>/dev/null); do
        MN_COUNT=$((MN_COUNT + 1))
        MN_COLLATERALS="$MN_COLLATERALS $MINT_TXID:$VOUT"
    done
    echo "MN-eligible collaterals: $MN_COUNT"
    # Debug: show all vouts
    echo "All mint outputs:"
    echo "$MINT_TX_JSON" | jq -r '.vout[] | "  vout \(.n): \(.value) sats"' 2>/dev/null | head -10

    $CLI rescanwallet 2>/dev/null || true
else
    MN_COUNT=0
    MN_COLLATERALS=""
    echo ""
    echo "[SKIP] No mints (no pending claims)"
fi

# ═══════════════════════════════════════════════════════════════════════════
# Fee UTXOs and MN registration
# ═══════════════════════════════════════════════════════════════════════════
if [ "$MN_COUNT" -gt 0 ]; then
    echo ""
    echo "═══ Fee UTXOs ═══"

    # Generate operator key
    KEYPAIR=$($CLI generateoperatorkeypair 2>/dev/null)
    OP_WIF=$(echo "$KEYPAIR" | jq -r ".secret")
    OP_PUB=$(echo "$KEYPAIR" | jq -r ".public")
    echo "Operator key generated"

    # Lock collaterals
    LOCK_JSON="["
    SENDMANY="{"
    i=0
    for COLLATERAL in $MN_COLLATERALS; do
        TXID="${COLLATERAL%%:*}"
        VOUT="${COLLATERAL##*:}"
        [ $i -gt 0 ] && LOCK_JSON+="," && SENDMANY+=","
        LOCK_JSON+="{\"txid\":\"$TXID\",\"vout\":$VOUT}"
        FEE_ADDR=$($CLI getnewaddress "mn${i}_fee" 2>/dev/null)
        SENDMANY+="\"$FEE_ADDR\":10000"
        i=$((i + 1))
    done
    LOCK_JSON+="]"
    SENDMANY+="}"

    $CLI lockunspent false true "$LOCK_JSON" 2>/dev/null || true
    SENDMANY_RESULT=$($CLI sendmany "" "$SENDMANY" 2>&1) || true
    if echo "$SENDMANY_RESULT" | grep -qE "error|Error"; then
        echo "  sendmany failed (may have UTXOs already)"
    else
        echo "  Fee TX: ${SENDMANY_RESULT:0:16}..."
        sleep 16
        FEE_BLOCK=$($CLI generatebootstrap 1 2>/dev/null | jq -r ".[0]")
        echo "  Fee block: ${FEE_BLOCK:0:16}..."
    fi

    # ProReg MNs
    echo ""
    echo "═══ ProReg MNs ═══"
    MN_REG_OK=0
    MN_REG_FAIL=0
    for COLLATERAL in $MN_COLLATERALS; do
        TXID="${COLLATERAL%%:*}"
        VOUT="${COLLATERAL##*:}"
        OWNER=$($CLI getnewaddress "owner" 2>/dev/null)
        VOTING=$($CLI getnewaddress "voting" 2>/dev/null)
        PAYOUT=$($CLI getnewaddress "payout" 2>/dev/null)

        REG_RESULT=$($CLI protx_register "$TXID" "$VOUT" "57.131.33.151:27171" "$OWNER" "$OP_PUB" "$VOTING" "$PAYOUT" 2>&1) || true
        if echo "$REG_RESULT" | grep -qE "error|Error"; then
            echo "  FAIL $TXID:$VOUT"
            MN_REG_FAIL=$((MN_REG_FAIL + 1))
        else
            echo "  OK: ${REG_RESULT:0:16}..."
            MN_REG_OK=$((MN_REG_OK + 1))
        fi
    done
    echo "ProReg: $MN_REG_OK OK, $MN_REG_FAIL failed"

    # Mine ProReg TXs
    if [ "$MN_REG_OK" -gt 0 ]; then
        sleep 16
        PROREG_BLOCK=$($CLI generatebootstrap 1 2>/dev/null | jq -r ".[0]")
        echo "ProReg block: ${PROREG_BLOCK:0:16}..."
    fi

    MN_REGISTERED=$($CLI protx_list 2>/dev/null | jq "length" 2>/dev/null || echo "0")
    echo "MNs registered: $MN_REGISTERED"

    # Validate minimum quorum (testnet needs at least 3 MNs)
    MIN_QUORUM=3
    if ! is_numeric "$MN_REGISTERED" || [ "$MN_REGISTERED" -lt $MIN_QUORUM ]; then
        echo "[WARN] Only $MN_REGISTERED MNs registered (need $MIN_QUORUM for quorum)"
        echo "[WARN] Network may not produce blocks without quorum!"
    fi

    # Save operator key
    mkdir -p ~/.pivkey
    cat > ~/.pivkey/operator_keys.json << KEYEOF
{"operator":{"wif":"$OP_WIF","pubkey":"$OP_PUB","mn_count":$MN_COUNT}}
KEYEOF
    echo "Operator key saved"
else
    MN_REGISTERED=0
fi

# ═══════════════════════════════════════════════════════════════════════════
# Summary
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "════════════════════════════════════════════════════════════════"
echo "  GENESIS BOOTSTRAP COMPLETE"
echo "════════════════════════════════════════════════════════════════"
echo "Height: $($CLI getblockcount)"
echo "BTC Headers: $HEADER_COUNT"
echo "FINAL burns: $($CLI listburnclaims final 100 2>/dev/null | jq length 2>/dev/null || echo "0")"
echo "MNs: $MN_REGISTERED registered"
echo ""
echo "Flow: DAEMON-ONLY (no genesis_burns*.json)"
echo "════════════════════════════════════════════════════════════════"

# Stop daemon
$CLI stop 2>/dev/null || true
echo "Daemon stopped"
