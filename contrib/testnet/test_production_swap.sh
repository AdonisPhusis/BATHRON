#!/bin/bash
# =============================================================================
# PRODUCTION SWAP TEST: Simulates full BTC ↔ M1 atomic swap
# =============================================================================
#
# This test demonstrates the complete swap flow:
# 1. User generates secret S, hashlock H
# 2. User "sends" BTC to HTLC (simulated - we track the intent)
# 3. LP creates M1 HTLC → User (locked by H)
# 4. User claims M1 with S (reveals preimage)
# 5. LP extracts S → could claim BTC
#
# Note: BTC HTLC creation requires pubkeys which need wallet access.
# This test focuses on the M1 HTLC flow which is the core of BATHRON.
#
# =============================================================================

set -e

SSH_KEY=~/.ssh/id_ed25519_vps
LP_API="http://57.131.33.152:8080"
OP1_IP="57.131.33.152"
OP3_IP="51.75.31.44"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
NC='\033[0m'

log() { echo -e "${BLUE}[$(date +%H:%M:%S)]${NC} $1"; }
success() { echo -e "${GREEN}[✓]${NC} $1"; }
error() { echo -e "${RED}[✗]${NC} $1"; exit 1; }
warn() { echo -e "${YELLOW}[!]${NC} $1"; }
api() { echo -e "${CYAN}[API]${NC} $1"; }
user() { echo -e "${MAGENTA}[USER]${NC} $1"; }
lp() { echo -e "${GREEN}[LP]${NC} $1"; }

AMOUNT_SATS=50000  # 50k sats

echo "╔══════════════════════════════════════════════════════════════════╗"
echo "║  PRODUCTION SWAP TEST: BTC ↔ M1                                  ║"
echo "║  Demonstrates atomic swap flow via P&A                           ║"
echo "╚══════════════════════════════════════════════════════════════════╝"
echo ""

# =============================================================================
# STEP 0: Check systems
# =============================================================================
log "STEP 0: System checks"

# LP API
if curl -s "$LP_API/api/status" | grep -q '"status":"ok"'; then
    success "LP API online"
else
    error "LP API offline"
fi

# LP M1 balance
LP_M1=$(curl -s "$LP_API/api/wallets" | python3 -c "import sys,json; print(json.load(sys.stdin).get('m1',{}).get('balance',0))" 2>/dev/null)
lp "M1 balance: $LP_M1 sats"

if [ "$LP_M1" -lt "$AMOUNT_SATS" ]; then
    error "LP has insufficient M1 liquidity ($LP_M1 < $AMOUNT_SATS)"
fi

# User M1 balance before
USER_M1_BEFORE=$(ssh -i $SSH_KEY ubuntu@$OP3_IP '~/bathron-cli -testnet getwalletstate true' 2>&1 | \
    python3 -c "import sys,json; print(json.load(sys.stdin).get('m1',{}).get('total',0))" 2>/dev/null || echo "0")
user "M1 balance before: $USER_M1_BEFORE sats"

# =============================================================================
# STEP 1: User generates secret
# =============================================================================
echo ""
log "STEP 1: User generates secret S and hashlock H"

SECRET=$(openssl rand -hex 32)
HASHLOCK=$(echo -n "$SECRET" | xxd -r -p | sha256sum | cut -d' ' -f1)

user "Generated:"
echo "    Secret (S):   $SECRET"
echo "    Hashlock (H): $HASHLOCK"
success "Only USER knows S. LP only knows H."

# =============================================================================
# STEP 2: Get user's M1 claim address
# =============================================================================
echo ""
log "STEP 2: User prepares claim address"

USER_M1_ADDR=$(ssh -i $SSH_KEY ubuntu@$OP3_IP '~/bathron-cli -testnet getnewaddress "swap"' 2>&1)
user "M1 claim address: $USER_M1_ADDR"

# =============================================================================
# STEP 3: User requests swap quote
# =============================================================================
echo ""
log "STEP 3: User requests swap quote from LP"

AMOUNT_BTC=$(python3 -c "print($AMOUNT_SATS / 100000000)")
api "GET /api/quote?from=BTC&to=M1&amount=$AMOUNT_BTC"

QUOTE=$(curl -s "$LP_API/api/quote?from=BTC&to=M1&amount=$AMOUNT_BTC" 2>&1)
echo "$QUOTE" | python3 -c "
import sys, json
d = json.load(sys.stdin)
print(f'    From: {d.get(\"from_amount\")} BTC')
print(f'    To:   {d.get(\"to_amount\"):.0f} M1 sats')
print(f'    Rate: 1 BTC = {d.get(\"rate\"):,.0f} sats')
print(f'    Spread: {d.get(\"spread_percent\")}%')
"

M1_RECEIVE=$(echo "$QUOTE" | python3 -c "import sys,json; print(int(json.load(sys.stdin).get('to_amount',0)))" 2>/dev/null)

# =============================================================================
# STEP 4: User initiates atomic swap
# =============================================================================
echo ""
log "STEP 4: User initiates atomic swap via LP API"
user "Sending hashlock H to LP (secret S stays private!)"
api "POST /api/atomic/initiate"

INIT_RESP=$(curl -s -X POST "$LP_API/api/atomic/initiate" \
    -H "Content-Type: application/json" \
    -d "{
        \"from_asset\": \"BTC\",
        \"to_asset\": \"M1\",
        \"from_amount\": $AMOUNT_BTC,
        \"hashlock\": \"$HASHLOCK\",
        \"user_claim_address\": \"$USER_M1_ADDR\",
        \"user_refund_address\": \"tb1q_user_refund_placeholder\"
    }" 2>&1)

SWAP_ID=$(echo "$INIT_RESP" | python3 -c "import sys,json; print(json.load(sys.stdin).get('swap_id',''))" 2>/dev/null)
M1_HTLC=$(echo "$INIT_RESP" | python3 -c "import sys,json; print(json.load(sys.stdin).get('lp_htlc',{}).get('htlc_outpoint',''))" 2>/dev/null)
M1_HTLC_TXID=$(echo "$INIT_RESP" | python3 -c "import sys,json; print(json.load(sys.stdin).get('lp_htlc',{}).get('txid',''))" 2>/dev/null)

if [ -z "$SWAP_ID" ] || [ -z "$M1_HTLC" ]; then
    echo "$INIT_RESP" | python3 -m json.tool 2>/dev/null
    error "Failed to initiate swap"
fi

success "Swap initiated: $SWAP_ID"
lp "Created M1 HTLC: $M1_HTLC"
echo ""
echo "    LP has locked M1 for User, but User can only claim with secret S"
echo "    In production: User would now send BTC to LP's HTLC address"

# =============================================================================
# STEP 5: Wait for M1 HTLC confirmation
# =============================================================================
echo ""
log "STEP 5: Waiting for M1 HTLC confirmation (65s)..."
echo "    (In production: LP waits for BTC HTLC to be funded first)"
sleep 65

# Check HTLC status
HTLC_STATUS=$(ssh -i $SSH_KEY ubuntu@$OP3_IP "~/bathron-cli -testnet htlc_get '$M1_HTLC'" 2>&1)
STATUS=$(echo "$HTLC_STATUS" | python3 -c "import sys,json; print(json.load(sys.stdin).get('status',''))" 2>/dev/null)

if [ "$STATUS" = "active" ]; then
    success "M1 HTLC is active and claimable"
else
    warn "HTLC status: $STATUS"
fi

# =============================================================================
# STEP 6: User claims M1 HTLC
# =============================================================================
echo ""
log "STEP 6: User claims M1 HTLC by revealing secret S"
user "Claiming with secret: ${SECRET:0:16}..."
echo "    --> This reveals S to the entire blockchain!"

CLAIM=$(ssh -i $SSH_KEY ubuntu@$OP3_IP "~/bathron-cli -testnet htlc_claim '$M1_HTLC' '$SECRET'" 2>&1)

CLAIM_TXID=$(echo "$CLAIM" | python3 -c "import sys,json; print(json.load(sys.stdin).get('txid',''))" 2>/dev/null)
CLAIM_AMOUNT=$(echo "$CLAIM" | python3 -c "import sys,json; print(json.load(sys.stdin).get('amount',0))" 2>/dev/null)

if [ -z "$CLAIM_TXID" ]; then
    echo "$CLAIM"
    error "Claim failed"
fi

success "User claimed M1!"
echo "    TX: $CLAIM_TXID"
echo "    Amount: $CLAIM_AMOUNT sats"

# =============================================================================
# STEP 7: Wait for claim confirmation
# =============================================================================
echo ""
log "STEP 7: Waiting for claim confirmation (65s)..."
sleep 65

# =============================================================================
# STEP 8: LP extracts preimage
# =============================================================================
echo ""
log "STEP 8: LP extracts preimage from blockchain"
lp "Reading claimed HTLC to extract S..."

FINAL_HTLC=$(ssh -i $SSH_KEY ubuntu@$OP1_IP "~/bathron-cli -testnet htlc_get '$M1_HTLC'" 2>&1)

echo "$FINAL_HTLC" | python3 -c "
import sys, json
d = json.load(sys.stdin)
print(f'    HTLC Status: {d.get(\"status\")}')
print(f'    Claimed by TX: {d.get(\"resolve_txid\", \"N/A\")}')
print(f'    Preimage: {d.get(\"preimage\", \"NOT FOUND\")}')
"

EXTRACTED=$(echo "$FINAL_HTLC" | python3 -c "import sys,json; print(json.load(sys.stdin).get('preimage',''))" 2>/dev/null)

if [ -n "$EXTRACTED" ]; then
    success "LP extracted preimage!"
    lp "Can now claim BTC HTLC using: $EXTRACTED"
else
    warn "Preimage not yet available"
fi

# =============================================================================
# STEP 9: Verify user received M1
# =============================================================================
echo ""
log "STEP 9: Verify user's M1 balance"

USER_M1_AFTER=$(ssh -i $SSH_KEY ubuntu@$OP3_IP '~/bathron-cli -testnet getwalletstate true' 2>&1 | \
    python3 -c "import sys,json; print(json.load(sys.stdin).get('m1',{}).get('total',0))" 2>/dev/null || echo "0")

GAINED=$((USER_M1_AFTER - USER_M1_BEFORE))

user "M1 balance after: $USER_M1_AFTER sats"
user "M1 gained: +$GAINED sats"

# =============================================================================
# SUMMARY
# =============================================================================
echo ""
echo "╔══════════════════════════════════════════════════════════════════════╗"
echo "║                     ATOMIC SWAP COMPLETE                             ║"
echo "╠══════════════════════════════════════════════════════════════════════╣"
echo "║                                                                      ║"
echo "║  SWAP: $SWAP_ID"
echo "║                                                                      ║"
echo "║  ┌─────────────────────────────────────────────────────────────┐     ║"
echo "║  │  USER                              LP                       │     ║"
echo "║  │                                                             │     ║"
echo "║  │  [1] Generate S, H=SHA256(S)                                │     ║"
echo "║  │  [2] Send H to LP ─────────────────► Receive H              │     ║"
echo "║  │  [3] (Send BTC to HTLC)              Create M1 HTLC ◄────── │     ║"
echo "║  │  [4] Verify M1 HTLC ◄───────────── (locked by H)            │     ║"
echo "║  │  [5] Claim M1 with S ──────────────► S revealed on chain    │     ║"
echo "║  │  [6] Receive M1 ✓                    Extract S from chain   │     ║"
echo "║  │                                      (Claim BTC with S) ✓   │     ║"
echo "║  └─────────────────────────────────────────────────────────────┘     ║"
echo "║                                                                      ║"
echo "║  RESULTS:                                                            ║"
echo "║  ────────────────────────────────────────────────────────────────    ║"
printf "║  User M1 before:  %10d sats                                   ║\n" "$USER_M1_BEFORE"
printf "║  User M1 after:   %10d sats                                   ║\n" "$USER_M1_AFTER"
printf "║  User gained:     %+10d sats                                   ║\n" "$GAINED"
echo "║                                                                      ║"
echo "║  SECURITY:                                                           ║"
echo "║  ────────────────────────────────────────────────────────────────    ║"
echo "║  ✓ LP cannot steal: M1 locked by H, only S unlocks it                ║"
echo "║  ✓ User cannot cheat: Must reveal S to claim M1                      ║"
echo "║  ✓ LP learns S when User claims → can claim BTC                      ║"
echo "║  ✓ ATOMIC: Both succeed or both fail (timeout refund)                ║"
echo "║                                                                      ║"
echo "╚══════════════════════════════════════════════════════════════════════╝"

if [ -n "$EXTRACTED" ] && [ "$GAINED" -gt 0 ]; then
    echo ""
    success "SWAP SUCCESSFUL! User received $GAINED M1 sats."
    echo ""
    echo "In production flow:"
    echo "  • User would have sent BTC to LP's HTLC address first"
    echo "  • LP waits for BTC confirmation before creating M1 HTLC"
    echo "  • After user claims M1, LP uses revealed S to claim BTC"
    echo "  • Trustless and atomic - no counterparty risk!"
fi
