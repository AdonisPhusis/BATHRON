#!/bin/bash
# Summary report for the swap issue

set -e

SSH_KEY="$HOME/.ssh/id_ed25519_vps"
SSH_OPTS="-o StrictHostKeyChecking=no -o ConnectTimeout=10"
SSH="ssh -i $SSH_KEY $SSH_OPTS"

BLUE='\033[0;34m'; RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'

cat << 'REPORT'
================================================================================
SWAP INVESTIGATION REPORT: fs_59f554fb4eef4dbd
================================================================================

SWAP DETAILS:
  - Swap ID: fs_59f554fb4eef4dbd
  - Direction: USDC → BTC
  - Amount: 20.0 USDC → 0.00029503 BTC
  - User BTC destination: tb1q0dgtuh268axeypa584rxddzp3jf7p2xw6vysxg
  - LP: LP1 (alice @ OP1 - 57.131.33.152)

TIMELINE:
  1. [03:04:40 UTC] Swap initialized successfully
     - State: awaiting_usdc
     - Hashlocks generated: H_user, H_lp1, H_lp2
     - Ephemeral BTC claim key generated
     - Plan expiry: 03:19:40 UTC (15 min window)

  2. [User Action] User attempts to create USDC HTLC on Base Sepolia
     - Expected: User locks 20 USDC in HTLC3S contract
     - Recipient: LP alice_evm (0x78F5e39850C222742Ac06a304893080883F1270c)
     - Contract: 0x2493EaaaBa6B129962c8967AaEE6bF11D0277756

  3. [03:04:4X] User posts HTLC ID to /usdc-funded endpoint
     - HTLC ID: 0xc6fa72a227b2ddd15a60290649be9667f23b4f06d97884f10688fb1a6263c90a
     - LP verifies HTLC on-chain → FAILED
     - Error: "USDC HTLC not found on-chain"
     - HTTP 400 Bad Request

  4. [Now] Swap returns 404 on API queries
     - Swap exists in DB file: ✓ (23 swaps total)
     - Swap in server memory: ✗ (returns 404)
     - Likely cause: Server restart or in-memory cleanup

ROOT CAUSE:
  The user's USDC HTLC transaction either:
  a) Never was broadcast to Base Sepolia
  b) Failed to confirm on-chain
  c) Was created with wrong parameters
  d) User provided incorrect HTLC ID
  e) EVM RPC node was unavailable/lagging during verification

CURRENT STATE:
  - LP has NOT locked any funds (lp_locked_at: null)
  - No M1 locked
  - No BTC locked
  - User funds status: Unknown (need to check Base Sepolia)

RISK ASSESSMENT: ✅ LOW RISK
  - No LP funds at risk (nothing locked)
  - Swap plan will expire at 03:19:40 UTC
  - User can safely retry from scratch

RECOMMENDED ACTIONS:
  1. Check Base Sepolia for HTLC TX:
     https://sepolia.basescan.org/address/0x2493EaaaBa6B129962c8967AaEE6bF11D0277756#events

  2. If HTLC exists on-chain:
     - Server needs restart to reload DB from file
     - User can retry /usdc-funded call

  3. If HTLC does NOT exist:
     - User should create new swap
     - Ensure MetaMask TX confirms before calling /usdc-funded

ADDITIONAL ISSUES FOUND:
  1. BTC scantxoutset errors (scan already in progress)
     - May cause inventory refresh delays
     - Not critical but should be fixed

  2. LP2 (OP2) has Bitcoin Core connectivity issues
     - Error: "Could not connect to server 127.0.0.1:38332"
     - BTC operations on LP2 will fail

  3. Multiple PIVX/DASH/ZEC warnings (binaries not installed)
     - Expected if multi-chain not fully deployed yet

================================================================================
REPORT

echo ""
echo -e "${BLUE}Checking if swap still in memory now:${NC}"
curl -s "http://57.131.33.152:8080/api/flowswap/fs_59f554fb4eef4dbd" | python3 -m json.tool 2>&1 | head -5

echo ""
echo -e "${BLUE}Current server uptime:${NC}"
$SSH ubuntu@57.131.33.152 "ps aux | grep 'uvicorn.*server' | grep -v grep | awk '{print \$2}' | head -1 | xargs ps -o etime= -p"
