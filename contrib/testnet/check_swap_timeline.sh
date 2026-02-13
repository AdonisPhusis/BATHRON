#!/bin/bash
# Build complete timeline of the swap

set -e

SSH_KEY="$HOME/.ssh/id_ed25519_vps"
SSH_OPTS="-o StrictHostKeyChecking=no -o ConnectTimeout=10"
SSH="ssh -i $SSH_KEY $SSH_OPTS"

BLUE='\033[0;34m'; GREEN='\033[0;32m'; RED='\033[0;31m'; NC='\033[0m'

echo -e "${BLUE}=== Complete Timeline: fs_59f554fb4eef4dbd ===${NC}\n"

echo "Swap Details:"
echo "- Direction: USDC → BTC"
echo "- Amount: 20.0 USDC → 0.00029503 BTC"
echo "- User BTC address: tb1q0dgtuh268axeypa584rxddzp3jf7p2xw6vysxg"
echo "- State: awaiting_usdc (STUCK)"
echo ""

echo -e "${GREEN}Timeline:${NC}"
echo "1. [03:04:40] Swap initialized (fs_59f554fb4eef4dbd)"
echo "2. [03:04:40] Ephemeral BTC key generated"
echo "3. [03:04:40] User receives quote + hashlock secrets (H_user, H_lp1, H_lp2)"
echo "4. [User Action] User creates USDC HTLC on Base Sepolia"
echo "5. [Unknown] User posts HTLC ID to /usdc-funded endpoint"
echo "6. [03:04:4X] LP tries to verify HTLC on-chain → 400 Bad Request"
echo ""

echo -e "${RED}ERROR:${NC} USDC HTLC not found on-chain"
echo "HTLC ID: 0xc6fa72a227b2ddd15a60290649be9667f23b4f06d97884f10688fb1a6263c90a"
echo ""

echo -e "${BLUE}Root Cause Analysis:${NC}"
echo "Most likely causes:"
echo "1. User TX failed or not confirmed on Base Sepolia"
echo "2. User provided wrong HTLC ID"
echo "3. User created HTLC on wrong network"
echo "4. EVM node was lagging/unavailable during verification"
echo ""

echo -e "${BLUE}Current State:${NC}"
echo "- Swap still exists in DB (state: awaiting_usdc)"
echo "- LP has NOT locked M1 or BTC yet (lp_locked_at: null)"
echo "- Plan expires at: $(date -d @1770866380 2>/dev/null || echo '1770866380')"
echo "- Swap returns 404 when queried (may have been auto-cleaned)"
echo ""

echo -e "${BLUE}Recommended Actions:${NC}"
echo "1. Check Base Sepolia explorer for HTLC TX: https://sepolia.basescan.org/tx/<user_tx_hash>"
echo "2. Verify HTLC3S contract events: https://sepolia.basescan.org/address/0x2493EaaaBa6B129962c8967AaEE6bF11D0277756#events"
echo "3. If HTLC exists on-chain, retry /usdc-funded endpoint"
echo "4. If HTLC never created, user needs to retry swap from scratch"
