#!/bin/bash
# Get detailed error info for the usdc-funded 400 error

set -e

SSH_KEY="$HOME/.ssh/id_ed25519_vps"
SSH_OPTS="-o StrictHostKeyChecking=no -o ConnectTimeout=10"
SSH="ssh -i $SSH_KEY $SSH_OPTS"

BLUE='\033[0;34m'; RED='\033[0;31m'; NC='\033[0m'

HTLC_ID="0xc6fa72a227b2ddd15a60290649be9667f23b4f06d97884f10688fb1a6263c90a"

echo -e "${BLUE}=== Searching for HTLC error context ===${NC}\n"

echo "HTLC ID: $HTLC_ID"
echo ""

# Get logs around the 400 error timestamp (03:04:40)
echo "=== Logs around 03:04:40 (swap init and USDC funding attempt) ==="
$SSH ubuntu@57.131.33.152 "grep -E '2026-02-12 03:04:[3-5]' /tmp/pna-sdk.log 2>/dev/null | grep -v 'GET.*200 OK' | tail -100"

echo ""
echo "=== Any ERROR/WARN around usdc-funded endpoint ==="
$SSH ubuntu@57.131.33.152 "grep -E '(usdc-funded|$HTLC_ID)' /tmp/pna-sdk.log 2>/dev/null | head -50"

echo ""
echo "=== Checking if HTLC appears on-chain (Base Sepolia) ==="
echo "HTLC3S contract: 0x2493EaaaBa6B129962c8967AaEE6bF11D0277756"
echo "HTLC ID: $HTLC_ID"
echo "Explorer: https://sepolia.basescan.org/address/0x2493EaaaBa6B129962c8967AaEE6bF11D0277756"
