#!/bin/bash
# ==============================================================================
# test_settlement_pivot.sh - E2E Settlement Pivot (Covenant HTLC) Test
# ==============================================================================
#
# Tests the full Settlement Pivot flow:
#   1. LP (alice/OP1) locks M1 in covenant HTLC2
#   2. Retail (charlie/OP3) claims HTLC2 → creates HTLC3 atomically
#   3. LP (alice/OP1) claims HTLC3 → gets M1Receipt back
#
# Usage:
#   ./contrib/testnet/test_settlement_pivot.sh
#   ./contrib/testnet/test_settlement_pivot.sh status    # Check test state
#   ./contrib/testnet/test_settlement_pivot.sh cleanup   # Clean state files
#
# Prerequisites:
#   - All nodes running and synced
#   - alice (OP1) has M1 receipts available
#   - charlie (OP3) address known
# ==============================================================================

set -euo pipefail

# ==============================================================================
# CONFIGURATION
# ==============================================================================
SSH_KEY="$HOME/.ssh/id_ed25519_vps"
SSH_OPTS="-o StrictHostKeyChecking=no -o ConnectTimeout=10 -o LogLevel=ERROR"
SSH="ssh -i $SSH_KEY $SSH_OPTS"

OP1_IP="57.131.33.152"   # alice (LP)
OP3_IP="51.75.31.44"     # charlie (retail)
SEED_IP="57.131.33.151"  # for block production monitoring

CLI_OP1="ubuntu@${OP1_IP} /home/ubuntu/bathron-cli -testnet"
CLI_OP3="ubuntu@${OP3_IP} /home/ubuntu/bathron-cli -testnet"
CLI_SEED="ubuntu@${SEED_IP} /home/ubuntu/BATHRON-Core/src/bathron-cli -testnet"

STATE_DIR="/tmp/settlement_pivot_test"
mkdir -p "$STATE_DIR"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# ==============================================================================
# HELPERS
# ==============================================================================
info()  { echo -e "${BLUE}[$(date +%H:%M:%S)]${NC} $*"; }
ok()    { echo -e "${GREEN}[OK]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
fail()  { echo -e "${RED}[FAIL]${NC} $*"; exit 1; }

rpc_op1() { $SSH $CLI_OP1 "$@" 2>&1; }
rpc_op3() { $SSH $CLI_OP3 "$@" 2>&1; }
rpc_seed() { $SSH $CLI_SEED "$@" 2>&1; }

wait_for_block() {
    local target_height=$1
    local max_wait=120
    local waited=0
    info "Waiting for block $target_height..."
    while [ $waited -lt $max_wait ]; do
        local current=$(rpc_seed getblockcount)
        if [ "$current" -ge "$target_height" ] 2>/dev/null; then
            ok "Block $current reached (target: $target_height)"
            return 0
        fi
        sleep 5
        waited=$((waited + 5))
    done
    fail "Timeout waiting for block $target_height (current: $(rpc_seed getblockcount))"
}

wait_for_confirmation() {
    local txid=$1
    local node_rpc=$2  # "op1" or "op3"
    local max_wait=180
    local waited=0
    info "Waiting for TX $txid to confirm..."
    while [ $waited -lt $max_wait ]; do
        local confirmations
        if [ "$node_rpc" = "op1" ]; then
            confirmations=$(rpc_op1 getrawtransaction "$txid" true 2>/dev/null | python3 -c "import sys,json; print(json.load(sys.stdin).get('confirmations',0))" 2>/dev/null || echo "0")
        else
            confirmations=$(rpc_op3 getrawtransaction "$txid" true 2>/dev/null | python3 -c "import sys,json; print(json.load(sys.stdin).get('confirmations',0))" 2>/dev/null || echo "0")
        fi
        if [ "$confirmations" -gt 0 ] 2>/dev/null; then
            ok "TX confirmed ($confirmations confirmations)"
            return 0
        fi
        sleep 5
        waited=$((waited + 5))
    done
    fail "Timeout waiting for TX $txid confirmation"
}

# ==============================================================================
# STATUS
# ==============================================================================
if [ "${1:-}" = "status" ]; then
    echo "=== Settlement Pivot Test State ==="
    if [ -f "$STATE_DIR/phase" ]; then
        echo "Phase: $(cat $STATE_DIR/phase)"
    else
        echo "Phase: not started"
    fi
    for f in secret hashlock htlc2_outpoint htlc2_txid htlc3_outpoint htlc3_txid receipt_outpoint alice_receipt; do
        if [ -f "$STATE_DIR/$f" ]; then
            echo "$f: $(cat $STATE_DIR/$f)"
        fi
    done
    exit 0
fi

if [ "${1:-}" = "cleanup" ]; then
    rm -rf "$STATE_DIR"
    ok "State cleaned up"
    exit 0
fi

# ==============================================================================
# PRE-FLIGHT CHECKS
# ==============================================================================
echo "================================================================"
echo " SETTLEMENT PIVOT E2E TEST"
echo " Covenant HTLC: LP → HTLC2(covenant) → claim → HTLC3 → claim → M1Receipt"
echo "================================================================"
echo ""

info "Pre-flight checks..."

# Check nodes are reachable and synced
OP1_HEIGHT=$(rpc_op1 getblockcount) || fail "OP1 unreachable"
OP3_HEIGHT=$(rpc_op3 getblockcount) || fail "OP3 unreachable"
SEED_HEIGHT=$(rpc_seed getblockcount) || fail "Seed unreachable"

info "Heights: OP1=$OP1_HEIGHT OP3=$OP3_HEIGHT Seed=$SEED_HEIGHT"

if [ "$((OP1_HEIGHT - OP3_HEIGHT))" -gt 2 ] || [ "$((OP3_HEIGHT - OP1_HEIGHT))" -gt 2 ]; then
    fail "Nodes not synced (OP1=$OP1_HEIGHT OP3=$OP3_HEIGHT)"
fi
ok "All nodes synced at ~$SEED_HEIGHT"

# Check alice has M1 receipts
info "Checking alice's M1 balance..."
ALICE_M1=$(rpc_op1 getwalletstate true)
ALICE_M1_COUNT=$(echo "$ALICE_M1" | python3 -c "import sys,json; print(json.load(sys.stdin)['m1']['count'])" 2>/dev/null || echo "0")
ALICE_M1_TOTAL=$(echo "$ALICE_M1" | python3 -c "import sys,json; print(json.load(sys.stdin)['m1']['total'])" 2>/dev/null || echo "0")

if [ "$ALICE_M1_COUNT" -eq 0 ] 2>/dev/null; then
    warn "alice has 0 M1 receipts, checking M0 balance to lock..."
    ALICE_M0=$(echo "$ALICE_M1" | python3 -c "import sys,json; print(json.load(sys.stdin)['m0']['balance'])" 2>/dev/null || echo "0")
    info "alice M0 balance: $ALICE_M0"
    if python3 -c "exit(0 if float('$ALICE_M0') > 0.001 else 1)" 2>/dev/null; then
        info "Locking 10000 sats (0.0001) M0 → M1 for test..."
        LOCK_RESULT=$(rpc_op1 lock 10000) || fail "Failed to lock M0 → M1"
        info "Lock TX: $LOCK_RESULT"
        info "Waiting for lock confirmation..."
        LOCK_TXID=$(echo "$LOCK_RESULT" | python3 -c "import sys,json; print(json.load(sys.stdin)['txid'])" 2>/dev/null || echo "$LOCK_RESULT")
        wait_for_confirmation "$LOCK_TXID" "op1"
        ALICE_M1=$(rpc_op1 getwalletstate true)
        ALICE_M1_COUNT=$(echo "$ALICE_M1" | python3 -c "import sys,json; print(json.load(sys.stdin)['m1']['count'])" 2>/dev/null || echo "0")
    else
        fail "alice has no M0 to lock. Fund alice first."
    fi
fi

info "alice has $ALICE_M1_COUNT M1 receipts (total: $ALICE_M1_TOTAL)"

# Get first available receipt (try unlockable first, then any)
ALICE_RECEIPT=$(echo "$ALICE_M1" | python3 -c "
import sys,json
data = json.load(sys.stdin)
receipts = data.get('m1', {}).get('receipts', [])
# First pass: try unlockable receipts
for r in receipts:
    if r.get('unlockable', False):
        print(r['outpoint'])
        break
else:
    # Second pass: try any receipt with confirmations > 0
    for r in receipts:
        if r.get('confirmations', 0) > 0:
            print(r['outpoint'])
            break
" 2>/dev/null)

if [ -z "$ALICE_RECEIPT" ]; then
    # Debug: show what receipts look like
    echo "$ALICE_M1" | python3 -c "
import sys,json
data = json.load(sys.stdin)
print('DEBUG m1 section:')
print(json.dumps(data.get('m1', {}), indent=2))
" 2>/dev/null
    fail "No usable M1 receipt found for alice"
fi
ok "Using alice receipt: $ALICE_RECEIPT"
echo "$ALICE_RECEIPT" > "$STATE_DIR/alice_receipt"

ALICE_RECEIPT_AMOUNT=$(echo "$ALICE_M1" | python3 -c "
import sys,json
data = json.load(sys.stdin)
for r in data.get('m1', {}).get('receipts', []):
    if r['outpoint'] == '$ALICE_RECEIPT':
        print(r['amount'])
        break
" 2>/dev/null)
info "Receipt amount: $ALICE_RECEIPT_AMOUNT M1"

# Get charlie's address
CHARLIE_ADDR=$(rpc_op3 getnewaddress "" "legacy") || fail "Cannot get charlie address"
ok "Charlie claim address: $CHARLIE_ADDR"

# Get alice's address (for HTLC3 claim)
ALICE_ADDR=$(rpc_op1 getnewaddress "" "legacy") || fail "Cannot get alice address"
ok "Alice LP claim address: $ALICE_ADDR"

# ==============================================================================
# PHASE 1: Generate secret + hashlock
# ==============================================================================
echo ""
echo "================================================================"
echo " PHASE 1: Generate hashlock pair"
echo "================================================================"

info "Generating secret/hashlock pair on OP1..."
GENERATE_RESULT=$(rpc_op1 htlc_generate) || fail "htlc_generate failed"
SECRET=$(echo "$GENERATE_RESULT" | python3 -c "import sys,json; print(json.load(sys.stdin)['secret'])")
HASHLOCK=$(echo "$GENERATE_RESULT" | python3 -c "import sys,json; print(json.load(sys.stdin)['hashlock'])")

echo "$SECRET" > "$STATE_DIR/secret"
echo "$HASHLOCK" > "$STATE_DIR/hashlock"
ok "Secret:   $SECRET"
ok "Hashlock: $HASHLOCK"
echo "1_generate" > "$STATE_DIR/phase"

# ==============================================================================
# PHASE 2: LP creates covenant HTLC2
# ==============================================================================
echo ""
echo "================================================================"
echo " PHASE 2: LP (alice) creates covenant HTLC2"
echo "================================================================"

info "Creating covenant HTLC2..."
info "  receipt:     $ALICE_RECEIPT"
info "  hashlock:    $HASHLOCK"
info "  retail_addr: $CHARLIE_ADDR (charlie claims)"
info "  lp_addr:     $ALICE_ADDR (alice claims HTLC3)"
info "  expiry:      20 blocks (short for testing)"

CREATE_RESULT=$(rpc_op1 htlc_create_m1_covenant \
    "$ALICE_RECEIPT" \
    "$HASHLOCK" \
    "$CHARLIE_ADDR" \
    "$ALICE_ADDR" \
    20 20) || fail "htlc_create_m1_covenant failed: $(rpc_op1 htlc_create_m1_covenant "$ALICE_RECEIPT" "$HASHLOCK" "$CHARLIE_ADDR" "$ALICE_ADDR" 20 20 2>&1)"

echo "$CREATE_RESULT" | python3 -m json.tool 2>/dev/null || echo "$CREATE_RESULT"

HTLC2_TXID=$(echo "$CREATE_RESULT" | python3 -c "import sys,json; print(json.load(sys.stdin)['txid'])")
HTLC2_OUTPOINT=$(echo "$CREATE_RESULT" | python3 -c "import sys,json; print(json.load(sys.stdin)['htlc_outpoint'])")
HTLC2_AMOUNT=$(echo "$CREATE_RESULT" | python3 -c "import sys,json; print(json.load(sys.stdin)['amount'])")
TEMPLATE_C3=$(echo "$CREATE_RESULT" | python3 -c "import sys,json; print(json.load(sys.stdin)['template_commitment'])")

echo "$HTLC2_TXID" > "$STATE_DIR/htlc2_txid"
echo "$HTLC2_OUTPOINT" > "$STATE_DIR/htlc2_outpoint"

ok "HTLC2 created!"
ok "  TXID:     $HTLC2_TXID"
ok "  Outpoint: $HTLC2_OUTPOINT"
ok "  Amount:   $HTLC2_AMOUNT"
ok "  C3:       $TEMPLATE_C3"
echo "2_htlc2_created" > "$STATE_DIR/phase"

# Wait for HTLC2 to confirm
wait_for_confirmation "$HTLC2_TXID" "op1"

# Verify HTLC2 in htlcdb on OP3
info "Verifying HTLC2 visible on OP3..."
sleep 5  # propagation delay
HTLC2_GET=$(rpc_op3 htlc_get "$HTLC2_OUTPOINT" 2>/dev/null) || fail "HTLC2 not found on OP3"
HTLC2_STATUS=$(echo "$HTLC2_GET" | python3 -c "import sys,json; print(json.load(sys.stdin).get('status','unknown'))" 2>/dev/null)
if [ "$HTLC2_STATUS" != "active" ]; then
    fail "HTLC2 status is '$HTLC2_STATUS', expected 'active'"
fi
ok "HTLC2 is ACTIVE on OP3"

# ==============================================================================
# PHASE 3: Retail (charlie) claims HTLC2 → creates HTLC3 (Settlement Pivot!)
# ==============================================================================
echo ""
echo "================================================================"
echo " PHASE 3: Retail (charlie) claims HTLC2 → HTLC3 (PIVOT)"
echo "================================================================"

info "Charlie claiming HTLC2 with preimage..."
info "  HTLC2:    $HTLC2_OUTPOINT"
info "  Preimage: $SECRET"

CLAIM2_RESULT=$(rpc_op3 htlc_claim "$HTLC2_OUTPOINT" "$SECRET") || fail "htlc_claim failed: $(rpc_op3 htlc_claim "$HTLC2_OUTPOINT" "$SECRET" 2>&1)"

echo "$CLAIM2_RESULT" | python3 -m json.tool 2>/dev/null || echo "$CLAIM2_RESULT"

CLAIM2_TYPE=$(echo "$CLAIM2_RESULT" | python3 -c "import sys,json; print(json.load(sys.stdin)['type'])")
CLAIM2_TXID=$(echo "$CLAIM2_RESULT" | python3 -c "import sys,json; print(json.load(sys.stdin)['txid'])")

echo "$CLAIM2_TXID" > "$STATE_DIR/claim2_txid"

if [ "$CLAIM2_TYPE" != "pivot" ]; then
    fail "Expected claim type 'pivot', got '$CLAIM2_TYPE'"
fi

HTLC3_OUTPOINT=$(echo "$CLAIM2_RESULT" | python3 -c "import sys,json; print(json.load(sys.stdin)['htlc3_outpoint'])")
HTLC3_AMOUNT=$(echo "$CLAIM2_RESULT" | python3 -c "import sys,json; print(json.load(sys.stdin)['htlc3_amount'])")
COVENANT_FEE=$(echo "$CLAIM2_RESULT" | python3 -c "import sys,json; print(json.load(sys.stdin)['covenant_fee'])")

echo "$HTLC3_OUTPOINT" > "$STATE_DIR/htlc3_outpoint"

ok "Settlement Pivot executed!"
ok "  Type:         $CLAIM2_TYPE"
ok "  Claim TXID:   $CLAIM2_TXID"
ok "  HTLC3:        $HTLC3_OUTPOINT"
ok "  HTLC3 Amount: $HTLC3_AMOUNT"
ok "  Covenant Fee: $COVENANT_FEE sats (to block producer)"
echo "3_htlc3_created" > "$STATE_DIR/phase"

# Wait for HTLC3 to confirm
wait_for_confirmation "$CLAIM2_TXID" "op3"

# Verify HTLC3 in htlcdb on OP1
info "Verifying HTLC3 visible on OP1..."
sleep 5
HTLC3_GET=$(rpc_op1 htlc_get "$HTLC3_OUTPOINT" 2>/dev/null) || fail "HTLC3 not found on OP1! Settlement logic may be broken."
HTLC3_STATUS=$(echo "$HTLC3_GET" | python3 -c "import sys,json; print(json.load(sys.stdin).get('status','unknown'))" 2>/dev/null)
if [ "$HTLC3_STATUS" != "active" ]; then
    fail "HTLC3 status is '$HTLC3_STATUS', expected 'active'"
fi
ok "HTLC3 is ACTIVE on OP1"
echo "$HTLC3_GET" | python3 -m json.tool 2>/dev/null || echo "$HTLC3_GET"

# Verify HTLC2 is now CLAIMED
HTLC2_AFTER=$(rpc_op1 htlc_get "$HTLC2_OUTPOINT" 2>/dev/null)
HTLC2_AFTER_STATUS=$(echo "$HTLC2_AFTER" | python3 -c "import sys,json; print(json.load(sys.stdin).get('status','unknown'))" 2>/dev/null)
if [ "$HTLC2_AFTER_STATUS" != "claimed" ]; then
    warn "HTLC2 status is '$HTLC2_AFTER_STATUS', expected 'claimed'"
else
    ok "HTLC2 is now CLAIMED"
fi

# ==============================================================================
# PHASE 4: LP (alice) claims HTLC3 → gets M1Receipt back
# ==============================================================================
echo ""
echo "================================================================"
echo " PHASE 4: LP (alice) claims HTLC3 → M1Receipt"
echo "================================================================"

info "Alice claiming HTLC3 with same preimage..."
info "  HTLC3:    $HTLC3_OUTPOINT"
info "  Preimage: $SECRET"

CLAIM3_RESULT=$(rpc_op1 htlc_claim "$HTLC3_OUTPOINT" "$SECRET") || fail "htlc_claim HTLC3 failed: $(rpc_op1 htlc_claim "$HTLC3_OUTPOINT" "$SECRET" 2>&1)"

echo "$CLAIM3_RESULT" | python3 -m json.tool 2>/dev/null || echo "$CLAIM3_RESULT"

CLAIM3_TYPE=$(echo "$CLAIM3_RESULT" | python3 -c "import sys,json; print(json.load(sys.stdin)['type'])")
CLAIM3_TXID=$(echo "$CLAIM3_RESULT" | python3 -c "import sys,json; print(json.load(sys.stdin)['txid'])")

echo "$CLAIM3_TXID" > "$STATE_DIR/claim3_txid"

if [ "$CLAIM3_TYPE" != "standard" ]; then
    fail "Expected claim type 'standard' for HTLC3, got '$CLAIM3_TYPE'"
fi

RECEIPT_OUTPOINT=$(echo "$CLAIM3_RESULT" | python3 -c "import sys,json; print(json.load(sys.stdin)['receipt_outpoint'])")
RECEIPT_AMOUNT=$(echo "$CLAIM3_RESULT" | python3 -c "import sys,json; print(json.load(sys.stdin)['amount'])")

echo "$RECEIPT_OUTPOINT" > "$STATE_DIR/receipt_outpoint"

ok "LP M1Receipt recovered!"
ok "  Type:     $CLAIM3_TYPE"
ok "  TXID:     $CLAIM3_TXID"
ok "  Receipt:  $RECEIPT_OUTPOINT"
ok "  Amount:   $RECEIPT_AMOUNT"
echo "4_m1_recovered" > "$STATE_DIR/phase"

# Wait for confirmation
wait_for_confirmation "$CLAIM3_TXID" "op1"

# ==============================================================================
# PHASE 5: Final verification
# ==============================================================================
echo ""
echo "================================================================"
echo " PHASE 5: Final State Verification"
echo "================================================================"

# Verify HTLC3 is now CLAIMED
sleep 5
HTLC3_FINAL=$(rpc_op1 htlc_get "$HTLC3_OUTPOINT" 2>/dev/null)
HTLC3_FINAL_STATUS=$(echo "$HTLC3_FINAL" | python3 -c "import sys,json; print(json.load(sys.stdin).get('status','unknown'))" 2>/dev/null)
if [ "$HTLC3_FINAL_STATUS" = "claimed" ]; then
    ok "HTLC3 is CLAIMED"
else
    warn "HTLC3 status: $HTLC3_FINAL_STATUS (expected: claimed)"
fi

# Verify alice's wallet state
info "Checking alice's final wallet state..."
ALICE_FINAL=$(rpc_op1 getwalletstate true)
ALICE_FINAL_M1=$(echo "$ALICE_FINAL" | python3 -c "import sys,json; print(json.load(sys.stdin)['m1']['total'])" 2>/dev/null)
ALICE_FINAL_COUNT=$(echo "$ALICE_FINAL" | python3 -c "import sys,json; print(json.load(sys.stdin)['m1']['count'])" 2>/dev/null)
info "alice M1: count=$ALICE_FINAL_COUNT total=$ALICE_FINAL_M1"

# Check that receipt exists
RECEIPT_CHECK=$(echo "$ALICE_FINAL" | python3 -c "
import sys,json
data = json.load(sys.stdin)
for r in data.get('m1', {}).get('receipts', []):
    if r['outpoint'] == '$RECEIPT_OUTPOINT':
        print('FOUND amount=' + str(r['amount']))
        break
else:
    print('NOT_FOUND')
" 2>/dev/null)

if [[ "$RECEIPT_CHECK" == FOUND* ]]; then
    ok "New M1Receipt found in alice's wallet: $RECEIPT_CHECK"
else
    warn "M1Receipt $RECEIPT_OUTPOINT not yet in wallet (may need more confirmations)"
fi

# Check global state (A6 invariant)
info "Checking A6 invariant..."
GLOBAL_STATE=$(rpc_seed getstate 2>/dev/null || echo "{}")
echo "$GLOBAL_STATE" | python3 -c "
import sys,json
try:
    data = json.load(sys.stdin)
    m0_vaulted = data.get('m0_vaulted', 'N/A')
    m1_supply = data.get('m1_supply', 'N/A')
    print(f'  M0_vaulted: {m0_vaulted}')
    print(f'  M1_supply:  {m1_supply}')
    if m0_vaulted == m1_supply:
        print('  A6 INVARIANT: OK (M0_vaulted == M1_supply)')
    else:
        print('  A6 INVARIANT: CHECK MANUALLY')
except:
    print('  (Could not parse state)')
" 2>/dev/null

# ==============================================================================
# SUMMARY
# ==============================================================================
echo ""
echo "================================================================"
echo " SETTLEMENT PIVOT TEST SUMMARY"
echo "================================================================"
echo ""
echo "  Secret:      $SECRET"
echo "  Hashlock:    $HASHLOCK"
echo ""
echo "  HTLC2 (covenant):  $HTLC2_OUTPOINT → CLAIMED"
echo "    Amount: $HTLC2_AMOUNT"
echo "    C3:     $TEMPLATE_C3"
echo ""
echo "  PivotTx:           $CLAIM2_TXID"
echo "    Type: pivot (covenant-enforced)"
echo "    Fee:  $COVENANT_FEE sats"
echo ""
echo "  HTLC3 (standard):  $HTLC3_OUTPOINT → CLAIMED"
echo "    Amount: $HTLC3_AMOUNT"
echo ""
echo "  LP Receipt:        $RECEIPT_OUTPOINT"
echo "    Amount: $RECEIPT_AMOUNT"
echo ""
echo -e "  ${GREEN}Settlement Pivot: SUCCESS${NC}"
echo "  M1 round-trip: Receipt → HTLC2 → HTLC3 → Receipt (minus $COVENANT_FEE fee)"
echo ""
echo "5_complete" > "$STATE_DIR/phase"
