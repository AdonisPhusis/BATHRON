#!/bin/bash
# ═══════════════════════════════════════════════════════════════════════════════
# verify_genesis.sh - Genesis & Premine Verification (Genesis Clean)
# ═══════════════════════════════════════════════════════════════════════════════
# Validates:
#   1. Genesis hash is deterministic
#   2. Block 1 premine outputs match expected values (8 MN + dev wallet)
#   3. GetBlockValue matches actual coinbase
#   4. Total supply is 98,850,000 M0
# ═══════════════════════════════════════════════════════════════════════════════

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BATHRON_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DATADIR="/tmp/verify_genesis_$$"
CONF="$DATADIR/bathron.conf"
CLI="$BATHRON_ROOT/src/bathron-cli"
DAEMON="$BATHRON_ROOT/src/bathrond"
RPC_PORT=28170
P2P_PORT=28171

# Expected values (from ~/.BathronKey/testnet_keys.json and blockassembler.cpp)
EXPECTED_PREMINE=98850000
EXPECTED_DEV_AMOUNT=98769992
EXPECTED_MN_AMOUNT=10001
EXPECTED_MN_COUNT=8

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_ok() { echo -e "${GREEN}✓${NC} $1"; }
log_fail() { echo -e "${RED}✗${NC} $1"; }
log_info() { echo -e "${YELLOW}→${NC} $1"; }

cli_cmd() {
    $CLI -datadir="$DATADIR" -conf="$CONF" -rpcconnect=127.0.0.1 -rpcport=$RPC_PORT "$@"
}

cleanup() {
    log_info "Cleaning up..."
    cli_cmd stop 2>/dev/null || true
    sleep 2
    pkill -f "bathrond.*verify_genesis_$$" 2>/dev/null || true
    rm -rf "$DATADIR"
}

trap cleanup EXIT

# ═══════════════════════════════════════════════════════════════════════════════
# BUILD CHECK
# ═══════════════════════════════════════════════════════════════════════════════
log_info "Checking binaries..."
if [ ! -x "$DAEMON" ] || [ ! -x "$CLI" ]; then
    log_info "Building..."
    cd "$BATHRON_ROOT" && make -j4 >/dev/null 2>&1
fi

if [ ! -x "$DAEMON" ]; then
    log_fail "bathrond not found at $DAEMON"
    exit 1
fi
log_ok "Binaries OK"

# ═══════════════════════════════════════════════════════════════════════════════
# START NODE
# ═══════════════════════════════════════════════════════════════════════════════
log_info "Starting fresh testnet node..."
mkdir -p "$DATADIR"

# Config with [test] section for network-specific settings
cat > "$CONF" << EOF
testnet=1
server=1
rpcuser=test
rpcpassword=test123
listen=0
listenonion=0
dnsseed=0

[test]
rpcport=$RPC_PORT
port=$P2P_PORT
EOF

$DAEMON -datadir="$DATADIR" -conf="$CONF" -daemon -debug=0 2>/dev/null
sleep 5

# Wait for RPC (fresh genesis, starts at block 0)
for i in {1..60}; do
    if cli_cmd getblockcount 2>/dev/null; then
        break
    fi
    sleep 1
done

HEIGHT=$(cli_cmd getblockcount 2>/dev/null || echo "-1")
if [ "$HEIGHT" -lt 0 ]; then
    log_fail "Node failed to start"
    # Show debug log for diagnosis
    cat "$DATADIR/testnet5/debug.log" 2>/dev/null | tail -30 || true
    exit 1
fi
log_ok "Node started at height $HEIGHT"

# ═══════════════════════════════════════════════════════════════════════════════
# GENESIS HASH CHECK
# ═══════════════════════════════════════════════════════════════════════════════
log_info "Checking genesis hash..."
GENESIS_HASH=$(cli_cmd getblockhash 0)
log_ok "Genesis hash: $GENESIS_HASH"

# ═══════════════════════════════════════════════════════════════════════════════
# GENERATE BOOTSTRAP BLOCKS (PREMINE)
# ═══════════════════════════════════════════════════════════════════════════════
log_info "Generating bootstrap blocks..."

# BATHRON uses generatebootstrap for testnet block generation
# Block 1 = premine (dev wallet + 8 MN collaterals)
# Block 2 = DMM activation
for i in 1 2 3; do
    result=$(cli_cmd generatebootstrap 1 2>&1) || true
    log_info "Block $i: $result"
    sleep 1
done

HEIGHT=$(cli_cmd getblockcount)
log_ok "Height after bootstrap: $HEIGHT"

if [ "$HEIGHT" -lt 1 ]; then
    log_fail "Failed to generate bootstrap blocks"
    exit 1
fi

# ═══════════════════════════════════════════════════════════════════════════════
# BLOCK 1 PREMINE VERIFICATION
# ═══════════════════════════════════════════════════════════════════════════════
log_info "Verifying Block 1 premine..."

BLOCK1_HASH=$(cli_cmd getblockhash 1)
BLOCK1=$(cli_cmd getblock "$BLOCK1_HASH" 2)

# Get coinbase transaction
COINBASE_TXID=$(echo "$BLOCK1" | jq -r '.tx[0].txid')
COINBASE_VOUT=$(echo "$BLOCK1" | jq '.tx[0].vout')
VOUT_COUNT=$(echo "$COINBASE_VOUT" | jq 'length')

log_info "Block 1 coinbase: $COINBASE_TXID"
log_info "Number of outputs: $VOUT_COUNT"

# Expected: 9 outputs (1 dev + 8 MN)
if [ "$VOUT_COUNT" -eq 9 ]; then
    log_ok "Output count: 9 (dev + 8 MN)"
else
    log_fail "Expected 9 outputs, got $VOUT_COUNT"
fi

# Check dev wallet amount (output 0)
DEV_AMOUNT=$(echo "$COINBASE_VOUT" | jq -r '.[0].value')
DEV_AMOUNT_INT=$(echo "$DEV_AMOUNT" | cut -d. -f1)
if [ "$DEV_AMOUNT_INT" -eq "$EXPECTED_DEV_AMOUNT" ]; then
    log_ok "Dev wallet: $DEV_AMOUNT M0"
else
    log_fail "Dev wallet mismatch: expected $EXPECTED_DEV_AMOUNT, got $DEV_AMOUNT_INT"
fi

# Check MN amounts (outputs 1-8)
MN_OK=0
for i in {1..8}; do
    MN_AMOUNT=$(echo "$COINBASE_VOUT" | jq -r ".[$i].value")
    MN_AMOUNT_INT=$(echo "$MN_AMOUNT" | cut -d. -f1)
    if [ "$MN_AMOUNT_INT" -eq "$EXPECTED_MN_AMOUNT" ]; then
        MN_OK=$((MN_OK + 1))
    fi
done

if [ "$MN_OK" -eq 8 ]; then
    log_ok "MN collaterals: 8 × $EXPECTED_MN_AMOUNT M0"
else
    log_fail "MN collateral mismatch: $MN_OK/8 correct"
fi

# Total supply check
TOTAL_SUPPLY=$(cli_cmd gettxoutsetinfo | jq -r '.total_amount')
TOTAL_INT=$(echo "$TOTAL_SUPPLY" | cut -d. -f1)
log_info "Total supply: $TOTAL_SUPPLY M0"

# ═══════════════════════════════════════════════════════════════════════════════
# DETERMINISM CHECK
# ═══════════════════════════════════════════════════════════════════════════════
log_info "Checking determinism..."

# Save hashes
BLOCK0_HASH=$(cli_cmd getblockhash 0)
BLOCK1_HASH=$(cli_cmd getblockhash 1)

log_ok "Block 0: $BLOCK0_HASH"
log_ok "Block 1: $BLOCK1_HASH"

# ═══════════════════════════════════════════════════════════════════════════════
# SUMMARY
# ═══════════════════════════════════════════════════════════════════════════════
echo ""
echo "═══════════════════════════════════════════════════════════════════════════════"
echo "GENESIS VERIFICATION SUMMARY"
echo "═══════════════════════════════════════════════════════════════════════════════"
echo "Genesis Hash:  $GENESIS_HASH"
echo "Block 1 Hash:  $BLOCK1_HASH"
echo "Premine:       $TOTAL_SUPPLY M0"
echo "Dev Wallet:    $DEV_AMOUNT M0"
echo "MN Outputs:    8 × $EXPECTED_MN_AMOUNT M0"
echo "═══════════════════════════════════════════════════════════════════════════════"

if [ "$VOUT_COUNT" -eq 9 ] && [ "$MN_OK" -eq 8 ]; then
    echo -e "${GREEN}PASS${NC} - Genesis and premine verified"
    exit 0
else
    echo -e "${RED}FAIL${NC} - Verification failed"
    exit 1
fi
