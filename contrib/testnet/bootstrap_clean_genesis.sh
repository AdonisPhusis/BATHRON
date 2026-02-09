#!/usr/bin/env bash
# ==============================================================================
# bootstrap_clean_genesis.sh - Ultra-Clean BATHRON Genesis v3.1
# ==============================================================================
#
# 100% trustless genesis:
#   - NO synthetic MNs (genesisMNs = {})
#   - NO pre-loaded JSON (no genesis_burns_spv.json)
#   - SPV checkpoint at 286000 (BEFORE first burn at 286326)
#   - All burns discovered dynamically from BTC Signet
#
# Burns range: 286326-288558 (31 burns expected)
#
# Requirements:
#   - bitcoin-cli configured for Signet with txindex=1
#   - bathron-cli (bathrond must be stopped before genesis)
#   - Run on Seed node (57.131.33.151)
#
# Usage:
#   ./bootstrap_clean_genesis.sh          # Full bootstrap
#   ./bootstrap_clean_genesis.sh status   # Check progress
#
# ==============================================================================

set -euo pipefail

# Configuration
CHECKPOINT=286300       # SPV checkpoint (just before first burn at 286326)
FIRST_BURN=286326       # First known burn on Signet
DMM_HEIGHT=100          # nDMMBootstrapHeight

# Bitcoin CLI (Signet)
BTC_CLI="${BTC_CLI:-$HOME/bitcoin-27.0/bin/bitcoin-cli}"
BTC_CONF="${BTC_CONF:-$HOME/.bitcoin-signet/bitcoin.conf}"
BTC_CMD="$BTC_CLI -conf=$BTC_CONF"

# BATHRON CLI
BATHRON_CLI="${BATHRON_CLI:-$HOME/bathron-cli}"
BATHRON_CMD="$BATHRON_CLI -testnet"

# Log file
LOG_FILE="/tmp/bootstrap_clean_genesis.log"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# ==============================================================================
# Logging
# ==============================================================================
log() {
    local msg="[$(date '+%H:%M:%S')] $*"
    echo "$msg" >> "$LOG_FILE"
    echo -e "${BLUE}[INFO]${NC} $*"
}

log_success() {
    local msg="[$(date '+%H:%M:%S')] [OK] $*"
    echo "$msg" >> "$LOG_FILE"
    echo -e "${GREEN}[OK]${NC} $*"
}

log_warn() {
    local msg="[$(date '+%H:%M:%S')] [WARN] $*"
    echo "$msg" >> "$LOG_FILE"
    echo -e "${YELLOW}[WARN]${NC} $*"
}

log_error() {
    local msg="[$(date '+%H:%M:%S')] [ERROR] $*"
    echo "$msg" >> "$LOG_FILE"
    echo -e "${RED}[ERROR]${NC} $*" >&2
}

phase() {
    echo ""
    echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
    echo -e "${CYAN}  $*${NC}"
    echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
}

# ==============================================================================
# Helper Functions
# ==============================================================================

get_btc_tip() {
    $BTC_CMD getblockcount 2>/dev/null || echo "-1"
}

get_bathron_height() {
    $BATHRON_CMD getblockcount 2>/dev/null || echo "0"
}

get_spv_tip() {
    local status=$($BATHRON_CMD getbtcheadersstatus 2>/dev/null || echo "{}")
    echo "$status" | jq -r '.tip_height // 0'
}

get_pending_claims() {
    $BATHRON_CMD listburnclaims 2>/dev/null | jq '[.[] | select(.db_status=="pending")] | length' 2>/dev/null || echo "0"
}

get_final_claims() {
    $BATHRON_CMD listburnclaims 2>/dev/null | jq '[.[] | select(.db_status=="final")] | length' 2>/dev/null || echo "0"
}

get_total_claims() {
    $BATHRON_CMD listburnclaims 2>/dev/null | jq 'length' 2>/dev/null || echo "0"
}

get_mn_count() {
    $BATHRON_CMD masternode count 2>/dev/null | jq -r '.total // 0' 2>/dev/null || echo "0"
}

get_m0_total() {
    $BATHRON_CMD getexplorerdata 2>/dev/null | jq -r '.supply.m0_total // 0' 2>/dev/null || echo "0"
}

# ==============================================================================
# Status Command
# ==============================================================================
show_status() {
    echo ""
    echo -e "${CYAN}=== BATHRON Bootstrap Status ===${NC}"
    echo ""

    local btc_tip=$(get_btc_tip)
    local bathron_height=$(get_bathron_height)
    local spv_tip=$(get_spv_tip)
    local pending=$(get_pending_claims)
    local final=$(get_final_claims)
    local total=$(get_total_claims)
    local mns=$(get_mn_count)
    local m0=$(get_m0_total)

    echo "BTC Signet tip:    $btc_tip"
    echo "BATHRON height:    $bathron_height"
    echo "SPV headers tip:   $spv_tip"
    echo ""
    echo "Burns discovered:  $total"
    echo "  - pending:       $pending"
    echo "  - finalized:     $final"
    echo ""
    echo "MNs registered:    $mns"
    echo "M0 total supply:   $m0 sats"
    echo ""

    # Determine phase
    if [[ "$bathron_height" -eq 0 ]]; then
        echo -e "Phase: ${YELLOW}Not started${NC}"
    elif [[ "$spv_tip" -lt "$((FIRST_BURN + 10))" ]]; then
        echo -e "Phase: ${YELLOW}2 - Headers Sync${NC} (need $FIRST_BURN+, have $spv_tip)"
    elif [[ "$total" -eq 0 ]]; then
        echo -e "Phase: ${YELLOW}3 - Burn Discovery${NC} (waiting for claims)"
    elif [[ "$pending" -gt 0 ]]; then
        echo -e "Phase: ${YELLOW}4 - Finalization${NC} ($pending pending)"
    elif [[ "$mns" -lt 3 ]]; then
        echo -e "Phase: ${YELLOW}5 - MN Registration${NC} ($mns/3 MNs)"
    elif [[ "$bathron_height" -lt "$DMM_HEIGHT" ]]; then
        echo -e "Phase: ${YELLOW}6 - DMM Activation${NC} ($bathron_height/$DMM_HEIGHT)"
    else
        echo -e "Phase: ${GREEN}COMPLETE${NC}"
    fi

    exit 0
}

# ==============================================================================
# Sanity Checks
# ==============================================================================
sanity_checks() {
    log "Running sanity checks..."

    # Check checkpoint is before first burn
    if [[ $CHECKPOINT -ge $FIRST_BURN ]]; then
        log_error "CHECKPOINT ($CHECKPOINT) must be < FIRST_BURN ($FIRST_BURN)"
        exit 1
    fi

    # Check BTC Signet is reachable and synced past first burn
    local btc_tip=$(get_btc_tip)
    if [[ "$btc_tip" == "-1" ]]; then
        log_error "Cannot reach BTC Signet node"
        exit 1
    fi

    if [[ "$btc_tip" -lt "$FIRST_BURN" ]]; then
        log_error "BTC Signet tip ($btc_tip) < FIRST_BURN ($FIRST_BURN) - Signet not synced?"
        exit 1
    fi

    # Check BATHRON CLI works
    if ! $BATHRON_CMD getblockcount >/dev/null 2>&1; then
        log_error "BATHRON daemon not running or not reachable"
        exit 1
    fi

    log_success "Sanity checks passed"
    log "  CHECKPOINT: $CHECKPOINT"
    log "  FIRST_BURN: $FIRST_BURN"
    log "  BTC_TIP:    $btc_tip"
}

# ==============================================================================
# PHASE 1: Genesis Block
# ==============================================================================
phase1_genesis() {
    phase "PHASE 1: Genesis Block"

    local height=$(get_bathron_height)
    if [[ "$height" -gt 0 ]]; then
        log "Already past genesis (height=$height)"
        return 0
    fi

    log "Generating genesis block..."
    $BATHRON_CMD generatebootstrap 1

    height=$(get_bathron_height)
    if [[ "$height" -ge 1 ]]; then
        log_success "Genesis block created (height=$height)"
    else
        log_error "Failed to create genesis block"
        exit 1
    fi
}

# ==============================================================================
# PHASE 2: Headers Sync
# ==============================================================================
phase2_headers_sync() {
    phase "PHASE 2: Headers Sync"

    local btc_tip=$(get_btc_tip)
    log "Need headers from $CHECKPOINT to ~$btc_tip (~$((btc_tip - CHECKPOINT)) headers)"

    # Check if header daemon is running, start if not
    if ! pgrep -f "btc_header_daemon.sh" >/dev/null 2>&1; then
        log "Starting btc_header_daemon.sh..."
        ./btc_header_daemon.sh start || true
        sleep 5
    fi

    local max_iterations=500
    local i=0

    while true; do
        local spv_tip=$(get_spv_tip)
        local gap=$((btc_tip - spv_tip))

        # Synced when within 10 blocks of BTC tip
        if [[ $gap -le 10 ]]; then
            log_success "Headers SYNCED (SPV=$spv_tip, BTC=$btc_tip)"
            break
        fi

        # Progress log every 10 iterations
        if [[ $((i % 10)) -eq 0 ]]; then
            log "Headers: $spv_tip / $btc_tip (gap=$gap)"
        fi

        # Generate a block to include TX_BTC_HEADERS from mempool
        $BATHRON_CMD generatebootstrap 1 >/dev/null 2>&1 || true

        i=$((i + 1))
        if [[ $i -ge $max_iterations ]]; then
            log_error "Headers sync timeout after $max_iterations iterations"
            exit 1
        fi

        sleep 3
    done
}

# ==============================================================================
# PHASE 3: Burn Claims Discovery
# ==============================================================================
phase3_burn_claims() {
    phase "PHASE 3: Burn Claims Discovery"

    log "Scanning from $CHECKPOINT for burns..."

    # Check if burn claim daemon is running, start if not
    if ! pgrep -f "btc_burn_claim_daemon.sh" >/dev/null 2>&1; then
        log "Starting btc_burn_claim_daemon.sh in bootstrap mode..."
        ./btc_burn_claim_daemon.sh bootstrap &
        sleep 5
    fi

    local btc_tip=$(get_btc_tip)
    local max_iterations=300
    local i=0

    while true; do
        local claims=$(get_total_claims)
        local scan_status=$($BATHRON_CMD getburnscanstatus 2>/dev/null || echo "{}")
        local last_scanned=$(echo "$scan_status" | jq -r '.last_height // 0')

        # Done when scan reached near BTC tip and we have claims
        if [[ $last_scanned -ge $((btc_tip - 10)) && $claims -gt 0 ]]; then
            log_success "Scan COMPLETE: $claims burns discovered"
            break
        fi

        # Progress log
        if [[ $((i % 10)) -eq 0 ]]; then
            log "Scanning: height=$last_scanned, claims=$claims"
        fi

        # Generate a block to process TX_BURN_CLAIM from mempool
        $BATHRON_CMD generatebootstrap 1 >/dev/null 2>&1 || true

        i=$((i + 1))
        if [[ $i -ge $max_iterations ]]; then
            log_error "Burn scan timeout after $max_iterations iterations"
            exit 1
        fi

        sleep 2
    done
}

# ==============================================================================
# PHASE 4: Finalization
# ==============================================================================
phase4_finalization() {
    phase "PHASE 4: Finalization (K=1 during bootstrap)"

    local max_iterations=200
    local i=0

    while true; do
        local pending=$(get_pending_claims)
        local final=$(get_final_claims)

        # All finalized when no pending claims left
        if [[ $pending -eq 0 && $final -gt 0 ]]; then
            log_success "All claims FINALIZED: $final burns"
            break
        fi

        # Progress log
        if [[ $((i % 5)) -eq 0 ]]; then
            log "Finalizing: pending=$pending, final=$final"
        fi

        # Generate block - TX_MINT_M0BTC created automatically for finalized claims
        $BATHRON_CMD generatebootstrap 1 >/dev/null 2>&1 || true

        i=$((i + 1))
        if [[ $i -ge $max_iterations ]]; then
            log_error "Finalization timeout after $max_iterations iterations"
            exit 1
        fi

        sleep 1
    done

    # Verify M0 supply
    local m0_total=$(get_m0_total)
    log_success "M0 Total: $m0_total sats"
}

# ==============================================================================
# PHASE 5: MN Registration
# ==============================================================================
phase5_mn_registration() {
    phase "PHASE 5: MN Registration"

    log "Waiting for ProRegTx from operators..."
    log "Operators can now register MNs using protx register"

    local max_wait=600  # 10 minutes
    local waited=0

    while true; do
        local mn_count=$(get_mn_count)

        if [[ $mn_count -ge 3 ]]; then
            log_success "$mn_count MNs registered"
            break
        fi

        log "MNs: $mn_count/3 - waiting for registrations..."

        # Generate blocks to include ProRegTx
        $BATHRON_CMD generatebootstrap 1 >/dev/null 2>&1 || true

        waited=$((waited + 10))
        if [[ $waited -ge $max_wait ]]; then
            log_warn "Waited $max_wait seconds, continuing with $mn_count MNs"
            log_warn "You can register more MNs later"
            break
        fi

        sleep 10
    done
}

# ==============================================================================
# PHASE 6: DMM Activation
# ==============================================================================
phase6_dmm_activation() {
    phase "PHASE 6: DMM Activation (generate to height $DMM_HEIGHT)"

    while true; do
        local height=$(get_bathron_height)

        if [[ $height -ge $DMM_HEIGHT ]]; then
            log_success "DMM ACTIVE at height $height"
            break
        fi

        log "Height: $height/$DMM_HEIGHT"

        # Generate blocks until DMM height
        $BATHRON_CMD generatebootstrap 1 >/dev/null 2>&1 || true

        sleep 1
    done
}

# ==============================================================================
# Summary
# ==============================================================================
show_summary() {
    phase "BOOTSTRAP COMPLETE"

    local height=$(get_bathron_height)
    local m0_total=$(get_m0_total)
    local mns=$(get_mn_count)
    local burns=$(get_total_claims)

    echo ""
    echo -e "${GREEN}  Height:    $height${NC}"
    echo -e "${GREEN}  M0 Total:  $m0_total sats${NC}"
    echo -e "${GREEN}  MNs:       $mns${NC}"
    echo -e "${GREEN}  Burns:     $burns${NC}"
    echo ""
    log_success "DMM is now autonomous - generatebootstrap no longer needed"
    echo ""
}

# ==============================================================================
# Main
# ==============================================================================
main() {
    # Handle status command
    if [[ "${1:-}" == "status" ]]; then
        show_status
    fi

    echo ""
    echo -e "${CYAN}╔═══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║       BATHRON Ultra-Clean Genesis v3.1                        ║${NC}"
    echo -e "${CYAN}║                                                               ║${NC}"
    echo -e "${CYAN}║  - NO synthetic MNs                                          ║${NC}"
    echo -e "${CYAN}║  - NO pre-loaded JSON                                        ║${NC}"
    echo -e "${CYAN}║  - SPV checkpoint: $CHECKPOINT (before first burn $FIRST_BURN)      ║${NC}"
    echo -e "${CYAN}║  - All burns discovered dynamically                           ║${NC}"
    echo -e "${CYAN}╚═══════════════════════════════════════════════════════════════╝${NC}"
    echo ""

    # Initialize log
    echo "=== Bootstrap started at $(date) ===" >> "$LOG_FILE"

    # Run sanity checks
    sanity_checks

    # Execute phases
    phase1_genesis
    phase2_headers_sync
    phase3_burn_claims
    phase4_finalization
    phase5_mn_registration
    phase6_dmm_activation

    # Show summary
    show_summary
}

main "$@"
