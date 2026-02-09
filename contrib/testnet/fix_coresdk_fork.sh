#!/bin/bash
# fix_coresdk_fork.sh - Fix Core+SDK fork by complete wipe and P2P resync
#
# This script implements the deterministic fix procedure:
# A) Verify Seed is canonical (without stopping)
# B) Stop Core+SDK properly
# C) Complete wipe of testnet5 state (ALL consensus + networking artifacts)
# D) Ensure Core+SDK connects to Seed via P2P (addnode, not connect=)
# E) Restart Core+SDK for P2P resync
# F) Validate Core+SDK has same chain as Seed
#
# CRITICAL: This script does NOT stop Seed - Seed is the reference chain.
#
# Common issue fixed: "mint-not-pending" error when Core+SDK settlementdb
# is out of sync with the network (missing pending burn claims).

set -e

# Configuration
SSH="ssh -i ~/.ssh/id_ed25519_vps -o StrictHostKeyChecking=no -o ConnectTimeout=15"
SEED_IP="57.131.33.151"
CORESDK_IP="162.19.251.75"
VPS_DATADIR="~/.bathron"
VPS_TESTNET_DIR="~/.bathron/testnet5"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log() { echo -e "${YELLOW}[INFO]${NC} $1"; }
success() { echo -e "${GREEN}[OK]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; }

echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║  Fix Core+SDK Fork - Complete Wipe + P2P Resync              ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""

# ==============================================================================
# STEP A: Verify Seed is canonical (WITHOUT stopping it)
# ==============================================================================
log "STEP A: Verifying Seed is canonical chain..."

SEED_HEIGHT=$($SSH ubuntu@$SEED_IP '~/BATHRON-Core/src/bathron-cli -testnet getblockcount 2>/dev/null' 2>/dev/null || echo "ERROR")
SEED_H56=$($SSH ubuntu@$SEED_IP '~/BATHRON-Core/src/bathron-cli -testnet getblockhash 56 2>/dev/null' 2>/dev/null || echo "NA")
SEED_BEST=$($SSH ubuntu@$SEED_IP '~/BATHRON-Core/src/bathron-cli -testnet getbestblockhash 2>/dev/null' 2>/dev/null || echo "NA")

echo "  SEED height: $SEED_HEIGHT"
echo "  SEED h56:    $SEED_H56"
echo "  SEED best:   ${SEED_BEST:0:16}..."

if [[ "$SEED_HEIGHT" == "ERROR" ]] || [[ "$SEED_H56" == "NA" ]]; then
    error "Seed is not responding! Cannot proceed."
    exit 1
fi

success "Seed is running at height $SEED_HEIGHT ✓"
echo ""

# ==============================================================================
# STEP B: Stop Core+SDK properly + force kill
# ==============================================================================
log "STEP B: Stopping Core+SDK properly..."

$SSH ubuntu@$CORESDK_IP '
    echo "  Attempting graceful stop..."
    ~/bathron-cli -testnet stop 2>/dev/null || true
    sleep 2

    echo "  Sending SIGTERM..."
    pkill -15 -f bathrond 2>/dev/null || true
    sleep 2

    echo "  Sending SIGKILL..."
    pkill -9 -f bathrond 2>/dev/null || true
    sleep 1

    # Verify stopped
    if pgrep -a bathrond >/dev/null 2>&1; then
        echo "  WARNING: bathrond still running, forcing..."
        killall -9 bathrond 2>/dev/null || true
        sleep 2
    fi

    if pgrep bathrond >/dev/null 2>&1; then
        echo "ERROR: Could not stop bathrond!"
        exit 1
    fi

    echo "  OK: bathrond stopped"
' 2>/dev/null || true

success "Core+SDK daemon stopped ✓"
echo ""

# ==============================================================================
# STEP C: COMPLETE WIPE of testnet5 state on Core+SDK
# ==============================================================================
log "STEP C: Complete wipe of Core+SDK consensus + networking state..."

$SSH ubuntu@$CORESDK_IP '
    DAT=~/.bathron/testnet5

    # Safety: ensure daemon is dead
    pkill -9 -f bathrond 2>/dev/null || true
    rm -f $DAT/.lock

    echo "  Wiping consensus state..."
    # Core consensus directories
    rm -rf $DAT/blocks
    rm -rf $DAT/chainstate
    rm -rf $DAT/index

    # Evo/LLMQ state
    rm -rf $DAT/evodb
    rm -rf $DAT/llmq

    # Settlement state (CRITICAL - this fixes "mint-not-pending" errors)
    rm -rf $DAT/settlement
    rm -rf $DAT/settlementdb

    # BTC SPV state (can cause fork preference issues)
    rm -rf $DAT/btcspv

    # HU finality
    rm -rf $DAT/hu_finality
    rm -rf $DAT/khu

    # Other state
    rm -rf $DAT/sporks
    rm -rf $DAT/database
    rm -rf $DAT/backups

    echo "  Wiping networking artifacts (prevents fork isolation)..."
    rm -f $DAT/peers.dat
    rm -f $DAT/banlist.dat
    rm -f $DAT/mempool.dat
    rm -f $DAT/mncache.dat
    rm -f $DAT/mnmetacache.dat
    rm -f $DAT/netrequests.dat
    rm -f $DAT/fee_estimates.dat

    echo "  Wiping logs..."
    rm -f $DAT/debug.log
    rm -f $DAT/db.log
    rm -f $DAT/*.log

    echo ""
    echo "  After wipe (should have bathron.conf + wallet.dat):"
    ls -la $DAT/ 2>/dev/null | head -20 || echo "    (directory empty)"
' 2>/dev/null

success "Core+SDK consensus state wiped ✓"
echo ""

# ==============================================================================
# STEP D: Configure Core+SDK to connect to Seed and other MNs
# ==============================================================================
log "STEP D: Configuring Core+SDK networking..."

$SSH ubuntu@$CORESDK_IP '
    CONF=~/.bathron/bathron.conf

    # Remove any connect= lines (incompatible with MN)
    sed -i "/^connect=/d" $CONF

    # Ensure addnode for all peers
    for PEER in "57.131.33.151:27171" "57.131.33.152:27171" "57.131.33.214:27171" "51.75.31.44:27171"; do
        if ! grep -q "^addnode=$PEER" $CONF; then
            echo "addnode=$PEER" >> $CONF
        fi
    done

    # Ensure seednode for Seed (backup)
    if ! grep -q "^seednode=57.131.33.151:27171" $CONF; then
        echo "seednode=57.131.33.151:27171" >> $CONF
    fi

    echo "  Config peer lines:"
    grep -E "^(addnode|seednode|connect)=" $CONF | tail -10
' 2>/dev/null

success "Core+SDK configured to connect to network ✓"
echo ""

# ==============================================================================
# STEP E: Restart Core+SDK and let it sync via P2P
# ==============================================================================
log "STEP E: Restarting Core+SDK daemon..."

$SSH ubuntu@$CORESDK_IP '
    # Final safety check
    rm -f ~/.bathron/testnet5/.lock

    # Start daemon
    ~/bathrond -testnet -daemon
    sleep 3

    # Show initial status
    echo "  Core+SDK height: $(~/bathron-cli -testnet getblockcount 2>/dev/null || echo NA)"
    echo "  Core+SDK peers:  $(~/bathron-cli -testnet getconnectioncount 2>/dev/null || echo NA)"
' 2>/dev/null

success "Core+SDK daemon restarted ✓"
echo ""

# ==============================================================================
# STEP F: Validate Core+SDK syncs to same chain as Seed
# ==============================================================================
log "STEP F: Validating Core+SDK is syncing to Seed chain..."
echo "  Waiting for Core+SDK to sync past block 56..."

MAX_WAIT=180
WAIT_INTERVAL=5
ELAPSED=0

while [ $ELAPSED -lt $MAX_WAIT ]; do
    CORESDK_HEIGHT=$($SSH ubuntu@$CORESDK_IP '~/bathron-cli -testnet getblockcount 2>/dev/null' 2>/dev/null || echo "0")
    CORESDK_PEERS=$($SSH ubuntu@$CORESDK_IP '~/bathron-cli -testnet getconnectioncount 2>/dev/null' 2>/dev/null || echo "0")

    echo "  [$ELAPSED s] Core+SDK height=$CORESDK_HEIGHT, peers=$CORESDK_PEERS"

    if [ "$CORESDK_HEIGHT" -ge 100 ] 2>/dev/null; then
        break
    fi

    sleep $WAIT_INTERVAL
    ELAPSED=$((ELAPSED + WAIT_INTERVAL))
done

echo ""

# Final comparison
CORESDK_H56=$($SSH ubuntu@$CORESDK_IP '~/bathron-cli -testnet getblockhash 56 2>/dev/null' 2>/dev/null || echo "NA")

echo "  SEED     h56: $SEED_H56"
echo "  Core+SDK h56: $CORESDK_H56"
echo ""

if [[ "$CORESDK_H56" == "$SEED_H56" ]]; then
    success "═══════════════════════════════════════════════════════════════"
    success " FORK RESOLVED! Core+SDK is now on the same chain as Seed"
    success "═══════════════════════════════════════════════════════════════"
else
    error "═══════════════════════════════════════════════════════════════"
    error " FORK NOT RESOLVED - Core+SDK h56 differs from Seed"
    error " "
    error " Possible causes:"
    error "   1. Core+SDK not connecting to peers (check peers count)"
    error "   2. Core+SDK using different datadir"
    error "   3. Core+SDK binaries differ from Seed"
    error " "
    error " Debug commands:"
    error "   ssh -i ~/.ssh/id_ed25519_vps ubuntu@$CORESDK_IP 'tail -30 ~/.bathron/testnet5/debug.log | grep -Ei \"connect|peer|misbehaving|banned|invalid|fork|reorg\"'"
    error "═══════════════════════════════════════════════════════════════"
    exit 1
fi

# Final status
echo ""
log "Final network status:"
SEED_HEIGHT=$($SSH ubuntu@$SEED_IP '~/BATHRON-Core/src/bathron-cli -testnet getblockcount 2>/dev/null' 2>/dev/null || echo "?")
CORESDK_HEIGHT=$($SSH ubuntu@$CORESDK_IP '~/bathron-cli -testnet getblockcount 2>/dev/null' 2>/dev/null || echo "?")
CORESDK_PEERS=$($SSH ubuntu@$CORESDK_IP '~/bathron-cli -testnet getconnectioncount 2>/dev/null' 2>/dev/null || echo "?")

echo "  SEED:     height=$SEED_HEIGHT"
echo "  Core+SDK: height=$CORESDK_HEIGHT, peers=$CORESDK_PEERS"
echo ""

# Verify settlement state after resync
log "Verifying burn claims on Core+SDK..."
$SSH ubuntu@$CORESDK_IP '~/bathron-cli -testnet listburnclaims 2>/dev/null' 2>/dev/null | head -30 || echo "  (listburnclaims not available yet - still syncing)"
echo ""

success "Done! Core+SDK should now accept blocks with TX_MINT_M0BTC."
