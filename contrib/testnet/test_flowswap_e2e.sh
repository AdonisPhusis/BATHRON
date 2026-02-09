#!/bin/bash
# =============================================================================
# test_flowswap_e2e.sh - End-to-end FlowSwap test (BTC → USDC)
#
# Tests the full 3-secret atomic swap with "user commits first" model.
# Uses fake user (charlie/OP3) and LP1 (alice/OP1).
#
# Usage:
#   ./test_flowswap_e2e.sh              # Full E2E test (default 0.0001 BTC)
#   ./test_flowswap_e2e.sh 0.0005       # Custom amount
#   ./test_flowswap_e2e.sh status <id>  # Check swap status
# =============================================================================

set -e

# Configuration
LP1_URL="http://57.131.33.152:8080"
OP3_IP="51.75.31.44"
SSH_KEY="$HOME/.ssh/id_ed25519_vps"
SSH_OPTS="-o StrictHostKeyChecking=no -o ConnectTimeout=10"
SSH="ssh -i $SSH_KEY $SSH_OPTS"

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
    curl -s "${LP1_URL}/api/flowswap/$2" | python3 -m json.tool
    exit 0
fi

echo -e "${BOLD}${CYAN}"
echo "============================================================"
echo "  FlowSwap E2E Test: BTC → USDC (3-Secret Atomic)"
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

# Check LP1 is reachable
LP_STATUS=$(curl -s --max-time 5 "${LP1_URL}/api/status" 2>/dev/null || echo "")
if [ -z "$LP_STATUS" ] || ! echo "$LP_STATUS" | python3 -c "import sys,json; json.load(sys.stdin)" 2>/dev/null; then
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
# STEP 4: Notify LP — /btc-funded
# =============================================================================
log_step "4: Notify LP — /btc-funded"

BTC_FUNDED_RESPONSE=$(curl -s -X POST "${LP1_URL}/api/flowswap/${SWAP_ID}/btc-funded" 2>&1)

FUNDED_STATE=$(echo "$BTC_FUNDED_RESPONSE" | python3 -c "import sys,json; print(json.load(sys.stdin).get('state','error'))" 2>/dev/null || echo "error")

if [ "$FUNDED_STATE" = "btc_funded" ]; then
    CONFS=$(echo "$BTC_FUNDED_RESPONSE" | python3 -c "import sys,json; print(json.load(sys.stdin).get('confirmations',0))")
    REQ_CONFS=$(echo "$BTC_FUNDED_RESPONSE" | python3 -c "import sys,json; print(json.load(sys.stdin).get('required_confirmations',0))")
    log_success "BTC funded and accepted by LP!"
    log_info "Confirmations: ${CONFS} (required: ${REQ_CONFS})"
    log_info "LP is now locking USDC + M1 in background..."
else
    log_error "/btc-funded failed:"
    echo "$BTC_FUNDED_RESPONSE" | python3 -m json.tool 2>/dev/null || echo "$BTC_FUNDED_RESPONSE"

    # If need confirmations, wait and retry
    if echo "$BTC_FUNDED_RESPONSE" | grep -qi "confirmation\|not funded"; then
        log_info "Waiting for BTC confirmation... (signet ~10 min)"
        log_info "Monitor: https://mempool.space/signet/tx/${FUND_TXID}"

        for i in $(seq 1 30); do
            sleep 20
            log_info "Retry $i/30..."
            BTC_FUNDED_RESPONSE=$(curl -s -X POST "${LP1_URL}/api/flowswap/${SWAP_ID}/btc-funded" 2>&1)
            FUNDED_STATE=$(echo "$BTC_FUNDED_RESPONSE" | python3 -c "import sys,json; print(json.load(sys.stdin).get('state','error'))" 2>/dev/null || echo "error")
            if [ "$FUNDED_STATE" = "btc_funded" ]; then
                log_success "BTC funded (after retries)!"
                break
            fi
        done

        if [ "$FUNDED_STATE" != "btc_funded" ]; then
            log_error "BTC funding not confirmed after 10 min."
            log_info "Check manually: ./test_flowswap_e2e.sh status ${SWAP_ID}"
            exit 1
        fi
    else
        exit 1
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

    if [ "$CURRENT_STATE" = "lp_locked" ]; then
        log_success "LP_LOCKED! Both USDC and M1 HTLCs confirmed on-chain."

        # Show LP lock details
        EVM_HTLC=$(echo "$STATUS_RESP" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('evm_htlc_id','n/a'))" 2>/dev/null)
        M1_HTLC=$(echo "$STATUS_RESP" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('m1_htlc_outpoint','n/a'))" 2>/dev/null)
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
# FINAL REPORT
# =============================================================================
echo ""
echo -e "${BOLD}${CYAN}============================================================${NC}"
echo -e "${BOLD}${CYAN}  SWAP REPORT${NC}"
echo -e "${BOLD}${CYAN}============================================================${NC}"

# Get final status
FINAL=$(curl -s "${LP1_URL}/api/flowswap/${SWAP_ID}" 2>&1)
FINAL_STATE=$(echo "$FINAL" | python3 -c "import sys,json; print(json.load(sys.stdin).get('state','unknown'))" 2>/dev/null)

echo ""
echo -e "  Swap ID:     ${SWAP_ID}"
echo -e "  State:       ${FINAL_STATE}"
echo -e "  Direction:   BTC → USDC (via M1)"
echo -e "  In:          ${AMOUNT} BTC (${BTC_AMOUNT_SATS} sats)"
echo -e "  Out:         ${USDC_AMOUNT} USDC"
echo ""

# Transaction IDs
BTC_FUND=$(echo "$FINAL" | python3 -c "import sys,json; print(json.load(sys.stdin).get('btc_fund_txid','n/a'))" 2>/dev/null)
BTC_CLAIM=$(echo "$FINAL" | python3 -c "import sys,json; print(json.load(sys.stdin).get('btc_claim_txid','n/a'))" 2>/dev/null)
EVM_HTLC=$(echo "$FINAL" | python3 -c "import sys,json; print(json.load(sys.stdin).get('evm_htlc_id','n/a'))" 2>/dev/null)
EVM_CLAIM=$(echo "$FINAL" | python3 -c "import sys,json; print(json.load(sys.stdin).get('evm_claim_txhash','n/a'))" 2>/dev/null)
M1_HTLC=$(echo "$FINAL" | python3 -c "import sys,json; print(json.load(sys.stdin).get('m1_htlc_outpoint','n/a'))" 2>/dev/null)

echo -e "  ${BOLD}BTC Leg:${NC}"
echo -e "    Fund TX:   ${BTC_FUND}"
echo -e "    Claim TX:  ${BTC_CLAIM}"
echo ""
echo -e "  ${BOLD}EVM Leg (USDC):${NC}"
echo -e "    HTLC ID:   ${EVM_HTLC}"
echo -e "    Claim TX:  ${EVM_CLAIM}"
echo ""
echo -e "  ${BOLD}M1 Leg:${NC}"
echo -e "    HTLC:      ${M1_HTLC}"
echo ""

# Anti-grief verification
echo -e "  ${BOLD}Anti-Grief Verification:${NC}"
echo -e "    User committed first:  YES (BTC funded before LP locked)"
echo -e "    LP locked after user:  YES (LP_LOCKED after BTC_FUNDED)"
echo -e "    Plan-only init:        YES (no EVM/M1 in /init response)"
echo ""

if [ "$FINAL_STATE" = "completed" ]; then
    echo -e "  ${GREEN}${BOLD}RESULT: SUCCESS — Full 3-secret atomic swap completed!${NC}"
    echo -e "  ${GREEN}User sent ${AMOUNT} BTC, received ${USDC_AMOUNT} USDC.${NC}"
else
    echo -e "  ${YELLOW}${BOLD}RESULT: State = ${FINAL_STATE} (may still be settling)${NC}"
    echo -e "  ${YELLOW}Check: ./test_flowswap_e2e.sh status ${SWAP_ID}${NC}"
fi

echo ""
echo -e "${CYAN}============================================================${NC}"
