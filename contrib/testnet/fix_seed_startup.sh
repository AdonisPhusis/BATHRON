#!/bin/bash
# fix_seed_startup.sh - Fix Seed startup issue (burn-claim-duplicate)

set -e

SSH_KEY="~/.ssh/id_ed25519_vps"
SSH_OPTS="-o StrictHostKeyChecking=no -o ConnectTimeout=10"
SSH="ssh -i $SSH_KEY $SSH_OPTS"

SEED_IP="57.131.33.151"
SEED_CLI="~/BATHRON-Core/src/bathron-cli -testnet"
SEED_DAEMON="~/BATHRON-Core/src/bathrond"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

if [ "$1" != "fix" ]; then
    echo -e "${YELLOW}=== Seed Startup Issue ===${NC}"
    echo ""
    echo "Problem: Seed daemon failed on block 12616 with 'burn-claim-duplicate'"
    echo "Solution: Complete wipe including finality DB"
    echo ""
    echo "Usage: $0 fix"
    exit 1
fi

echo -e "${YELLOW}=== Fixing Seed Startup Issue ===${NC}"
echo ""

echo -e "${GREEN}Step 1: Stop daemon${NC}"
$SSH ubuntu@$SEED_IP "$SEED_CLI stop" 2>/dev/null || echo "Daemon already stopped"
sleep 5

echo ""
echo -e "${GREEN}Step 2: Complete wipe (all consensus + finality)${NC}"
$SSH ubuntu@$SEED_IP << 'REMOTE'
set -x
DAT=~/.bathron/testnet5

# Wipe ALL consensus and finality databases
rm -rf $DAT/blocks $DAT/chainstate $DAT/index
rm -rf $DAT/evodb $DAT/llmq $DAT/settlementdb
rm -rf $DAT/burnclaimdb $DAT/btcheadersdb
rm -rf $DAT/btcspv
rm -rf $DAT/hu_finality $DAT/khu
rm -rf $DAT/finality  # CDBWrapper finality storage
rm -rf $DAT/sporks    # For good measure

# Wipe networking
rm -f $DAT/peers.dat $DAT/banlist.dat $DAT/mempool.dat
rm -f $DAT/mncache.dat $DAT/mnmetacache.dat

# Remove lock
rm -f $DAT/.lock

echo "Complete wipe done"
REMOTE

echo ""
echo -e "${GREEN}Step 3: Restart daemon${NC}"
$SSH ubuntu@$SEED_IP "$SEED_DAEMON -testnet -daemon"

echo ""
echo -e "${YELLOW}Waiting 15s for startup...${NC}"
sleep 15

echo ""
echo -e "${GREEN}Step 4: Check status${NC}"
$SSH ubuntu@$SEED_IP "$SEED_CLI getblockcount" 2>&1 || echo "Still starting..."
$SSH ubuntu@$SEED_IP "$SEED_CLI getconnectioncount" 2>&1 || echo "Still starting..."
$SSH ubuntu@$SEED_IP "$SEED_CLI getfinalitystatus" 2>&1 | grep -E "last_finalized_height|tip_height" || echo "Still starting..."

echo ""
echo -e "${GREEN}=== Fix Applied ===${NC}"
echo ""
echo "Monitor sync with:"
echo "  ./contrib/testnet/deploy_to_vps.sh --status"
