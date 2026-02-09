#!/bin/bash
# fix_seed_fork.sh - Fix Seed fork by wiping and resyncing from MN nodes
#
# SITUATION: Seed is on wrong chain (4a319a32...), MNs are on correct chain (115bf0c8...)
# SOLUTION: Wipe Seed consensus state, let it resync from MN network
#
# After Seed is fixed, also restart OP3 to complete network recovery.

set -e

SSH="ssh -i ~/.ssh/id_ed25519_vps -o StrictHostKeyChecking=no -o ConnectTimeout=15"
SEED_IP="57.131.33.151"
OP3_IP="51.75.31.44"
REFERENCE_MN="162.19.251.75"  # Core+SDK - reference for canonical chain

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log() { echo -e "${YELLOW}[INFO]${NC} $1"; }
success() { echo -e "${GREEN}[OK]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; }

echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║  Fix Seed Fork - Wipe + Resync from MN Network               ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""

# ==============================================================================
# STEP 1: Get reference h56 from Core+SDK (canonical chain)
# ==============================================================================
log "STEP 1: Getting canonical h56 from Core+SDK MN..."

CANONICAL_H56=$($SSH ubuntu@$REFERENCE_MN '~/bathron-cli -testnet getblockhash 56 2>/dev/null' 2>/dev/null || echo "ERROR")
CANONICAL_HEIGHT=$($SSH ubuntu@$REFERENCE_MN '~/bathron-cli -testnet getblockcount 2>/dev/null' 2>/dev/null || echo "ERROR")

if [[ "$CANONICAL_H56" == "ERROR" ]]; then
    error "Cannot get canonical chain from Core+SDK!"
    exit 1
fi

echo "  Canonical h56: ${CANONICAL_H56:0:16}..."
echo "  Canonical height: $CANONICAL_HEIGHT"
success "Reference obtained ✓"
echo ""

# ==============================================================================
# STEP 2: Stop Seed daemon
# ==============================================================================
log "STEP 2: Stopping Seed daemon..."

$SSH ubuntu@$SEED_IP '
    echo "  Attempting graceful stop..."
    ~/BATHRON-Core/src/bathron-cli -testnet stop 2>/dev/null || true
    sleep 3

    echo "  Force killing..."
    pkill -9 -f bathrond 2>/dev/null || true
    sleep 2

    if pgrep bathrond >/dev/null 2>&1; then
        echo "ERROR: bathrond still running!"
        exit 1
    fi
    echo "  OK: Seed daemon stopped"
' 2>/dev/null

success "Seed stopped ✓"
echo ""

# ==============================================================================
# STEP 3: Wipe Seed consensus state
# ==============================================================================
log "STEP 3: Wiping Seed consensus state..."

$SSH ubuntu@$SEED_IP '
    DAT=~/.bathron/testnet5

    rm -f $DAT/.lock

    echo "  Wiping consensus directories..."
    rm -rf $DAT/blocks
    rm -rf $DAT/chainstate
    rm -rf $DAT/index
    rm -rf $DAT/evodb
    rm -rf $DAT/llmq
    rm -rf $DAT/settlement
    rm -rf $DAT/settlementdb
    rm -rf $DAT/btcspv
    rm -rf $DAT/hu_finality
    rm -rf $DAT/khu
    rm -rf $DAT/sporks
    rm -rf $DAT/database
    rm -rf $DAT/wallets
    rm -rf $DAT/backups

    echo "  Wiping networking artifacts..."
    rm -f $DAT/peers.dat
    rm -f $DAT/banlist.dat
    rm -f $DAT/mempool.dat
    rm -f $DAT/mncache.dat
    rm -f $DAT/mnmetacache.dat
    rm -f $DAT/*.log

    echo "  After wipe:"
    ls -la $DAT/ 2>/dev/null | head -10
' 2>/dev/null

success "Seed wiped ✓"
echo ""

# ==============================================================================
# STEP 4: Restart Seed with addnode to MNs
# ==============================================================================
log "STEP 4: Restarting Seed daemon..."

$SSH ubuntu@$SEED_IP '
    CONF=~/.bathron/bathron.conf

    # Ensure connections to all MN nodes
    for MN_IP in 162.19.251.75 57.131.33.152 57.131.33.214 51.75.31.44; do
        if ! grep -q "^addnode=$MN_IP:27171" $CONF 2>/dev/null; then
            echo "addnode=$MN_IP:27171" >> $CONF
        fi
    done

    rm -f ~/.bathron/testnet5/.lock
    ~/BATHRON-Core/src/bathrond -testnet -daemon
    sleep 3

    echo "  Seed height: $(~/BATHRON-Core/src/bathron-cli -testnet getblockcount 2>/dev/null || echo starting)"
    echo "  Seed peers:  $(~/BATHRON-Core/src/bathron-cli -testnet getconnectioncount 2>/dev/null || echo starting)"
' 2>/dev/null

success "Seed restarted ✓"
echo ""

# ==============================================================================
# STEP 5: Wait for Seed to sync to canonical chain
# ==============================================================================
log "STEP 5: Waiting for Seed to sync..."

MAX_WAIT=120
WAIT_INTERVAL=5
ELAPSED=0

while [ $ELAPSED -lt $MAX_WAIT ]; do
    SEED_HEIGHT=$($SSH ubuntu@$SEED_IP '~/BATHRON-Core/src/bathron-cli -testnet getblockcount 2>/dev/null' 2>/dev/null || echo "0")
    SEED_PEERS=$($SSH ubuntu@$SEED_IP '~/BATHRON-Core/src/bathron-cli -testnet getconnectioncount 2>/dev/null' 2>/dev/null || echo "0")

    echo "  [$ELAPSED s] Seed height=$SEED_HEIGHT, peers=$SEED_PEERS"

    if [ "$SEED_HEIGHT" -ge 56 ] 2>/dev/null; then
        break
    fi

    sleep $WAIT_INTERVAL
    ELAPSED=$((ELAPSED + WAIT_INTERVAL))
done

# Verify Seed h56
SEED_H56=$($SSH ubuntu@$SEED_IP '~/BATHRON-Core/src/bathron-cli -testnet getblockhash 56 2>/dev/null' 2>/dev/null || echo "NA")

echo ""
echo "  Canonical h56: ${CANONICAL_H56:0:16}..."
echo "  Seed h56:      ${SEED_H56:0:16}..."

if [[ "$SEED_H56" == "$CANONICAL_H56" ]]; then
    success "Seed is now on canonical chain ✓"
else
    error "Seed h56 does not match canonical chain!"
    error "Manual intervention required."
    exit 1
fi
echo ""

# ==============================================================================
# STEP 6: Start OP3 (if offline)
# ==============================================================================
log "STEP 6: Checking and starting OP3..."

OP3_RUNNING=$($SSH ubuntu@$OP3_IP 'pgrep bathrond | wc -l' 2>/dev/null || echo "0")

if [ "$OP3_RUNNING" = "0" ]; then
    log "  OP3 is offline, wiping and starting..."

    $SSH ubuntu@$OP3_IP '
        DAT=~/.bathron/testnet5

        # Wipe consensus state
        rm -rf $DAT/blocks $DAT/chainstate $DAT/index
        rm -rf $DAT/evodb $DAT/llmq $DAT/settlement $DAT/settlementdb
        rm -rf $DAT/btcspv $DAT/hu_finality $DAT/khu
        rm -rf $DAT/sporks $DAT/database $DAT/wallets $DAT/backups
        rm -f $DAT/peers.dat $DAT/banlist.dat $DAT/mempool.dat
        rm -f $DAT/*.log $DAT/.lock

        # Ensure SPV off
        CONF=~/.bathron/bathron.conf
        sed -i "s/^btcspv=.*/btcspv=0/" $CONF 2>/dev/null || true
        if ! grep -q "^btcspv=" $CONF; then echo "btcspv=0" >> $CONF; fi

        # Start
        ~/bathrond -testnet -daemon
        sleep 3
        echo "  OP3 started: height=$(~/bathron-cli -testnet getblockcount 2>/dev/null || echo starting)"
    ' 2>/dev/null

    success "OP3 started ✓"
else
    echo "  OP3 already running with $OP3_RUNNING processes"
fi
echo ""

# ==============================================================================
# FINAL: Show network status
# ==============================================================================
log "FINAL: Network status after fix..."
sleep 10  # Give nodes time to connect

echo ""
for IP in 57.131.33.151 162.19.251.75 57.131.33.152 57.131.33.214 51.75.31.44; do
    NAME=""
    case $IP in
        57.131.33.151) NAME="Seed" ;;
        162.19.251.75) NAME="Core+SDK" ;;
        57.131.33.152) NAME="OP1" ;;
        57.131.33.214) NAME="OP2" ;;
        51.75.31.44) NAME="OP3" ;;
    esac

    RESULT=$($SSH ubuntu@$IP '
        if [ -x ~/BATHRON-Core/src/bathron-cli ]; then CLI=~/BATHRON-Core/src/bathron-cli; else CLI=~/bathron-cli; fi
        COUNT=$(pgrep bathrond | wc -l)
        if [ "$COUNT" = "0" ]; then
            echo "OFFLINE"
        else
            H=$($CLI -testnet getblockcount 2>/dev/null || echo "?")
            H56=$($CLI -testnet getblockhash 56 2>/dev/null | cut -c1-12 || echo "?")
            P=$($CLI -testnet getconnectioncount 2>/dev/null || echo "?")
            echo "h=$H h56=$H56 p=$P"
        fi
    ' 2>/dev/null || echo "SSH_FAIL")

    printf "  %-10s %-17s : %s\n" "$NAME" "($IP)" "$RESULT"
done

echo ""
success "═══════════════════════════════════════════════════════════════"
success " Network recovery complete!"
success " All nodes should now show h56=115bf0c8..."
success "═══════════════════════════════════════════════════════════════"
echo ""
