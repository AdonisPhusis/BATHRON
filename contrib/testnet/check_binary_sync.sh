#!/bin/bash
# ==============================================================================
# check_binary_sync.sh - Verify binary deployment across testnet
# ==============================================================================
set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

VPS_NODES=(
    "57.131.33.151:Seed:BATHRON-Core"
    "162.19.251.75:Core:BATHRON-Core"
    "57.131.33.152:OP1:home"
    "57.131.33.214:OP2:home"
    "51.75.31.44:OP3:home"
)

SSH_KEY="$HOME/.ssh/id_ed25519_vps"
SSH_OPTS="-o StrictHostKeyChecking=no -o ConnectTimeout=10 -o BatchMode=yes"
SSH="ssh -i $SSH_KEY $SSH_OPTS"

# Get local binary hash
LOCAL_HASH=$(sha256sum /home/ubuntu/BATHRON/src/bathrond | awk '{print $1}')
echo -e "${BLUE}Local binary SHA256:${NC} $LOCAL_HASH"
echo ""

MISMATCH_COUNT=0
HTLC_IN_MEMPOOL=0

for node_spec in "${VPS_NODES[@]}"; do
    IFS=: read -r IP NAME PATH_TYPE <<< "$node_spec"
    
    echo -e "${YELLOW}=== $NAME ($IP) ===${NC}"
    
    # Determine binary path
    if [ "$PATH_TYPE" = "BATHRON-Core" ]; then
        REMOTE_PATH="~/BATHRON-Core/src/bathrond"
    else
        REMOTE_PATH="~/bathrond"
    fi
    
    # Get remote hash
    REMOTE_HASH=$($SSH ubuntu@$IP "sha256sum $REMOTE_PATH 2>/dev/null | awk '{print \$1}' || echo 'NOT_FOUND'")
    
    if [ "$REMOTE_HASH" = "$LOCAL_HASH" ]; then
        echo -e "${GREEN}✓ Binary synced${NC} ($REMOTE_HASH)"
    elif [ "$REMOTE_HASH" = "NOT_FOUND" ]; then
        echo -e "${RED}✗ Binary not found at $REMOTE_PATH${NC}"
        MISMATCH_COUNT=$((MISMATCH_COUNT + 1))
    else
        echo -e "${RED}✗ Binary MISMATCH${NC}"
        echo "  Remote: $REMOTE_HASH"
        echo "  Local:  $LOCAL_HASH"
        MISMATCH_COUNT=$((MISMATCH_COUNT + 1))
    fi
    
    # Check for problematic HTLC tx in mempool
    HTLC_CHECK=$($SSH ubuntu@$IP "~/bathron-cli -testnet getrawmempool 2>/dev/null | grep -i '0a72b136' || echo ''" || echo "RPC_FAILED")
    
    if [ "$HTLC_CHECK" = "RPC_FAILED" ]; then
        echo -e "${YELLOW}⚠ Could not check mempool (daemon may be stopped)${NC}"
    elif [ -z "$HTLC_CHECK" ]; then
        echo -e "${GREEN}✓ HTLC tx not in mempool${NC}"
    else
        echo -e "${RED}✗ HTLC tx STILL in mempool${NC}"
        HTLC_IN_MEMPOOL=$((HTLC_IN_MEMPOOL + 1))
    fi
    
    echo ""
done

# Summary
echo -e "${BLUE}=== SUMMARY ===${NC}"
if [ $MISMATCH_COUNT -eq 0 ]; then
    echo -e "${GREEN}✓ All nodes have matching binaries${NC}"
else
    echo -e "${RED}✗ $MISMATCH_COUNT node(s) need binary update${NC}"
    echo "  Run: ./contrib/testnet/deploy_to_vps.sh --update"
fi

if [ $HTLC_IN_MEMPOOL -eq 0 ]; then
    echo -e "${GREEN}✓ No problematic HTLC tx in any mempool${NC}"
else
    echo -e "${RED}✗ HTLC tx found in $HTLC_IN_MEMPOOL mempool(s)${NC}"
    echo "  This indicates the fix may not be active or daemon needs restart"
fi

exit $MISMATCH_COUNT
