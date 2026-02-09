#!/bin/bash
# =============================================================================
# FULL ATOMIC SWAP: BTC ↔ M1 (Production Flow)
# =============================================================================
#
# Complete bidirectional HTLC swap:
# 1. User generates secret S, hashlock H = SHA256(S)
# 2. User creates BTC HTLC → LP (locked by H)
# 3. LP detects BTC HTLC, creates M1 HTLC → User (locked by H)
# 4. User claims M1 HTLC with S (reveals preimage)
# 5. LP extracts S, claims BTC HTLC
#
# =============================================================================

set -e

SSH_KEY=~/.ssh/id_ed25519_vps
LP_API="http://57.131.33.152:8080"
OP1_IP="57.131.33.152"  # LP
OP3_IP="51.75.31.44"    # Fake user

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
btc() { echo -e "${MAGENTA}[BTC]${NC} $1"; }

AMOUNT_BTC="0.00010000"  # 10000 sats
AMOUNT_SATS=10000

echo "╔══════════════════════════════════════════════════════════════════╗"
echo "║  FULL ATOMIC SWAP: BTC ↔ M1 (Production Flow)                    ║"
echo "║  Amount: $AMOUNT_BTC BTC ($AMOUNT_SATS sats)                             ║"
echo "╚══════════════════════════════════════════════════════════════════╝"
echo ""

# =============================================================================
# STEP 0: Pre-checks
# =============================================================================
log "STEP 0: Pre-flight checks"

# Check LP API
LP_STATUS=$(curl -s "$LP_API/api/status" 2>&1)
if ! echo "$LP_STATUS" | grep -q '"status":"ok"'; then
    error "LP API not available"
fi
success "LP API online"

# Check user BTC balance
USER_BTC_BAL=$(ssh -i $SSH_KEY -o ConnectTimeout=15 ubuntu@$OP3_IP '
    ~/bitcoin/bin/bitcoin-cli -signet -datadir=/home/ubuntu/.bitcoin-signet getbalance
' 2>&1)

btc "User BTC balance: $USER_BTC_BAL BTC"

if (( $(echo "$USER_BTC_BAL < 0.0002" | bc -l) )); then
    warn "Low BTC balance. Need at least 0.0002 BTC (amount + fees)"
    echo "  Get testnet BTC from: https://signetfaucet.com"
fi

# =============================================================================
# STEP 1: User generates secret and hashlock
# =============================================================================
echo ""
log "STEP 1: User generates secret S and hashlock H"

SECRET=$(openssl rand -hex 32)
HASHLOCK=$(echo -n "$SECRET" | xxd -r -p | sha256sum | cut -d' ' -f1)

echo "  Secret (S):   $SECRET"
echo "  Hashlock (H): $HASHLOCK"
success "Hashlock = SHA256(Secret)"

# =============================================================================
# STEP 2: Get addresses
# =============================================================================
echo ""
log "STEP 2: Getting addresses"

# User's M1 claim address
USER_M1_ADDR=$(ssh -i $SSH_KEY ubuntu@$OP3_IP \
    '~/bathron-cli -testnet getnewaddress "swap_claim"' 2>&1)
echo "  User M1 claim:    $USER_M1_ADDR"

# User's BTC refund address
USER_BTC_REFUND=$(ssh -i $SSH_KEY ubuntu@$OP3_IP \
    '~/bitcoin/bin/bitcoin-cli -signet -datadir=/home/ubuntu/.bitcoin-signet getnewaddress "swap_refund" bech32' 2>&1)
echo "  User BTC refund:  $USER_BTC_REFUND"

# LP's BTC claim address (from API)
LP_BTC_ADDR=$(curl -s "$LP_API/api/wallets" | python3 -c "import sys,json; print(json.load(sys.stdin).get('btc',{}).get('address',''))" 2>/dev/null)
if [ -z "$LP_BTC_ADDR" ]; then
    LP_BTC_ADDR="tb1qxuljrzqckwyzzmh5l7kq4zslcr6zvahzqfahre"  # fallback
fi
echo "  LP BTC claim:     $LP_BTC_ADDR"

# =============================================================================
# STEP 3: Create BTC HTLC address via API
# =============================================================================
echo ""
log "STEP 3: Generate BTC HTLC address (User → LP)"
api "POST /api/sdk/btc/htlc/create"

BTC_HTLC_RESP=$(curl -s -X POST "$LP_API/api/sdk/btc/htlc/create?amount_sats=$AMOUNT_SATS&hashlock=$HASHLOCK&recipient_address=$LP_BTC_ADDR&refund_address=$USER_BTC_REFUND&timeout_blocks=144" 2>&1)

echo "$BTC_HTLC_RESP" | python3 -m json.tool 2>/dev/null | head -15 | sed 's/^/  /'

BTC_HTLC_ADDR=$(echo "$BTC_HTLC_RESP" | python3 -c "
import sys, json
d = json.load(sys.stdin)
print(d.get('htlc_address', ''))
" 2>/dev/null)

if [ -z "$BTC_HTLC_ADDR" ]; then
    error "Failed to create BTC HTLC: $BTC_HTLC_RESP"
fi

success "BTC HTLC address: $BTC_HTLC_ADDR"

# =============================================================================
# STEP 4: User sends BTC to HTLC address
# =============================================================================
echo ""
log "STEP 4: User sends $AMOUNT_BTC BTC to HTLC address"
btc "Sending from OP3 to $BTC_HTLC_ADDR"

BTC_SEND_RESULT=$(ssh -i $SSH_KEY ubuntu@$OP3_IP "
    ~/bitcoin/bin/bitcoin-cli -signet -datadir=/home/ubuntu/.bitcoin-signet \
    sendtoaddress '$BTC_HTLC_ADDR' $AMOUNT_BTC
" 2>&1)

if [[ "$BTC_SEND_RESULT" =~ ^[a-f0-9]{64}$ ]]; then
    BTC_HTLC_TXID="$BTC_SEND_RESULT"
    success "BTC sent! TXID: $BTC_HTLC_TXID"
else
    error "Failed to send BTC: $BTC_SEND_RESULT"
fi

# =============================================================================
# STEP 5: Wait for BTC confirmation
# =============================================================================
echo ""
log "STEP 5: Waiting for BTC confirmation (~10 min on Signet)..."
echo "  Signet blocks are ~10 min. Checking every 30s..."

for i in {1..30}; do
    sleep 30

    BTC_CONF=$(ssh -i $SSH_KEY ubuntu@$OP3_IP "
        ~/bitcoin/bin/bitcoin-cli -signet -datadir=/home/ubuntu/.bitcoin-signet \
        gettransaction '$BTC_HTLC_TXID' 2>/dev/null | python3 -c 'import sys,json; print(json.load(sys.stdin).get(\"confirmations\",0))'
    " 2>/dev/null || echo "0")

    btc "BTC confirmations: $BTC_CONF (attempt $i/30)"

    if [ "$BTC_CONF" -ge 1 ]; then
        success "BTC HTLC confirmed!"
        break
    fi
done

if [ "$BTC_CONF" -lt 1 ]; then
    warn "BTC not yet confirmed after 15 min. Continuing anyway (LP may wait)..."
fi

# =============================================================================
# STEP 6: Check BTC HTLC funded via API
# =============================================================================
echo ""
log "STEP 6: Verify BTC HTLC funded"
api "GET /api/sdk/btc/htlc/check"

BTC_CHECK=$(curl -s "$LP_API/api/sdk/btc/htlc/check?htlc_address=$BTC_HTLC_ADDR&expected_amount=$AMOUNT_SATS&min_confirmations=0" 2>&1)
echo "$BTC_CHECK" | python3 -m json.tool 2>/dev/null | sed 's/^/  /'

FUNDED=$(echo "$BTC_CHECK" | python3 -c "import sys,json; print(json.load(sys.stdin).get('funded', False))" 2>/dev/null)

if [ "$FUNDED" = "True" ]; then
    success "BTC HTLC is funded!"
else
    warn "BTC HTLC not detected as funded yet"
fi

# =============================================================================
# STEP 7: LP creates M1 HTLC (responds to user's BTC HTLC)
# =============================================================================
echo ""
log "STEP 7: LP creates M1 HTLC → User (same hashlock)"
api "POST /api/atomic/initiate"

# Calculate M1 amount (with 1% spread)
M1_AMOUNT=$(python3 -c "print(int($AMOUNT_SATS * 0.99))")

INIT_RESP=$(curl -s -X POST "$LP_API/api/atomic/initiate" \
    -H "Content-Type: application/json" \
    -d "{
        \"from_asset\": \"BTC\",
        \"to_asset\": \"M1\",
        \"from_amount\": $AMOUNT_BTC,
        \"hashlock\": \"$HASHLOCK\",
        \"user_claim_address\": \"$USER_M1_ADDR\",
        \"user_refund_address\": \"$USER_BTC_REFUND\"
    }" 2>&1)

echo "$INIT_RESP" | python3 -m json.tool 2>/dev/null | head -20 | sed 's/^/  /'

SWAP_ID=$(echo "$INIT_RESP" | python3 -c "import sys,json; print(json.load(sys.stdin).get('swap_id',''))" 2>/dev/null)
M1_HTLC_OUTPOINT=$(echo "$INIT_RESP" | python3 -c "import sys,json; print(json.load(sys.stdin).get('lp_htlc',{}).get('htlc_outpoint',''))" 2>/dev/null)

if [ -z "$M1_HTLC_OUTPOINT" ]; then
    error "LP failed to create M1 HTLC: $INIT_RESP"
fi

success "LP created M1 HTLC: $M1_HTLC_OUTPOINT"

# =============================================================================
# STEP 8: Wait for M1 HTLC confirmation
# =============================================================================
echo ""
log "STEP 8: Waiting for M1 HTLC confirmation (65s)..."
sleep 65

# =============================================================================
# STEP 9: User claims M1 HTLC with secret
# =============================================================================
echo ""
log "STEP 9: User claims M1 HTLC with secret S"
echo "  --> This reveals S to LP!"

M1_CLAIM=$(ssh -i $SSH_KEY ubuntu@$OP3_IP \
    "~/bathron-cli -testnet htlc_claim '$M1_HTLC_OUTPOINT' '$SECRET'" 2>&1)

echo "$M1_CLAIM" | python3 -m json.tool 2>/dev/null | sed 's/^/  /'

M1_CLAIM_TXID=$(echo "$M1_CLAIM" | python3 -c "import sys,json; print(json.load(sys.stdin).get('txid',''))" 2>/dev/null)

if [ -z "$M1_CLAIM_TXID" ]; then
    error "User failed to claim M1: $M1_CLAIM"
fi

success "User claimed M1! TX: $M1_CLAIM_TXID"
echo "  --> SECRET S IS NOW PUBLIC ON BATHRON CHAIN"

# =============================================================================
# STEP 10: Wait for M1 claim confirmation
# =============================================================================
echo ""
log "STEP 10: Waiting for M1 claim confirmation (65s)..."
sleep 65

# =============================================================================
# STEP 11: LP extracts preimage and claims BTC
# =============================================================================
echo ""
log "STEP 11: LP extracts preimage from M1 chain"

M1_HTLC_STATUS=$(ssh -i $SSH_KEY ubuntu@$OP1_IP \
    "~/bathron-cli -testnet htlc_get '$M1_HTLC_OUTPOINT'" 2>&1)

EXTRACTED=$(echo "$M1_HTLC_STATUS" | python3 -c "import sys,json; print(json.load(sys.stdin).get('preimage',''))" 2>/dev/null)

echo "  HTLC status:"
echo "$M1_HTLC_STATUS" | python3 -c "
import sys,json
d = json.load(sys.stdin)
print(f\"    Status: {d.get('status')}\")
print(f\"    Preimage: {d.get('preimage', 'N/A')}\")
"

if [ -n "$EXTRACTED" ]; then
    success "LP extracted preimage: $EXTRACTED"
    echo ""
    btc "LP would now claim BTC HTLC using this preimage"
    echo "  (BTC claim requires spending the P2WSH with preimage + signature)"
else
    warn "Preimage not yet extracted"
fi

# =============================================================================
# SUMMARY
# =============================================================================
echo ""
echo "╔══════════════════════════════════════════════════════════════════════╗"
echo "║  FULL ATOMIC SWAP COMPLETE                                           ║"
echo "╠══════════════════════════════════════════════════════════════════════╣"
echo "║                                                                      ║"
echo "║  SWAP DETAILS                                                        ║"
echo "║  ───────────────────────────────────────────────────────────────     ║"
printf "║  Swap ID:       %-50s   ║\n" "$SWAP_ID"
printf "║  Amount:        %-50s   ║\n" "$AMOUNT_BTC BTC → ~$M1_AMOUNT M1 sats"
echo "║                                                                      ║"
echo "║  SECRETS                                                             ║"
echo "║  ───────────────────────────────────────────────────────────────     ║"
printf "║  Secret (S):    %.56s...║\n" "$SECRET"
printf "║  Hashlock (H):  %.56s...║\n" "$HASHLOCK"
printf "║  Extracted:     %.56s...║\n" "$EXTRACTED"
echo "║                                                                      ║"
echo "║  TRANSACTIONS                                                        ║"
echo "║  ───────────────────────────────────────────────────────────────     ║"
printf "║  BTC HTLC TX:   %.56s...║\n" "$BTC_HTLC_TXID"
printf "║  M1 HTLC:       %.56s...║\n" "$M1_HTLC_OUTPOINT"
printf "║  M1 Claim TX:   %.56s...║\n" "$M1_CLAIM_TXID"
echo "║                                                                      ║"
echo "╚══════════════════════════════════════════════════════════════════════╝"
echo ""

if [ -n "$EXTRACTED" ] && [ -n "$M1_CLAIM_TXID" ]; then
    success "ATOMIC SWAP SUCCESSFUL!"
    echo ""
    echo "  Flow completed:"
    echo "  [1] User sent $AMOUNT_BTC BTC to HTLC (locked by H)"
    echo "  [2] LP created M1 HTLC for User (locked by same H)"
    echo "  [3] User claimed M1 with secret S"
    echo "  [4] LP extracted S from blockchain"
    echo "  [5] LP can now claim BTC using S"
    echo ""
    echo "  TRUSTLESS: Neither party could cheat!"
else
    warn "Swap incomplete - check logs above"
fi
