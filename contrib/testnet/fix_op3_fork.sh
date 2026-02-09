#!/bin/bash
# fix_op3_fork.sh - Fix OP3 fork by complete wipe and P2P resync from Seed
#
# This script implements the deterministic fix procedure:
# A) Verify Seed is canonical (without stopping)
# B) Stop OP3 properly
# C) Complete wipe of testnet5 state (ALL consensus + networking artifacts)
# D) Ensure OP3 connects to Seed via P2P (addnode, not connect=)
# E) Restart OP3 for P2P resync
# F) Validate OP3 has same h56 as Seed
#
# CRITICAL: This script does NOT stop Seed - Seed is the reference chain.

set -e

# Configuration
SSH="ssh -i ~/.ssh/id_ed25519_vps -o StrictHostKeyChecking=no -o ConnectTimeout=15"
SEED_IP="57.131.33.151"
OP3_IP="51.75.31.44"
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
echo "║  Fix OP3 Fork - Complete Wipe + P2P Resync                   ║"
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
echo "  SEED best:   $SEED_BEST"

if [[ "$SEED_HEIGHT" == "ERROR" ]] || [[ "$SEED_H56" == "NA" ]]; then
    error "Seed is not responding! Cannot proceed."
    exit 1
fi

# Expected h56 (from canonical chain)
EXPECTED_H56="115bf0c8"
if [[ "$SEED_H56" == "$EXPECTED_H56"* ]]; then
    success "Seed h56 matches expected canonical chain ✓"
else
    log "Note: Seed h56=$SEED_H56 (reference for this fix)"
fi
echo ""

# ==============================================================================
# STEP B: Stop OP3 properly + force kill
# ==============================================================================
log "STEP B: Stopping OP3 properly..."

$SSH ubuntu@$OP3_IP '
    set -e

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
' 2>/dev/null

success "OP3 daemon stopped ✓"
echo ""

# ==============================================================================
# STEP C: COMPLETE WIPE of testnet5 state on OP3
# ==============================================================================
log "STEP C: Complete wipe of OP3 consensus + networking state..."

$SSH ubuntu@$OP3_IP '
    set -e
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

    # Settlement state
    rm -rf $DAT/settlement
    rm -rf $DAT/settlementdb

    # BTC SPV state (critical - this can cause fork preference issues)
    rm -rf $DAT/btcspv

    # HU finality
    rm -rf $DAT/hu_finality
    rm -rf $DAT/khu

    # Other state
    rm -rf $DAT/sporks
    rm -rf $DAT/database
    rm -rf $DAT/wallets
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
    echo "  After wipe (should only have bathron.conf):"
    ls -la $DAT/ 2>/dev/null | head -20 || echo "    (directory empty)"
' 2>/dev/null

success "OP3 consensus state wiped ✓"
echo ""

# ==============================================================================
# STEP D: Force OP3 to connect to Seed (addnode, NOT connect=)
# ==============================================================================
log "STEP D: Configuring OP3 to connect to Seed..."

$SSH ubuntu@$OP3_IP '
    set -e
    CONF=~/.bathron/bathron.conf

    # Remove any connect= lines (incompatible with MN)
    sed -i "/^connect=/d" $CONF

    # Ensure addnode for Seed
    if ! grep -q "^addnode=57.131.33.151:27171" $CONF; then
        echo "addnode=57.131.33.151:27171" >> $CONF
    fi

    # Ensure seednode for Seed (backup)
    if ! grep -q "^seednode=57.131.33.151:27171" $CONF; then
        echo "seednode=57.131.33.151:27171" >> $CONF
    fi

    # Disable SPV on OP3 (producer node - SPV only on Seed)
    sed -i "s/^btcspv=.*/btcspv=0/" $CONF 2>/dev/null || true
    sed -i "s/^btcautosync=.*/btcautosync=0/" $CONF 2>/dev/null || true

    # If no btcspv line exists, add it
    if ! grep -q "^btcspv=" $CONF; then
        echo "btcspv=0" >> $CONF
    fi

    echo "  Config peer/SPV lines:"
    grep -E "^(addnode|seednode|connect|btcspv|btcautosync)=" $CONF | tail -10
' 2>/dev/null

success "OP3 configured to connect to Seed ✓"
echo ""

# ==============================================================================
# STEP E: Restart OP3 and let it sync via P2P
# ==============================================================================
log "STEP E: Restarting OP3 daemon..."

$SSH ubuntu@$OP3_IP '
    set -e

    # Final safety check
    rm -f ~/.bathron/testnet5/.lock

    # Start daemon
    ~/bathrond -testnet -daemon
    sleep 3

    # Show initial status
    echo "  OP3 height: $(~/bathron-cli -testnet getblockcount 2>/dev/null || echo NA)"
    echo "  OP3 peers:  $(~/bathron-cli -testnet getconnectioncount 2>/dev/null || echo NA)"
' 2>/dev/null

success "OP3 daemon restarted ✓"
echo ""

# ==============================================================================
# STEP F: Validate OP3 syncs to same h56 as Seed
# ==============================================================================
log "STEP F: Validating OP3 is syncing to Seed chain..."
echo "  Waiting for OP3 to sync past block 56..."

MAX_WAIT=120
WAIT_INTERVAL=5
ELAPSED=0

while [ $ELAPSED -lt $MAX_WAIT ]; do
    OP3_HEIGHT=$($SSH ubuntu@$OP3_IP '~/bathron-cli -testnet getblockcount 2>/dev/null' 2>/dev/null || echo "0")
    OP3_PEERS=$($SSH ubuntu@$OP3_IP '~/bathron-cli -testnet getconnectioncount 2>/dev/null' 2>/dev/null || echo "0")

    echo "  [$ELAPSED s] OP3 height=$OP3_HEIGHT, peers=$OP3_PEERS"

    if [ "$OP3_HEIGHT" -ge 56 ] 2>/dev/null; then
        break
    fi

    sleep $WAIT_INTERVAL
    ELAPSED=$((ELAPSED + WAIT_INTERVAL))
done

echo ""

# Final comparison
OP3_H56=$($SSH ubuntu@$OP3_IP '~/bathron-cli -testnet getblockhash 56 2>/dev/null' 2>/dev/null || echo "NA")

echo "  SEED h56: $SEED_H56"
echo "  OP3  h56: $OP3_H56"
echo ""

if [[ "$OP3_H56" == "$SEED_H56" ]]; then
    success "═══════════════════════════════════════════════════════════════"
    success " FORK RESOLVED! OP3 is now on the same chain as Seed"
    success "═══════════════════════════════════════════════════════════════"
else
    error "═══════════════════════════════════════════════════════════════"
    error " FORK NOT RESOLVED - OP3 h56 differs from Seed"
    error " "
    error " Possible causes:"
    error "   1. OP3 not connecting to peers (check peers count)"
    error "   2. OP3 using different datadir"
    error "   3. OP3 binaries differ from Seed"
    error " "
    error " Debug commands:"
    error "   ssh ubuntu@$OP3_IP 'tail -30 ~/.bathron/testnet5/debug.log | grep -Ei \"connect|peer|misbehaving|banned|invalid|fork|reorg\"'"
    error "═══════════════════════════════════════════════════════════════"
    exit 1
fi

# Final status
echo ""
log "Final network status:"
SEED_HEIGHT=$($SSH ubuntu@$SEED_IP '~/BATHRON-Core/src/bathron-cli -testnet getblockcount 2>/dev/null' 2>/dev/null || echo "?")
OP3_HEIGHT=$($SSH ubuntu@$OP3_IP '~/bathron-cli -testnet getblockcount 2>/dev/null' 2>/dev/null || echo "?")
OP3_PEERS=$($SSH ubuntu@$OP3_IP '~/bathron-cli -testnet getconnectioncount 2>/dev/null' 2>/dev/null || echo "?")

echo "  SEED: height=$SEED_HEIGHT"
echo "  OP3:  height=$OP3_HEIGHT, peers=$OP3_PEERS"
echo ""
