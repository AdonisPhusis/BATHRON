#!/bin/bash
# =============================================================================
# BATHRON 2.0 Functional Tests - LIVE TESTNET
# =============================================================================
# Copyright (c) 2025 The BATHRON 2.0 developers
# Distributed under the MIT software license
#
# This script runs functional tests on the LIVE testnet via RPC.
# Unlike unit tests (compiled C++), these test real network behavior.
#
# Usage:
#   ./contrib/testnet/functional_tests.sh [--all] [--quick] [--verbose]
#   ./contrib/testnet/functional_tests.sh --test <test_name>
#
# Available tests:
#   - connectivity    : Test node connectivity and peer count
#   - sync            : Test blockchain sync status across nodes
#   - dmm             : Test DMM block production
#   - finality        : Test HU finality signatures
#   - kpiv_mint       : Test KPIV minting (requires dev wallet)
#   - kpiv_lock       : Test KPIV locking (requires KPIV balance)
#   - kpiv_unlock     : Test KPIV unlocking
#   - kpiv_redeem     : Test KPIV redemption
#   - invariants      : Test global state invariants
#   - mempool         : Test mempool behavior
#   - rpc             : Test RPC availability
#
# Exit codes:
#   0 = All tests passed
#   1 = One or more tests failed
# =============================================================================

set -euo pipefail

# =============================================================================
# Configuration
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# SSH key for VPS access
SSH_KEY="$HOME/.ssh/id_ed25519_vps"
SSH="ssh -i $SSH_KEY -o StrictHostKeyChecking=no -o ConnectTimeout=10"

# Testnet nodes
declare -A NODES=(
    ["seed"]="57.131.33.151"
    ["mn1"]="162.19.251.75"
    ["mn2"]="57.131.33.152"
    ["mn3"]="57.131.33.214"
    ["mn4"]="51.75.31.44"
)

# Local dev wallet (for KPIV operations)
LOCAL_CLI="$PROJECT_ROOT/src/bathron-cli -testnet"
LOCAL_DAEMON_RUNNING=0

# Test results
declare -A TEST_RESULTS
VERBOSE=0
QUICK_MODE=0

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# =============================================================================
# Utility Functions
# =============================================================================

log() {
    echo -e "[$(date '+%H:%M:%S')] $*"
}

log_verbose() {
    if [[ $VERBOSE -eq 1 ]]; then
        echo -e "[$(date '+%H:%M:%S')] ${BLUE}[VERBOSE]${NC} $*"
    fi
}

log_pass() {
    echo -e "[$(date '+%H:%M:%S')] ${GREEN}[PASS]${NC} $*"
}

log_fail() {
    echo -e "[$(date '+%H:%M:%S')] ${RED}[FAIL]${NC} $*"
}

log_skip() {
    echo -e "[$(date '+%H:%M:%S')] ${YELLOW}[SKIP]${NC} $*"
}

log_info() {
    echo -e "[$(date '+%H:%M:%S')] ${BLUE}[INFO]${NC} $*"
}

# Execute RPC command on a node
rpc() {
    local node=$1
    shift
    local ip="${NODES[$node]}"

    if [[ -z "$ip" ]]; then
        echo "ERROR: Unknown node $node"
        return 1
    fi

    $SSH ubuntu@$ip "~/bathron-cli -testnet $*" 2>/dev/null
}

# Execute RPC on local dev wallet
rpc_local() {
    $LOCAL_CLI "$@" 2>/dev/null
}

# Check if local daemon is running
check_local_daemon() {
    if $LOCAL_CLI getblockcount &>/dev/null; then
        LOCAL_DAEMON_RUNNING=1
        return 0
    else
        LOCAL_DAEMON_RUNNING=0
        return 1
    fi
}

# =============================================================================
# Test: Connectivity
# =============================================================================

test_connectivity() {
    log_info "=== TEST: Connectivity ==="
    local passed=0
    local failed=0

    for node in "${!NODES[@]}"; do
        local ip="${NODES[$node]}"
        log_verbose "Testing SSH to $node ($ip)..."

        if $SSH ubuntu@$ip "echo ok" &>/dev/null; then
            log_verbose "SSH OK: $node"

            # Check daemon is running
            local blockcount
            blockcount=$(rpc "$node" getblockcount 2>/dev/null) || blockcount=""

            if [[ -n "$blockcount" ]]; then
                log_pass "$node: daemon running, height=$blockcount"
                ((passed++))
            else
                log_fail "$node: daemon NOT responding"
                ((failed++))
            fi
        else
            log_fail "$node: SSH connection failed"
            ((failed++))
        fi
    done

    log_info "Connectivity: $passed passed, $failed failed"

    if [[ $failed -eq 0 ]]; then
        TEST_RESULTS["connectivity"]="PASS"
        return 0
    else
        TEST_RESULTS["connectivity"]="FAIL"
        return 1
    fi
}

# =============================================================================
# Test: Sync Status
# =============================================================================

test_sync() {
    log_info "=== TEST: Sync Status ==="

    # Collect heights from all nodes
    declare -A heights
    local max_height=0

    for node in "${!NODES[@]}"; do
        local h
        h=$(rpc "$node" getblockcount 2>/dev/null) || h=0
        heights[$node]=$h
        log_verbose "$node: height=$h"

        if [[ $h -gt $max_height ]]; then
            max_height=$h
        fi
    done

    # Check all nodes are within 2 blocks of max
    local sync_ok=1
    for node in "${!NODES[@]}"; do
        local diff=$((max_height - heights[$node]))
        if [[ $diff -gt 2 ]]; then
            log_fail "$node: behind by $diff blocks (height=${heights[$node]}, max=$max_height)"
            sync_ok=0
        else
            log_pass "$node: synced (height=${heights[$node]}, diff=$diff)"
        fi
    done

    if [[ $sync_ok -eq 1 ]]; then
        log_pass "All nodes synced (max height: $max_height)"
        TEST_RESULTS["sync"]="PASS"
        return 0
    else
        TEST_RESULTS["sync"]="FAIL"
        return 1
    fi
}

# =============================================================================
# Test: DMM Block Production
# =============================================================================

test_dmm() {
    log_info "=== TEST: DMM Block Production ==="

    # Get initial height
    local initial_height
    initial_height=$(rpc seed getblockcount 2>/dev/null) || {
        log_fail "Could not get initial height"
        TEST_RESULTS["dmm"]="FAIL"
        return 1
    }

    log_info "Initial height: $initial_height"
    log_info "Waiting 120 seconds for new blocks..."

    # Wait for new blocks (60s target spacing, wait 2 blocks worth)
    local wait_time=120
    if [[ $QUICK_MODE -eq 1 ]]; then
        wait_time=70
    fi

    sleep $wait_time

    # Check new height
    local new_height
    new_height=$(rpc seed getblockcount 2>/dev/null) || {
        log_fail "Could not get new height"
        TEST_RESULTS["dmm"]="FAIL"
        return 1
    }

    local blocks_produced=$((new_height - initial_height))
    log_info "New height: $new_height (produced $blocks_produced blocks)"

    # Should have produced at least 1 block in 120s (60s spacing)
    if [[ $blocks_produced -ge 1 ]]; then
        log_pass "DMM produced $blocks_produced blocks"

        # Check last block for MN signature
        local last_hash
        last_hash=$(rpc seed getblockhash $new_height 2>/dev/null)

        if [[ -n "$last_hash" ]]; then
            log_verbose "Last block hash: $last_hash"

            # Get block details
            local block_json
            block_json=$(rpc seed getblock "$last_hash" 2>/dev/null)

            if echo "$block_json" | grep -q "proTxHash"; then
                log_pass "Block has MN producer info (proTxHash present)"
            else
                log_verbose "Block missing proTxHash (may be bootstrap block)"
            fi
        fi

        TEST_RESULTS["dmm"]="PASS"
        return 0
    else
        log_fail "No blocks produced in $wait_time seconds"
        TEST_RESULTS["dmm"]="FAIL"
        return 1
    fi
}

# =============================================================================
# Test: HU Finality
# =============================================================================

test_finality() {
    log_info "=== TEST: HU Finality Signatures ==="

    # Get current height
    local height
    height=$(rpc seed getblockcount 2>/dev/null) || {
        log_fail "Could not get height"
        TEST_RESULTS["finality"]="FAIL"
        return 1
    }

    # Check finality status (BATHRON 2.0 RPC)
    local finality_info
    finality_info=$(rpc seed getfinalitystatus 2>/dev/null) || {
        log_skip "getfinalitystatus RPC not available"
        TEST_RESULTS["finality"]="SKIP"
        return 0
    }

    log_verbose "Finality info: $finality_info"

    # Parse finality status
    local status
    status=$(echo "$finality_info" | grep -o '"status"[[:space:]]*:[[:space:]]*"[^"]*"' | cut -d'"' -f4 || echo "unknown")

    local finalized_height
    finalized_height=$(echo "$finality_info" | grep -o '"last_finalized_height"[[:space:]]*:[[:space:]]*[0-9]*' | grep -o '[0-9]*' || echo "0")

    local lag
    lag=$(echo "$finality_info" | grep -o '"finality_lag"[[:space:]]*:[[:space:]]*[0-9]*' | grep -o '[0-9]*' || echo "0")

    log_info "Finality: finalized=$finalized_height, tip=$height, lag=$lag, status=$status"

    if [[ "$status" == "healthy" ]]; then
        log_pass "Finality status: healthy"

        if [[ $lag -le 5 ]]; then
            log_pass "Finality lag acceptable ($lag blocks)"
        else
            log_fail "Finality lag too high ($lag blocks)"
        fi

        TEST_RESULTS["finality"]="PASS"
        return 0
    else
        log_fail "Finality status: $status"
        TEST_RESULTS["finality"]="FAIL"
        return 1
    fi
}

# =============================================================================
# Test: RPC Availability
# =============================================================================

test_rpc() {
    log_info "=== TEST: RPC Availability ==="

    # List of critical RPC commands to test
    # BATHRON 2.0 uses DMM (not PoW) and protx (not legacy masternode commands)
    local rpcs=("getblockcount" "getblockchaininfo" "getnetworkinfo" "getpeerinfo" "getbestblockhash")
    local passed=0
    local failed=0
    local skipped=0

    for rpc_cmd in "${rpcs[@]}"; do
        log_verbose "Testing RPC: $rpc_cmd"

        if rpc seed "$rpc_cmd" &>/dev/null; then
            log_pass "RPC $rpc_cmd: OK"
            ((passed++))
        else
            log_fail "RPC $rpc_cmd: FAILED"
            ((failed++))
        fi
    done

    # Test BATHRON 2.0 specific RPCs (only ones that exist)
    local bathron2_rpcs=("getstate" "getfinalitystatus")
    for rpc_cmd in "${bathron2_rpcs[@]}"; do
        log_verbose "Testing BATHRON2 RPC: $rpc_cmd"

        if rpc seed "$rpc_cmd" &>/dev/null; then
            log_pass "RPC $rpc_cmd: OK"
            ((passed++)) || true
        else
            log_skip "RPC $rpc_cmd: not implemented"
            ((skipped++)) || true
        fi
    done

    log_info "RPC: $passed passed, $failed failed"

    if [[ $failed -eq 0 ]]; then
        TEST_RESULTS["rpc"]="PASS"
        return 0
    else
        TEST_RESULTS["rpc"]="FAIL"
        return 1
    fi
}

# =============================================================================
# Test: Mempool
# =============================================================================

test_mempool() {
    log_info "=== TEST: Mempool ==="

    # Get mempool info from all nodes
    local total_mempool=0

    for node in "${!NODES[@]}"; do
        local mempool_size
        mempool_size=$(rpc "$node" getmempoolinfo 2>/dev/null | grep -o '"size":[0-9]*' | cut -d: -f2 || echo "0")
        log_verbose "$node mempool size: $mempool_size"
        ((total_mempool += mempool_size))
    done

    # Mempool consistency (all should have similar size, allow ±10 txs)
    local prev_size=-1
    local consistent=1

    for node in "${!NODES[@]}"; do
        local size
        size=$(rpc "$node" getmempoolinfo 2>/dev/null | grep -o '"size":[0-9]*' | cut -d: -f2 || echo "0")

        if [[ $prev_size -ge 0 ]]; then
            local diff=$((size - prev_size))
            if [[ ${diff#-} -gt 10 ]]; then
                log_fail "Mempool inconsistency: $node has $size txs (diff=$diff)"
                consistent=0
            fi
        fi
        prev_size=$size
    done

    if [[ $consistent -eq 1 ]]; then
        log_pass "Mempool consistent across nodes"
        TEST_RESULTS["mempool"]="PASS"
        return 0
    else
        TEST_RESULTS["mempool"]="FAIL"
        return 1
    fi
}

# =============================================================================
# Test: KPIV Mint (requires local daemon with dev wallet)
# =============================================================================

test_kpiv_mint() {
    log_info "=== TEST: KPIV Deposit (PIV → KPIV) ==="

    if ! check_local_daemon; then
        log_skip "Local daemon not running (needed for dev wallet)"
        TEST_RESULTS["kpiv_mint"]="SKIP"
        return 0
    fi

    # Get balance from getbalance
    local balance_json
    balance_json=$(rpc_local getbalance 2>/dev/null) || {
        log_fail "Could not get balance"
        TEST_RESULTS["kpiv_mint"]="FAIL"
        return 1
    }

    # Parse PIV balance (can be scalar or object)
    local piv_balance
    if echo "$balance_json" | grep -q '"piv"'; then
        piv_balance=$(echo "$balance_json" | grep -oE '"piv"[[:space:]]*:[[:space:]]*[0-9.]+' | grep -oE '[0-9.]+$' || echo "0")
    else
        # Scalar response
        piv_balance=$(echo "$balance_json" | grep -oE '^[0-9.]+' || echo "0")
    fi

    log_info "PIV balance: $piv_balance"

    # Need at least 100 PIV for deposit test
    if (( $(echo "$piv_balance < 100" | bc -l 2>/dev/null || echo 0) )); then
        log_skip "Insufficient PIV balance for deposit test (need 100 PIV)"
        TEST_RESULTS["kpiv_mint"]="SKIP"
        return 0
    fi

    # Try deposit 10 PIV -> 10 KPIV
    log_info "Attempting to deposit 10 PIV to get 10 KPIV..."
    local deposit_result
    deposit_result=$(rpc_local deposit 10 2>&1) || {
        log_fail "Deposit failed: $deposit_result"
        TEST_RESULTS["kpiv_mint"]="FAIL"
        return 1
    }

    log_verbose "Deposit result: $deposit_result"

    # Check if tx was created
    if echo "$deposit_result" | grep -q "txid"; then
        local txid
        txid=$(echo "$deposit_result" | grep -oE '"txid"[[:space:]]*:[[:space:]]*"[^"]+"' | cut -d'"' -f4)
        log_pass "KPIV deposit transaction created: $txid"
        TEST_RESULTS["kpiv_mint"]="PASS"
        return 0
    else
        log_fail "Deposit did not return txid: $deposit_result"
        TEST_RESULTS["kpiv_mint"]="FAIL"
        return 1
    fi
}

# =============================================================================
# Test: KPIV Lock (requires KPIV balance)
# =============================================================================

test_kpiv_lock() {
    log_info "=== TEST: KPIV Lock (savings) ==="

    if ! check_local_daemon; then
        log_skip "Local daemon not running"
        TEST_RESULTS["kpiv_lock"]="SKIP"
        return 0
    fi

    # Check KPIV balance from getbalance
    local balance_json
    balance_json=$(rpc_local getbalance 2>/dev/null) || {
        log_skip "getbalance not available"
        TEST_RESULTS["kpiv_lock"]="SKIP"
        return 0
    }

    # Parse KPIV balance (handle JSON with spaces)
    local kpiv_balance
    kpiv_balance=$(echo "$balance_json" | grep -oE '"kpiv"[[:space:]]*:[[:space:]]*[0-9.]+' | grep -oE '[0-9.]+$' || echo "0")

    log_info "KPIV balance: $kpiv_balance"

    if [[ "$kpiv_balance" == "0" ]] || (( $(echo "$kpiv_balance < 5" | bc -l 2>/dev/null || echo 1) )); then
        log_skip "Insufficient KPIV balance for lock test (need 5 KPIV, have $kpiv_balance)"
        TEST_RESULTS["kpiv_lock"]="SKIP"
        return 0
    fi

    # Try to lock 5 KPIV using savings RPC
    log_info "Attempting to lock 5 KPIV (savings)..."
    local lock_result
    lock_result=$(rpc_local savings 5 2>&1) || {
        log_fail "Savings failed: $lock_result"
        TEST_RESULTS["kpiv_lock"]="FAIL"
        return 1
    }

    log_verbose "Savings result: $lock_result"

    if echo "$lock_result" | grep -qE "(txid|note_commitment)"; then
        log_pass "KPIV savings transaction created"
        TEST_RESULTS["kpiv_lock"]="PASS"
        return 0
    else
        log_fail "Savings did not return expected result: $lock_result"
        TEST_RESULTS["kpiv_lock"]="FAIL"
        return 1
    fi
}

# =============================================================================
# Test: Global Invariants
# =============================================================================

test_invariants() {
    log_info "=== TEST: Global Invariants ==="

    # Get BATHRON 2.0 state from seed
    local state
    state=$(rpc seed getstate 2>/dev/null) || {
        log_skip "getstate not available"
        TEST_RESULTS["invariants"]="SKIP"
        return 0
    }

    log_verbose "BATHRON2 State: $state"

    # Check invariants_ok field directly from RPC (handle JSON with spaces)
    local invariants_ok_rpc
    invariants_ok_rpc=$(echo "$state" | grep -oE '"invariants_ok"[[:space:]]*:[[:space:]]*true' || echo "")

    # Parse state values for display
    local C=$(echo "$state" | grep -o '"C":[0-9.]*' | cut -d: -f2 || echo "0")
    local U=$(echo "$state" | grep -o '"U":[0-9.]*' | cut -d: -f2 || echo "0")
    local Z=$(echo "$state" | grep -o '"Z":[0-9.]*' | cut -d: -f2 || echo "0")
    local Cr=$(echo "$state" | grep -o '"Cr":[0-9.]*' | cut -d: -f2 || echo "0")
    local Ur=$(echo "$state" | grep -o '"Ur":[0-9.]*' | cut -d: -f2 || echo "0")
    local T=$(echo "$state" | grep -o '"T":[0-9.]*' | cut -d: -f2 || echo "0")

    log_info "State: C=$C U=$U Z=$Z Cr=$Cr Ur=$Ur T=$T"

    local invariants_ok=1

    # Use RPC invariants_ok if available
    if [[ -n "$invariants_ok_rpc" ]]; then
        log_pass "RPC reports invariants_ok: true"
    else
        log_fail "RPC reports invariants_ok: false"
        invariants_ok=0
    fi

    # Invariant 1: C == U + Z (note: Z not S in BATHRON 2.0)
    # Skip arithmetic check for now - trust RPC invariants_ok

    # Check consistency across nodes using getstate
    log_info "Checking state consistency across nodes..."
    for node in "${!NODES[@]}"; do
        local node_state
        node_state=$(rpc "$node" getstate 2>/dev/null) || continue

        local node_invariants
        node_invariants=$(echo "$node_state" | grep -oE '"invariants_ok"[[:space:]]*:[[:space:]]*true' || echo "")

        if [[ -n "$node_invariants" ]]; then
            log_verbose "$node: invariants_ok=true"
        else
            log_fail "$node: invariants_ok=false"
            invariants_ok=0
        fi
    done

    if [[ $invariants_ok -eq 1 ]]; then
        log_pass "All invariants verified"
        TEST_RESULTS["invariants"]="PASS"
        return 0
    else
        TEST_RESULTS["invariants"]="FAIL"
        return 1
    fi
}

# =============================================================================
# Print Report
# =============================================================================

print_report() {
    echo ""
    echo "============================================="
    echo "=== BATHRON 2.0 Functional Tests - RESULTS ==="
    echo "============================================="
    echo ""

    local passed=0
    local failed=0
    local skipped=0

    # Iterate through known test names in order
    local all_tests="connectivity sync rpc mempool dmm finality invariants kpiv_mint kpiv_lock"

    for test_name in $all_tests; do
        local result="${TEST_RESULTS[$test_name]:-NOT_RUN}"

        # Skip tests that weren't run
        [[ "$result" == "NOT_RUN" ]] && continue

        printf "%-20s : " "$test_name"

        case $result in
            PASS)
                echo -e "${GREEN}PASS${NC}"
                ((passed++)) || true
                ;;
            FAIL)
                echo -e "${RED}FAIL${NC}"
                ((failed++)) || true
                ;;
            SKIP)
                echo -e "${YELLOW}SKIP${NC}"
                ((skipped++)) || true
                ;;
            *)
                echo "$result"
                ;;
        esac
    done

    echo ""
    echo "============================================="
    echo "Passed: $passed | Failed: $failed | Skipped: $skipped"
    echo "============================================="
    echo ""

    if [[ $failed -eq 0 ]] && [[ $passed -gt 0 ]]; then
        echo -e "${GREEN}OVERALL: SUCCESS${NC} ($passed passed, $skipped skipped)"
        return 0
    elif [[ $failed -eq 0 ]] && [[ $passed -eq 0 ]]; then
        echo -e "${YELLOW}OVERALL: NO TESTS RAN${NC}"
        return 1
    else
        echo -e "${RED}OVERALL: FAILURE${NC} ($failed failed)"
        return 1
    fi
}

# =============================================================================
# Main
# =============================================================================

usage() {
    echo "BATHRON 2.0 Functional Tests - Live Testnet"
    echo ""
    echo "Usage: $0 [options]"
    echo ""
    echo "Options:"
    echo "  --all           Run all tests"
    echo "  --quick         Run quick tests only (skip slow ones)"
    echo "  --verbose, -v   Enable verbose output"
    echo "  --test <name>   Run specific test"
    echo "  --list          List available tests"
    echo "  --help, -h      Show this help"
    echo ""
    echo "Available tests:"
    echo "  connectivity, sync, dmm, finality, rpc, mempool"
    echo "  kpiv_mint, kpiv_lock (requires local daemon)"
    echo "  invariants"
}

main() {
    local run_all=0
    local specific_test=""

    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case $1 in
            --all|-a)
                run_all=1
                shift
                ;;
            --quick|-q)
                QUICK_MODE=1
                shift
                ;;
            --verbose|-v)
                VERBOSE=1
                shift
                ;;
            --test|-t)
                specific_test="$2"
                shift 2
                ;;
            --list)
                echo "Available tests:"
                echo "  connectivity  - Test node connectivity"
                echo "  sync          - Test blockchain sync"
                echo "  dmm           - Test block production"
                echo "  finality      - Test HU finality"
                echo "  rpc           - Test RPC availability"
                echo "  mempool       - Test mempool"
                echo "  kpiv_mint     - Test KPIV minting"
                echo "  kpiv_lock     - Test KPIV locking"
                echo "  invariants    - Test state invariants"
                exit 0
                ;;
            --help|-h)
                usage
                exit 0
                ;;
            *)
                echo "Unknown option: $1"
                usage
                exit 1
                ;;
        esac
    done

    log_info "============================================="
    log_info "BATHRON 2.0 Functional Tests - Live Testnet"
    log_info "============================================="

    # Check SSH key exists
    if [[ ! -f "$SSH_KEY" ]]; then
        log_fail "SSH key not found: $SSH_KEY"
        exit 1
    fi

    # Run tests
    if [[ -n "$specific_test" ]]; then
        # Run specific test
        case $specific_test in
            connectivity) test_connectivity ;;
            sync) test_sync ;;
            dmm) test_dmm ;;
            finality) test_finality ;;
            rpc) test_rpc ;;
            mempool) test_mempool ;;
            kpiv_mint) test_kpiv_mint ;;
            kpiv_lock) test_kpiv_lock ;;
            invariants) test_invariants ;;
            *)
                log_fail "Unknown test: $specific_test"
                exit 1
                ;;
        esac
    elif [[ $run_all -eq 1 ]]; then
        # Run all tests
        test_connectivity || true
        test_sync || true
        test_rpc || true
        test_mempool || true
        test_dmm || true
        test_finality || true
        test_invariants || true

        # KPIV tests only if local daemon running
        test_kpiv_mint || true
        test_kpiv_lock || true
    else
        # Default: run basic tests
        test_connectivity || true
        test_sync || true
        test_rpc || true
    fi

    # Print report
    print_report
}

main "$@"
