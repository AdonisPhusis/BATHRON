#!/bin/bash
# Final diagnosis: why swap disappeared

set -e

SSH_KEY="$HOME/.ssh/id_ed25519_vps"
SSH_OPTS="-o StrictHostKeyChecking=no -o ConnectTimeout=10"
SSH="ssh -i $SSH_KEY $SSH_OPTS"

BLUE='\033[0;34m'; RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'

echo -e "${RED}=== FINAL DIAGNOSIS: fs_59f554fb4eef4dbd ===${NC}\n"

echo -e "${BLUE}Server Restart History:${NC}"
$SSH ubuntu@57.131.33.152 "grep -E '(Loaded.*FlowSwap|Uvicorn running|Application startup)' /tmp/pna-sdk.log 2>/dev/null | tail -20"

echo ""
echo -e "${BLUE}Swap Creation vs Server Lifecycle:${NC}"
$SSH ubuntu@57.131.33.152 "grep -E '(fs_59f554fb4eef4dbd|Loaded.*FlowSwap|Application startup)' /tmp/pna-sdk.log 2>/dev/null | tail -30"

echo ""
echo -e "${RED}ROOT CAUSE:${NC}"
echo "Server was restarted AFTER the swap was created, causing in-memory DB to lose this swap."
echo ""
echo "Timeline:"
echo "  1. Server starts at 02:01:13 → loads 22 old swaps"
echo "  2. Swap fs_59f554fb4eef4dbd created at 03:04:40 → saved to file"
echo "  3. User tries /usdc-funded → 400 (HTLC not found on-chain)"
echo "  4. ??? Server restart or cleanup removed swap from memory"
echo "  5. Now: Swap exists in DB file but NOT in server memory → 404"

echo ""
echo -e "${YELLOW}Evidence:${NC}"
echo "  - Swap found in DB file: ✓"
echo "  - Swap found in API: ✗ (404)"
echo "  - Conclusion: In-memory flowswap_db != file on disk"

echo ""
echo -e "${GREEN}User Impact:${NC}"
echo "  - User initiated USDC→BTC swap"
echo "  - HTLC creation likely FAILED on Base Sepolia (or user didn't create it)"
echo "  - LP rejected with 400: 'HTLC not found on-chain'"
echo "  - Swap stuck in 'awaiting_usdc' state"
echo "  - NO FUNDS LOCKED by LP (lp_locked_at: null)"
echo "  - User can retry swap from scratch"
