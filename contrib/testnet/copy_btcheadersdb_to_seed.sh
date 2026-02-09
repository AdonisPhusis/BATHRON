#!/bin/bash
# copy_btcheadersdb_to_seed.sh - Copy btcheadersdb from Core+SDK to Seed
#
# Problem: Seed has truncated btcheadersdb starting at 286000
# Solution: Copy complete btcheadersdb from SDK which has all headers

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
echo "║  Copy btcheadersdb from SDK to Seed                          ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""

# Step 1: Check SDK btcheadersdb
log "Checking SDK btcheadersdb..."
SDK_HEIGHT=$($SSH ubuntu@$SDK_IP '~/bathron-cli -testnet getbtcheaderstip 2>/dev/null | jq -r ".height"' || echo "0")
echo "  SDK btcheadersdb height: $SDK_HEIGHT"
if [ "$SDK_HEIGHT" -lt 200000 ]; then
    error "SDK btcheadersdb seems incomplete (height=$SDK_HEIGHT)"
    exit 1
fi
success "SDK btcheadersdb verified"
echo ""

# Step 2: Stop Seed daemon
log "Stopping Seed daemon..."
$SSH ubuntu@$SEED_IP '
    ~/BATHRON-Core/src/bathron-cli -testnet stop 2>/dev/null || true
    sleep 3
    pkill -9 bathrond 2>/dev/null || true
    rm -f ~/.bathron/testnet5/.lock
    echo "  Stopped"
'
success "Seed stopped"
echo ""

# Step 3: Create tarball on SDK
log "Creating btcheadersdb tarball on SDK..."
$SSH ubuntu@$SDK_IP '
    cd ~/.bathron/testnet5
    tar -czf /tmp/btcheadersdb.tar.gz btcheadersdb/
    ls -lh /tmp/btcheadersdb.tar.gz
'
success "Tarball created"
echo ""

# Step 4: Transfer tarball SDK -> Seed via local relay
log "Transferring btcheadersdb to Seed (via local relay)..."
$SCP ubuntu@$SDK_IP:/tmp/btcheadersdb.tar.gz /tmp/btcheadersdb.tar.gz
ls -lh /tmp/btcheadersdb.tar.gz
$SCP /tmp/btcheadersdb.tar.gz ubuntu@$SEED_IP:/tmp/btcheadersdb.tar.gz
rm -f /tmp/btcheadersdb.tar.gz
success "Transfer complete"
echo ""

# Step 5: Extract on Seed
log "Extracting btcheadersdb on Seed..."
$SSH ubuntu@$SEED_IP '
    rm -rf ~/.bathron/testnet5/btcheadersdb
    cd ~/.bathron/testnet5
    tar -xzf /tmp/btcheadersdb.tar.gz
    rm -f /tmp/btcheadersdb.tar.gz
    ls -la btcheadersdb/ | head -5
'
success "Extracted"
echo ""

# Step 6: Also wipe consensus data for clean sync
log "Wiping Seed consensus data for clean sync..."
$SSH ubuntu@$SEED_IP '
    DAT=~/.bathron/testnet5
    rm -rf $DAT/blocks $DAT/chainstate $DAT/index
    rm -rf $DAT/evodb $DAT/llmq $DAT/settlementdb
    rm -rf $DAT/hu_finality $DAT/khu $DAT/sporks $DAT/database
    rm -f $DAT/peers.dat $DAT/banlist.dat $DAT/mempool.dat
    rm -f $DAT/mncache.dat $DAT/mnmetacache.dat
    rm -f $DAT/.lock
'
success "Consensus data wiped"
echo ""

# Step 7: Restart Seed
log "Restarting Seed daemon..."
$SSH ubuntu@$SEED_IP '
    ~/BATHRON-Core/src/bathrond -testnet -daemon
    sleep 3
'
success "Seed restarted"
echo ""

# Step 8: Wait for sync
log "Waiting for Seed to sync..."
CANONICAL_HEIGHT=$($SSH ubuntu@$SDK_IP '~/bathron-cli -testnet getblockcount 2>/dev/null' || echo "5276")

for i in {1..60}; do
    SEED_HEIGHT=$($SSH ubuntu@$SEED_IP '~/BATHRON-Core/src/bathron-cli -testnet getblockcount 2>/dev/null' || echo "0")
    SEED_PEERS=$($SSH ubuntu@$SEED_IP '~/BATHRON-Core/src/bathron-cli -testnet getconnectioncount 2>/dev/null' || echo "0")

    echo "  [${i}0s] height=$SEED_HEIGHT peers=$SEED_PEERS (target=$CANONICAL_HEIGHT)"

    if [ "$SEED_HEIGHT" -ge "$((CANONICAL_HEIGHT - 5))" ] 2>/dev/null; then
        success "Seed synced!"
        break
    fi

    sleep 10
done

# Final status
echo ""
FINAL_HEIGHT=$($SSH ubuntu@$SEED_IP '~/BATHRON-Core/src/bathron-cli -testnet getblockcount 2>/dev/null' || echo "0")
FINAL_PEERS=$($SSH ubuntu@$SEED_IP '~/BATHRON-Core/src/bathron-cli -testnet getconnectioncount 2>/dev/null' || echo "0")

success "═══════════════════════════════════════════════════════════════"
success " Seed btcheadersdb copy complete!"
success "   Height: $FINAL_HEIGHT"
success "   Peers:  $FINAL_PEERS"
success "═══════════════════════════════════════════════════════════════"
echo ""
