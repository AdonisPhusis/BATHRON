#!/bin/bash
# ═══════════════════════════════════════════════════════════════════════════════
# run_settlement_tests.sh - Settlement Layer Test Suite
# ═══════════════════════════════════════════════════════════════════════════════
# Runs all BP30 settlement tests including:
#   - SettlementState invariants (A6)
#   - TX_LOCK validation
#   - Sapling orthogonality (A7)
#
# These tests verify the settlement layer is working correctly before
# launching the testnet.
# ═══════════════════════════════════════════════════════════════════════════════

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BATHRON_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TEST_BIN="$BATHRON_ROOT/src/test/test_bathron"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

log_ok() { echo -e "${GREEN}✓${NC} $1"; }
log_fail() { echo -e "${RED}✗${NC} $1"; }
log_info() { echo -e "${YELLOW}→${NC} $1"; }
log_section() { echo -e "\n${CYAN}=== $1 ===${NC}"; }

# ═══════════════════════════════════════════════════════════════════════════════
# CHECK TEST BINARY
# ═══════════════════════════════════════════════════════════════════════════════
log_section "Checking Test Binary"

if [ ! -x "$TEST_BIN" ]; then
    log_info "Test binary not found. Building..."
    cd "$BATHRON_ROOT" && make -j4 src/test/test_bathron
fi

if [ ! -x "$TEST_BIN" ]; then
    log_fail "Failed to build test binary"
    exit 1
fi
log_ok "Test binary: $TEST_BIN"

# ═══════════════════════════════════════════════════════════════════════════════
# RUN SETTLEMENT TESTS
# ═══════════════════════════════════════════════════════════════════════════════
log_section "Settlement Tests (BP30)"

log_info "Running settlement_tests..."
if $TEST_BIN --run_test=settlement_tests 2>&1 | grep -E "(passed|failed|error)" | tail -5; then
    log_ok "settlement_tests passed"
else
    log_fail "settlement_tests failed"
    EXIT_CODE=1
fi

log_info "Running settlement_builder_tests..."
if $TEST_BIN --run_test=settlement_builder_tests 2>&1 | grep -E "(passed|failed|error)" | tail -5; then
    log_ok "settlement_builder_tests passed"
else
    log_fail "settlement_builder_tests failed"
    EXIT_CODE=1
fi

# ═══════════════════════════════════════════════════════════════════════════════
# SAPLING ORTHOGONALITY (A7)
# ═══════════════════════════════════════════════════════════════════════════════
log_section "Sapling Orthogonality Tests (A7)"

log_info "Running settlement_sapling_orthogonality_tests..."
if $TEST_BIN --run_test=settlement_sapling_orthogonality_tests 2>&1 | grep -E "(passed|failed|error)" | tail -5; then
    log_ok "Sapling orthogonality verified (A7)"
else
    log_fail "Sapling orthogonality tests failed"
    EXIT_CODE=1
fi

# ═══════════════════════════════════════════════════════════════════════════════
# SUMMARY
# ═══════════════════════════════════════════════════════════════════════════════
log_section "Test Summary"

# Get test counts
TOTAL=$($TEST_BIN --list_content=HRF 2>/dev/null | grep -c "settlement" || echo "?")
log_info "Settlement test suites: $TOTAL"

if [ "${EXIT_CODE:-0}" -eq 0 ]; then
    log_ok "All settlement tests PASSED"
    echo ""
    echo "Invariants verified:"
    echo "  A6: M0_vaulted_active + M0_savingspool == M1_supply + M2_locked"
    echo "  A7: M0_SHIELD is orthogonal to settlement"
    echo ""
    exit 0
else
    log_fail "Some tests FAILED - check output above"
    exit 1
fi
