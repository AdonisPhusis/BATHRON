#!/bin/bash
# genesis_bootstrap_seed.sh - Run directly on Seed node
# Creates genesis bootstrap blocks with LIVE burn auto-discovery
#
# CLEAN FLOW (zero hardcoded data, zero pre-collected files):
# 1. Block 1: TX_BTC_HEADERS from btcspv backup
# 2. Header catch-up: generatebootstrap until btcheadersdb covers BTC Signet safe height
# 3. Burn discovery: scan BTC Signet blocks for BATHRON burns (same logic as btc_burn_claim_daemon.sh)
# 4. Submit burn claims via submitburnclaimproof
# 5. K=20 blocks for finality → TX_MINT_M0BTC
# 6. MNs registered with minted funds
#
# Requirements:
# - Bitcoin Core running on Signet with txindex=1 (on this Seed node)
# - btcspv backup for TX_BTC_HEADERS

# Strict mode: fail on undefined vars and pipe errors.
# Individual commands that may fail use explicit || guards.
set -uo pipefail

# ── Constants (derived from consensus — src/btcspv/btcspv.cpp, src/chainparams.cpp) ──
BTC_CHECKPOINT=286000             # Must match BTCHEADERS_GENESIS_CHECKPOINT in btcheaders.h
K_FINALITY=20                     # Blocks before TX_MINT_M0BTC
K_BTC_CONFS=6                     # Required BTC confirmations (Signet)
MN_COLLATERAL_SATS=1000000        # Must match consensus.nMNCollateralAmt in chainparams.cpp
MN_COLLATERAL_MARGIN_PCT=0        # Exact match (consensus requires exact collateral)
SEED_IP="57.131.33.151"
SEED_PORT=27171
BATHRON_MAGIC="42415448524f4e"    # "BATHRON" in hex

# ── Paths (use $HOME, never /home/ubuntu) ──
DATADIR=/tmp/bathron_bootstrap
TESTNET_DIR=$DATADIR/testnet5
CLI="$HOME/bathron-cli -datadir=$DATADIR -testnet"
DAEMON="$HOME/bathrond -datadir=$DATADIR -testnet"

# BTC Signet CLI — auto-detect bitcoin-cli location
if [ -n "${BTC_CLI:-}" ]; then
    : # user override
elif [ -x "$HOME/bitcoin/bin/bitcoin-cli" ]; then
    BTC_CLI="$HOME/bitcoin/bin/bitcoin-cli"
else
    # Find any bitcoin-cli under $HOME
    BTC_CLI=$(find "$HOME" -maxdepth 3 -name bitcoin-cli -type f -executable 2>/dev/null | head -1)
    if [ -z "$BTC_CLI" ]; then
        echo "[FATAL] bitcoin-cli not found under $HOME"; exit 1
    fi
fi
BTC_CONF="${BTC_CONF:-$HOME/.bitcoin-signet/bitcoin.conf}"
BTC_CMD="$BTC_CLI -conf=$BTC_CONF"

# ── Derived values ──
MN_COLLATERAL_MIN=$(( MN_COLLATERAL_SATS * (100 - MN_COLLATERAL_MARGIN_PCT) / 100 ))
MN_COLLATERAL_MAX=$(( MN_COLLATERAL_SATS * (100 + MN_COLLATERAL_MARGIN_PCT) / 100 ))

# ── Error handling ──
fatal() {
    echo "[FATAL] $1"
    echo "[FATAL] Check logs: $TESTNET_DIR/debug.log"
    $CLI stop 2>/dev/null || true
    pkill -9 -u "$(whoami)" bathrond 2>/dev/null || true
    exit 1
}

cleanup_on_exit() {
    echo ""
    echo "[CLEANUP] Stopping any running daemon..."
    $CLI stop 2>/dev/null || true
    sleep 2
    pkill -9 -u "$(whoami)" -f "bathrond.*bathron_bootstrap" 2>/dev/null || true
}
trap cleanup_on_exit EXIT

is_numeric() {
    [[ "$1" =~ ^[0-9]+$ ]]
}

# ═══════════════════════════════════════════════════════════════════════════
# Burn scan functions (inlined from btc_burn_claim_daemon.sh)
# ═══════════════════════════════════════════════════════════════════════════

# Find BATHRON burns in a BTC Signet block
# Outputs one btc_txid per line for each burn found
find_burns_in_block() {
    local height="$1"
    local block_hash=$($BTC_CMD getblockhash "$height" 2>/dev/null) || return
    local block_json=$($BTC_CMD getblock "$block_hash" 2 2>/dev/null) || return

    echo "$block_json" | jq -r '.tx[] | select(.vout[]?.scriptPubKey.asm | startswith("OP_RETURN")) | .txid' 2>/dev/null | while read txid; do
        if [ -n "$txid" ]; then
            local raw_tx=$($BTC_CMD getrawtransaction "$txid" 2>/dev/null) || continue
            # Check for BATHRON magic: 6a = OP_RETURN, 1d = push 29 bytes, then "BATHRON"
            if echo "$raw_tx" | grep -qi "6a1d${BATHRON_MAGIC}"; then
                echo "$txid"
            fi
        fi
    done
}

# Submit a burn claim to BATHRON
submit_claim() {
    local btc_txid="$1"
    local height="$2"

    local raw_tx=$($BTC_CMD getrawtransaction "$btc_txid" 2>/dev/null)
    if [ -z "$raw_tx" ]; then
        echo "    [ERROR] Failed to get raw TX for $btc_txid"
        return 1
    fi

    local merkleblock=$($BTC_CMD gettxoutproof "[\"$btc_txid\"]" 2>/dev/null)
    if [ -z "$merkleblock" ]; then
        echo "    [ERROR] Failed to get merkle proof for $btc_txid"
        return 1
    fi

    local result=$($CLI submitburnclaimproof "$raw_tx" "$merkleblock" 2>&1)
    if echo "$result" | grep -q '"txid"'; then
        local bathron_txid=$(echo "$result" | jq -r '.txid')
        echo "    OK -> ${bathron_txid:0:16}..."
        return 0
    elif echo "$result" | grep -qi "duplicate\|already\|exists"; then
        echo "    skip (already claimed)"
        return 0
    else
        echo "    FAILED: $result"
        return 1
    fi
}

# Check if a burn is already claimed on BATHRON
is_already_claimed() {
    local btc_txid="$1"
    local result=$($CLI checkburnclaim "$btc_txid" 2>/dev/null || echo "")
    if echo "$result" | jq -e '.exists == true' >/dev/null 2>&1; then
        return 0  # Already claimed
    fi
    return 1  # Not claimed
}

echo "════════════════════════════════════════════════════════════════"
echo "  Genesis Bootstrap - Clean Auto-Discovery Flow"
echo "════════════════════════════════════════════════════════════════"
echo "Datadir: $DATADIR"
echo "K_FINALITY: $K_FINALITY"
echo "K_BTC_CONFS: $K_BTC_CONFS"
echo "BTC Checkpoint: $BTC_CHECKPOINT"
echo "BTC Signet CLI: $BTC_CMD"
echo ""

# Ensure latest binary
if [ -x "$HOME/BATHRON-Core/src/bathrond" ]; then
    cp -f "$HOME/BATHRON-Core/src/bathrond" "$HOME/bathrond"
    cp -f "$HOME/BATHRON-Core/src/bathron-cli" "$HOME/bathron-cli"
    echo "[OK] Binary updated from BATHRON-Core"
fi

# Kill ALL existing bathrond (any datadir)
echo "Stopping any running bathrond..."
pkill -9 bathrond 2>/dev/null || true
sleep 3
# Double check — if still alive, something is restarting it
if pgrep -u ubuntu bathrond >/dev/null 2>&1; then
    echo "[WARN] bathrond still alive after SIGKILL, waiting..."
    sleep 5
    pkill -9 -f bathrond 2>/dev/null || true
    sleep 2
fi
if pgrep -u ubuntu bathrond >/dev/null 2>&1; then
    fatal "Cannot kill existing bathrond — check systemd or other process managers"
fi
echo "[OK] No bathrond running"

# Wipe and setup
rm -rf $DATADIR
mkdir -p $TESTNET_DIR

# Restore btcspv (needed for Block 1 TX_BTC_HEADERS)
if [ -f "$HOME/btcspv_backup_latest.tar.gz" ]; then
    cd $TESTNET_DIR && tar xzf "$HOME/btcspv_backup_latest.tar.gz"
    # Verify btcspv has actual data (LevelDB uses WAL .log files + .ldb files)
    SPV_SIZE=$(du -sb $TESTNET_DIR/btcspv 2>/dev/null | cut -f1)
    SPV_HAS_CURRENT=$(test -f $TESTNET_DIR/btcspv/CURRENT && echo "yes" || echo "no")
    echo "[OK] btcspv restored (${SPV_SIZE} bytes, CURRENT=$SPV_HAS_CURRENT)"
    if [ "$SPV_HAS_CURRENT" != "yes" ] || [ "${SPV_SIZE:-0}" -lt 10000 ]; then
        fatal "btcspv backup is empty or corrupt (size=${SPV_SIZE}, CURRENT=$SPV_HAS_CURRENT)"
    fi
else
    fatal "No btcspv backup found at $HOME/btcspv_backup_latest.tar.gz"
fi

# Config
# Generate random RPC credentials for this ephemeral bootstrap daemon
RPC_USER="bootstrap_$(head -c 4 /dev/urandom | xxd -p)"
RPC_PASS="$(head -c 16 /dev/urandom | xxd -p)"
cat > $DATADIR/bathron.conf << EOF
testnet=1
server=1
rpcuser=$RPC_USER
rpcpassword=$RPC_PASS
listen=0
txindex=1
EOF

# Start daemon
echo ""
echo "Starting daemon..."
$DAEMON -daemon -noconnect -listen=0
sleep 5

# Health check: wait for daemon to be responsive (max 30s)
DAEMON_OK=false
for i in $(seq 1 25); do
    if $CLI getblockcount >/dev/null 2>&1; then
        DAEMON_OK=true
        break
    fi
    sleep 1
done

if ! $DAEMON_OK; then
    echo "[DIAG] ps check:"
    ps aux | grep bathrond | grep -v grep || echo "  No bathrond process found!"
    echo "[DIAG] debug.log tail:"
    tail -20 $TESTNET_DIR/debug.log 2>/dev/null || echo "  No debug.log"
    fatal "Daemon failed to start or not responding after 30s"
fi

# Verify btcspv is loaded
SPV_STATUS=$($CLI getbtcsyncstatus 2>&1 || echo "FAIL")
SPV_TIP=$(echo "$SPV_STATUS" | jq -r '.tip_height // 0' 2>/dev/null || echo "0")
SPV_COUNT=$(echo "$SPV_STATUS" | jq -r '.headers_count // 0' 2>/dev/null || echo "0")
echo "[OK] Daemon running, btcspv loaded: tip=$SPV_TIP, count=$SPV_COUNT"

if [ "$SPV_TIP" -lt 286001 ]; then
    echo "[DIAG] Full SPV status: $SPV_STATUS"
    fatal "btcspv tip ($SPV_TIP) below checkpoint+1 (286001) — backup is corrupt or empty"
fi

# ── Sync missing btcspv headers from BTC Signet (fallback for incomplete backups) ──
BTC_TIP_EARLY=$($BTC_CMD getblockcount 2>/dev/null || echo "-1")
if [ "$BTC_TIP_EARLY" != "-1" ] && [ "$SPV_TIP" -lt "$BTC_TIP_EARLY" ]; then
    SPV_GAP=$((BTC_TIP_EARLY - SPV_TIP))
    echo "  btcspv gap: $SPV_GAP headers behind BTC Signet ($SPV_TIP → $BTC_TIP_EARLY)"
    echo "  Syncing missing headers from BTC Signet..."
    SYNC_CURRENT=$((SPV_TIP + 1))
    SYNC_BATCH=500
    SYNC_DONE=0
    while [ $SYNC_CURRENT -le $BTC_TIP_EARLY ]; do
        SYNC_END=$((SYNC_CURRENT + SYNC_BATCH - 1))
        [ $SYNC_END -gt $BTC_TIP_EARLY ] && SYNC_END=$BTC_TIP_EARLY
        headers_hex=""
        for h in $(seq $SYNC_CURRENT $SYNC_END); do
            hash=$($BTC_CMD getblockhash $h 2>/dev/null) || continue
            header=$($BTC_CMD getblockheader $hash false 2>/dev/null) || continue
            headers_hex="${headers_hex}${header}"
        done
        if [ -n "$headers_hex" ]; then
            $CLI submitbtcheaders "$headers_hex" >/dev/null 2>&1 || true
        fi
        SYNC_DONE=$((SYNC_END - SPV_TIP))
        SYNC_PCT=$((SYNC_DONE * 100 / SPV_GAP))
        echo "    Progress: ${SYNC_PCT}% ($SYNC_DONE/$SPV_GAP)"
        SYNC_CURRENT=$((SYNC_END + 1))
    done
    # Re-check tip
    SPV_TIP=$($CLI getbtcsyncstatus 2>/dev/null | jq -r '.tip_height // 0' 2>/dev/null || echo "0")
    echo "  btcspv tip after sync: $SPV_TIP"
else
    echo "  btcspv tip ($SPV_TIP) is current with BTC Signet"
fi

# ═══════════════════════════════════════════════════════════════════════════
# Block 1: TX_BTC_HEADERS only (NO burns at this stage)
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "═══ Block 1: TX_BTC_HEADERS ═══"
BLOCK1_RESULT=$($CLI generatebootstrap 1 2>&1)
BLOCK1=$(echo "$BLOCK1_RESULT" | jq -r ".[0]" 2>/dev/null)
echo "Block 1: $BLOCK1"
if [ -z "$BLOCK1" ] || [ "$BLOCK1" = "null" ]; then
    echo "[DIAG] generatebootstrap result: $BLOCK1_RESULT"
    tail -30 $TESTNET_DIR/debug.log 2>/dev/null || true
    fatal "generatebootstrap failed for Block 1"
fi

H1=$($CLI getblockcount 2>/dev/null || echo "?")
echo "Height: $H1"

# Verify BTC headers in Block 1
HEADER_COUNT=$($CLI getblock "$BLOCK1" 2 2>/dev/null | jq "[.tx[] | select(.type == 33)] | length" 2>/dev/null)
echo "TX_BTC_HEADERS: $HEADER_COUNT"

# Validate HEADER_COUNT is numeric and > 0
if ! is_numeric "$HEADER_COUNT"; then
    echo "[DIAG] getblock output:"
    $CLI getblock "$BLOCK1" 2 2>/dev/null | jq '.tx[] | {type, txid}' 2>/dev/null || true
    tail -20 $TESTNET_DIR/debug.log 2>/dev/null | grep -i "genesis\|header\|error" || true
    fatal "Failed to count BTC headers (jq parse error or daemon not responding)"
fi
if [ "$HEADER_COUNT" -eq 0 ]; then
    echo "[DIAG] btcspv tip at Block 1 time: $SPV_TIP"
    echo "[DIAG] debug.log genesis entries:"
    grep -i "genesis\|GENESIS" $TESTNET_DIR/debug.log 2>/dev/null | tail -10 || true
    fatal "No BTC headers in Block 1 - btcspv may be corrupted or empty"
fi

# Verify NO TX_BURN_CLAIM at Block 1 (daemon-only flow)
CLAIM_COUNT=$($CLI getblock "$BLOCK1" 2 2>/dev/null | jq "[.tx[] | select(.type == 31)] | length" 2>/dev/null || echo "0")
if [ "$CLAIM_COUNT" != "0" ]; then
    echo "[WARN] Block 1 has $CLAIM_COUNT TX_BURN_CLAIM - expected 0 for daemon-only flow"
fi

# ═══════════════════════════════════════════════════════════════════════════
# Phase 2: Header catch-up (btcheadersdb must cover BTC Signet safe height)
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "═══ Phase 2: Header catch-up ═══"

# Verify BTC Signet is reachable
BTC_TIP=$($BTC_CMD getblockcount 2>/dev/null || echo "-1")
if [ "$BTC_TIP" = "-1" ]; then
    fatal "BTC Signet not reachable. Ensure bitcoind is running on Seed."
fi
SAFE_HEIGHT=$((BTC_TIP - K_BTC_CONFS))
echo "BTC Signet tip: $BTC_TIP (safe height: $SAFE_HEIGHT)"

# Check current btcheadersdb tip
HEADERS_TIP=$($CLI getbtcheaderstip 2>/dev/null | jq -r '.height // 0' 2>/dev/null)
if ! is_numeric "$HEADERS_TIP"; then
    HEADERS_TIP=0
fi
echo "btcheadersdb tip after Block 1: $HEADERS_TIP"

# Generate additional blocks until btcheadersdb covers safe height
# C++ catch-up code (g_fBootstrapGenerating) publishes headers from btcspv → btcheadersdb
EXTRA_BLOCKS=0
DEAD_COUNT=0
while [ "$HEADERS_TIP" -lt "$SAFE_HEIGHT" ]; do
    EXTRA_BLOCKS=$((EXTRA_BLOCKS + 1))
    if [ "$EXTRA_BLOCKS" -gt 500 ]; then
        fatal "Too many catch-up blocks ($EXTRA_BLOCKS). btcspv tip may be below safe height (btcheadersdb=$HEADERS_TIP, need=$SAFE_HEIGHT)."
    fi
    sleep 1

    # Check daemon is alive before generating
    if ! $CLI getblockcount >/dev/null 2>&1; then
        DEAD_COUNT=$((DEAD_COUNT + 1))
        if [ "$DEAD_COUNT" -ge 3 ]; then
            echo "[DIAG] debug.log tail:"
            tail -30 $TESTNET_DIR/debug.log 2>/dev/null || true
            fatal "Daemon died during header catch-up (btcheadersdb tip=$HEADERS_TIP, need=$SAFE_HEIGHT)"
        fi
        echo "  [WARN] Daemon not responding (attempt $DEAD_COUNT/3), waiting..."
        sleep 5
        continue
    fi
    DEAD_COUNT=0

    GEN_RESULT=$($CLI generatebootstrap 1 2>&1)
    if echo "$GEN_RESULT" | grep -qi "error"; then
        echo "  [WARN] generatebootstrap error: $GEN_RESULT"
    fi

    HEADERS_TIP=$($CLI getbtcheaderstip 2>/dev/null | jq -r '.height // 0' 2>/dev/null)
    if ! is_numeric "$HEADERS_TIP"; then
        HEADERS_TIP=0
    fi
    # Show progress every 10 blocks, or first 5
    if [ "$EXTRA_BLOCKS" -le 5 ] || [ $((EXTRA_BLOCKS % 10)) -eq 0 ]; then
        echo "  Catch-up block $EXTRA_BLOCKS: btcheadersdb tip = $HEADERS_TIP"
    fi
done
echo "btcheadersdb tip: $HEADERS_TIP (covers safe height $SAFE_HEIGHT) — $EXTRA_BLOCKS catch-up blocks"

# ═══════════════════════════════════════════════════════════════════════════
# Phase 3: Burn discovery & claiming (auto-scan BTC Signet)
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "═══ Phase 3: Burn discovery (BTC Signet scan) ═══"

# ── Burn scan cache: skip already-scanned BTC blocks ──
BURN_CACHE="$HOME/cached_btc_burns.json"
SCAN_FROM=$((BTC_CHECKPOINT + 1))
CACHED_BURNS=""
if [ -f "$BURN_CACHE" ]; then
    CACHE_TIP=$(jq -r '.last_scanned_height // 0' "$BURN_CACHE" 2>/dev/null || echo "0")
    if is_numeric "$CACHE_TIP" && [ "$CACHE_TIP" -gt "$SCAN_FROM" ]; then
        SCAN_FROM=$((CACHE_TIP + 1))
        CACHED_BURNS=$(jq -r '.burns[]?.txid // empty' "$BURN_CACHE" 2>/dev/null || echo "")
        CACHED_COUNT=$(echo "$CACHED_BURNS" | grep -c . 2>/dev/null || echo "0")
        echo "  Burn cache loaded: $CACHED_COUNT burns, scanned to $CACHE_TIP"
        echo "  Scanning only blocks $SCAN_FROM to $SAFE_HEIGHT (skipped $((CACHE_TIP - BTC_CHECKPOINT)) cached blocks)"
    fi
fi
if [ "$SCAN_FROM" -le "$SAFE_HEIGHT" ]; then
    echo "Scanning BTC blocks $SCAN_FROM to $SAFE_HEIGHT for BATHRON burns..."
else
    echo "All BTC blocks already scanned (cache covers to $CACHE_TIP, need $SAFE_HEIGHT)"
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

BURNS_FOUND=0
BURNS_SUBMITTED=0
BURNS_SKIPPED=0
NEW_BURNS_JSON="["

# Submit cached burns first (from previous scans)
if [ -n "$CACHED_BURNS" ]; then
    while IFS= read -r btc_txid; do
        [ -z "$btc_txid" ] && continue
        BURNS_FOUND=$((BURNS_FOUND + 1))
        CACHE_HEIGHT=$(jq -r ".burns[] | select(.txid==\"$btc_txid\") | .height" "$BURN_CACHE" 2>/dev/null || echo "0")
        echo "  [CACHE] $btc_txid at height $CACHE_HEIGHT"
        if is_already_claimed "$btc_txid"; then
            echo "    skip (already claimed)"
            BURNS_SKIPPED=$((BURNS_SKIPPED + 1))
        elif submit_claim "$btc_txid" "$CACHE_HEIGHT"; then
            BURNS_SUBMITTED=$((BURNS_SUBMITTED + 1))
        fi
        [ "$NEW_BURNS_JSON" != "[" ] && NEW_BURNS_JSON+=","
        NEW_BURNS_JSON+="{\"txid\":\"$btc_txid\",\"height\":$CACHE_HEIGHT}"
    done <<< "$CACHED_BURNS"
fi

# Scan only NEW blocks
for HEIGHT in $(seq $SCAN_FROM $SAFE_HEIGHT); do
    # Progress every 500 blocks
    if [ $((HEIGHT % 500)) -eq 0 ]; then
        echo "  Scanning block $HEIGHT / $SAFE_HEIGHT (found $BURNS_FOUND so far)..."
    fi

    BURNS=$(find_burns_in_block "$HEIGHT")
    if [ -n "$BURNS" ]; then
        while IFS= read -r btc_txid; do
            [ -z "$btc_txid" ] && continue
            BURNS_FOUND=$((BURNS_FOUND + 1))
            echo "  [BURN] $btc_txid at height $HEIGHT"
            [ "$NEW_BURNS_JSON" != "[" ] && NEW_BURNS_JSON+=","
            NEW_BURNS_JSON+="{\"txid\":\"$btc_txid\",\"height\":$HEIGHT}"

            if is_already_claimed "$btc_txid"; then
                echo "    skip (already claimed)"
                BURNS_SKIPPED=$((BURNS_SKIPPED + 1))
                continue
            fi

            if submit_claim "$btc_txid" "$HEIGHT"; then
                BURNS_SUBMITTED=$((BURNS_SUBMITTED + 1))
            fi
        done <<< "$BURNS"
    fi
done

echo ""
echo "Burn scan complete: found=$BURNS_FOUND, submitted=$BURNS_SUBMITTED, skipped=$BURNS_SKIPPED"

# Save burn cache for next run
NEW_BURNS_JSON+="]"
echo "{\"last_scanned_height\":$SAFE_HEIGHT,\"burns\":$NEW_BURNS_JSON}" | jq '.' > "$BURN_CACHE" 2>/dev/null || true
echo "[OK] Burn cache saved ($BURNS_FOUND burns, scanned to $SAFE_HEIGHT)"

# Check daemon is still alive
if ! $CLI getblockcount >/dev/null 2>&1; then
    tail -30 $TESTNET_DIR/debug.log 2>/dev/null || true
    fatal "Daemon died during burn claiming"
fi

if [ "$BURNS_FOUND" -eq 0 ]; then
    echo "[WARN] No burns found on BTC Signet in range $BTC_CHECKPOINT..$SAFE_HEIGHT"
fi

# Mine burn claims block (claims are in mempool from submit_claim)
echo "Mining burn claims block..."
sleep 1
CLAIM_BLOCK=$($CLI generatebootstrap 1 2>/dev/null | jq -r ".[0]")
echo "Claims block: ${CLAIM_BLOCK:0:16}..."

# Set burn scan progress so burn daemon starts from here after genesis
SCAN_HASH=$($CLI getbtcheader "$SAFE_HEIGHT" 2>/dev/null | jq -r '.hash // empty')
if [ -n "$SCAN_HASH" ]; then
    $CLI setburnscanprogress "$SAFE_HEIGHT" "$SCAN_HASH" 2>/dev/null || true
    echo "Burn scan progress set to BTC height $SAFE_HEIGHT"
fi

# Check results
PENDING=$($CLI listburnclaims pending 100 2>/dev/null | jq length 2>/dev/null || echo "0")
FINAL=$($CLI listburnclaims final 100 2>/dev/null | jq length 2>/dev/null || echo "0")
echo "PENDING: $PENDING, FINAL: $FINAL"

# ═══════════════════════════════════════════════════════════════════════════
# Generate K_FINALITY blocks
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "═══ Generating $K_FINALITY blocks ═══"
for i in $(seq 1 $K_FINALITY); do
    # Block assembler auto-aligns timestamps to 15s slots. No real-time wait needed
    # during bootstrap — generatebootstrap is synchronous and time-too-old was removed.
    sleep 1

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

sleep 1
MINT_BLOCK=$($CLI generatebootstrap 1 2>/dev/null | jq -r ".[0]")
echo "Mint block: $MINT_BLOCK"

# Validate mints: count all TX_MINT_M0BTC (type=32) in the block
MINT_TXIDS=($($CLI getblock "$MINT_BLOCK" 2 2>/dev/null | jq -r '.tx[] | select(.type == 32) | .txid' 2>/dev/null))
MINT_TX_COUNT=${#MINT_TXIDS[@]}
echo "TX_MINT_M0BTC count: $MINT_TX_COUNT"

if [ "$MINT_TX_COUNT" -eq 0 ]; then
    MINT_TXID=""
    echo "Mint TXID: NONE"
elif [ "$MINT_TX_COUNT" -eq 1 ]; then
    MINT_TXID="${MINT_TXIDS[0]}"
    echo "Mint TXID: $MINT_TXID"
else
    # Multiple mints: use first, but aggregate all collaterals from all mints
    echo "[WARN] Multiple TX_MINT_M0BTC ($MINT_TX_COUNT) in block — aggregating all outputs"
    MINT_TXID="${MINT_TXIDS[0]}"
    for txid in "${MINT_TXIDS[@]}"; do
        echo "  Mint: $txid"
    done
fi

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

    # Show mint outputs for debug
    echo ""
    echo "═══ Mint TX Outputs ═══"
    for SCAN_TXID in "${MINT_TXIDS[@]}"; do
        SCAN_TX_JSON=$($CLI getrawtransaction "$SCAN_TXID" true 2>/dev/null) || continue
        echo "Mint outputs (${SCAN_TXID:0:16}...):"
        echo "$SCAN_TX_JSON" | jq -r '.vout[] | "  vout \(.n): \(.value) sats → \(.scriptPubKey.addresses[0] // "unknown")"' 2>/dev/null | head -40
    done

    # Import ALL known wallet keys (burns may go to any known address)
    # 1. Import from /tmp/all_wallet_keys.json (uploaded by deploy script)
    echo ""
    echo "═══ Importing wallet keys ═══"
    WALLET_ADDR=""
    if [ -f /tmp/all_wallet_keys.json ]; then
        IMPORTED=0
        for ROW in $(jq -c '.[]' /tmp/all_wallet_keys.json 2>/dev/null); do
            W_NAME=$(echo "$ROW" | jq -r '.name')
            W_WIF=$(echo "$ROW" | jq -r '.wif')
            W_ADDR=$(echo "$ROW" | jq -r '.address')
            if [ -n "$W_WIF" ] && [ "$W_WIF" != "null" ]; then
                $CLI importprivkey "$W_WIF" "$W_NAME" false 2>/dev/null || true
                IMPORTED=$((IMPORTED + 1))
                echo "  Imported: $W_NAME ($W_ADDR)"
                # Use pilpous as the MN owner address
                if [ "$W_NAME" = "pilpous" ]; then
                    WALLET_ADDR="$W_ADDR"
                fi
            fi
        done
        echo "[OK] Imported $IMPORTED wallet keys from all_wallet_keys.json"
    fi

    # 2. Fallback: import from ~/.BathronKey/wallet.json if all_wallet_keys.json missing
    WALLET_JSON="$HOME/.BathronKey/wallet.json"
    if [ -z "$WALLET_ADDR" ] && [ -f "$WALLET_JSON" ]; then
        WALLET_WIF=$(jq -r '.wif' "$WALLET_JSON" 2>/dev/null)
        WALLET_NAME=$(jq -r '.name' "$WALLET_JSON" 2>/dev/null)
        WALLET_ADDR=$(jq -r '.address' "$WALLET_JSON" 2>/dev/null)
        if [ -n "$WALLET_WIF" ] && [ "$WALLET_WIF" != "null" ]; then
            echo "Importing wallet key ($WALLET_NAME) for collateral signing..."
            $CLI importprivkey "$WALLET_WIF" "$WALLET_NAME" false 2>/dev/null || true
        fi
    fi

    if [ -z "$WALLET_ADDR" ] || [ "$WALLET_ADDR" = "null" ]; then
        echo "[WARN] No wallet address found — using Seed wallet.json"
        WALLET_ADDR=$(jq -r '.address' "$WALLET_JSON" 2>/dev/null || echo "")
    fi
    echo "MN owner address: $WALLET_ADDR"

    echo "Rescanning blockchain for imported keys..."
    $CLI rescanblockchain 0 2>/dev/null || echo "[WARN] rescanblockchain failed"

    # ALWAYS consolidate: create fresh collateral UTXOs at wallet-controlled addresses.
    # Mint outputs go to burn DESTINATION addresses which may not be in our wallet.
    # Consolidation gathers all spendable UTXOs and creates properly-sized collaterals.
    echo ""
    echo "═══ Consolidating into MN collaterals ═══"
    # getbalance returns JSON: {"total": N, "piv": N, ...}
    BALANCE_JSON=$($CLI getbalance 2>/dev/null || echo "{}")
    BALANCE=$(echo "$BALANCE_JSON" | jq -r '.piv // .total // 0' 2>/dev/null || echo "0")
    if ! [[ "$BALANCE" =~ ^[0-9]+$ ]]; then
        echo "[WARN] getbalance returned non-numeric: $BALANCE_JSON"
        BALANCE=0
    fi
    echo "Wallet balance: $BALANCE sats"

    # Reserve for fees: each MN needs ~10000 sats for ProReg fee + 10000 for sendmany fee
    FEE_RESERVE_PER_MN=20000
    TARGET_MNS=8
    NEEDED=$((TARGET_MNS * (MN_COLLATERAL_SATS + FEE_RESERVE_PER_MN)))
    if [ "$BALANCE" -lt "$NEEDED" ]; then
        TARGET_MNS=$(( (BALANCE - 50000) / (MN_COLLATERAL_SATS + FEE_RESERVE_PER_MN) ))
        if [ "$TARGET_MNS" -lt 3 ]; then
            echo "[ERROR] Balance ($BALANCE) too low for even 3 MNs (need $((3 * (MN_COLLATERAL_SATS + FEE_RESERVE_PER_MN) + 50000)))"
            echo "  Available balance may be from known wallets only"
        fi
    fi
    echo "Target: $TARGET_MNS MNs (collateral=$MN_COLLATERAL_SATS + fee_reserve=$FEE_RESERVE_PER_MN each)"

    MN_COLLATERALS=""
    MN_COUNT=0

    if [ "$TARGET_MNS" -ge 3 ]; then
        # Create collateral + fee outputs in ONE sendmany (avoids needing separate fee step)
        CONSOLIDATE="{"
        for i in $(seq 1 $TARGET_MNS); do
            COLL_ADDR=$($CLI getnewaddress "mn_collateral_$i" 2>/dev/null)
            FEE_ADDR=$($CLI getnewaddress "mn_fee_$i" 2>/dev/null)
            [ $i -gt 1 ] && CONSOLIDATE+=","
            CONSOLIDATE+="\"$COLL_ADDR\":$MN_COLLATERAL_SATS,\"$FEE_ADDR\":10000"
        done
        CONSOLIDATE+="}"
        echo "Consolidation sendmany: $TARGET_MNS collaterals + $TARGET_MNS fee outputs"

        CONSOL_TX=$($CLI sendmany "" "$CONSOLIDATE" 2>&1)
        if echo "$CONSOL_TX" | grep -qE "^[0-9a-f]{64}$"; then
            echo "  Consolidation TX: ${CONSOL_TX:0:16}..."
            sleep 1
            CONSOL_BLOCK=$($CLI generatebootstrap 1 2>/dev/null | jq -r ".[0]")
            echo "  Consolidation block: ${CONSOL_BLOCK:0:16}..."

            # Scan consolidation TX for collateral-sized outputs
            CONSOL_JSON=$($CLI getrawtransaction "$CONSOL_TX" true 2>/dev/null)
            for VOUT in $(echo "$CONSOL_JSON" | jq -r ".vout[] | select(.value >= $MN_COLLATERAL_MIN and .value <= $MN_COLLATERAL_MAX) | .n" 2>/dev/null); do
                MN_COUNT=$((MN_COUNT + 1))
                MN_COLLATERALS="$MN_COLLATERALS $CONSOL_TX:$VOUT"
            done
            echo "  MN collaterals created: $MN_COUNT"
        else
            echo "  [ERROR] sendmany failed: $CONSOL_TX"
            echo "  Listing UTXOs for debug:"
            $CLI listunspent 0 99999 2>/dev/null | jq -c '.[] | {txid: .txid[0:16], vout, amount, address: .address[0:16]}' 2>/dev/null | head -20
        fi
    fi
else
    MN_COUNT=0
    MN_COLLATERALS=""
    echo ""
    echo "[SKIP] No mints (no pending claims)"
fi

# ═══════════════════════════════════════════════════════════════════════════
# Operator key + MN registration
# ═══════════════════════════════════════════════════════════════════════════
if [ "$MN_COUNT" -gt 0 ]; then
    # Generate operator key
    KEYPAIR=$($CLI generateoperatorkeypair 2>/dev/null)
    OP_WIF=$(echo "$KEYPAIR" | jq -r ".secret")
    OP_PUB=$(echo "$KEYPAIR" | jq -r ".public")
    echo ""
    echo "Operator key generated: ${OP_PUB:0:24}..."

    # Lock collaterals so ProReg doesn't accidentally spend them as fee inputs
    LOCK_JSON="["
    i=0
    for COLLATERAL in $MN_COLLATERALS; do
        TXID="${COLLATERAL%%:*}"
        VOUT="${COLLATERAL##*:}"
        [ $i -gt 0 ] && LOCK_JSON+=","
        LOCK_JSON+="{\"txid\":\"$TXID\",\"vout\":$VOUT}"
        i=$((i + 1))
    done
    LOCK_JSON+="]"
    $CLI lockunspent false true "$LOCK_JSON" 2>/dev/null || true
    echo "Locked $i collateral UTXOs"

    # ProReg MNs
    echo ""
    echo "═══ ProReg MNs ═══"
    MN_REG_OK=0
    MN_REG_FAIL=0
    # Each MN needs UNIQUE owner, voting, and payout addresses (consensus: protx-dup)
    # All owner WIFs are saved to operators.json for later protx_update_registrar
    echo "All addresses: unique per MN (dumpprivkey to save owner keys)"
    MN_OWNER_KEYS="["  # JSON array of owner keys for operators.json

    MN_IDX=0
    for COLLATERAL in $MN_COLLATERALS; do
        TXID="${COLLATERAL%%:*}"
        VOUT="${COLLATERAL##*:}"
        MN_IDX=$((MN_IDX + 1))

        # Generate unique addresses for this MN
        OWNER_ADDR=$($CLI getnewaddress "mn${MN_IDX}_owner" 2>/dev/null)
        VOTING_ADDR=$($CLI getnewaddress "mn${MN_IDX}_voting" 2>/dev/null)
        PAYOUT_ADDR=$($CLI getnewaddress "mn${MN_IDX}_payout" 2>/dev/null)

        # Export owner key for later use (protx_update_registrar needs it)
        OWNER_WIF=$($CLI dumpprivkey "$OWNER_ADDR" 2>/dev/null || echo "")

        REG_RESULT=$($CLI protx_register "$TXID" "$VOUT" "$SEED_IP:$SEED_PORT" "$OWNER_ADDR" "$OP_PUB" "$VOTING_ADDR" "$PAYOUT_ADDR" 2>&1) || true
        if echo "$REG_RESULT" | grep -qE "error|Error"; then
            echo "  FAIL MN$MN_IDX $TXID:$VOUT => $REG_RESULT"
            MN_REG_FAIL=$((MN_REG_FAIL + 1))
        else
            PROTX_HASH=$(echo "$REG_RESULT" | tr -d '[:space:]')
            echo "  OK MN$MN_IDX: ${PROTX_HASH:0:16}... (owner=$OWNER_ADDR, payout=$PAYOUT_ADDR)"
            MN_REG_OK=$((MN_REG_OK + 1))
            # Append to MN owner keys array
            [ "$MN_OWNER_KEYS" != "[" ] && MN_OWNER_KEYS+=","
            MN_OWNER_KEYS+="{\"mn\":$MN_IDX,\"proTxHash\":\"$PROTX_HASH\",\"owner\":\"$OWNER_ADDR\",\"owner_wif\":\"$OWNER_WIF\",\"payout\":\"$PAYOUT_ADDR\"}"
        fi
    done
    MN_OWNER_KEYS+="]"
    echo "ProReg: $MN_REG_OK OK, $MN_REG_FAIL failed"

    # Mine ProReg TXs
    if [ "$MN_REG_OK" -gt 0 ]; then
        sleep 1
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

    # Save operator key + all owner keys
    mkdir -p ~/.BathronKey
    chmod 700 ~/.BathronKey
    cat > ~/.BathronKey/operators.json << KEYEOF
{"operator":{"wif":"$OP_WIF","pubkey":"$OP_PUB","mn_count":$MN_REG_OK},"masternodes":$MN_OWNER_KEYS}
KEYEOF
    chmod 600 ~/.BathronKey/operators.json
    echo "Operator key + $MN_REG_OK owner keys saved to ~/.BathronKey/operators.json"

    # ═══ Post-registration verification ═══
    echo ""
    echo "═══ Key Verification ═══"
    PROTX_LIST=$($CLI protx_list 2>/dev/null)
    if [ -n "$PROTX_LIST" ] && echo "$PROTX_LIST" | jq -e '.[0]' >/dev/null 2>&1; then
        TOTAL_MN=$(echo "$PROTX_LIST" | jq 'length')
        OP_OK=$(echo "$PROTX_LIST" | jq -r "[.[] | select(.dmnstate.operatorPubKey == \"$OP_PUB\")] | length")
        echo "  Total MNs:     $TOTAL_MN"
        echo "  Operator match: $OP_OK / $TOTAL_MN (pubkey=${OP_PUB:0:24}...)"
        echo "  Owners:        unique per MN (WIFs saved in operators.json)"
        echo "  Payouts:       unique per MN (updatable via protx_update_registrar)"
        echo "$PROTX_LIST" | jq -r '.[] | "  MN \(.proTxHash[0:16])...: owner=\(.dmnstate.ownerAddress) payout=\(.dmnstate.payoutAddress)"' 2>/dev/null
        if [ "$OP_OK" = "$TOTAL_MN" ]; then
            echo "  [OK] All MN keys verified — operator match + owner WIFs saved"
        else
            echo "  [WARN] Operator key mismatch! Check operators.json"
        fi
    else
        echo "  [WARN] Could not verify — protx_list empty or failed"
    fi
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
echo "Burns found: $BURNS_FOUND (submitted: $BURNS_SUBMITTED)"
echo ""
echo "Keys:"
echo "  Owner/Voting: ${WALLET_ADDR:-unknown} (from wallet keys)"
echo "  Operator WIF: ${OP_WIF:+${OP_WIF:0:8}...} (saved in ~/.BathronKey/operators.json)"
echo "  Operator Pub: ${OP_PUB:+${OP_PUB:0:24}...}"
echo ""
echo "Flow: CLEAN (auto-discovery from BTC Signet, zero hardcoded data)"
echo "════════════════════════════════════════════════════════════════"

# Stop daemon
$CLI stop 2>/dev/null || true
echo "Daemon stopped"
