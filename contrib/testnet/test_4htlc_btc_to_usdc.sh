#!/bin/bash
# =============================================================================
# 4-HTLC ATOMIC SWAP: BTC → USDC (via invisible M1)
# =============================================================================
#
# This demonstrates the full trustless, permissionless CLS-like swap:
#
#   User (BTC) ──HTLC-1──► LP
#            ◄──HTLC-2─── LP (M1 + covenant) [invisible to user]
#                 │
#                 └──HTLC-3──► LP (M1 returns) [invisible to user]
#            ◄──HTLC-4─── LP (USDC)
#
# TRUSTLESS: Atomic - either all transfers happen or none
# PERMISSIONLESS: No registration, no KYC, just cryptographic proofs
# =============================================================================

set -e

# Configuration
SSH_KEY="$HOME/.ssh/id_ed25519_vps"
OP1_IP="57.131.33.152"   # LP server
OP3_IP="51.75.31.44"     # Fake user
LP_URL="http://$OP1_IP:8080"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

log_step() { echo -e "\n${CYAN}═══════════════════════════════════════════════════════════════${NC}"; echo -e "${BLUE}STEP $1: $2${NC}"; echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"; }
log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_htlc() { echo -e "${YELLOW}[HTLC-$1]${NC} $2"; }

echo -e "${CYAN}"
echo "╔═══════════════════════════════════════════════════════════════════╗"
echo "║     4-HTLC ATOMIC SWAP: BTC → USDC (via invisible M1)             ║"
echo "║                                                                   ║"
echo "║  TRUSTLESS: Cryptographic guarantees, no trust required          ║"
echo "║  PERMISSIONLESS: No registration, no KYC                         ║"
echo "║  INVISIBLE M1: User never sees or touches M1                     ║"
echo "╚═══════════════════════════════════════════════════════════════════╝"
echo -e "${NC}"

# =============================================================================
log_step "0" "SETUP - Check balances and generate secret"
# =============================================================================

echo ""
log_info "Checking Fake User (OP3) BTC balance..."
USER_BTC_BALANCE=$(ssh -i "$SSH_KEY" ubuntu@$OP3_IP '~/bitcoin/bin/bitcoin-cli -signet -datadir=/home/ubuntu/.bitcoin-signet getbalance')
echo "  Fake User BTC: $USER_BTC_BALANCE BTC"

log_info "Checking LP (OP1) BTC balance..."
LP_BTC_BALANCE=$(ssh -i "$SSH_KEY" ubuntu@$OP1_IP '~/bitcoin/bin/bitcoin-cli -signet getbalance')
echo "  LP BTC: $LP_BTC_BALANCE BTC"

log_info "Generating cryptographic secret (preimage)..."
SECRET=$(openssl rand -hex 32)
HASHLOCK=$(echo -n "$SECRET" | xxd -r -p | sha256sum | cut -d' ' -f1)
echo "  Secret (preimage): ${SECRET:0:16}...${SECRET:48:16}"
echo "  Hashlock (SHA256): ${HASHLOCK:0:16}...${HASHLOCK:48:16}"

# Save for later
echo "$SECRET" > /tmp/swap_secret.txt
echo "$HASHLOCK" > /tmp/swap_hashlock.txt

# Get user's USDC receive address (Base Sepolia)
USER_USDC_ADDR="0x742d35Cc6634C0532925a3b844Bc9e7595f5bE21"  # Fake user's EVM address
USER_REFUND_ADDR=$(ssh -i "$SSH_KEY" ubuntu@$OP3_IP '~/bitcoin/bin/bitcoin-cli -signet -datadir=/home/ubuntu/.bitcoin-signet getnewaddress "swap_refund" bech32')
echo "  User BTC refund addr: $USER_REFUND_ADDR"
echo "  User USDC receive addr: $USER_USDC_ADDR"

# =============================================================================
log_step "1" "INITIATE SWAP - User requests BTC → USDC quote"
# =============================================================================

SWAP_AMOUNT="0.0005"  # 0.0005 BTC = 50,000 sats

log_info "Requesting quote for $SWAP_AMOUNT BTC → USDC..."
QUOTE=$(curl -s "$LP_URL/api/quote?from=BTC&to=USDC&amount=$SWAP_AMOUNT")
echo "$QUOTE" | python3 -m json.tool 2>/dev/null || echo "$QUOTE"

log_info "Creating swap request..."
SWAP_RESPONSE=$(curl -s -X POST "$LP_URL/api/swap/full/initiate" \
  -H "Content-Type: application/json" \
  -d "{
    \"from_asset\": \"BTC\",
    \"to_asset\": \"USDC\",
    \"from_amount\": $SWAP_AMOUNT,
    \"hashlock\": \"$HASHLOCK\",
    \"user_receive_address\": \"$USER_USDC_ADDR\",
    \"user_refund_address\": \"$USER_REFUND_ADDR\"
  }")

echo ""
echo "$SWAP_RESPONSE" | python3 -m json.tool 2>/dev/null || echo "$SWAP_RESPONSE"

SWAP_ID=$(echo "$SWAP_RESPONSE" | python3 -c "import sys,json; print(json.load(sys.stdin).get('swap_id',''))" 2>/dev/null)
HTLC_ADDR=$(echo "$SWAP_RESPONSE" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('deposit_instructions',{}).get('htlc_address',''))" 2>/dev/null)

if [ -z "$SWAP_ID" ] || [ -z "$HTLC_ADDR" ]; then
    log_warn "Could not extract swap details. Response:"
    echo "$SWAP_RESPONSE"
    exit 1
fi

echo ""
log_info "Swap ID: $SWAP_ID"
log_info "User must send BTC to: $HTLC_ADDR"

# Save swap ID
echo "$SWAP_ID" > /tmp/swap_id.txt

# =============================================================================
log_step "2" "HTLC-1: User locks BTC in P2WSH HTLC"
# =============================================================================

log_htlc "1" "User creating BTC HTLC (locks $SWAP_AMOUNT BTC)..."
echo ""
echo "  Flow: User BTC → HTLC Address (LP can claim with preimage)"
echo "  Address: $HTLC_ADDR"
echo "  Amount: $SWAP_AMOUNT BTC ($(echo "$SWAP_AMOUNT * 100000000" | bc) sats)"
echo ""

log_info "Sending BTC from Fake User to HTLC..."
FUNDING_TXID=$(ssh -i "$SSH_KEY" ubuntu@$OP3_IP "~/bitcoin/bin/bitcoin-cli -signet -datadir=/home/ubuntu/.bitcoin-signet sendtoaddress $HTLC_ADDR $SWAP_AMOUNT")

echo "  Funding TX: $FUNDING_TXID"
log_htlc "1" "BTC LOCKED! User's funds are now in the atomic swap."

# =============================================================================
log_step "3" "WAIT FOR CONFIRMATION"
# =============================================================================

log_info "Waiting for BTC confirmation (Signet ~10min blocks)..."
log_info "LP monitors the HTLC address for deposits..."

# Register the HTLC with LP
log_info "Notifying LP of the deposit..."
curl -s -X POST "$LP_URL/api/swap/full/$SWAP_ID/register-htlc?htlc_id=$FUNDING_TXID" | python3 -m json.tool 2>/dev/null || true

# Check swap status
echo ""
log_info "Current swap status:"
curl -s "$LP_URL/api/swap/full/$SWAP_ID/status" | python3 -m json.tool 2>/dev/null

# =============================================================================
log_step "4" "4-HTLC FLOW EXPLAINED (M1 is invisible to user)"
# =============================================================================

echo ""
echo -e "${YELLOW}══════════════════════════════════════════════════════════════${NC}"
echo -e "${YELLOW}             THE 4-HTLC ATOMIC SWAP FLOW                      ${NC}"
echo -e "${YELLOW}══════════════════════════════════════════════════════════════${NC}"
echo ""
echo "  WHAT USER SEES:                    WHAT ACTUALLY HAPPENS:"
echo "  ───────────────                    ─────────────────────"
echo "  1. I send BTC to swap              HTLC-1: User→LP BTC locked"
echo "  2. (invisible)                     HTLC-2: LP→User M1 locked"
echo "  3. (invisible)                     HTLC-3: M1 returns to LP"
echo "  4. I receive USDC                  HTLC-4: LP→User USDC"
echo ""
echo "  M1 SETTLEMENT RAIL:"
echo "  ───────────────────"
echo "  • M1 has ~1 minute finality (vs BTC 60min, USDC 1s)"
echo "  • Eliminates Herstatt Risk between slow & fast chains"
echo "  • User NEVER sees or touches M1 - it's LP's tool"
echo "  • Like CLS for forex: internal settlement currency"
echo ""
echo -e "${YELLOW}══════════════════════════════════════════════════════════════${NC}"

# =============================================================================
log_step "5" "TRUSTLESS VERIFICATION"
# =============================================================================

echo ""
log_info "Demonstrating TRUSTLESS property..."
echo ""
echo "  ATOMIC GUARANTEE:"
echo "  ─────────────────"
echo "  • Same hashlock ($HASHLOCK) links all 4 HTLCs"
echo "  • Revealing preimage claims ONE HTLC → enables ALL claims"
echo "  • If user claims BTC: preimage revealed → LP can claim USDC"
echo "  • If LP claims USDC first: IMPOSSIBLE (preimage not known)"
echo ""
echo "  TIMELOCK PROTECTION:"
echo "  ────────────────────"
echo "  • User's HTLC expires AFTER LP's HTLC"
echo "  • If LP doesn't complete, user gets refund"
echo "  • No funds can be lost (worst case: timeout refund)"
echo ""

# =============================================================================
log_step "6" "PERMISSIONLESS VERIFICATION"
# =============================================================================

echo ""
log_info "Demonstrating PERMISSIONLESS property..."
echo ""
echo "  NO REGISTRATION:"
echo "  ─────────────────"
echo "  • User just needs: BTC address + USDC address"
echo "  • No account creation, no email, no KYC"
echo "  • LP accepts any valid cryptographic proof"
echo ""
echo "  CRYPTOGRAPHIC TRUST:"
echo "  ─────────────────────"
echo "  • Hash function (SHA256) is the only trust assumption"
echo "  • Math guarantees atomicity, not reputation"
echo "  • Anyone can verify the swap on-chain"
echo ""

# =============================================================================
log_step "7" "SWAP SUMMARY"
# =============================================================================

echo ""
echo -e "${GREEN}╔═══════════════════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║                    SWAP INITIATED SUCCESSFULLY                    ║${NC}"
echo -e "${GREEN}╚═══════════════════════════════════════════════════════════════════╝${NC}"
echo ""
echo "  Swap ID:        $SWAP_ID"
echo "  From:           $SWAP_AMOUNT BTC (Signet)"
echo "  To:             ~\$$(echo "$SWAP_AMOUNT * 73000" | bc) USDC (Base Sepolia)"
echo "  Funding TX:     $FUNDING_TXID"
echo "  HTLC Address:   $HTLC_ADDR"
echo ""
echo "  Files saved:"
echo "    /tmp/swap_id.txt      - Swap ID"
echo "    /tmp/swap_secret.txt  - Preimage (keep secret until claim!)"
echo "    /tmp/swap_hashlock.txt - Hashlock"
echo ""
echo "  NEXT STEPS:"
echo "  ──────────────────────────────────────────────────────────"
echo "  1. Wait for BTC confirmation (~10 min on Signet)"
echo "  2. LP will auto-create M1 HTLC (HTLC-2) - invisible"
echo "  3. M1 settlement happens internally (HTLC-3) - invisible"
echo "  4. LP creates USDC HTLC (HTLC-4)"
echo "  5. User claims USDC with preimage"
echo "  6. LP claims user's BTC (sees preimage on-chain)"
echo ""
echo "  Monitor: curl $LP_URL/api/swap/full/$SWAP_ID/status"
echo ""
