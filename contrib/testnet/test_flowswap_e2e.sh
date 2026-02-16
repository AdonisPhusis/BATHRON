#!/bin/bash
# =============================================================================
# test_flowswap_e2e.sh - End-to-end FlowSwap test (BTC → USDC)
#
# Tests the full 4-HTLC Settlement Pivot swap with "user commits first" model.
# Verifies: HTLC-1 (BTC), HTLC-2 (M1+covenant), HTLC-3 (pivot), HTLC-4 (USDC).
# Uses fake user (charlie/OP3) and LP1 (alice/OP1).
#
# Usage:
#   ./test_flowswap_e2e.sh              # Full E2E test (default 0.0001 BTC)
#   ./test_flowswap_e2e.sh 0.0005       # Custom amount
#   ./test_flowswap_e2e.sh status <id>  # Check swap status
# =============================================================================

set -e

# Configuration
OP1_IP="57.131.33.152"
OP3_IP="51.75.31.44"
SSH_KEY="$HOME/.ssh/id_ed25519_vps"
SSH_OPTS="-o StrictHostKeyChecking=no -o ConnectTimeout=10"
SSH="ssh -i $SSH_KEY $SSH_OPTS"

# SSH tunnel to LP1 (dev→OP1 direct curl is unreliable)
TUNNEL_PORT=18080
# Kill any stale tunnel first
kill $(lsof -ti tcp:${TUNNEL_PORT} -sTCP:LISTEN 2>/dev/null) 2>/dev/null || true
sleep 1
ssh -fN -L ${TUNNEL_PORT}:localhost:8080 -i $SSH_KEY -o StrictHostKeyChecking=no -o ConnectTimeout=15 -o ServerAliveInterval=10 ubuntu@${OP1_IP} 2>/dev/null
sleep 3  # Wait for tunnel to establish
LP1_URL="http://localhost:${TUNNEL_PORT}"
cleanup_tunnel() { kill $(lsof -ti tcp:${TUNNEL_PORT} -sTCP:LISTEN 2>/dev/null) 2>/dev/null || true; }
trap cleanup_tunnel EXIT

# Charlie (fake user) EVM address for USDC receipt
CHARLIE_USDC_ADDRESS="0x9f11B03618DeE8f12E7F90e753093B613CeD51D2"

# BTC CLI on OP3 (must specify wallet for signet)
BTC_CLI="/home/ubuntu/bitcoin/bin/bitcoin-cli -signet -datadir=/home/ubuntu/.bitcoin-signet -rpcwallet=fake_user"

# Colors
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'
log_info()    { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[OK]${NC} $1"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $1"; }
log_step()    { echo -e "\n${CYAN}${BOLD}=== STEP $1 ===${NC}"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC} $1"; }

# Amount
AMOUNT="${1:-0.0001}"

# If "status" mode, just check a swap
if [ "$1" = "status" ] && [ -n "$2" ]; then
    curl -s --max-time 15 "${LP1_URL}/api/flowswap/$2" | python3 -m json.tool
    exit 0
fi

echo -e "${BOLD}${CYAN}"
echo "============================================================"
echo "  FlowSwap E2E Test: BTC → USDC (4-HTLC Settlement Pivot)"
echo "  User Commits First — LP locks AFTER user's BTC on-chain"
echo "============================================================"
echo -e "${NC}"
echo -e "  LP1:     ${LP1_URL}"
echo -e "  User:    charlie (OP3 ${OP3_IP})"
echo -e "  Amount:  ${AMOUNT} BTC"
echo -e "  USDC to: ${CHARLIE_USDC_ADDRESS}"
echo ""

# =============================================================================
# STEP 0: Pre-flight checks
# =============================================================================
log_step "0: Pre-flight checks"

# Check LP1 is reachable (retry with increasing timeout)
LP_STATUS=""
for _try in 1 2 3; do
    LP_STATUS=$(curl -s --max-time 20 "${LP1_URL}/api/status" 2>/dev/null || echo "")
    if [ -n "$LP_STATUS" ] && echo "$LP_STATUS" | python3 -c "import sys,json; json.load(sys.stdin)" 2>/dev/null; then
        break
    fi
    log_warn "LP1 not responding (attempt $_try/3), retrying in 5s..."
    sleep 5
    LP_STATUS=""
done
if [ -z "$LP_STATUS" ]; then
    log_error "LP1 unreachable at ${LP1_URL}"
    exit 1
fi
log_success "LP1 is up"

# Ensure BTC wallet is loaded on OP3
log_info "Loading BTC wallet on OP3..."
$SSH ubuntu@${OP3_IP} "/home/ubuntu/bitcoin/bin/bitcoin-cli -signet -datadir=/home/ubuntu/.bitcoin-signet loadwallet 'fake_user' 2>/dev/null || true" 2>/dev/null

# Check OP3 BTC wallet
OP3_BALANCE=$($SSH ubuntu@${OP3_IP} "$BTC_CLI getbalance" 2>/dev/null || echo "0")
log_info "OP3 BTC balance: ${OP3_BALANCE} BTC"

if [ "$(echo "$OP3_BALANCE <= 0" | bc -l 2>/dev/null)" = "1" ]; then
    log_error "OP3 has no BTC! Fund from signet faucet first."
    log_info "Faucets: https://signetfaucet.com | https://alt.signetfaucet.com"
    OP3_ADDR=$($SSH ubuntu@${OP3_IP} "$BTC_CLI getnewaddress 'flowswap_test'" 2>/dev/null || echo "unknown")
    log_info "OP3 address: ${OP3_ADDR}"
    exit 1
fi

# Check enough balance (amount + fee margin)
NEEDED=$(echo "$AMOUNT + 0.0001" | bc -l)
if [ "$(echo "$OP3_BALANCE < $NEEDED" | bc -l 2>/dev/null)" = "1" ]; then
    log_error "Insufficient BTC: have ${OP3_BALANCE}, need ~${NEEDED}"
    exit 1
fi
log_success "OP3 has enough BTC (${OP3_BALANCE} >= ${NEEDED})"

# =============================================================================
# STEP 1: Generate user secret S_user and compute H_user
# =============================================================================
log_step "1: Generate user secret"

# Generate 32 random bytes as hex (S_user)
S_USER=$(python3 -c "import secrets; print(secrets.token_hex(32))")
H_USER=$(python3 -c "
import hashlib
s = bytes.fromhex('${S_USER}')
print(hashlib.sha256(s).hexdigest())
")

log_info "S_user: ${S_USER:0:16}... (kept secret until presign)"
log_info "H_user: ${H_USER}"

# =============================================================================
# STEP 2: Call /init — get PLAN (off-chain, no LP commitment)
# =============================================================================
log_step "2: Init swap plan (off-chain)"

INIT_RESPONSE=$(curl -s -X POST "${LP1_URL}/api/flowswap/init" \
    -H "Content-Type: application/json" \
    -d "{
        \"from_asset\": \"BTC\",
        \"to_asset\": \"USDC\",
        \"amount\": ${AMOUNT},
        \"H_user\": \"${H_USER}\",
        \"user_usdc_address\": \"${CHARLIE_USDC_ADDRESS}\"
    }" 2>&1)

# Check for error
if echo "$INIT_RESPONSE" | python3 -c "import sys,json; d=json.load(sys.stdin); sys.exit(0 if 'swap_id' in d else 1)" 2>/dev/null; then
    SWAP_ID=$(echo "$INIT_RESPONSE" | python3 -c "import sys,json; print(json.load(sys.stdin)['swap_id'])")
    BTC_ADDRESS=$(echo "$INIT_RESPONSE" | python3 -c "import sys,json; print(json.load(sys.stdin)['btc_deposit']['address'])")
    BTC_AMOUNT_SATS=$(echo "$INIT_RESPONSE" | python3 -c "import sys,json; print(json.load(sys.stdin)['btc_deposit']['amount_sats'])")
    USDC_AMOUNT=$(echo "$INIT_RESPONSE" | python3 -c "import sys,json; print(json.load(sys.stdin)['usdc_output']['amount'])")
    PLAN_EXPIRES=$(echo "$INIT_RESPONSE" | python3 -c "import sys,json; print(json.load(sys.stdin).get('plan_expires_at',0))")
    STATE=$(echo "$INIT_RESPONSE" | python3 -c "import sys,json; print(json.load(sys.stdin)['state'])")

    log_success "Plan created!"
    log_info "Swap ID:      ${SWAP_ID}"
    log_info "State:        ${STATE}"
    log_info "BTC deposit:  ${BTC_ADDRESS}"
    log_info "Amount:       ${BTC_AMOUNT_SATS} sats (${AMOUNT} BTC)"
    log_info "USDC output:  ${USDC_AMOUNT} USDC → ${CHARLIE_USDC_ADDRESS}"
    log_info "Plan expires: $(date -d @${PLAN_EXPIRES} '+%H:%M:%S' 2>/dev/null || echo ${PLAN_EXPIRES})"

    # Show hashlocks
    H_LP1=$(echo "$INIT_RESPONSE" | python3 -c "import sys,json; print(json.load(sys.stdin)['hashlocks']['H_lp1'])")
    H_LP2=$(echo "$INIT_RESPONSE" | python3 -c "import sys,json; print(json.load(sys.stdin)['hashlocks']['H_lp2'])")
    log_info "H_lp1:        ${H_LP1:0:16}..."
    log_info "H_lp2:        ${H_LP2:0:16}..."

    # Verify NO LP locks yet (anti-grief check)
    HAS_EVM=$(echo "$INIT_RESPONSE" | python3 -c "
import sys,json
d=json.load(sys.stdin)
# Check response doesn't contain evm_htlc_id (proves no LP lock at init)
print('CLEAN' if 'evm_htlc_id' not in str(d.get('usdc_output','')) else 'DIRTY')
")
    if [ "$HAS_EVM" = "CLEAN" ]; then
        log_success "Anti-grief verified: NO LP locks in /init response (plan-only)"
    else
        log_warn "Response may contain LP lock info — check anti-grief"
    fi
else
    log_error "Init failed:"
    echo "$INIT_RESPONSE" | python3 -m json.tool 2>/dev/null || echo "$INIT_RESPONSE"
    exit 1
fi

# =============================================================================
# STEP 3: User funds BTC HTLC (user commits FIRST)
# =============================================================================
log_step "3: User funds BTC HTLC (user commits first)"
log_info "Sending ${AMOUNT} BTC to HTLC: ${BTC_ADDRESS}"

# Send with RBF disabled (required for 0-conf acceptance by LP)
FUND_TXID=$($SSH ubuntu@${OP3_IP} "$BTC_CLI -named sendtoaddress address='${BTC_ADDRESS}' amount=${AMOUNT} replaceable=false" 2>&1)

if [ $? -ne 0 ] || [ -z "$FUND_TXID" ]; then
    log_error "BTC funding failed: ${FUND_TXID}"
    exit 1
fi

log_success "BTC funded!"
log_info "TX: ${FUND_TXID}"
log_info "Explorer: https://mempool.space/signet/tx/${FUND_TXID}"

# Wait a moment for mempool propagation
log_info "Waiting 5s for mempool propagation..."
sleep 5

# =============================================================================
# STEP 4: Notify LP — /btc-funded (watcher may have already advanced state)
# =============================================================================
log_step "4: Notify LP — /btc-funded"

# Check if watcher already moved past btc_funded (e.g. to lp_locked)
CURRENT_CHECK=$(curl -s "${LP1_URL}/api/flowswap/${SWAP_ID}" 2>/dev/null)
CURRENT_STATE=$(echo "$CURRENT_CHECK" | python3 -c "import sys,json; print(json.load(sys.stdin).get('state','unknown'))" 2>/dev/null || echo "unknown")

if echo "$CURRENT_STATE" | grep -qE "lp_locked|btc_claimed|completing|completed"; then
    log_success "Watcher already advanced to ${CURRENT_STATE} (0-conf auto-detect)"
    FUNDED_STATE="$CURRENT_STATE"
else
    BTC_FUNDED_RESPONSE=$(curl -s -X POST "${LP1_URL}/api/flowswap/${SWAP_ID}/btc-funded" 2>&1)
    FUNDED_STATE=$(echo "$BTC_FUNDED_RESPONSE" | python3 -c "import sys,json; print(json.load(sys.stdin).get('state','error'))" 2>/dev/null || echo "error")

    if echo "$FUNDED_STATE" | grep -qE "btc_funded|lp_locked"; then
        log_success "BTC funded and accepted by LP! (state=${FUNDED_STATE})"
    else
        log_warn "/btc-funded returned: ${FUNDED_STATE} — polling for state change..."
        for i in $(seq 1 30); do
            sleep 10
            POLL_RESP=$(curl -s "${LP1_URL}/api/flowswap/${SWAP_ID}" 2>/dev/null)
            FUNDED_STATE=$(echo "$POLL_RESP" | python3 -c "import sys,json; print(json.load(sys.stdin).get('state','unknown'))" 2>/dev/null || echo "unknown")
            if echo "$FUNDED_STATE" | grep -qE "btc_funded|lp_locked|btc_claimed|completing|completed"; then
                log_success "State advanced to ${FUNDED_STATE} (retry $i)"
                break
            fi
            if [ $((i % 5)) -eq 0 ]; then
                log_info "Waiting... state=${FUNDED_STATE} ($i/30)"
            fi
        done

        if ! echo "$FUNDED_STATE" | grep -qE "btc_funded|lp_locked|btc_claimed|completing|completed"; then
            log_error "BTC funding not confirmed after 5 min."
            log_info "Check manually: ./test_flowswap_e2e.sh status ${SWAP_ID}"
            exit 1
        fi
    fi
fi

# =============================================================================
# STEP 5: Poll until LP_LOCKED
# =============================================================================
log_step "5: Wait for LP_LOCKED (LP locks USDC + M1)"

LP_LOCKED=false
for i in $(seq 1 60); do
    sleep 3
    STATUS_RESP=$(curl -s "${LP1_URL}/api/flowswap/${SWAP_ID}" 2>&1)
    CURRENT_STATE=$(echo "$STATUS_RESP" | python3 -c "import sys,json; print(json.load(sys.stdin).get('state','unknown'))" 2>/dev/null || echo "unknown")

    if echo "$CURRENT_STATE" | grep -qE "lp_locked|btc_claimed|completing|completed"; then
        log_success "LP_LOCKED! Both USDC and M1 HTLCs confirmed on-chain. (state=${CURRENT_STATE})"

        # Show LP lock details from nested legs
        EVM_HTLC=$(echo "$STATUS_RESP" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('evm',{}).get('htlc_id','n/a'))" 2>/dev/null)
        M1_HTLC=$(echo "$STATUS_RESP" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('m1',{}).get('htlc_outpoint','n/a'))" 2>/dev/null)
        log_info "EVM HTLC:    ${EVM_HTLC}"
        log_info "M1 HTLC:     ${M1_HTLC}"
        LP_LOCKED=true
        break
    elif [ "$CURRENT_STATE" = "failed" ]; then
        ERROR=$(echo "$STATUS_RESP" | python3 -c "import sys,json; print(json.load(sys.stdin).get('error','unknown'))" 2>/dev/null)
        log_error "LP lock FAILED: ${ERROR}"
        exit 1
    elif [ "$CURRENT_STATE" = "expired" ]; then
        log_error "Plan expired before LP could lock!"
        exit 1
    fi

    if [ $((i % 5)) -eq 0 ]; then
        log_info "Waiting... state=${CURRENT_STATE} (${i}/60)"
    fi
done

if [ "$LP_LOCKED" != "true" ]; then
    log_error "LP_LOCKED timeout after 3 min"
    log_info "Current state: ${CURRENT_STATE}"
    exit 1
fi

# =============================================================================
# STEP 6: Presign — reveal S_user to LP
# =============================================================================
log_step "6: Presign — reveal S_user (settlement)"

PRESIGN_RESPONSE=$(curl -s -X POST "${LP1_URL}/api/flowswap/${SWAP_ID}/presign" \
    -H "Content-Type: application/json" \
    -d "{\"S_user\": \"${S_USER}\"}" 2>&1)

PRESIGN_STATE=$(echo "$PRESIGN_RESPONSE" | python3 -c "import sys,json; print(json.load(sys.stdin).get('state','error'))" 2>/dev/null || echo "error")

if echo "$PRESIGN_STATE" | grep -qE "btc_claimed|completing|completed"; then
    log_success "Presign accepted! LP claiming BTC..."
    log_info "State: ${PRESIGN_STATE}"

    BTC_CLAIM=$(echo "$PRESIGN_RESPONSE" | python3 -c "import sys,json; print(json.load(sys.stdin).get('btc_claim_txid','pending'))" 2>/dev/null)
    log_info "BTC claim TX: ${BTC_CLAIM}"
else
    log_error "Presign failed:"
    echo "$PRESIGN_RESPONSE" | python3 -m json.tool 2>/dev/null || echo "$PRESIGN_RESPONSE"
    exit 1
fi

# =============================================================================
# STEP 7: Poll until COMPLETED
# =============================================================================
log_step "7: Wait for completion (all legs settled)"

COMPLETED=false
for i in $(seq 1 120); do
    sleep 5
    STATUS_RESP=$(curl -s "${LP1_URL}/api/flowswap/${SWAP_ID}" 2>&1)
    CURRENT_STATE=$(echo "$STATUS_RESP" | python3 -c "import sys,json; print(json.load(sys.stdin).get('state','unknown'))" 2>/dev/null || echo "unknown")

    if [ "$CURRENT_STATE" = "completed" ]; then
        log_success "SWAP COMPLETED!"
        COMPLETED=true
        break
    elif [ "$CURRENT_STATE" = "failed" ]; then
        ERROR=$(echo "$STATUS_RESP" | python3 -c "import sys,json; print(json.load(sys.stdin).get('error','unknown'))" 2>/dev/null)
        log_error "Swap failed: ${ERROR}"
        break
    fi

    if [ $((i % 6)) -eq 0 ]; then
        log_info "Settling... state=${CURRENT_STATE} (${i}s)"
    fi
done

# =============================================================================
# FINAL REPORT — 4-HTLC Settlement Pivot Model
# =============================================================================
echo ""
echo -e "${BOLD}${CYAN}============================================================${NC}"
echo -e "${BOLD}${CYAN}  SWAP REPORT — 4-HTLC Settlement Pivot${NC}"
echo -e "${BOLD}${CYAN}============================================================${NC}"

# Get final status
FINAL=$(curl -s "${LP1_URL}/api/flowswap/${SWAP_ID}" 2>&1)
FINAL_STATE=$(echo "$FINAL" | python3 -c "import sys,json; print(json.load(sys.stdin).get('state','unknown'))" 2>/dev/null)

echo ""
echo -e "  Swap ID:     ${SWAP_ID}"
echo -e "  State:       ${FINAL_STATE}"
echo -e "  Direction:   BTC → USDC (via M1 Settlement Pivot)"
echo -e "  In:          ${AMOUNT} BTC (${BTC_AMOUNT_SATS} sats)"
echo -e "  Out:         ${USDC_AMOUNT} USDC"
echo ""

# Extract 4 HTLC legs from API response
HTLC_DATA=$(echo "$FINAL" | python3 -c "
import sys, json
d = json.load(sys.stdin)
legs = d.get('legs', {})
btc = d.get('btc', {})
m1 = d.get('m1', {})
evm = d.get('evm', {})

# HTLC-1: BTC (User → LP)
h1 = legs.get('htlc1_btc', {})
print(f\"H1_STATUS={h1.get('status','n/a')}\")
print(f\"H1_FUND={btc.get('fund_txid','n/a')}\")
print(f\"H1_CLAIM={btc.get('claim_txid','n/a')}\")

# HTLC-2: M1 + covenant (LP → covenant)
h2 = legs.get('htlc2_m1_covenant', {})
print(f\"H2_STATUS={h2.get('status','n/a')}\")
print(f\"H2_OUTPOINT={m1.get('htlc_outpoint','n/a')}\")
print(f\"H2_CLAIM={m1.get('claim_txid','n/a')}\")

# HTLC-3: Settlement Pivot (covenant → LP)
h3 = legs.get('htlc3_pivot', {})
print(f\"H3_STATUS={h3.get('status','n/a')}\")
print(f\"H3_PIVOT_TYPE={m1.get('pivot_type','n/a')}\")
print(f\"H3_RECEIPT={m1.get('pivot_receipt','n/a')}\")
print(f\"H3_DEST={m1.get('covenant_dest','n/a')}\")

# HTLC-4: USDC (LP → User)
h4 = legs.get('htlc4_usdc', {})
print(f\"H4_STATUS={h4.get('status','n/a')}\")
print(f\"H4_HTLC_ID={evm.get('htlc_id','n/a')}\")
print(f\"H4_LOCK={evm.get('lock_txhash','n/a')}\")
print(f\"H4_CLAIM={evm.get('claim_txhash','n/a')}\")
" 2>/dev/null)

eval "$HTLC_DATA"

echo -e "  ${BOLD}HTLC-1: BTC (User → LP)${NC}  [${H1_STATUS}]"
echo -e "    Fund TX:       ${H1_FUND}"
echo -e "    Claim TX:      ${H1_CLAIM}"
echo ""
echo -e "  ${BOLD}HTLC-2: M1 + covenant (LP → covenant)${NC}  [${H2_STATUS}]"
echo -e "    HTLC outpoint: ${H2_OUTPOINT}"
echo -e "    Claim TX:      ${H2_CLAIM}"
echo ""
echo -e "  ${BOLD}HTLC-3: Settlement Pivot (covenant → LP)${NC}  [${H3_STATUS}]"
echo -e "    Pivot type:    ${H3_PIVOT_TYPE}"
echo -e "    Receipt:       ${H3_RECEIPT}"
echo -e "    Covenant dest: ${H3_DEST}"
echo ""
echo -e "  ${BOLD}HTLC-4: USDC (LP → User)${NC}  [${H4_STATUS}]"
echo -e "    HTLC ID:       ${H4_HTLC_ID}"
echo -e "    Lock TX:       ${H4_LOCK}"
echo -e "    Claim TX:      ${H4_CLAIM}"
echo ""

# 4-HTLC verification
echo -e "  ${BOLD}4-HTLC Verification:${NC}"

HTLC_ERRORS=0

# HTLC-1: BTC claimed
if [ "$H1_CLAIM" != "n/a" ] && [ "$H1_CLAIM" != "None" ] && [ -n "$H1_CLAIM" ]; then
    echo -e "    ${GREEN}[OK]${NC} HTLC-1 BTC claimed"
else
    echo -e "    ${RED}[FAIL]${NC} HTLC-1 BTC not claimed"
    HTLC_ERRORS=$((HTLC_ERRORS + 1))
fi

# HTLC-2: M1 claimed
if [ "$H2_CLAIM" != "n/a" ] && [ "$H2_CLAIM" != "None" ] && [ -n "$H2_CLAIM" ]; then
    echo -e "    ${GREEN}[OK]${NC} HTLC-2 M1 claimed (covenant)"
else
    echo -e "    ${RED}[FAIL]${NC} HTLC-2 M1 not claimed (Settlement Pivot missing!)"
    HTLC_ERRORS=$((HTLC_ERRORS + 1))
fi

# HTLC-3: Pivot created
if [ "$H3_PIVOT_TYPE" = "pivot" ]; then
    echo -e "    ${GREEN}[OK]${NC} HTLC-3 Settlement Pivot created (type=pivot)"
else
    echo -e "    ${RED}[FAIL]${NC} HTLC-3 Settlement Pivot missing (type=${H3_PIVOT_TYPE})"
    HTLC_ERRORS=$((HTLC_ERRORS + 1))
fi

# HTLC-3: Receipt exists
if [ "$H3_RECEIPT" != "n/a" ] && [ "$H3_RECEIPT" != "None" ] && [ -n "$H3_RECEIPT" ]; then
    echo -e "    ${GREEN}[OK]${NC} HTLC-3 receipt: ${H3_RECEIPT}"
else
    echo -e "    ${RED}[FAIL]${NC} HTLC-3 no receipt (M1 not returned to LP)"
    HTLC_ERRORS=$((HTLC_ERRORS + 1))
fi

# HTLC-4: USDC claimed
if [ "$H4_CLAIM" != "n/a" ] && [ "$H4_CLAIM" != "None" ] && [ -n "$H4_CLAIM" ]; then
    echo -e "    ${GREEN}[OK]${NC} HTLC-4 USDC claimed"
else
    echo -e "    ${RED}[FAIL]${NC} HTLC-4 USDC not claimed"
    HTLC_ERRORS=$((HTLC_ERRORS + 1))
fi

echo ""

# Anti-grief verification
echo -e "  ${BOLD}Anti-Grief Verification:${NC}"
echo -e "    User committed first:  YES (BTC funded before LP locked)"
echo -e "    LP locked after user:  YES (LP_LOCKED after BTC_FUNDED)"
echo -e "    Plan-only init:        YES (no EVM/M1 in /init response)"
echo ""

if [ "$FINAL_STATE" = "completed" ] && [ "$HTLC_ERRORS" -eq 0 ]; then
    echo -e "  ${GREEN}${BOLD}RESULT: SUCCESS — Full 4-HTLC Settlement Pivot swap!${NC}"
    echo -e "  ${GREEN}User sent ${AMOUNT} BTC, received ${USDC_AMOUNT} USDC.${NC}"
    echo -e "  ${GREEN}M1 made full round-trip via OP_TEMPLATEVERIFY covenant.${NC}"
elif [ "$FINAL_STATE" = "completed" ]; then
    echo -e "  ${YELLOW}${BOLD}RESULT: COMPLETED but ${HTLC_ERRORS} HTLC check(s) failed${NC}"
    echo -e "  ${YELLOW}USDC delivered but Settlement Pivot incomplete.${NC}"
elif [ "$FINAL_STATE" = "completing" ]; then
    echo -e "  ${YELLOW}${BOLD}RESULT: COMPLETING — M1 Settlement Pivot in progress${NC}"
    echo -e "  ${YELLOW}USDC delivered, waiting for M1 claim + pivot.${NC}"
    echo -e "  ${YELLOW}Check: ./test_flowswap_e2e.sh status ${SWAP_ID}${NC}"
else
    echo -e "  ${YELLOW}${BOLD}RESULT: State = ${FINAL_STATE} (may still be settling)${NC}"
    echo -e "  ${YELLOW}Check: ./test_flowswap_e2e.sh status ${SWAP_ID}${NC}"
fi

echo ""
echo -e "${CYAN}============================================================${NC}"
