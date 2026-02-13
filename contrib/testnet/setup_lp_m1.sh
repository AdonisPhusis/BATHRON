#!/usr/bin/env bash
# =============================================================================
# setup_lp_m1.sh - Lock M0 → M1 on LP1, then split 30% to LP2
# =============================================================================
#
# Usage:
#   ./setup_lp_m1.sh          # Execute lock + split
#   ./setup_lp_m1.sh status   # Check M1 state on LPs
# =============================================================================

set -euo pipefail

SSH_KEY="$HOME/.ssh/id_ed25519_vps"
SSH_OPTS="-i $SSH_KEY -o StrictHostKeyChecking=no -o ConnectTimeout=10 -o BatchMode=yes"

# LP1 = alice on OP1
LP1_IP="57.131.33.152"
LP1_CLI="/home/ubuntu/bathron-cli -testnet"
LP1_NAME="alice"

# LP2 = dev on OP2
LP2_IP="57.131.33.214"
LP2_CLI="/home/ubuntu/bathron-cli -testnet"
LP2_NAME="dev"
LP2_ADDR="y7XRqXgz1d8ELErDxtwQPnvfbe2ZcUecka"

# Keep some M0 for fees on LP1
FEE_RESERVE=100000  # 100k sats for future fees

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

log()     { echo -e "${CYAN}[$(date +%H:%M:%S)]${NC} $*"; }
success() { echo -e "${GREEN}[OK]${NC} $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

show_status() {
    echo ""
    log "=== LP M1 Status ==="
    echo ""

    for LP_INFO in "LP1 ($LP1_NAME)|$LP1_IP|$LP1_CLI" "LP2 ($LP2_NAME)|$LP2_IP|$LP2_CLI"; do
        IFS='|' read -r name ip cli <<< "$LP_INFO"
        echo -e "${CYAN}$name ($ip):${NC}"
        BALANCE=$(ssh $SSH_OPTS ubuntu@$ip "$cli getbalance" 2>&1 || echo "{}")
        M0=$(echo "$BALANCE" | jq -r '.m0 // 0' 2>/dev/null)
        M1=$(echo "$BALANCE" | jq -r '.m1 // 0' 2>/dev/null)
        echo "  M0: $M0  M1: $M1"

        WSTATE=$(ssh $SSH_OPTS ubuntu@$ip "$cli getwalletstate true" 2>&1 || echo "{}")
        RECEIPTS=$(echo "$WSTATE" | jq -r '.m1.receipts // []' 2>/dev/null)
        COUNT=$(echo "$RECEIPTS" | jq 'length' 2>/dev/null || echo "0")
        if [ "$COUNT" != "0" ] && [ "$COUNT" != "null" ]; then
            echo "$RECEIPTS" | jq -r '.[] | "  → \(.outpoint)  amount=\(.amount)"' 2>/dev/null
        else
            echo "  (no M1 receipts)"
        fi
        echo ""
    done

    echo "=== Global ==="
    ssh $SSH_OPTS ubuntu@$LP1_IP "$LP1_CLI getstate" 2>&1 | jq '{m0_vaulted: .supply.m0_vaulted, m1_supply: .supply.m1_supply}' 2>/dev/null || echo "ERROR"
}

do_setup() {
    # Step 1: Check LP1 M0 balance
    log "Step 1: Checking LP1 ($LP1_NAME) M0 balance..."
    LP1_BALANCE=$(ssh $SSH_OPTS ubuntu@$LP1_IP "$LP1_CLI getbalance" 2>&1)
    LP1_M0=$(echo "$LP1_BALANCE" | jq -r '.m0' 2>/dev/null)

    if [ -z "$LP1_M0" ] || [ "$LP1_M0" = "null" ] || [ "$LP1_M0" = "0" ]; then
        error "LP1 ($LP1_NAME) has no M0. Run fix_wallet_import.sh first."
    fi
    success "LP1 M0 balance: $LP1_M0 sats"

    # Calculate lock amount (keep fee reserve)
    LOCK_AMOUNT=$((LP1_M0 - FEE_RESERVE))
    if [ "$LOCK_AMOUNT" -le 0 ]; then
        error "LP1 M0 ($LP1_M0) too small to lock (need > $FEE_RESERVE for fees)"
    fi

    # Calculate split: 70% LP1, 30% LP2
    LP2_SHARE=$((LOCK_AMOUNT * 30 / 100))
    LP1_SHARE=$((LOCK_AMOUNT - LP2_SHARE))

    log "Plan:"
    log "  Lock: $LOCK_AMOUNT M0 → M1"
    log "  LP1 ($LP1_NAME): $LP1_SHARE M1 (70%)"
    log "  LP2 ($LP2_NAME): $LP2_SHARE M1 (30%)"
    log "  Fee reserve: $FEE_RESERVE M0 (stays as M0)"
    echo ""

    # Step 2: Lock M0 → M1 on LP1
    log "Step 2: Locking $LOCK_AMOUNT M0 → M1 on LP1..."
    LOCK_RESULT=$(ssh $SSH_OPTS ubuntu@$LP1_IP "$LP1_CLI lock $LOCK_AMOUNT" 2>&1)
    LOCK_TXID=$(echo "$LOCK_RESULT" | jq -r '.txid // empty' 2>/dev/null)

    if [ -z "$LOCK_TXID" ]; then
        error "Lock failed: $LOCK_RESULT"
    fi
    success "Lock TX: $LOCK_TXID"

    # Step 3: Wait for confirmation
    log "Step 3: Waiting for lock TX to confirm (~60-120s)..."
    for i in $(seq 1 30); do
        sleep 10
        CONFIRMATIONS=$(ssh $SSH_OPTS ubuntu@$LP1_IP "$LP1_CLI gettransaction $LOCK_TXID" 2>&1 | jq -r '.confirmations // 0' 2>/dev/null || echo "0")
        if [ "$CONFIRMATIONS" -ge 1 ]; then
            success "Lock confirmed (${CONFIRMATIONS} confirmations) after $((i * 10))s"
            break
        fi
        echo -n "."
    done
    echo ""

    if [ "$CONFIRMATIONS" -lt 1 ]; then
        error "Lock TX not confirmed after 300s. Check network."
    fi

    # Step 4: Get M1 receipt outpoint
    log "Step 4: Getting M1 receipt..."
    WSTATE=$(ssh $SSH_OPTS ubuntu@$LP1_IP "$LP1_CLI getwalletstate true" 2>&1)
    RECEIPT_OUTPOINT=$(echo "$WSTATE" | jq -r '.m1.receipts[0].outpoint // empty' 2>/dev/null)
    RECEIPT_AMOUNT=$(echo "$WSTATE" | jq -r '.m1.receipts[0].amount // 0' 2>/dev/null)

    if [ -z "$RECEIPT_OUTPOINT" ]; then
        error "No M1 receipt found after lock. Check getwalletstate."
    fi
    success "M1 Receipt: $RECEIPT_OUTPOINT = $RECEIPT_AMOUNT sats"

    # Step 5: Split M1 — 70% LP1, 30% LP2
    # Fee is deducted automatically from M1, so we need to account for it
    # split_m1 fee is ~23 sats (TX_TRANSFER_M1 fee)
    SPLIT_FEE=50  # conservative estimate
    LP2_SHARE_FINAL=$LP2_SHARE
    LP1_SHARE_FINAL=$((RECEIPT_AMOUNT - LP2_SHARE_FINAL - SPLIT_FEE))

    log "Step 5: Splitting M1 receipt..."
    log "  LP1 ($LP1_NAME): $LP1_SHARE_FINAL M1"
    log "  LP2 ($LP2_NAME → $LP2_ADDR): $LP2_SHARE_FINAL M1"
    log "  Fee: ~$SPLIT_FEE M1"

    # Get LP1 address for the return
    LP1_ADDR=$(ssh $SSH_OPTS ubuntu@$LP1_IP "jq -r '.address' ~/.BathronKey/wallet.json" 2>&1)

    SPLIT_RESULT=$(ssh $SSH_OPTS ubuntu@$LP1_IP "$LP1_CLI split_m1 \"$RECEIPT_OUTPOINT\" '[{\"address\":\"$LP1_ADDR\",\"amount\":$LP1_SHARE_FINAL},{\"address\":\"$LP2_ADDR\",\"amount\":$LP2_SHARE_FINAL}]'" 2>&1)
    SPLIT_TXID=$(echo "$SPLIT_RESULT" | jq -r '.txid // empty' 2>/dev/null)

    if [ -z "$SPLIT_TXID" ]; then
        # If split fails, try with adjusted amounts (fee might be different)
        warn "Split failed: $SPLIT_RESULT"
        warn "Retrying with smaller amounts..."
        SPLIT_FEE=100
        LP1_SHARE_FINAL=$((RECEIPT_AMOUNT - LP2_SHARE_FINAL - SPLIT_FEE))
        SPLIT_RESULT=$(ssh $SSH_OPTS ubuntu@$LP1_IP "$LP1_CLI split_m1 \"$RECEIPT_OUTPOINT\" '[{\"address\":\"$LP1_ADDR\",\"amount\":$LP1_SHARE_FINAL},{\"address\":\"$LP2_ADDR\",\"amount\":$LP2_SHARE_FINAL}]'" 2>&1)
        SPLIT_TXID=$(echo "$SPLIT_RESULT" | jq -r '.txid // empty' 2>/dev/null)
        if [ -z "$SPLIT_TXID" ]; then
            error "Split failed: $SPLIT_RESULT"
        fi
    fi
    success "Split TX: $SPLIT_TXID"

    # Step 6: Wait for split confirmation
    log "Step 6: Waiting for split TX to confirm..."
    for i in $(seq 1 30); do
        sleep 10
        CONFIRMATIONS=$(ssh $SSH_OPTS ubuntu@$LP1_IP "$LP1_CLI gettransaction $SPLIT_TXID" 2>&1 | jq -r '.confirmations // 0' 2>/dev/null || echo "0")
        if [ "$CONFIRMATIONS" -ge 1 ]; then
            success "Split confirmed (${CONFIRMATIONS} confirmations)"
            break
        fi
        echo -n "."
    done
    echo ""

    # Step 7: Rescan LP2 to see the new M1
    log "Step 7: Rescanning LP2 wallet..."
    ssh $SSH_OPTS ubuntu@$LP2_IP "$LP2_CLI rescanblockchain 0" 2>/dev/null || warn "LP2 rescan returned error (may be OK)"
    success "LP2 rescanned"

    # Final status
    echo ""
    log "═══════════════════════════════════════"
    log "SETUP COMPLETE"
    log "═══════════════════════════════════════"
    show_status
}

case "${1:-setup}" in
    status)
        show_status
        ;;
    setup|"")
        do_setup
        ;;
    *)
        echo "Usage: $0 [setup|status]"
        exit 1
        ;;
esac
