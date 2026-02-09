#!/usr/bin/env bash
set -euo pipefail

# test_htlc_flow.sh
# Full HTLC test on OP1 (LP node)
# Tests: lock M0→M1, create HTLC, claim HTLC

SSH_KEY="$HOME/.ssh/id_ed25519_vps"
SSH_OPTS="-i $SSH_KEY -o StrictHostKeyChecking=no -o ConnectTimeout=10"
OP1_IP="57.131.33.152"
CLI="~/bathron-cli -testnet"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
log_info()    { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[OK]${NC} $1"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $1"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC} $1"; }

ssh_cmd() {
    ssh $SSH_OPTS ubuntu@$OP1_IP "$1"
}

echo ""
echo "=============================================="
echo "     HTLC Full Flow Test on OP1"
echo "=============================================="
echo ""

# -----------------------------------------------
# STEP 1: Check initial state
# -----------------------------------------------
log_info "Step 1: Checking initial state..."

WALLET_STATE=$(ssh_cmd "$CLI getwalletstate true")
M0_BALANCE=$(echo "$WALLET_STATE" | jq -r '.m0.balance')
M1_COUNT=$(echo "$WALLET_STATE" | jq -r '.m1.count')

echo "  M0 balance: $M0_BALANCE"
echo "  M1 receipts: $M1_COUNT"

if [ "$M0_BALANCE" -lt 100000 ]; then
    log_error "Insufficient M0 balance. Need at least 100,000 sats."
    exit 1
fi

# -----------------------------------------------
# STEP 2: Lock M0 → M1 (create receipt for HTLC)
# -----------------------------------------------
LOCK_AMOUNT=50000
log_info "Step 2: Locking $LOCK_AMOUNT M0 → M1..."

LOCK_RESULT=$(ssh_cmd "$CLI lock $LOCK_AMOUNT" 2>&1) || {
    log_error "Lock failed: $LOCK_RESULT"
    exit 1
}

LOCK_TXID=$(echo "$LOCK_RESULT" | jq -r '.txid // empty')
if [ -z "$LOCK_TXID" ]; then
    log_error "Lock returned no txid: $LOCK_RESULT"
    exit 1
fi
log_success "Lock TX: $LOCK_TXID"

# Wait for confirmation
log_info "Waiting for block confirmation (up to 90s)..."
for i in {1..15}; do
    sleep 6
    CONFIRMS=$(ssh_cmd "$CLI gettransaction $LOCK_TXID 2>/dev/null | jq -r '.confirmations // 0'" 2>/dev/null || echo "0")
    echo -n "  Confirmations: $CONFIRMS"
    if [ "$CONFIRMS" -ge 1 ]; then
        echo ""
        log_success "Lock confirmed!"
        break
    fi
    echo " (waiting...)"
done

# -----------------------------------------------
# STEP 3: Get M1 receipt outpoint
# -----------------------------------------------
log_info "Step 3: Getting M1 receipt..."

WALLET_STATE=$(ssh_cmd "$CLI getwalletstate true")
RECEIPT=$(echo "$WALLET_STATE" | jq -r '.m1.receipts[0] // empty')

if [ -z "$RECEIPT" ]; then
    log_error "No M1 receipt found after lock"
    echo "$WALLET_STATE"
    exit 1
fi

RECEIPT_OUTPOINT=$(echo "$RECEIPT" | jq -r '.outpoint')
RECEIPT_AMOUNT=$(echo "$RECEIPT" | jq -r '.amount')

log_success "Receipt: $RECEIPT_OUTPOINT (amount: $RECEIPT_AMOUNT)"

# -----------------------------------------------
# STEP 4: Generate HTLC secret/hashlock
# -----------------------------------------------
log_info "Step 4: Generating HTLC secret..."

HTLC_GEN=$(ssh_cmd "$CLI htlc_generate")
SECRET=$(echo "$HTLC_GEN" | jq -r '.secret')
HASHLOCK=$(echo "$HTLC_GEN" | jq -r '.hashlock')

echo "  Secret:   ${SECRET:0:16}..."
echo "  Hashlock: ${HASHLOCK:0:16}..."

# -----------------------------------------------
# STEP 5: Get a claim address
# -----------------------------------------------
log_info "Step 5: Getting claim address..."

CLAIM_ADDR=$(ssh_cmd "$CLI getnewaddress htlc_claim")
log_success "Claim address: $CLAIM_ADDR"

# -----------------------------------------------
# STEP 6: Create M1 HTLC
# -----------------------------------------------
EXPIRY_BLOCKS=50  # Short for testing
log_info "Step 6: Creating M1 HTLC (expiry: $EXPIRY_BLOCKS blocks)..."

HTLC_CREATE=$(ssh_cmd "$CLI htlc_create_m1 \"$RECEIPT_OUTPOINT\" \"$HASHLOCK\" \"$CLAIM_ADDR\" $EXPIRY_BLOCKS" 2>&1) || {
    log_error "HTLC create failed: $HTLC_CREATE"
    exit 1
}

HTLC_TXID=$(echo "$HTLC_CREATE" | jq -r '.txid // empty')
if [ -z "$HTLC_TXID" ]; then
    log_error "HTLC create returned no txid: $HTLC_CREATE"
    exit 1
fi
log_success "HTLC created: $HTLC_TXID"

# Wait for HTLC to confirm
log_info "Waiting for HTLC confirmation..."
for i in {1..15}; do
    sleep 6
    CONFIRMS=$(ssh_cmd "$CLI gettransaction $HTLC_TXID 2>/dev/null | jq -r '.confirmations // 0'" 2>/dev/null || echo "0")
    echo -n "  Confirmations: $CONFIRMS"
    if [ "$CONFIRMS" -ge 1 ]; then
        echo ""
        log_success "HTLC confirmed!"
        break
    fi
    echo " (waiting...)"
done

# -----------------------------------------------
# STEP 7: Verify HTLC exists
# -----------------------------------------------
log_info "Step 7: Verifying HTLC..."

HTLC_OUTPOINT="${HTLC_TXID}:0"
HTLC_INFO=$(ssh_cmd "$CLI htlc_get \"$HTLC_OUTPOINT\"" 2>&1) || {
    log_warn "htlc_get failed (might need htlc_list): $HTLC_INFO"
}

if [ -n "$HTLC_INFO" ] && [ "$HTLC_INFO" != "null" ]; then
    echo "$HTLC_INFO" | jq .
fi

# List all HTLCs
log_info "Listing all HTLCs..."
ssh_cmd "$CLI htlc_list" 2>&1 | jq . || echo "No HTLCs or command failed"

# -----------------------------------------------
# STEP 8: Claim HTLC with preimage
# -----------------------------------------------
log_info "Step 8: Claiming HTLC with preimage..."

CLAIM_RESULT=$(ssh_cmd "$CLI htlc_claim \"$HTLC_OUTPOINT\" \"$SECRET\"" 2>&1) || {
    log_error "HTLC claim failed: $CLAIM_RESULT"
    echo ""
    log_warn "This is expected if htlc_claim requires waiting for confirmation or different syntax"
    exit 1
}

CLAIM_TXID=$(echo "$CLAIM_RESULT" | jq -r '.txid // empty')
if [ -n "$CLAIM_TXID" ]; then
    log_success "HTLC claimed: $CLAIM_TXID"
else
    log_warn "Claim result: $CLAIM_RESULT"
fi

# -----------------------------------------------
# STEP 9: Verify final state
# -----------------------------------------------
log_info "Step 9: Final state verification..."

FINAL_STATE=$(ssh_cmd "$CLI getwalletstate true")
FINAL_M1=$(echo "$FINAL_STATE" | jq -r '.m1.count')
FINAL_RECEIPTS=$(echo "$FINAL_STATE" | jq -r '.m1.receipts')

echo "  M1 receipt count: $FINAL_M1"
echo "  Receipts: $FINAL_RECEIPTS"

echo ""
echo "=============================================="
echo "     HTLC Test Complete!"
echo "=============================================="
echo ""
echo "Summary:"
echo "  - Lock TX:  $LOCK_TXID"
echo "  - HTLC TX:  $HTLC_TXID"
echo "  - Claim TX: ${CLAIM_TXID:-'(pending)'}"
echo ""
