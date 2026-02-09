#!/bin/bash
# sync_seed_from_sdk.sh - Copy full BATHRON state from SDK to Seed
#
# Problem: Seed was wiped and can't sync due to checkpoint validation added after
#          other nodes synced. The btcheadersdb starts at h=286000, but checkpoint
#          code requires h=200000 and h=280000 which don't exist.
#
# Solution: Copy entire validated state from SDK (which synced before the check was added)

set -e

SSH_KEY="$HOME/.ssh/id_ed25519_vps"
SSH_OPTS="-o StrictHostKeyChecking=no -o ConnectTimeout=10"
SSH="ssh -i $SSH_KEY $SSH_OPTS"
SCP="scp -i $SSH_KEY $SSH_OPTS"

SEED_IP="57.131.33.151"
SDK_IP="162.19.251.75"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log() { echo -e "${YELLOW}[INFO]${NC} $1"; }
success() { echo -e "${GREEN}[OK]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; }

echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║  Sync Seed State from SDK                                    ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""

# Step 1: Check SDK health
log "Verifying SDK health..."
SDK_HEIGHT=$($SSH ubuntu@$SDK_IP '~/bathron-cli -testnet getblockcount 2>/dev/null' || echo "0")
SDK_PEERS=$($SSH ubuntu@$SDK_IP '~/bathron-cli -testnet getconnectioncount 2>/dev/null' || echo "0")
echo "  SDK height: $SDK_HEIGHT, peers: $SDK_PEERS"
if [ "$SDK_HEIGHT" -lt 100 ]; then
    error "SDK appears unhealthy (height=$SDK_HEIGHT)"
    exit 1
fi
success "SDK healthy"
echo ""

# Step 2: Stop both daemons
log "Stopping SDK daemon (for consistent snapshot)..."
$SSH ubuntu@$SDK_IP '
    ~/bathron-cli -testnet stop 2>/dev/null || true
    sleep 5
    pkill -9 bathrond 2>/dev/null || true
    rm -f ~/.bathron/testnet5/.lock
'
success "SDK stopped"

log "Stopping Seed daemon..."
$SSH ubuntu@$SEED_IP '
    ~/BATHRON-Core/src/bathron-cli -testnet stop 2>/dev/null || true
    sleep 3
    pkill -9 bathrond 2>/dev/null || true
    rm -f ~/.bathron/testnet5/.lock
'
success "Seed stopped"
echo ""

# Step 3: Create snapshot on SDK
log "Creating state snapshot on SDK..."
$SSH ubuntu@$SDK_IP '
    cd ~/.bathron/testnet5

    # Archive consensus-critical directories
    tar -czf /tmp/bathron_state.tar.gz \
        blocks/ \
        chainstate/ \
        evodb/ \
        llmq/ \
        settlementdb/ \
        btcheadersdb/ \
        burnclaimdb/ \
        hu_finality/ \
        2>/dev/null || true

    ls -lh /tmp/bathron_state.tar.gz
'
success "Snapshot created"
echo ""

# Step 4: Transfer snapshot SDK -> Local -> Seed
log "Transferring snapshot to Seed (via local relay)..."
echo "  Downloading from SDK..."
$SCP ubuntu@$SDK_IP:/tmp/bathron_state.tar.gz /tmp/bathron_state.tar.gz
ls -lh /tmp/bathron_state.tar.gz

echo "  Uploading to Seed..."
$SCP /tmp/bathron_state.tar.gz ubuntu@$SEED_IP:/tmp/bathron_state.tar.gz

# Cleanup local and SDK
rm -f /tmp/bathron_state.tar.gz
$SSH ubuntu@$SDK_IP 'rm -f /tmp/bathron_state.tar.gz'
success "Transfer complete"
echo ""

# Step 5: Extract on Seed
log "Extracting state on Seed..."
$SSH ubuntu@$SEED_IP '
    DAT=~/.bathron/testnet5

    # Wipe old state
    rm -rf $DAT/blocks $DAT/chainstate $DAT/index
    rm -rf $DAT/evodb $DAT/llmq $DAT/settlementdb
    rm -rf $DAT/btcheadersdb $DAT/burnclaimdb
    rm -rf $DAT/hu_finality $DAT/khu $DAT/sporks $DAT/database
    rm -f $DAT/peers.dat $DAT/banlist.dat $DAT/mempool.dat
    rm -f $DAT/mncache.dat $DAT/mnmetacache.dat

    # Extract new state
    cd $DAT
    tar -xzf /tmp/bathron_state.tar.gz
    rm -f /tmp/bathron_state.tar.gz

    echo "  Extracted directories:"
    ls -la | grep "^d"
'
success "State extracted"
echo ""

# Step 6: Restart SDK first
log "Restarting SDK..."
$SSH ubuntu@$SDK_IP '
    rm -f ~/.bathron/testnet5/.lock
    ~/bathrond -testnet -daemon
    sleep 5
'
SDK_NEW_HEIGHT=$($SSH ubuntu@$SDK_IP '~/bathron-cli -testnet getblockcount 2>/dev/null' || echo "0")
echo "  SDK height: $SDK_NEW_HEIGHT"
success "SDK restarted"
echo ""

# Step 7: Restart Seed
log "Restarting Seed..."
$SSH ubuntu@$SEED_IP '
    rm -f ~/.bathron/testnet5/.lock
    ~/BATHRON-Core/src/bathrond -testnet -daemon
    sleep 5
'
success "Seed restarted"
echo ""

# Step 8: Wait for Seed to come up
log "Waiting for Seed to initialize..."
for i in {1..30}; do
    SEED_HEIGHT=$($SSH ubuntu@$SEED_IP '~/BATHRON-Core/src/bathron-cli -testnet getblockcount 2>/dev/null' || echo "0")
    SEED_PEERS=$($SSH ubuntu@$SEED_IP '~/BATHRON-Core/src/bathron-cli -testnet getconnectioncount 2>/dev/null' || echo "0")

    echo "  [${i}0s] height=$SEED_HEIGHT peers=$SEED_PEERS"

    if [ "$SEED_HEIGHT" -gt 100 ]; then
        success "Seed synced at height $SEED_HEIGHT!"
        break
    fi

    sleep 10
done

echo ""
success "═══════════════════════════════════════════════════════════════"
success " Seed sync from SDK complete!"
success "   Seed height: $SEED_HEIGHT"
success "   Seed peers:  $SEED_PEERS"
success "═══════════════════════════════════════════════════════════════"
echo ""
