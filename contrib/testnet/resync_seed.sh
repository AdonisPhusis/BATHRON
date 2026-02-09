#!/bin/bash
# resync_seed.sh - Resync Seed node from canonical chain (MN network)
#
# SITUATION: Seed is behind or on wrong chain
# SOLUTION: Stop, wipe consensus data, restart with MN peers, wait for sync

set -e

SSH_KEY="$HOME/.ssh/id_ed25519_vps"
SSH_OPTS="-o StrictHostKeyChecking=no -o ConnectTimeout=10"
SSH="ssh -i $SSH_KEY $SSH_OPTS"
SEED_IP="57.131.33.151"
REFERENCE_MN="162.19.251.75"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log() { echo -e "${YELLOW}[INFO]${NC} $1"; }
success() { echo -e "${GREEN}[OK]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; }

echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║  Resync Seed Node from MN Network                            ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""

# Get canonical height from reference MN
log "Getting canonical height from Core+SDK..."
CANONICAL_HEIGHT=$($SSH ubuntu@$REFERENCE_MN '~/bathron-cli -testnet getblockcount 2>/dev/null' || echo "ERROR")
if [[ "$CANONICAL_HEIGHT" == "ERROR" ]]; then
    error "Cannot reach reference MN!"
    exit 1
fi
echo "  Canonical height: $CANONICAL_HEIGHT"
success "Reference obtained"
echo ""

# Stop Seed
log "Stopping Seed daemon..."
$SSH ubuntu@$SEED_IP '
    ~/BATHRON-Core/src/bathron-cli -testnet stop 2>/dev/null || true
    sleep 5
    pkill -9 bathrond 2>/dev/null || true
    sleep 2
    echo "  Stopped"
'
success "Seed stopped"
echo ""

# Wipe consensus data
log "Wiping Seed consensus data..."
$SSH ubuntu@$SEED_IP '
    DAT=~/.bathron/testnet5
    
    echo "  Removing consensus directories..."
    rm -rf $DAT/blocks $DAT/chainstate $DAT/index
    rm -rf $DAT/evodb $DAT/llmq $DAT/settlementdb
    rm -rf $DAT/btcspv $DAT/hu_finality $DAT/khu
    rm -rf $DAT/sporks $DAT/database
    
    echo "  Removing network artifacts..."
    rm -f $DAT/peers.dat $DAT/banlist.dat $DAT/mempool.dat
    rm -f $DAT/mncache.dat $DAT/mnmetacache.dat
    rm -f $DAT/.lock
    
    echo "  Done"
'
success "Seed wiped"
echo ""

# Ensure addnode entries exist
log "Configuring peer connections..."
$SSH ubuntu@$SEED_IP '
    CONF=~/.bathron/bathron.conf
    
    for MN_IP in 162.19.251.75 57.131.33.152 57.131.33.214 51.75.31.44; do
        if ! grep -q "^addnode=$MN_IP:27171" $CONF 2>/dev/null; then
            echo "addnode=$MN_IP:27171" >> $CONF
            echo "  Added $MN_IP"
        fi
    done
'
success "Peers configured"
echo ""

# Restart Seed
log "Restarting Seed daemon..."
$SSH ubuntu@$SEED_IP '
    rm -f ~/.bathron/testnet5/.lock
    ~/BATHRON-Core/src/bathrond -testnet -daemon
    sleep 5
    echo "  Started"
'
success "Seed restarted"
echo ""

# Wait for sync
log "Waiting for sync (target: $CANONICAL_HEIGHT)..."
MAX_WAIT=180
ELAPSED=0
INTERVAL=10

while [ $ELAPSED -lt $MAX_WAIT ]; do
    SEED_HEIGHT=$($SSH ubuntu@$SEED_IP '~/BATHRON-Core/src/bathron-cli -testnet getblockcount 2>/dev/null' || echo "0")
    SEED_PEERS=$($SSH ubuntu@$SEED_IP '~/BATHRON-Core/src/bathron-cli -testnet getconnectioncount 2>/dev/null' || echo "0")
    
    echo "  [${ELAPSED}s] height=$SEED_HEIGHT peers=$SEED_PEERS (target=$CANONICAL_HEIGHT)"
    
    # Check if within 10 blocks of canonical height
    if [ "$SEED_HEIGHT" -ge $((CANONICAL_HEIGHT - 10)) ] 2>/dev/null; then
        success "Seed synced to height $SEED_HEIGHT"
        break
    fi
    
    sleep $INTERVAL
    ELAPSED=$((ELAPSED + INTERVAL))
done

echo ""
if [ $ELAPSED -ge $MAX_WAIT ]; then
    error "Sync timeout after ${MAX_WAIT}s"
    error "Current height: $SEED_HEIGHT / Target: $CANONICAL_HEIGHT"
    exit 1
fi

# Final verification
sleep 5
FINAL_HEIGHT=$($SSH ubuntu@$SEED_IP '~/BATHRON-Core/src/bathron-cli -testnet getblockcount 2>/dev/null' || echo "0")
FINAL_PEERS=$($SSH ubuntu@$SEED_IP '~/BATHRON-Core/src/bathron-cli -testnet getconnectioncount 2>/dev/null' || echo "0")

echo ""
success "═══════════════════════════════════════════════════════════════"
success " Seed resync complete!"
success "   Height: $FINAL_HEIGHT"
success "   Peers:  $FINAL_PEERS"
success "═══════════════════════════════════════════════════════════════"
echo ""
