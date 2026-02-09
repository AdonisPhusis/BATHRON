#!/bin/bash
# =============================================================================
# P&A Atomic Swap Test via API
# =============================================================================
#
# Tests the full atomic swap flow through the P&A LP API:
# 1. User generates secret S and hashlock H
# 2. User calls /api/atomic/initiate → LP creates M1 HTLC
# 3. User claims M1 HTLC with S via /api/atomic/claim
# 4. LP extracts preimage
#
# =============================================================================

set -e

SSH_KEY=~/.ssh/id_ed25519_vps
LP_API="http://57.131.33.152:8080"
OP3_IP="51.75.31.44"  # Fake user (charlie)

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

log() { echo -e "${BLUE}[$(date +%H:%M:%S)]${NC} $1"; }
success() { echo -e "${GREEN}[✓]${NC} $1"; }
error() { echo -e "${RED}[✗]${NC} $1"; exit 1; }
warn() { echo -e "${YELLOW}[!]${NC} $1"; }
api() { echo -e "${CYAN}[API]${NC} $1"; }

echo "╔══════════════════════════════════════════════════════════════════╗"
echo "║  P&A ATOMIC SWAP TEST (via API)                                  ║"
echo "║  BTC → M1 swap using LP at $LP_API                  ║"
echo "╚══════════════════════════════════════════════════════════════════╝"
echo ""

# =============================================================================
# STEP 1: Check LP API status
# =============================================================================
log "STEP 1: Checking LP API status"

STATUS=$(curl -s "$LP_API/api/status" 2>&1)
if echo "$STATUS" | grep -q '"status":"ok"'; then
    success "LP API is online"
    echo "$STATUS" | python3 -c "
import sys, json
d = json.load(sys.stdin)
print(f\"  Version: {d.get('version')}  |  Active swaps: {d.get('swaps_active')}  |  LPs: {d.get('lps_active')}\")
"
else
    error "LP API not available: $STATUS"
fi

# =============================================================================
# STEP 2: User generates secret and hashlock
# =============================================================================
echo ""
log "STEP 2: User generates secret S and hashlock H"

SECRET=$(openssl rand -hex 32)
HASHLOCK=$(echo -n "$SECRET" | xxd -r -p | sha256sum | cut -d' ' -f1)

echo "  Secret (S):   $SECRET"
echo "  Hashlock (H): $HASHLOCK"

# Verify locally
VERIFY=$(python3 -c "
import hashlib
s = bytes.fromhex('$SECRET')
h = hashlib.sha256(s).hexdigest()
print('MATCH' if h == '$HASHLOCK' else 'MISMATCH')
")
[ "$VERIFY" = "MATCH" ] || error "Hashlock verification failed!"
success "Hashlock verified"

# =============================================================================
# STEP 3: Get user addresses from OP3
# =============================================================================
echo ""
log "STEP 3: Getting user addresses from OP3 (fake user)"

USER_M1_ADDR=$(ssh -i $SSH_KEY -o ConnectTimeout=15 ubuntu@$OP3_IP \
    '~/bathron-cli -testnet getnewaddress "pna_claim"' 2>&1)

if [[ ! "$USER_M1_ADDR" == y* ]]; then
    error "Failed to get M1 address: $USER_M1_ADDR"
fi
echo "  User M1 claim addr:  $USER_M1_ADDR"

USER_BTC_ADDR=$(ssh -i $SSH_KEY -o ConnectTimeout=15 ubuntu@$OP3_IP \
    '~/bitcoin/bin/bitcoin-cli -signet -datadir=/home/ubuntu/.bitcoin-signet getnewaddress "pna_refund" bech32' 2>&1)

if [[ ! "$USER_BTC_ADDR" == tb1* ]]; then
    warn "BTC address issue (might not have BTC wallet): $USER_BTC_ADDR"
    USER_BTC_ADDR="tb1qxyz_placeholder"
fi
echo "  User BTC refund addr: $USER_BTC_ADDR"

# =============================================================================
# STEP 4: Get quote
# =============================================================================
echo ""
log "STEP 4: Getting swap quote (0.0001 BTC → M1)"

QUOTE=$(curl -s "$LP_API/api/quote?from=BTC&to=M1&amount=0.0001" 2>&1)
echo "$QUOTE" | python3 -c "
import sys, json
d = json.load(sys.stdin)
print(f\"  Rate: 1 BTC = {d.get('rate'):,.0f} M1 sats\")
print(f\"  You send: {d.get('from_amount')} BTC\")
print(f\"  You get:  {d.get('to_amount'):,.0f} M1 sats\")
print(f\"  Spread:   {d.get('spread_percent')}%\")
"

# =============================================================================
# STEP 5: Initiate atomic swap via API
# =============================================================================
echo ""
log "STEP 5: Initiating atomic swap via LP API"
api "POST /api/atomic/initiate"

INIT_REQ=$(cat <<EOF
{
    "from_asset": "BTC",
    "to_asset": "M1",
    "from_amount": 0.0001,
    "hashlock": "$HASHLOCK",
    "user_claim_address": "$USER_M1_ADDR",
    "user_refund_address": "$USER_BTC_ADDR"
}
EOF
)

echo "  Request:"
echo "$INIT_REQ" | python3 -m json.tool | sed 's/^/    /'

INIT_RESP=$(curl -s -X POST "$LP_API/api/atomic/initiate" \
    -H "Content-Type: application/json" \
    -d "$INIT_REQ" 2>&1)

echo ""
echo "  Response:"
echo "$INIT_RESP" | python3 -m json.tool 2>/dev/null | head -30 | sed 's/^/    /'

# Extract swap_id and HTLC outpoint
SWAP_ID=$(echo "$INIT_RESP" | python3 -c "
import sys, json
d = json.load(sys.stdin)
print(d.get('swap_id', ''))
" 2>/dev/null)

HTLC_OUTPOINT=$(echo "$INIT_RESP" | python3 -c "
import sys, json
d = json.load(sys.stdin)
print(d.get('lp_htlc', {}).get('htlc_outpoint', ''))
" 2>/dev/null)

if [ -z "$SWAP_ID" ] || [ -z "$HTLC_OUTPOINT" ]; then
    error "Failed to initiate swap: $INIT_RESP"
fi

success "Swap initiated: $SWAP_ID"
echo "  LP HTLC outpoint: $HTLC_OUTPOINT"

# =============================================================================
# STEP 6: Wait for HTLC confirmation
# =============================================================================
echo ""
log "STEP 6: Waiting for LP's M1 HTLC confirmation (65s)..."
sleep 65

# Check swap status
api "GET /api/atomic/$SWAP_ID"
SWAP_STATUS=$(curl -s "$LP_API/api/atomic/$SWAP_ID" 2>&1)
echo "$SWAP_STATUS" | python3 -c "
import sys, json
d = json.load(sys.stdin)
print(f\"  Swap status: {d.get('status')}\")
"

# =============================================================================
# STEP 7: User claims M1 HTLC with preimage
# =============================================================================
echo ""
log "STEP 7: User claims M1 HTLC with secret S"

# User claims via bathron-cli on OP3
CLAIM_RESULT=$(ssh -i $SSH_KEY ubuntu@$OP3_IP \
    "~/bathron-cli -testnet htlc_claim '$HTLC_OUTPOINT' '$SECRET'" 2>&1)

echo "  Claim result:"
echo "$CLAIM_RESULT" | python3 -m json.tool 2>/dev/null | sed 's/^/    /' || echo "    $CLAIM_RESULT"

CLAIM_TXID=$(echo "$CLAIM_RESULT" | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    print(d.get('txid', ''))
except:
    print('')
" 2>/dev/null)

if [ -z "$CLAIM_TXID" ]; then
    error "User failed to claim: $CLAIM_RESULT"
fi

success "User claimed M1 HTLC! TX: $CLAIM_TXID"
echo "  --> SECRET S IS NOW PUBLIC ON BATHRON CHAIN"

# =============================================================================
# STEP 8: Wait for claim confirmation
# =============================================================================
echo ""
log "STEP 8: Waiting for claim confirmation (65s)..."
sleep 65

# =============================================================================
# STEP 9: Check final swap status
# =============================================================================
echo ""
log "STEP 9: Checking final swap status"

api "GET /api/atomic/$SWAP_ID"
FINAL_STATUS=$(curl -s "$LP_API/api/atomic/$SWAP_ID" 2>&1)
echo "$FINAL_STATUS" | python3 -m json.tool 2>/dev/null | head -20 | sed 's/^/    /'

# Also check HTLC status on chain
HTLC_FINAL=$(ssh -i $SSH_KEY ubuntu@$OP3_IP \
    "~/bathron-cli -testnet htlc_get '$HTLC_OUTPOINT'" 2>&1)

echo ""
echo "  HTLC on-chain status:"
echo "$HTLC_FINAL" | python3 -c "
import sys, json
d = json.load(sys.stdin)
print(f\"    Status: {d.get('status')}\")
print(f\"    Resolve TX: {d.get('resolve_txid', 'N/A')}\")
print(f\"    Preimage: {d.get('preimage', 'NOT YET')}\")
"

# =============================================================================
# SUMMARY
# =============================================================================
echo ""
echo "╔══════════════════════════════════════════════════════════════════╗"
echo "║  P&A ATOMIC SWAP TEST COMPLETE                                   ║"
echo "╠══════════════════════════════════════════════════════════════════╣"
echo "║  Swap ID:        $SWAP_ID"
echo "║  User secret:    ${SECRET:0:32}..."
echo "║  LP HTLC TX:     ${HTLC_OUTPOINT}"
echo "║  User claim TX:  $CLAIM_TXID"
echo "╚══════════════════════════════════════════════════════════════════╝"
echo ""
success "Atomic swap flow verified via P&A API!"
echo ""
echo "In production:"
echo "  1. User would also create BTC HTLC with same hashlock"
echo "  2. LP would wait for BTC HTLC before creating M1 HTLC"
echo "  3. User claims M1 → reveals preimage"
echo "  4. LP claims BTC using revealed preimage"
