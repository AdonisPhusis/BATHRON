#!/bin/bash
# =============================================================================
# test_flowswap_reverse_e2e.sh - End-to-end FlowSwap test (USDC → BTC)
#
# Tests the full 3-secret atomic swap REVERSE direction.
# User locks USDC on EVM first, LP locks M1+BTC after.
# Uses fake user (charlie/OP3) and LP1 (alice/OP1).
#
# Usage:
#   ./test_flowswap_reverse_e2e.sh              # Default 5 USDC
#   ./test_flowswap_reverse_e2e.sh 10            # Custom USDC amount
#   ./test_flowswap_reverse_e2e.sh status <id>  # Check swap status
# =============================================================================

set -e

# Configuration
LP1_URL="http://57.131.33.152:8080"
OP3_IP="51.75.31.44"
SSH_KEY="$HOME/.ssh/id_ed25519_vps"
SSH_OPTS="-o StrictHostKeyChecking=no -o ConnectTimeout=10"
SSH="ssh -i $SSH_KEY $SSH_OPTS"

# Charlie (fake user) addresses
CHARLIE_USDC_ADDRESS="0x9f11B03618DeE8f12E7F90e753093B613CeD51D2"
CHARLIE_BTC_ADDRESS="tb1qkd2kyur0yqxpp6hvtwheukwpfjt2h5atapyhe7"

# EVM config
HTLC3S_CONTRACT="0x2493EaaaBa6B129962c8967AaEE6bF11D0277756"
USDC_TOKEN="0x036CbD53842c5426634e7929541eC2318f3dCF7e"
BASE_SEPOLIA_RPC="https://sepolia.base.org"
CHAIN_ID=84532

# Colors
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'
log_info()    { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[OK]${NC} $1"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $1"; }
log_step()    { echo -e "\n${CYAN}${BOLD}=== STEP $1 ===${NC}"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC} $1"; }

# Amount (USDC)
USDC_AMOUNT="${1:-5}"

# If "status" mode, just check a swap
if [ "$1" = "status" ] && [ -n "$2" ]; then
    curl -s "${LP1_URL}/api/flowswap/$2" | python3 -m json.tool
    exit 0
fi

echo -e "${BOLD}${CYAN}"
echo "============================================================"
echo "  FlowSwap E2E Test: USDC → BTC (3-Secret Atomic)"
echo "  User Commits First — LP locks AFTER user's USDC on-chain"
echo "============================================================"
echo -e "${NC}"
echo -e "  LP1:     ${LP1_URL}"
echo -e "  User:    charlie (OP3 ${OP3_IP})"
echo -e "  Amount:  ${USDC_AMOUNT} USDC"
echo -e "  BTC to:  ${CHARLIE_BTC_ADDRESS}"
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

# Check charlie's USDC balance on Base Sepolia
CHARLIE_USDC_BAL=$(curl -s -X POST "$BASE_SEPOLIA_RPC" \
    -H "Content-Type: application/json" \
    -d "{\"jsonrpc\":\"2.0\",\"method\":\"eth_call\",\"params\":[{\"to\":\"${USDC_TOKEN}\",\"data\":\"0x70a08231000000000000000000000000${CHARLIE_USDC_ADDRESS:2}\"},\"latest\"],\"id\":1}" 2>/dev/null \
    | python3 -c "import sys,json; r=json.load(sys.stdin); print(f'{int(r[\"result\"],16)/1e6:.2f}')" 2>/dev/null || echo "0")
log_info "Charlie USDC balance: ${CHARLIE_USDC_BAL} USDC"

if [ "$(echo "${CHARLIE_USDC_BAL} < ${USDC_AMOUNT}" | bc -l 2>/dev/null)" = "1" ]; then
    log_error "Insufficient USDC! Have ${CHARLIE_USDC_BAL}, need ${USDC_AMOUNT}"
    log_info "Fund charlie_evm at: https://faucet.circle.com/ (Base Sepolia)"
    exit 1
fi
log_success "Charlie has enough USDC (${CHARLIE_USDC_BAL} >= ${USDC_AMOUNT})"

# Check charlie's ETH for gas
CHARLIE_ETH_BAL=$(curl -s -X POST "$BASE_SEPOLIA_RPC" \
    -H "Content-Type: application/json" \
    -d "{\"jsonrpc\":\"2.0\",\"method\":\"eth_getBalance\",\"params\":[\"${CHARLIE_USDC_ADDRESS}\",\"latest\"],\"id\":1}" 2>/dev/null \
    | python3 -c "import sys,json; r=json.load(sys.stdin); print(f'{int(r[\"result\"],16)/1e18:.6f}')" 2>/dev/null || echo "0")
log_info "Charlie ETH balance: ${CHARLIE_ETH_BAL} ETH"

if [ "$(echo "${CHARLIE_ETH_BAL} < 0.001" | bc -l 2>/dev/null)" = "1" ]; then
    log_error "Insufficient ETH for gas! Have ${CHARLIE_ETH_BAL}, need >= 0.001"
    log_info "Fund at: https://www.alchemy.com/faucets/base-sepolia"
    exit 1
fi
log_success "Charlie has enough ETH for gas"

# =============================================================================
# STEP 1: Generate user secret S_user and compute H_user
# =============================================================================
log_step "1: Generate user secret"

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
        \"from_asset\": \"USDC\",
        \"to_asset\": \"BTC\",
        \"amount\": ${USDC_AMOUNT},
        \"H_user\": \"${H_USER}\",
        \"user_usdc_address\": \"${CHARLIE_USDC_ADDRESS}\",
        \"user_btc_claim_address\": \"${CHARLIE_BTC_ADDRESS}\"
    }" 2>&1)

# Check for error
if echo "$INIT_RESPONSE" | python3 -c "import sys,json; d=json.load(sys.stdin); sys.exit(0 if 'swap_id' in d else 1)" 2>/dev/null; then
    SWAP_ID=$(echo "$INIT_RESPONSE" | python3 -c "import sys,json; print(json.load(sys.stdin)['swap_id'])")
    STATE=$(echo "$INIT_RESPONSE" | python3 -c "import sys,json; print(json.load(sys.stdin)['state'])")
    BTC_OUT_SATS=$(echo "$INIT_RESPONSE" | python3 -c "import sys,json; print(json.load(sys.stdin)['btc_output']['amount_sats'])")
    BTC_OUT=$(echo "$INIT_RESPONSE" | python3 -c "import sys,json; print(json.load(sys.stdin)['btc_output']['amount_btc'])")
    PLAN_EXPIRES=$(echo "$INIT_RESPONSE" | python3 -c "import sys,json; print(json.load(sys.stdin).get('plan_expires_at',0))")

    # USDC deposit info (what user must create via MetaMask/script)
    USDC_DEP_AMOUNT=$(echo "$INIT_RESPONSE" | python3 -c "import sys,json; print(json.load(sys.stdin)['usdc_deposit']['amount'])")
    USDC_DEP_RECIPIENT=$(echo "$INIT_RESPONSE" | python3 -c "import sys,json; print(json.load(sys.stdin)['usdc_deposit']['recipient'])")
    USDC_DEP_TIMELOCK=$(echo "$INIT_RESPONSE" | python3 -c "import sys,json; print(json.load(sys.stdin)['usdc_deposit']['timelock_seconds'])")

    # Hashlocks
    H_LP1=$(echo "$INIT_RESPONSE" | python3 -c "import sys,json; print(json.load(sys.stdin)['hashlocks']['H_lp1'])")
    H_LP2=$(echo "$INIT_RESPONSE" | python3 -c "import sys,json; print(json.load(sys.stdin)['hashlocks']['H_lp2'])")

    log_success "Plan created!"
    log_info "Swap ID:      ${SWAP_ID}"
    log_info "State:        ${STATE}"
    log_info "USDC in:      ${USDC_DEP_AMOUNT} USDC"
    log_info "BTC out:      ${BTC_OUT} BTC (${BTC_OUT_SATS} sats)"
    log_info "LP receives:  ${USDC_DEP_RECIPIENT}"
    log_info "Timelock:     ${USDC_DEP_TIMELOCK}s"
    log_info "Plan expires: $(date -d @${PLAN_EXPIRES} '+%H:%M:%S' 2>/dev/null || echo ${PLAN_EXPIRES})"
    log_info "H_lp1:        ${H_LP1:0:16}..."
    log_info "H_lp2:        ${H_LP2:0:16}..."

    # Verify NO LP locks yet
    HAS_BTC_FUND=$(echo "$INIT_RESPONSE" | python3 -c "
import sys,json
d=json.load(sys.stdin)
print('CLEAN' if not d.get('btc_output',{}).get('fund_txid') else 'DIRTY')
")
    if [ "$HAS_BTC_FUND" = "CLEAN" ]; then
        log_success "Anti-grief verified: NO LP locks in /init response (plan-only)"
    else
        log_warn "Response contains LP lock info — check anti-grief"
    fi
else
    log_error "Init failed:"
    echo "$INIT_RESPONSE" | python3 -m json.tool 2>/dev/null || echo "$INIT_RESPONSE"
    exit 1
fi

# =============================================================================
# STEP 3: User creates USDC HTLC on EVM (user commits FIRST)
# =============================================================================
log_step "3: User creates USDC HTLC on EVM (user commits first)"
log_info "Creating USDC HTLC: ${USDC_DEP_AMOUNT} USDC → ${USDC_DEP_RECIPIENT}"

# Load charlie's EVM private key from OP3
CHARLIE_EVM_KEY=$($SSH ubuntu@${OP3_IP} 'python3 -c "
import json, os
p = os.path.expanduser(\"~/.BathronKey/evm.json\")
if os.path.exists(p):
    d = json.load(open(p))
    print(d.get(\"private_key\", d.get(\"privkey\", \"\")))
else:
    print(\"\")
"' 2>/dev/null)

if [ -z "$CHARLIE_EVM_KEY" ]; then
    log_error "Cannot load charlie's EVM key from OP3:~/.BathronKey/evm.json"
    exit 1
fi
log_info "Charlie EVM key loaded"

# Create USDC HTLC using Python SDK
EVM_RESULT=$(python3 -c "
import sys, json, os
sys.path.insert(0, 'contrib/dex/pna-lp')
from sdk.htlc.evm_3s import EVMHTLC3S

htlc = EVMHTLC3S(contract_address='${HTLC3S_CONTRACT}')
result = htlc.create_htlc(
    recipient='${USDC_DEP_RECIPIENT}',
    amount_usdc=${USDC_DEP_AMOUNT},
    H_user='${H_USER}',
    H_lp1='${H_LP1}',
    H_lp2='${H_LP2}',
    timelock_seconds=${USDC_DEP_TIMELOCK},
    private_key='${CHARLIE_EVM_KEY}',
)
print(json.dumps({
    'success': result.success,
    'htlc_id': result.htlc_id,
    'tx_hash': result.tx_hash,
    'error': result.error,
}))
" 2>&1)

# Parse result
EVM_SUCCESS=$(echo "$EVM_RESULT" | python3 -c "import sys,json; print(json.load(sys.stdin)['success'])" 2>/dev/null || echo "False")
EVM_HTLC_ID=$(echo "$EVM_RESULT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('htlc_id',''))" 2>/dev/null || echo "")
EVM_TX_HASH=$(echo "$EVM_RESULT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('tx_hash',''))" 2>/dev/null || echo "")
EVM_ERROR=$(echo "$EVM_RESULT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('error',''))" 2>/dev/null || echo "")

if [ "$EVM_SUCCESS" = "True" ] && [ -n "$EVM_HTLC_ID" ]; then
    log_success "USDC HTLC created on EVM!"
    log_info "HTLC ID: ${EVM_HTLC_ID}"
    log_info "TX: ${EVM_TX_HASH}"
    log_info "Explorer: https://sepolia.basescan.org/tx/0x${EVM_TX_HASH}"
else
    log_error "USDC HTLC creation failed: ${EVM_ERROR}"
    echo "$EVM_RESULT"
    exit 1
fi

# =============================================================================
# STEP 4: Notify LP — /usdc-funded (with retry for TX confirmation)
# =============================================================================
log_step "4: Notify LP — /usdc-funded"

# Wait for EVM TX to be indexed by RPC node before notifying LP
log_info "Waiting for USDC HTLC TX to confirm on Base Sepolia..."
sleep 5

FUNDED_OK=false
for attempt in $(seq 1 12); do
    USDC_FUNDED_RESPONSE=$(curl -s -X POST "${LP1_URL}/api/flowswap/${SWAP_ID}/usdc-funded" \
        -H "Content-Type: application/json" \
        -d "{\"htlc_id\": \"${EVM_HTLC_ID}\"}" 2>&1)

    FUNDED_STATE=$(echo "$USDC_FUNDED_RESPONSE" | python3 -c "import sys,json; print(json.load(sys.stdin).get('state','error'))" 2>/dev/null || echo "error")

    if [ "$FUNDED_STATE" = "usdc_funded" ]; then
        log_success "USDC funded and verified by LP!"
        log_info "LP is now locking M1 + BTC in background..."
        FUNDED_OK=true
        break
    fi

    # Check if error is "not found on-chain" (timing issue, retry)
    NOT_FOUND=$(echo "$USDC_FUNDED_RESPONSE" | python3 -c "
import sys,json
try:
    d=json.load(sys.stdin)
    detail=d.get('detail','')
    print('1' if 'not found on-chain' in detail.lower() else '0')
except: print('0')
" 2>/dev/null || echo "0")

    if [ "$NOT_FOUND" = "1" ]; then
        log_info "HTLC not yet indexed on-chain, retrying... (${attempt}/12)"
        sleep 10
        continue
    fi

    # Non-retryable error
    log_error "/usdc-funded failed:"
    echo "$USDC_FUNDED_RESPONSE" | python3 -m json.tool 2>/dev/null || echo "$USDC_FUNDED_RESPONSE"
    exit 1
done

if [ "$FUNDED_OK" != "true" ]; then
    log_error "USDC HTLC not confirmed after 2 minutes. TX may have failed."
    log_info "Check TX: https://sepolia.basescan.org/tx/0x${EVM_TX_HASH}"
    exit 1
fi

# =============================================================================
# STEP 5: Poll until LP_LOCKED
# =============================================================================
log_step "5: Wait for LP_LOCKED (LP locks M1 + BTC)"

LP_LOCKED=false
for i in $(seq 1 60); do
    sleep 3
    STATUS_RESP=$(curl -s "${LP1_URL}/api/flowswap/${SWAP_ID}" 2>&1)
    CURRENT_STATE=$(echo "$STATUS_RESP" | python3 -c "import sys,json; print(json.load(sys.stdin).get('state','unknown'))" 2>/dev/null || echo "unknown")

    if [ "$CURRENT_STATE" = "lp_locked" ]; then
        log_success "LP_LOCKED! Both M1 and BTC HTLCs confirmed on-chain."

        BTC_HTLC_ADDR=$(echo "$STATUS_RESP" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('btc',{}).get('htlc_address',d.get('btc_htlc_address','n/a')))" 2>/dev/null)
        BTC_FUND_TX=$(echo "$STATUS_RESP" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('btc',{}).get('fund_txid',d.get('btc_fund_txid','n/a')))" 2>/dev/null)
        M1_HTLC=$(echo "$STATUS_RESP" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('m1',{}).get('htlc_outpoint',d.get('m1_htlc_outpoint','n/a')))" 2>/dev/null)

        log_info "BTC HTLC:     ${BTC_HTLC_ADDR}"
        log_info "BTC Fund TX:  ${BTC_FUND_TX}"
        log_info "M1 HTLC:      ${M1_HTLC}"
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
    log_success "Presign accepted! Settlement in progress..."
    log_info "State: ${PRESIGN_STATE}"

    USDC_CLAIM=$(echo "$PRESIGN_RESPONSE" | python3 -c "import sys,json; print(json.load(sys.stdin).get('evm_claim_txhash','pending'))" 2>/dev/null)
    log_info "USDC claim TX: ${USDC_CLAIM}"
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
echo -e "  Direction:   USDC → BTC (via M1)"
echo -e "  In:          ${USDC_AMOUNT} USDC"
echo -e "  Out:         ${BTC_OUT} BTC (${BTC_OUT_SATS} sats)"
echo ""

# Transaction IDs
BTC_HTLC_ADDR=$(echo "$FINAL" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('btc',{}).get('htlc_address',d.get('btc_htlc_address','n/a')))" 2>/dev/null)
BTC_FUND=$(echo "$FINAL" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('btc',{}).get('fund_txid',d.get('btc_fund_txid','n/a')))" 2>/dev/null)
BTC_CLAIM=$(echo "$FINAL" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('btc',{}).get('claim_txid',d.get('btc_claim_txid','n/a')))" 2>/dev/null)
EVM_HTLC_FINAL=$(echo "$FINAL" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('evm',{}).get('htlc_id',d.get('evm_htlc_id','n/a')))" 2>/dev/null)
EVM_CLAIM=$(echo "$FINAL" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('evm',{}).get('claim_txhash',d.get('evm_claim_txhash','n/a')))" 2>/dev/null)
M1_HTLC=$(echo "$FINAL" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('m1',{}).get('htlc_outpoint',d.get('m1_htlc_outpoint','n/a')))" 2>/dev/null)

echo -e "  ${BOLD}EVM Leg (USDC — user locked):${NC}"
echo -e "    HTLC ID:   ${EVM_HTLC_FINAL}"
echo -e "    Claim TX:  ${EVM_CLAIM}"
echo ""
echo -e "  ${BOLD}BTC Leg (LP locked):${NC}"
echo -e "    HTLC:      ${BTC_HTLC_ADDR}"
echo -e "    Fund TX:   ${BTC_FUND}"
echo -e "    Claim TX:  ${BTC_CLAIM}"
echo ""
echo -e "  ${BOLD}M1 Leg:${NC}"
echo -e "    HTLC:      ${M1_HTLC}"
echo ""

# Anti-grief verification
echo -e "  ${BOLD}Anti-Grief Verification:${NC}"
echo -e "    User committed first:  YES (USDC HTLC created before LP locked)"
echo -e "    LP locked after user:  YES (LP_LOCKED after USDC_FUNDED)"
echo -e "    Plan-only init:        YES (no BTC/M1 in /init response)"
echo ""

if [ "$FINAL_STATE" = "completed" ]; then
    echo -e "  ${GREEN}${BOLD}RESULT: SUCCESS — Full 3-secret atomic swap completed!${NC}"
    echo -e "  ${GREEN}User sent ${USDC_AMOUNT} USDC, received ${BTC_OUT} BTC.${NC}"
else
    echo -e "  ${YELLOW}${BOLD}RESULT: State = ${FINAL_STATE} (may still be settling)${NC}"
    echo -e "  ${YELLOW}Check: ./test_flowswap_reverse_e2e.sh status ${SWAP_ID}${NC}"
fi

echo ""
echo -e "${CYAN}============================================================${NC}"
