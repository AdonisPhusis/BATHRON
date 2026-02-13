#!/bin/bash
# reenable_seed_mns.sh - Re-enable masternodes on Seed after sync

set -e

SSH_KEY="~/.ssh/id_ed25519_vps"
SSH_OPTS="-o StrictHostKeyChecking=no -o ConnectTimeout=10"
SSH="ssh -i $SSH_KEY $SSH_OPTS"

SEED_IP="57.131.33.151"
SEED_CLI="~/BATHRON-Core/src/bathron-cli -testnet"
SEED_DAEMON="~/BATHRON-Core/src/bathrond"

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo -e "${YELLOW}=== Re-enabling Seed Masternodes ===${NC}"
echo ""

echo -e "${GREEN}Step 1: Verify sync${NC}"
HEIGHT=$($SSH ubuntu@$SEED_IP "$SEED_CLI getblockcount 2>/dev/null")
echo "Current height: $HEIGHT"

if [ "$HEIGHT" -lt "12618" ]; then
    echo "ERROR: Seed not fully synced (height=$HEIGHT, expected>=12618)"
    exit 1
fi

echo ""
echo -e "${GREEN}Step 2: Stop daemon${NC}"
$SSH ubuntu@$SEED_IP "$SEED_CLI stop"
sleep 5

echo ""
echo -e "${GREEN}Step 3: Restore MN configuration${NC}"
$SSH ubuntu@$SEED_IP << 'REMOTE'
# Restore from backup
if [ -f ~/.bathron/bathron.conf.mn_backup ]; then
    cp ~/.bathron/bathron.conf.mn_backup ~/.bathron/bathron.conf
    echo "MN config restored from backup"
else
    # Fallback: restore manually
    sed -i 's/^masternode=0/masternode=1/' ~/.bathron/bathron.conf
    sed -i 's/^#mnoperatorprivatekey=/mnoperatorprivatekey=/' ~/.bathron/bathron.conf
    echo "MN config restored (fallback method)"
fi

echo ""
echo "Active MN config:"
grep -E "^(masternode|mnoperator)" ~/.bathron/bathron.conf | head -10
REMOTE

echo ""
echo -e "${GREEN}Step 4: Restart with MN mode${NC}"
$SSH ubuntu@$SEED_IP "$SEED_DAEMON -testnet -daemon"
sleep 10

echo ""
echo -e "${GREEN}Step 5: Verify MN status${NC}"
$SSH ubuntu@$SEED_IP "$SEED_CLI getblockcount" 2>&1
$SSH ubuntu@$SEED_IP "$SEED_CLI getconnectioncount" 2>&1
$SSH ubuntu@$SEED_IP "$SEED_CLI listmasternodes | grep ENABLED | wc -l" 2>&1 | sed 's/^/Enabled MNs: /'

echo ""
echo -e "${GREEN}=== Masternodes Re-enabled ===${NC}"
echo ""
echo "Monitor block production resumption with:"
echo "  watch -n5 './contrib/testnet/deploy_to_vps.sh --status'"
