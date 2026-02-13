#!/bin/bash
# Get the actual 400 error message from server logs

set -e

SSH_KEY="$HOME/.ssh/id_ed25519_vps"
SSH_OPTS="-o StrictHostKeyChecking=no -o ConnectTimeout=10"
SSH="ssh -i $SSH_KEY $SSH_OPTS"

BLUE='\033[0;34m'; RED='\033[0;31m'; NC='\033[0m'

echo -e "${RED}=== Detailed 400 error for fs_59f554fb4eef4dbd ===${NC}\n"

# Get the actual error response body + surrounding log context
$SSH ubuntu@57.131.33.152 "grep -E '(fs_59f554fb4eef4dbd.*usdc-funded|400|HTTPException|Invalid|mismatch|not found)' /tmp/pna-sdk.log 2>/dev/null | grep -A 5 -B 5 'usdc-funded' | tail -100"

echo ""
echo -e "${BLUE}=== Checking swap state at time of 400 error ===${NC}"
echo "Swap was in state: awaiting_usdc (from DB)"
echo "HTLC ID provided: 0xc6fa72a227b2ddd15a60290649be9667f23b4f06d97884f10688fb1a6263c90a"
echo ""
echo "Possible 400 causes based on code:"
echo "1. HTLC not found on-chain (most likely)"
echo "2. HTLC status not 'active'"
echo "3. Wrong token (not USDC)"
echo "4. Amount mismatch"
echo "5. Recipient mismatch"
echo "6. Hashlock mismatch (H_user, H_lp1, H_lp2)"
echo "7. Timelock too short (< 1800s)"
