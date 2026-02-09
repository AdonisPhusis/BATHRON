#!/bin/bash
# =============================================================================
# M1 HTLC Bidirectional Test: User generates secret, LP creates HTLC
# =============================================================================
#
# Flow:
# 1. User generates secret S and hashlock H = SHA256(S)
# 2. LP creates M1 HTLC → User address (locked with H)
# 3. User claims M1 HTLC with S (reveals preimage)
# 4. LP extracts S from claimed HTLC
#
# =============================================================================

set -e

SSH_KEY=~/.ssh/id_ed25519_vps
OP1_IP="57.131.33.152"   # LP (alice)
OP3_IP="51.75.31.44"      # Fake User (charlie)

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log() { echo -e "${BLUE}[$(date +%H:%M:%S)]${NC} $1"; }
success() { echo -e "${GREEN}[✓]${NC} $1"; }
error() { echo -e "${RED}[✗]${NC} $1"; exit 1; }
warn() { echo -e "${YELLOW}[!]${NC} $1"; }

echo "╔══════════════════════════════════════════════════════════════════╗"
echo "║  M1 HTLC BIDIRECTIONAL TEST                                      ║"
echo "║  User generates secret, LP creates HTLC, User claims             ║"
echo "╚══════════════════════════════════════════════════════════════════╝"
echo ""

# =============================================================================
# STEP 1: User generates secret and hashlock (locally, simulating OP3)
# =============================================================================
log "STEP 1: User generates secret and hashlock"

SECRET=$(openssl rand -hex 32)
HASHLOCK=$(echo -n "$SECRET" | xxd -r -p | sha256sum | cut -d' ' -f1)

echo "  Secret (S):   $SECRET"
echo "  Hashlock (H): $HASHLOCK"

# Verify
VERIFY=$(python3 -c "
import hashlib
s = bytes.fromhex('$SECRET')
h = hashlib.sha256(s).hexdigest()
print('MATCH' if h == '$HASHLOCK' else 'MISMATCH')
")
[ "$VERIFY" = "MATCH" ] || error "Hashlock verification failed!"
success "Hashlock verified: SHA256(S) = H"

# =============================================================================
# STEP 2: Get User's M1 claim address from OP3
# =============================================================================
echo ""
log "STEP 2: Get User's M1 address from OP3"

USER_M1_ADDR=$(ssh -i $SSH_KEY -o ConnectTimeout=15 ubuntu@$OP3_IP \
    '~/bathron-cli -testnet getnewaddress "htlc_claim"' 2>&1)

if [[ "$USER_M1_ADDR" == y* ]]; then
    success "User M1 address: $USER_M1_ADDR"
else
    error "Failed to get user address: $USER_M1_ADDR"
fi

# =============================================================================
# STEP 3: LP (OP1) checks available M1 receipts
# =============================================================================
echo ""
log "STEP 3: LP checks available M1 receipts"

LP_M1_STATE=$(ssh -i $SSH_KEY -o ConnectTimeout=15 ubuntu@$OP1_IP \
    '~/bathron-cli -testnet getwalletstate true' 2>&1)

LP_M1_TOTAL=$(echo "$LP_M1_STATE" | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    print(d.get('m1', {}).get('total', 0))
except:
    print(0)
" 2>/dev/null)

echo "  LP M1 total: $LP_M1_TOTAL sats"

if [ "$LP_M1_TOTAL" -lt 100000 ]; then
    warn "LP needs M1 receipts, creating lock..."
    LOCK_RESULT=$(ssh -i $SSH_KEY ubuntu@$OP1_IP \
        '~/bathron-cli -testnet lock 100000' 2>&1)
    echo "  Lock result: $LOCK_RESULT"
    log "Waiting 65s for lock confirmation..."
    sleep 65
fi

# Get first suitable receipt
LP_RECEIPT=$(ssh -i $SSH_KEY ubuntu@$OP1_IP '~/bathron-cli -testnet getwalletstate true' 2>&1 | \
    python3 -c "
import sys, json
d = json.load(sys.stdin)
receipts = d.get('m1', {}).get('receipts', [])
for r in receipts:
    if r.get('amount', 0) >= 100000 and r.get('unlockable', False):
        print(r['outpoint'])
        break
" 2>/dev/null)

if [ -z "$LP_RECEIPT" ]; then
    error "No suitable M1 receipt found on LP"
fi
success "LP will use receipt: $LP_RECEIPT"

# =============================================================================
# STEP 4: LP creates M1 HTLC for User with User's hashlock
# =============================================================================
echo ""
log "STEP 4: LP creates M1 HTLC → User (with User's hashlock H)"
echo "  Receipt: $LP_RECEIPT"
echo "  Hashlock: $HASHLOCK"
echo "  Claim addr: $USER_M1_ADDR"

HTLC_RESULT=$(ssh -i $SSH_KEY ubuntu@$OP1_IP \
    "~/bathron-cli -testnet htlc_create_m1 '$LP_RECEIPT' '$HASHLOCK' '$USER_M1_ADDR'" 2>&1)

echo "  Raw result: $HTLC_RESULT"

HTLC_TXID=$(echo "$HTLC_RESULT" | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    print(d.get('txid', ''))
except:
    print('')
" 2>/dev/null)

if [ -z "$HTLC_TXID" ]; then
    error "Failed to create M1 HTLC: $HTLC_RESULT"
fi

HTLC_OUTPOINT="${HTLC_TXID}:0"
success "M1 HTLC created: $HTLC_TXID"

# =============================================================================
# STEP 5: Wait for HTLC confirmation
# =============================================================================
echo ""
log "STEP 5: Waiting for HTLC confirmation (65s)..."
sleep 65

HTLC_STATUS=$(ssh -i $SSH_KEY ubuntu@$OP1_IP \
    "~/bathron-cli -testnet htlc_get '$HTLC_OUTPOINT'" 2>&1)

HTLC_STATE=$(echo "$HTLC_STATUS" | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    print(d.get('status', 'unknown'))
except:
    print('parse_error')
" 2>/dev/null)

echo "  HTLC status: $HTLC_STATE"
[ "$HTLC_STATE" = "active" ] || warn "HTLC not active yet: $HTLC_STATUS"

# =============================================================================
# STEP 6: User (OP3) claims M1 HTLC with secret S
# =============================================================================
echo ""
log "STEP 6: User (OP3) claims M1 HTLC with secret S"
echo "  HTLC outpoint: $HTLC_OUTPOINT"
echo "  Secret (S): $SECRET"

CLAIM_RESULT=$(ssh -i $SSH_KEY ubuntu@$OP3_IP \
    "~/bathron-cli -testnet htlc_claim '$HTLC_OUTPOINT' '$SECRET'" 2>&1)

echo "  Raw result: $CLAIM_RESULT"

CLAIM_TXID=$(echo "$CLAIM_RESULT" | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    print(d.get('txid', ''))
except:
    print('')
" 2>/dev/null)

if [ -z "$CLAIM_TXID" ]; then
    error "User failed to claim HTLC: $CLAIM_RESULT"
fi

success "User claimed M1 HTLC! TX: $CLAIM_TXID"
echo "  --> SECRET S IS NOW PUBLIC ON CHAIN"

# =============================================================================
# STEP 7: Wait for claim confirmation
# =============================================================================
echo ""
log "STEP 7: Waiting for claim confirmation (65s)..."
sleep 65

# =============================================================================
# STEP 8: LP extracts preimage from claimed HTLC
# =============================================================================
echo ""
log "STEP 8: LP extracts preimage from claimed HTLC"

FINAL_HTLC=$(ssh -i $SSH_KEY ubuntu@$OP1_IP \
    "~/bathron-cli -testnet htlc_get '$HTLC_OUTPOINT'" 2>&1)

echo "$FINAL_HTLC" | python3 -c "
import sys, json
d = json.load(sys.stdin)
print(f\"  Status: {d.get('status')}\")
print(f\"  Resolve TX: {d.get('resolve_txid', 'N/A')}\")
print(f\"  Preimage: {d.get('preimage', 'NOT FOUND')}\")
"

EXTRACTED=$(echo "$FINAL_HTLC" | python3 -c "
import sys, json
d = json.load(sys.stdin)
print(d.get('preimage', ''))
" 2>/dev/null)

# =============================================================================
# SUMMARY
# =============================================================================
echo ""
echo "╔══════════════════════════════════════════════════════════════════╗"
echo "║  BIDIRECTIONAL M1 HTLC TEST COMPLETE                             ║"
echo "╠══════════════════════════════════════════════════════════════════╣"
printf "║  Original Secret (User):  %.48s...║\n" "$SECRET"
printf "║  Hashlock (H):            %.48s...║\n" "$HASHLOCK"
printf "║  HTLC TX:                 %.48s...║\n" "$HTLC_TXID"
printf "║  Claim TX:                %.48s...║\n" "$CLAIM_TXID"
printf "║  Extracted Preimage:      %.48s...║\n" "$EXTRACTED"
echo "╚══════════════════════════════════════════════════════════════════╝"

if [ -n "$EXTRACTED" ]; then
    success "LP successfully extracted preimage from User's claim!"
    echo ""
    echo "Flow verified:"
    echo "  1. User generated S, computed H=SHA256(S)"
    echo "  2. LP created M1 HTLC locked with H"
    echo "  3. User claimed HTLC revealing S"
    echo "  4. LP extracted S from blockchain"
    echo ""
    success "In real swap: LP would now claim BTC HTLC using S"
else
    error "Failed to extract preimage"
fi
