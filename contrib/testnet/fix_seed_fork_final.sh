#!/bin/bash
# fix_seed_fork_final.sh - Fix Seed fork by syncing without MN mode

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
    echo -e "${YELLOW}=== Seed Fork Issue ===${NC}"
    echo ""
    echo "Problem: Seed is on wrong chain (forked at 528) with finality preventing reorg"
    echo "Solution: Sync without MN mode (no finality), then re-enable MNs"
    echo ""
    echo "Usage: $0 fix"
    exit 1
fi

echo -e "${YELLOW}=== Fixing Seed Fork ===${NC}"
echo ""

echo -e "${GREEN}Step 1: Stop daemon${NC}"
$SSH ubuntu@$SEED_IP "$SEED_CLI stop" 2>/dev/null || echo "Already stopped"
sleep 5

echo ""
echo -e "${GREEN}Step 2: Backup MN config and disable MNs${NC}"
$SSH ubuntu@$SEED_IP << 'REMOTE'
# Backup bathron.conf
cp ~/.bathron/bathron.conf ~/.bathron/bathron.conf.mn_backup

# Disable masternode mode temporarily
sed -i 's/^masternode=1/masternode=0/' ~/.bathron/bathron.conf
sed -i 's/^mnoperatorprivatekey=/#mnoperatorprivatekey=/' ~/.bathron/bathron.conf

echo "MN mode disabled"
cat ~/.bathron/bathron.conf | grep -E "^(masternode|mnoperator)" || echo "No active MN config"
REMOTE

echo ""
echo -e "${GREEN}Step 3: Wipe everything and resync as regular node${NC}"
$SSH ubuntu@$SEED_IP << 'REMOTE'
DAT=~/.bathron/testnet5
rm -rf $DAT/blocks $DAT/chainstate $DAT/index
rm -rf $DAT/evodb $DAT/llmq $DAT/settlementdb
rm -rf $DAT/burnclaimdb $DAT/btcheadersdb $DAT/btcspv
rm -rf $DAT/hu_finality $DAT/khu $DAT/finality $DAT/sporks
rm -f $DAT/peers.dat $DAT/banlist.dat $DAT/mempool.dat
rm -f $DAT/mncache.dat $DAT/mnmetacache.dat $DAT/.lock
echo "Wipe complete"
REMOTE

echo ""
echo -e "${GREEN}Step 4: Start daemon (non-MN mode)${NC}"
$SSH ubuntu@$SEED_IP "$SEED_DAEMON -testnet -daemon"

echo ""
echo -e "${YELLOW}Waiting for sync to complete...${NC}"
echo "This may take several minutes. Monitoring every 10s..."
echo ""

for i in {1..60}; do
    HEIGHT=$($SSH ubuntu@$SEED_IP "$SEED_CLI getblockcount 2>/dev/null" || echo "0")
    PEERS=$($SSH ubuntu@$SEED_IP "$SEED_CLI getconnectioncount 2>/dev/null" || echo "0")
    echo "[$i/60] Seed: height=$HEIGHT, peers=$PEERS (target: 12618)"
    
    if [ "$HEIGHT" -ge "12618" ]; then
        echo ""
        echo -e "${GREEN}Sync complete!${NC}"
        break
    fi
    
    sleep 10
done

echo ""
echo -e "${GREEN}Step 5: Verify sync${NC}"
FINAL_HEIGHT=$($SSH ubuntu@$SEED_IP "$SEED_CLI getblockcount 2>/dev/null" || echo "0")
if [ "$FINAL_HEIGHT" -ge "12618" ]; then
    echo -e "${GREEN}SUCCESS: Seed synced to height $FINAL_HEIGHT${NC}"
    echo ""
    echo -e "${YELLOW}Step 6: Re-enable MN mode${NC}"
    $SSH ubuntu@$SEED_IP << 'REMOTE'
# Restore MN config
cp ~/.bathron/bathron.conf.mn_backup ~/.bathron/bathron.conf
echo "MN config restored"
REMOTE
    
    echo ""
    echo -e "${GREEN}Step 7: Restart with MN mode${NC}"
    $SSH ubuntu@$SEED_IP "$SEED_CLI stop"
    sleep 5
    $SSH ubuntu@$SEED_IP "$SEED_DAEMON -testnet -daemon"
    sleep 10
    
    echo ""
    echo -e "${GREEN}=== Fix Complete ===${NC}"
    echo ""
    echo "Verify with: ./contrib/testnet/deploy_to_vps.sh --status"
else
    echo -e "${RED}FAILED: Seed only reached height $FINAL_HEIGHT${NC}"
    echo "Check logs with: ./contrib/testnet/check_seed_daemon.sh"
fi
