#!/bin/bash
# =============================================================================
# FULL WALLET AUDIT: BATHRON (M0/M1) + EVM (USDC/ETH) + BTC
# Checks key independence, address consistency, balances, LP display.
# =============================================================================
set -uo pipefail  # no -e (arithmetic can return 0)

SSH_KEY="$HOME/.ssh/id_ed25519_vps"
SSH_OPTS="-o StrictHostKeyChecking=no -o ConnectTimeout=10"
SSH="ssh -i $SSH_KEY $SSH_OPTS"

RED='\033[0;31m'; GREEN='\033[0;32m'; BLUE='\033[0;34m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

PASS=0; FAIL=0; WARN=0

ok()   { echo -e "  ${GREEN}[PASS]${NC} $1"; PASS=$((PASS+1)); }
fail() { echo -e "  ${RED}[FAIL]${NC} $1"; FAIL=$((FAIL+1)); }
warn() { echo -e "  ${BLUE}[WARN]${NC} $1"; WARN=$((WARN+1)); }

echo -e "${BOLD}${CYAN}"
echo "============================================================"
echo "  FULL WALLET AUDIT — BATHRON + EVM + BTC"
echo "  LP1 (OP1) + LP2 (OP2) + Fake User (OP3)"
echo "============================================================"
echo -e "${NC}"

# VPS configs
declare -A NAME IP ROLE
declare -A M1_CLI BTC_CLI BTC_DD BTC_W LP

NAME[1]="LP1 (alice)";       IP[1]="57.131.33.152"; ROLE[1]="lp"
NAME[2]="LP2 (dev)";         IP[2]="57.131.33.214"; ROLE[2]="lp"
NAME[3]="User (charlie)";    IP[3]="51.75.31.44";   ROLE[3]="user"

M1_CLI[1]="/home/ubuntu/bathron-cli -testnet"
M1_CLI[2]="/home/ubuntu/bathron/bin/bathron-cli -testnet"
M1_CLI[3]="/home/ubuntu/bathron-cli -testnet"

BTC_CLI[1]="/home/ubuntu/bitcoin/bin/bitcoin-cli"; BTC_DD[1]="/home/ubuntu/.bitcoin-signet"; BTC_W[1]="alice_lp"
BTC_CLI[2]="/home/ubuntu/bitcoin/bin/bitcoin-cli"; BTC_DD[2]="/home/ubuntu/.bitcoin-signet"; BTC_W[2]="lp2_wallet"
BTC_CLI[3]="/home/ubuntu/bitcoin/bin/bitcoin-cli"; BTC_DD[3]="/home/ubuntu/.bitcoin-signet"; BTC_W[3]="fake_user"

LP[1]="http://57.131.33.152:8080"
LP[2]="http://57.131.33.214:8080"
LP[3]=""

# Collected data
declare -A BTC_ADDR BTC_PK BTC_WIF WAL_BTC WAL_M1 WAL_WIF EVM_ADDR EVM_PK
declare -A M1_BAL M0_BAL BTC_BAL EVM_USDC EVM_ETH
declare -A LP_BTC LP_M1 LP_EVM

# =============================================================================
# COLLECT DATA
# =============================================================================

for i in 1 2 3; do
    echo -e "${BOLD}${CYAN}=== ${NAME[$i]} — ${IP[$i]} ===${NC}"

    # --- Key files ---
    BTC_JSON=$($SSH ubuntu@${IP[$i]} "cat ~/.BathronKey/btc.json 2>/dev/null" || echo '{}')
    WALLET_JSON=$($SSH ubuntu@${IP[$i]} "cat ~/.BathronKey/wallet.json 2>/dev/null" || echo '{}')
    EVM_JSON=$($SSH ubuntu@${IP[$i]} "cat ~/.BathronKey/evm.json 2>/dev/null" || echo '{}')

    # BTC keys
    BTC_ADDR[$i]=$(echo "$BTC_JSON" | python3 -c "import sys,json; print(json.load(sys.stdin).get('address',''))" 2>/dev/null || echo "")
    BTC_PK[$i]=$(echo "$BTC_JSON" | python3 -c "import sys,json; print(json.load(sys.stdin).get('pubkey',''))" 2>/dev/null || echo "")
    BTC_WIF[$i]=$(echo "$BTC_JSON" | python3 -c "
import sys,json; d=json.load(sys.stdin)
w=d.get('claim_wif','') or d.get('wif','')
print(w[:10]+'...' if len(w)>10 else '(none)')
" 2>/dev/null || echo "(none)")

    # BATHRON wallet keys
    WAL_BTC[$i]=$(echo "$WALLET_JSON" | python3 -c "import sys,json; print(json.load(sys.stdin).get('btc_address',''))" 2>/dev/null || echo "")
    WAL_M1[$i]=$(echo "$WALLET_JSON" | python3 -c "import sys,json; print(json.load(sys.stdin).get('address',''))" 2>/dev/null || echo "")
    WAL_WIF[$i]=$(echo "$WALLET_JSON" | python3 -c "
import sys,json; w=json.load(sys.stdin).get('wif','')
print(w[:10]+'...' if len(w)>10 else '(none)')
" 2>/dev/null || echo "(none)")

    # EVM keys
    EVM_ADDR[$i]=$(echo "$EVM_JSON" | python3 -c "import sys,json; print(json.load(sys.stdin).get('address',''))" 2>/dev/null || echo "")
    EVM_PK[$i]=$(echo "$EVM_JSON" | python3 -c "
import sys,json; pk=json.load(sys.stdin).get('private_key','') or json.load(open('/dev/stdin')).get('key','')
print(pk[:10]+'...' if len(pk)>10 else '(none)')
" 2>/dev/null || echo "(none)")
    # retry for private_key
    EVM_PK[$i]=$(echo "$EVM_JSON" | python3 -c "
import sys,json; d=json.load(sys.stdin)
pk=d.get('private_key','') or d.get('key','') or d.get('pk','')
print(pk[:10]+'...' if len(pk)>10 else '(none)')
" 2>/dev/null || echo "(none)")

    # --- BATHRON node balances ---
    echo -e "  ${BOLD}BATHRON (M0/M1):${NC}"
    WALLET_STATE=$($SSH ubuntu@${IP[$i]} "${M1_CLI[$i]} getwalletstate true 2>/dev/null" || echo '{}')
    M0_BAL[$i]=$(echo "$WALLET_STATE" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('m0',{}).get('balance',0))" 2>/dev/null || echo "0")
    M1_BAL[$i]=$(echo "$WALLET_STATE" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('m1',{}).get('total',0))" 2>/dev/null || echo "0")
    M1_RECEIPTS=$(echo "$WALLET_STATE" | python3 -c "
import sys,json
d=json.load(sys.stdin)
receipts=d.get('m1',{}).get('receipts',[])
print(f'{len(receipts)} receipts')
for r in receipts[:5]:
    print(f'    {r.get(\"outpoint\",\"?\")[:40]}...: {r.get(\"amount\",0)} sats')
if len(receipts)>5: print(f'    ... +{len(receipts)-5} more')
" 2>/dev/null || echo "  (error)")

    echo "    wallet.json addr: ${WAL_M1[$i]:-(not set)}"
    echo "    wallet.json WIF:  ${WAL_WIF[$i]}"
    echo "    Free M0: ${M0_BAL[$i]} sats"
    echo "    M1 total: ${M1_BAL[$i]} sats ($M1_RECEIPTS)"

    # Verify address is actually used by the node
    NODE_ADDR=$($SSH ubuntu@${IP[$i]} "${M1_CLI[$i]} getaccountaddress '' 2>/dev/null" || echo "(error)")
    echo "    Node default addr: $NODE_ADDR"
    if [ "$NODE_ADDR" = "${WAL_M1[$i]}" ]; then
        echo -e "    ${GREEN}→ Matches wallet.json${NC}"
    elif [ "$NODE_ADDR" != "(error)" ]; then
        echo -e "    ${BLUE}→ Different from wallet.json (node may use multiple addresses)${NC}"
    fi

    # --- BTC ---
    echo -e "  ${BOLD}BTC Signet:${NC}"
    echo "    btc.json addr:    ${BTC_ADDR[$i]:-(not set)}"
    echo "    btc.json pubkey:  ${BTC_PK[$i]:-(not set)}"
    echo "    btc.json WIF:     ${BTC_WIF[$i]}"
    echo "    wallet.json btc:  ${WAL_BTC[$i]:-(not set)}"

    BTC_BAL[$i]=$($SSH ubuntu@${IP[$i]} "${BTC_CLI[$i]} -signet -datadir=${BTC_DD[$i]} -rpcwallet=${BTC_W[$i]} getbalance 2>/dev/null" || echo "(error)")
    echo "    BC wallet balance: ${BTC_BAL[$i]} BTC"

    # ismine check
    if [ -n "${BTC_ADDR[$i]}" ]; then
        IS_MINE=$($SSH ubuntu@${IP[$i]} "${BTC_CLI[$i]} -signet -datadir=${BTC_DD[$i]} -rpcwallet=${BTC_W[$i]} getaddressinfo ${BTC_ADDR[$i]} 2>/dev/null" | python3 -c "import sys,json; print(json.load(sys.stdin).get('ismine',False))" 2>/dev/null || echo "?")
        echo "    ismine in BC wallet: $IS_MINE"
    fi

    # --- EVM ---
    echo -e "  ${BOLD}EVM (Base Sepolia):${NC}"
    echo "    evm.json addr:    ${EVM_ADDR[$i]:-(not set)}"
    echo "    evm.json pk:      ${EVM_PK[$i]}"

    # Check USDC + ETH balance via LP or direct
    if [ -n "${LP[$i]}" ]; then
        LP_WALLETS=$(curl -s "${LP[$i]}/api/wallets" 2>/dev/null || echo '{}')
        EVM_USDC[$i]=$(echo "$LP_WALLETS" | python3 -c "import sys,json; print(json.load(sys.stdin).get('usdc',{}).get('balance',0))" 2>/dev/null || echo "?")
        EVM_ETH[$i]=$(echo "$LP_WALLETS" | python3 -c "import sys,json; print(json.load(sys.stdin).get('usdc',{}).get('eth_balance',0))" 2>/dev/null || echo "?")
        LP_BTC[$i]=$(echo "$LP_WALLETS" | python3 -c "import sys,json; print(json.load(sys.stdin).get('btc',{}).get('address','?'))" 2>/dev/null || echo "?")
        LP_M1[$i]=$(echo "$LP_WALLETS" | python3 -c "import sys,json; print(json.load(sys.stdin).get('m1',{}).get('address','?'))" 2>/dev/null || echo "?")
        LP_EVM[$i]=$(echo "$LP_WALLETS" | python3 -c "import sys,json; print(json.load(sys.stdin).get('usdc',{}).get('address','?'))" 2>/dev/null || echo "?")
    else
        EVM_USDC[$i]="(no LP)"
        EVM_ETH[$i]="(no LP)"
    fi
    echo "    USDC balance: ${EVM_USDC[$i]}"
    echo "    ETH balance:  ${EVM_ETH[$i]}"

    # --- LP server display ---
    if [ -n "${LP[$i]}" ]; then
        echo -e "  ${BOLD}LP Server display:${NC}"
        echo "    BTC:  ${LP_BTC[$i]}"
        echo "    M1:   ${LP_M1[$i]}"
        echo "    EVM:  ${LP_EVM[$i]}"
    fi

    echo ""
done

# =============================================================================
# CONSISTENCY & INDEPENDENCE CHECKS
# =============================================================================

echo -e "${BOLD}${CYAN}============================================================"
echo "  CONSISTENCY & INDEPENDENCE CHECKS"
echo "============================================================${NC}"
echo ""

# --- BATHRON addresses ---
echo -e "${BOLD}1. BATHRON (M1) address independence:${NC}"
if [ "${WAL_M1[1]}" != "${WAL_M1[2]}" ] && [ "${WAL_M1[1]}" != "${WAL_M1[3]}" ] && [ "${WAL_M1[2]}" != "${WAL_M1[3]}" ]; then
    ok "All M1 addresses are unique"
    echo "    LP1:  ${WAL_M1[1]}"
    echo "    LP2:  ${WAL_M1[2]}"
    echo "    User: ${WAL_M1[3]}"
else
    fail "M1 address collision detected!"
fi
echo ""

echo -e "${BOLD}2. BATHRON WIF independence:${NC}"
if [ "${WAL_WIF[1]}" != "${WAL_WIF[2]}" ] && [ "${WAL_WIF[1]}" != "${WAL_WIF[3]}" ] && [ "${WAL_WIF[2]}" != "${WAL_WIF[3]}" ]; then
    ok "All BATHRON WIFs are different"
else
    fail "BATHRON WIF collision!"
fi
echo ""

# --- BTC addresses ---
echo -e "${BOLD}3. BTC address independence:${NC}"
if [ -n "${BTC_ADDR[1]}" ] && [ -n "${BTC_ADDR[2]}" ] && [ -n "${BTC_ADDR[3]}" ]; then
    if [ "${BTC_ADDR[1]}" != "${BTC_ADDR[2]}" ] && [ "${BTC_ADDR[1]}" != "${BTC_ADDR[3]}" ] && [ "${BTC_ADDR[2]}" != "${BTC_ADDR[3]}" ]; then
        ok "All BTC addresses are unique"
        echo "    LP1:  ${BTC_ADDR[1]}"
        echo "    LP2:  ${BTC_ADDR[2]}"
        echo "    User: ${BTC_ADDR[3]}"
    else
        fail "BTC address collision!"
    fi
else
    warn "Some BTC addresses not set"
fi
echo ""

echo -e "${BOLD}4. BTC pubkey independence:${NC}"
if [ -n "${BTC_PK[1]}" ] && [ -n "${BTC_PK[2]}" ] && [ -n "${BTC_PK[3]}" ]; then
    if [ "${BTC_PK[1]}" != "${BTC_PK[2]}" ] && [ "${BTC_PK[1]}" != "${BTC_PK[3]}" ] && [ "${BTC_PK[2]}" != "${BTC_PK[3]}" ]; then
        ok "All BTC pubkeys are unique"
    else
        fail "BTC pubkey collision!"
    fi
else
    warn "Some BTC pubkeys not set"
fi
echo ""

# --- EVM addresses ---
echo -e "${BOLD}5. EVM address independence:${NC}"
if [ -n "${EVM_ADDR[1]}" ] && [ -n "${EVM_ADDR[2]}" ] && [ -n "${EVM_ADDR[3]}" ]; then
    if [ "${EVM_ADDR[1]}" != "${EVM_ADDR[2]}" ] && [ "${EVM_ADDR[1]}" != "${EVM_ADDR[3]}" ] && [ "${EVM_ADDR[2]}" != "${EVM_ADDR[3]}" ]; then
        ok "All EVM addresses are unique"
        echo "    LP1:  ${EVM_ADDR[1]}"
        echo "    LP2:  ${EVM_ADDR[2]}"
        echo "    User: ${EVM_ADDR[3]}"
    else
        fail "EVM address collision!"
    fi
else
    warn "Some EVM addresses not set"
fi
echo ""

# --- Cross-file consistency ---
echo -e "${BOLD}6. btc.json ↔ wallet.json BTC address match:${NC}"
for i in 1 2 3; do
    if [ -z "${BTC_ADDR[$i]}" ]; then
        warn "${NAME[$i]}: btc.json has no address"
    elif [ "${BTC_ADDR[$i]}" = "${WAL_BTC[$i]}" ]; then
        ok "${NAME[$i]}: btc.json = wallet.json"
    elif [ -z "${WAL_BTC[$i]}" ]; then
        warn "${NAME[$i]}: wallet.json has no btc_address"
    else
        fail "${NAME[$i]}: MISMATCH btc.json=${BTC_ADDR[$i]} vs wallet.json=${WAL_BTC[$i]}"
    fi
done
echo ""

# --- LP server matches key files ---
echo -e "${BOLD}7. LP server displays correct addresses:${NC}"
for i in 1 2; do
    [ -z "${LP[$i]}" ] && continue

    # BTC
    if [ "${LP_BTC[$i]}" = "${BTC_ADDR[$i]}" ]; then
        ok "${NAME[$i]} LP BTC: matches btc.json"
    else
        fail "${NAME[$i]} LP BTC: ${LP_BTC[$i]} != btc.json ${BTC_ADDR[$i]}"
    fi

    # M1
    if [ "${LP_M1[$i]}" = "${WAL_M1[$i]}" ]; then
        ok "${NAME[$i]} LP M1: matches wallet.json"
    else
        fail "${NAME[$i]} LP M1: ${LP_M1[$i]} != wallet.json ${WAL_M1[$i]}"
    fi

    # EVM
    if [ "${LP_EVM[$i]}" = "${EVM_ADDR[$i]}" ]; then
        ok "${NAME[$i]} LP EVM: matches evm.json"
    else
        fail "${NAME[$i]} LP EVM: ${LP_EVM[$i]} != evm.json ${EVM_ADDR[$i]}"
    fi
done
echo ""

# --- BTC ismine ---
echo -e "${BOLD}8. BTC address owned by Bitcoin Core (ismine):${NC}"
for i in 1 2 3; do
    if [ -z "${BTC_ADDR[$i]}" ]; then
        warn "${NAME[$i]}: no BTC address"
        continue
    fi
    IS_MINE=$($SSH ubuntu@${IP[$i]} "${BTC_CLI[$i]} -signet -datadir=${BTC_DD[$i]} -rpcwallet=${BTC_W[$i]} getaddressinfo ${BTC_ADDR[$i]} 2>/dev/null" | python3 -c "import sys,json; print(json.load(sys.stdin).get('ismine',False))" 2>/dev/null || echo "?")
    if [ "$IS_MINE" = "True" ]; then
        ok "${NAME[$i]}: ${BTC_ADDR[$i]} ismine=True in ${BTC_W[$i]}"
    else
        fail "${NAME[$i]}: ${BTC_ADDR[$i]} ismine=$IS_MINE in ${BTC_W[$i]}"
    fi
done
echo ""

# --- BTC WIF present ---
echo -e "${BOLD}9. BTC claim WIF present (needed for HTLC claims):${NC}"
for i in 1 2 3; do
    W="${BTC_WIF[$i]}"
    if [ "$W" = "(none)" ] || [ -z "$W" ]; then
        if [ "${ROLE[$i]}" = "lp" ]; then
            fail "${NAME[$i]}: NO claim_wif in btc.json (LP cannot claim BTC HTLCs!)"
        else
            warn "${NAME[$i]}: No claim_wif (ok for user — uses Bitcoin Core wallet)"
        fi
    else
        ok "${NAME[$i]}: claim_wif present ($W)"
    fi
done
echo ""

# --- EVM private key present ---
echo -e "${BOLD}10. EVM private key present (needed for HTLC ops):${NC}"
for i in 1 2 3; do
    PK="${EVM_PK[$i]}"
    if [ "$PK" = "(none)" ] || [ -z "$PK" ]; then
        if [ "${ROLE[$i]}" = "lp" ]; then
            fail "${NAME[$i]}: NO private key in evm.json (LP cannot create EVM HTLCs!)"
        else
            warn "${NAME[$i]}: No EVM private key (user uses MetaMask)"
        fi
    else
        ok "${NAME[$i]}: EVM key present ($PK)"
    fi
done
echo ""

# =============================================================================
# SUMMARY TABLE
# =============================================================================

echo -e "${BOLD}${CYAN}============================================================"
echo "  COMPLETE ADDRESS MAP"
echo "============================================================${NC}"
echo ""
echo "  ┌──────────────┬─────────┬────────────────────────────────────────────────────────┬──────────────┐"
echo "  │ Actor        │ Chain   │ Address                                                │ Balance      │"
echo "  ├──────────────┼─────────┼────────────────────────────────────────────────────────┼──────────────┤"
for i in 1 2 3; do
    printf "  │ %-12s │ %-7s │ %-54s │ %12s │\n" "${NAME[$i]}" "BTC" "${BTC_ADDR[$i]:-(not set)}" "${BTC_BAL[$i]} BTC"
    printf "  │ %-12s │ %-7s │ %-54s │ %8s sats │\n" "" "M1" "${WAL_M1[$i]:-(not set)}" "${M1_BAL[$i]}"
    printf "  │ %-12s │ %-7s │ %-54s │ %8s M0   │\n" "" "M0" "(same node)" "${M0_BAL[$i]}"
    printf "  │ %-12s │ %-7s │ %-54s │ %8s USDC │\n" "" "EVM" "${EVM_ADDR[$i]:-(not set)}" "${EVM_USDC[$i]}"
    echo "  ├──────────────┼─────────┼────────────────────────────────────────────────────────┼──────────────┤"
done
echo "  └──────────────┴─────────┴────────────────────────────────────────────────────────┴──────────────┘"
echo ""

# =============================================================================
# FINAL VERDICT
# =============================================================================

echo -e "${BOLD}${CYAN}============================================================"
echo "  VERDICT"
echo "============================================================${NC}"
echo ""
echo -e "  ${GREEN}PASS: $PASS${NC}"
echo -e "  ${RED}FAIL: $FAIL${NC}"
echo -e "  ${BLUE}WARN: $WARN${NC}"
echo ""

if [ $FAIL -gt 0 ]; then
    echo -e "  ${RED}${BOLD}⚠ $FAIL FAILURES DETECTED — review above${NC}"
    exit 1
else
    echo -e "  ${GREEN}${BOLD}✓ All critical checks passed${NC}"
    if [ $WARN -gt 0 ]; then
        echo -e "  ${BLUE}  ($WARN warnings — review recommended)${NC}"
    fi
fi
