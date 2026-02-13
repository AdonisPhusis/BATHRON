#!/bin/bash
# =============================================================================
# search_swap_details.sh - Search for specific swap in LP logs
# =============================================================================

set -e

SSH_KEY="$HOME/.ssh/id_ed25519_vps"
SSH_OPTS="-o StrictHostKeyChecking=no -o ConnectTimeout=10"
SSH="ssh -i $SSH_KEY $SSH_OPTS"

# Colors
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'

DEST_ADDR="${1:-tb1q0dgtuh26}"
AMOUNT="${2:-0.00029503}"

echo -e "${BLUE}=== Searching for swap: dest=${DEST_ADDR}*, amount=${AMOUNT} ===${NC}\n"

echo -e "${BLUE}--- LP1 (OP1 - 57.131.33.152) ---${NC}"
$SSH ubuntu@57.131.33.152 "tail -2000 /tmp/pna-sdk.log 2>/dev/null | grep -E '(${DEST_ADDR}|${AMOUNT}|USDC.*BTC|FlowSwap|swap_id|fs_|BTC_dest|destination)' -i || echo 'No matches found in LP1 logs'"

echo ""
echo -e "${BLUE}--- LP2 (OP2 - 57.131.33.214) ---${NC}"
$SSH ubuntu@57.131.33.214 "tail -2000 /tmp/pna-sdk.log 2>/dev/null | grep -E '(${DEST_ADDR}|${AMOUNT}|USDC.*BTC|FlowSwap|swap_id|fs_|BTC_dest|destination)' -i || echo 'No matches found in LP2 logs'"

echo ""
echo -e "${BLUE}--- Checking FlowSwap DB files ---${NC}"
echo "LP1:"
$SSH ubuntu@57.131.33.152 "ls -lh ~/.bathron/flowswap_db*.json 2>/dev/null && cat ~/.bathron/flowswap_db*.json 2>/dev/null | python3 -m json.tool | grep -E '(${DEST_ADDR}|${AMOUNT}|USDC.*BTC)' -i -A 10 -B 2 || echo 'No FlowSwap DB or no matches'"

echo ""
echo "LP2:"
$SSH ubuntu@57.131.33.214 "ls -lh ~/.bathron/flowswap_db*.json 2>/dev/null && cat ~/.bathron/flowswap_db*.json 2>/dev/null | python3 -m json.tool | grep -E '(${DEST_ADDR}|${AMOUNT}|USDC.*BTC)' -i -A 10 -B 2 || echo 'No FlowSwap DB or no matches'"
