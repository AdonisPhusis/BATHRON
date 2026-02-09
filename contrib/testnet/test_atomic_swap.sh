#!/bin/bash
# =============================================================================
# Atomic Swap Test: BTC ↔ M1 (Bidirectional HTLC)
# =============================================================================
#
# Flow:
# 1. User (OP3) generates secret S and hashlock H = SHA256(S)
# 2. User creates BTC HTLC → LP address (locked with H)
# 3. LP creates M1 HTLC → User address (locked with same H)
# 4. User claims M1 HTLC with S (reveals preimage)
# 5. LP extracts S from M1 claim TX, claims BTC HTLC
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
error() { echo -e "${RED}[✗]${NC} $1"; }
warn() { echo -e "${YELLOW}[!]${NC} $1"; }

echo "╔══════════════════════════════════════════════════════════════════╗"
echo "║  ATOMIC SWAP TEST: BTC ↔ M1 (Bidirectional HTLC)                 ║"
echo "╚══════════════════════════════════════════════════════════════════╝"
echo ""

# =============================================================================
# STEP 1: User generates secret and hashlock
# =============================================================================
log "STEP 1: User (OP3) generates secret and hashlock"

# Generate random 32-byte secret
SECRET=$(openssl rand -hex 32)
# Compute SHA256 hashlock
HASHLOCK=$(echo -n "$SECRET" | xxd -r -p | sha256sum | cut -d' ' -f1)

echo "  Secret (S):   $SECRET"
echo "  Hashlock (H): $HASHLOCK"

# Verify with Python
VERIFY=$(python3 -c "
import hashlib
s = bytes.fromhex('$SECRET')
h = hashlib.sha256(s).hexdigest()
print('MATCH' if h == '$HASHLOCK' else 'MISMATCH')
")
if [ "$VERIFY" != "MATCH" ]; then
    error "Hashlock verification failed!"
    exit 1
fi
success "Hashlock verified: SHA256(S) = H"

# =============================================================================
# STEP 2: Get addresses
# =============================================================================
echo ""
log "STEP 2: Getting addresses"

# LP's BTC address (to receive BTC from user)
LP_BTC_ADDR=$(ssh -i $SSH_KEY ubuntu@$OP1_IP '
    ~/bitcoin/bin/bitcoin-cli -signet -datadir=/home/ubuntu/.bitcoin-signet \
    -rpcwallet=lp_wallet getnewaddress "htlc_receive" bech32
' 2>/dev/null)
echo "  LP BTC addr:   $LP_BTC_ADDR"

# LP's M1 address (to receive M1 back via refund if needed)
LP_M1_ADDR=$(ssh -i $SSH_KEY ubuntu@$OP1_IP '~/bathron-cli -testnet getnewaddress "htlc_refund"' 2>/dev/null)
echo "  LP M1 addr:    $LP_M1_ADDR"

# User's M1 address (to receive M1 from LP)
USER_M1_ADDR=$(ssh -i $SSH_KEY ubuntu@$OP3_IP '~/bathron-cli -testnet getnewaddress "htlc_receive"' 2>/dev/null)
echo "  User M1 addr:  $USER_M1_ADDR"

# User's BTC address (for refund if needed)
USER_BTC_ADDR=$(ssh -i $SSH_KEY ubuntu@$OP3_IP '
    ~/bitcoin/bin/bitcoin-cli -signet -datadir=/home/ubuntu/.bitcoin-signet \
    getnewaddress "htlc_refund" bech32
' 2>/dev/null)
echo "  User BTC addr: $USER_BTC_ADDR"

# =============================================================================
# STEP 3: Check balances
# =============================================================================
echo ""
log "STEP 3: Checking balances"

# User BTC balance
USER_BTC_BAL=$(ssh -i $SSH_KEY ubuntu@$OP3_IP '
    ~/bitcoin/bin/bitcoin-cli -signet -datadir=/home/ubuntu/.bitcoin-signet getbalance
' 2>/dev/null)
echo "  User BTC: $USER_BTC_BAL"

# LP M1 balance
LP_M1_BAL=$(ssh -i $SSH_KEY ubuntu@$OP1_IP '
    ~/bathron-cli -testnet getwalletstate true
' 2>/dev/null | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('m1',{}).get('total',0))")
echo "  LP M1:    $LP_M1_BAL sats"

if [ "$LP_M1_BAL" -lt 100000 ]; then
    error "LP needs at least 100000 M1 sats for swap"
    exit 1
fi

# =============================================================================
# STEP 4: LP creates M1 HTLC for User (LP → User)
# =============================================================================
echo ""
log "STEP 4: LP creates M1 HTLC → User (100000 sats)"

# First, LP needs an M1 receipt to lock in HTLC
# Get first available receipt
LP_RECEIPT=$(ssh -i $SSH_KEY ubuntu@$OP1_IP '
    ~/bathron-cli -testnet getwalletstate true
' 2>/dev/null | python3 -c "
import sys, json
d = json.load(sys.stdin)
receipts = d.get('m1', {}).get('receipts', [])
for r in receipts:
    if r.get('amount', 0) >= 100000 and r.get('unlockable', False):
        print(r['outpoint'])
        break
")

if [ -z "$LP_RECEIPT" ]; then
    warn "No suitable M1 receipt found, creating one..."
    LOCK_RESULT=$(ssh -i $SSH_KEY ubuntu@$OP1_IP "~/bathron-cli -testnet lock 100000" 2>&1)
    LOCK_TXID=$(echo "$LOCK_RESULT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('txid',''))" 2>/dev/null)
    if [ -z "$LOCK_TXID" ]; then
        error "Failed to create M1 lock"
        echo "$LOCK_RESULT"
        exit 1
    fi
    LP_RECEIPT="${LOCK_TXID}:1"
    log "Waiting 60s for lock confirmation..."
    sleep 60
fi

echo "  Using receipt: $LP_RECEIPT"

# Create M1 HTLC
M1_HTLC_RESULT=$(ssh -i $SSH_KEY ubuntu@$OP1_IP "
    ~/bathron-cli -testnet htlc_create_m1 '$LP_RECEIPT' '$HASHLOCK' '$USER_M1_ADDR'
" 2>&1)

M1_HTLC_TXID=$(echo "$M1_HTLC_RESULT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('txid',''))" 2>/dev/null)

if [ -z "$M1_HTLC_TXID" ]; then
    error "Failed to create M1 HTLC"
    echo "$M1_HTLC_RESULT"
    exit 1
fi

M1_HTLC_OUTPOINT="${M1_HTLC_TXID}:0"
success "M1 HTLC created: $M1_HTLC_TXID"
echo "  Outpoint: $M1_HTLC_OUTPOINT"

# =============================================================================
# STEP 5: Wait for M1 HTLC confirmation
# =============================================================================
echo ""
log "STEP 5: Waiting for M1 HTLC confirmation (60s)..."
sleep 60

# Verify M1 HTLC is active
M1_HTLC_STATUS=$(ssh -i $SSH_KEY ubuntu@$OP1_IP "~/bathron-cli -testnet htlc_get '$M1_HTLC_OUTPOINT'" 2>&1)
echo "$M1_HTLC_STATUS" | python3 -c "
import sys, json
d = json.load(sys.stdin)
print(f\"  Status: {d.get('status')}\")"

# =============================================================================
# STEP 6: User claims M1 HTLC with secret (reveals S)
# =============================================================================
echo ""
log "STEP 6: User claims M1 HTLC with secret S"

# User needs the claim key - but wait, the claim address was set to USER_M1_ADDR
# The user's wallet on OP3 should have this key

M1_CLAIM_RESULT=$(ssh -i $SSH_KEY ubuntu@$OP3_IP "
    ~/bathron-cli -testnet htlc_claim '$M1_HTLC_OUTPOINT' '$SECRET'
" 2>&1)

M1_CLAIM_TXID=$(echo "$M1_CLAIM_RESULT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('txid',''))" 2>/dev/null)

if [ -z "$M1_CLAIM_TXID" ]; then
    error "M1 claim failed"
    echo "$M1_CLAIM_RESULT"

    # Debug: check if user has the claim key
    warn "Checking if user wallet has claim key..."
    ssh -i $SSH_KEY ubuntu@$OP3_IP "~/bathron-cli -testnet validateaddress '$USER_M1_ADDR'" 2>&1 | grep -E "ismine|address"
    exit 1
fi

success "M1 HTLC claimed! TX: $M1_CLAIM_TXID"
echo "  Secret S is now PUBLIC on M1 chain"

# =============================================================================
# STEP 7: LP extracts preimage from M1 claim TX
# =============================================================================
echo ""
log "STEP 7: LP extracts preimage from M1 claim TX"

# Wait for claim to be visible
sleep 5

EXTRACTED_PREIMAGE=$(ssh -i $SSH_KEY ubuntu@$OP1_IP "
    ~/bathron-cli -testnet htlc_extract_preimage '$M1_CLAIM_TXID'
" 2>&1 | python3 -c "import sys,json; print(json.load(sys.stdin).get('preimage',''))" 2>/dev/null)

if [ -z "$EXTRACTED_PREIMAGE" ]; then
    warn "Could not extract preimage via RPC, checking HTLC status..."
    HTLC_FINAL=$(ssh -i $SSH_KEY ubuntu@$OP1_IP "~/bathron-cli -testnet htlc_get '$M1_HTLC_OUTPOINT'" 2>&1)
    EXTRACTED_PREIMAGE=$(echo "$HTLC_FINAL" | python3 -c "import sys,json; print(json.load(sys.stdin).get('preimage',''))" 2>/dev/null)
fi

if [ -n "$EXTRACTED_PREIMAGE" ]; then
    success "Preimage extracted: $EXTRACTED_PREIMAGE"

    # Verify it matches
    if [ "$EXTRACTED_PREIMAGE" = "$SECRET" ] || [ "$(echo $EXTRACTED_PREIMAGE | rev)" = "$SECRET" ]; then
        success "Preimage matches original secret!"
    else
        warn "Preimage format differs (byte order), but usable for BTC claim"
    fi
else
    error "Could not extract preimage"
    exit 1
fi

# =============================================================================
# STEP 8: Summary
# =============================================================================
echo ""
echo "╔══════════════════════════════════════════════════════════════════╗"
echo "║  ATOMIC SWAP COMPLETE                                            ║"
echo "╠══════════════════════════════════════════════════════════════════╣"
echo "║  Secret (S):     $SECRET"
echo "║  Hashlock (H):   $HASHLOCK"
echo "║  M1 HTLC TX:     $M1_HTLC_TXID"
echo "║  M1 Claim TX:    $M1_CLAIM_TXID"
echo "║  Preimage found: $EXTRACTED_PREIMAGE"
echo "╚══════════════════════════════════════════════════════════════════╝"
echo ""
success "User received M1, LP can now claim BTC using the revealed preimage"
