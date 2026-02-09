#!/bin/bash
# =============================================================================
# FULL BTC WALLET AUDIT
# Checks: key independence, address consistency, Bitcoin Core wallet match,
# LP server display, and flow correctness for LP1, LP2, and fake user.
# =============================================================================
set -euo pipefail

SSH_KEY="$HOME/.ssh/id_ed25519_vps"
SSH_OPTS="-o StrictHostKeyChecking=no -o ConnectTimeout=10"
SSH="ssh -i $SSH_KEY $SSH_OPTS"

RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

PASS=0
FAIL=0
WARN=0

check_pass() { echo -e "  ${GREEN}[PASS]${NC} $1"; ((PASS++)); }
check_fail() { echo -e "  ${RED}[FAIL]${NC} $1"; ((FAIL++)); }
check_warn() { echo -e "  ${BLUE}[WARN]${NC} $1"; ((WARN++)); }

echo -e "${BOLD}${CYAN}"
echo "============================================================"
echo "  FULL BTC WALLET AUDIT"
echo "  LP1 (OP1) + LP2 (OP2) + Fake User (OP3)"
echo "============================================================"
echo -e "${NC}"

# =============================================================================
# SECTION 1: Collect all key data from each VPS
# =============================================================================

declare -A VPS_NAME VPS_IP VPS_BTC_CLI VPS_BTC_DATADIR VPS_BTC_WALLET VPS_ROLE
declare -A KEY_BTC_ADDR KEY_BTC_PUBKEY KEY_BTC_WIF_PREFIX KEY_WALLET_BTC_ADDR KEY_M1_ADDR KEY_EVM_ADDR
declare -A BC_BALANCE BC_ADDRESSES LP_URL

VPS_NAME[1]="LP1 (alice)"; VPS_IP[1]="57.131.33.152"; VPS_ROLE[1]="lp"
VPS_BTC_CLI[1]="/home/ubuntu/bitcoin/bin/bitcoin-cli"; VPS_BTC_DATADIR[1]="/home/ubuntu/.bitcoin-signet"; VPS_BTC_WALLET[1]="alice_lp"
LP_URL[1]="http://57.131.33.152:8080"

VPS_NAME[2]="LP2 (dev)"; VPS_IP[2]="57.131.33.214"; VPS_ROLE[2]="lp"
VPS_BTC_CLI[2]="/home/ubuntu/bitcoin/bin/bitcoin-cli"; VPS_BTC_DATADIR[2]="/home/ubuntu/.bitcoin-signet"; VPS_BTC_WALLET[2]="lp2_wallet"
LP_URL[2]="http://57.131.33.214:8080"

VPS_NAME[3]="Fake User (charlie)"; VPS_IP[3]="51.75.31.44"; VPS_ROLE[3]="user"
VPS_BTC_CLI[3]="/home/ubuntu/bitcoin/bin/bitcoin-cli"; VPS_BTC_DATADIR[3]="/home/ubuntu/.bitcoin-signet"; VPS_BTC_WALLET[3]="fake_user"
LP_URL[3]=""

for i in 1 2 3; do
    IP="${VPS_IP[$i]}"
    echo -e "${BOLD}${CYAN}=== ${VPS_NAME[$i]} — ${IP} ===${NC}"
    echo ""

    # --- btc.json ---
    echo -e "  ${BOLD}~/.BathronKey/btc.json:${NC}"
    BTC_JSON=$($SSH ubuntu@${IP} "cat ~/.BathronKey/btc.json 2>/dev/null" || echo '{}')
    KEY_BTC_ADDR[$i]=$(echo "$BTC_JSON" | python3 -c "import sys,json; print(json.load(sys.stdin).get('address',''))" 2>/dev/null || echo "")
    KEY_BTC_PUBKEY[$i]=$(echo "$BTC_JSON" | python3 -c "import sys,json; print(json.load(sys.stdin).get('pubkey',''))" 2>/dev/null || echo "")
    KEY_BTC_WIF_PREFIX[$i]=$(echo "$BTC_JSON" | python3 -c "import sys,json; w=json.load(sys.stdin).get('claim_wif','') or json.load(open('/dev/stdin')).get('wif',''); print(w[:8]+'...' if len(w)>8 else '(none)')" 2>/dev/null || echo "(none)")
    # Try again for wif
    KEY_BTC_WIF_PREFIX[$i]=$(echo "$BTC_JSON" | python3 -c "
import sys,json
d=json.load(sys.stdin)
w = d.get('claim_wif','') or d.get('wif','')
print(w[:8]+'...' if len(w)>8 else '(none)')
" 2>/dev/null || echo "(none)")

    echo "    address: ${KEY_BTC_ADDR[$i]:-(not set)}"
    echo "    pubkey:  ${KEY_BTC_PUBKEY[$i]:-(not set)}"
    echo "    wif:     ${KEY_BTC_WIF_PREFIX[$i]}"

    # --- wallet.json ---
    echo -e "  ${BOLD}~/.BathronKey/wallet.json:${NC}"
    WALLET_JSON=$($SSH ubuntu@${IP} "cat ~/.BathronKey/wallet.json 2>/dev/null" || echo '{}')
    KEY_WALLET_BTC_ADDR[$i]=$(echo "$WALLET_JSON" | python3 -c "import sys,json; print(json.load(sys.stdin).get('btc_address',''))" 2>/dev/null || echo "")
    KEY_M1_ADDR[$i]=$(echo "$WALLET_JSON" | python3 -c "import sys,json; print(json.load(sys.stdin).get('address',''))" 2>/dev/null || echo "")

    echo "    btc_address: ${KEY_WALLET_BTC_ADDR[$i]:-(not set)}"
    echo "    m1_address:  ${KEY_M1_ADDR[$i]:-(not set)}"

    # --- evm.json ---
    EVM_JSON=$($SSH ubuntu@${IP} "cat ~/.BathronKey/evm.json 2>/dev/null" || echo '{}')
    KEY_EVM_ADDR[$i]=$(echo "$EVM_JSON" | python3 -c "import sys,json; print(json.load(sys.stdin).get('address',''))" 2>/dev/null || echo "")
    echo -e "  ${BOLD}~/.BathronKey/evm.json:${NC}"
    echo "    address: ${KEY_EVM_ADDR[$i]:-(not set)}"

    # --- Bitcoin Core wallet ---
    echo -e "  ${BOLD}Bitcoin Core wallet (${VPS_BTC_WALLET[$i]}):${NC}"
    BTC_CLI="${VPS_BTC_CLI[$i]}"
    BTC_DD="${VPS_BTC_DATADIR[$i]}"
    BTC_W="${VPS_BTC_WALLET[$i]}"

    BC_BALANCE[$i]=$($SSH ubuntu@${IP} "$BTC_CLI -signet -datadir=$BTC_DD -rpcwallet=$BTC_W getbalance 2>/dev/null" || echo "(error)")
    echo "    balance: ${BC_BALANCE[$i]} BTC"

    # List all addresses that have received funds
    BC_ADDRESSES[$i]=$($SSH ubuntu@${IP} "$BTC_CLI -signet -datadir=$BTC_DD -rpcwallet=$BTC_W listreceivedbyaddress 0 true 2>/dev/null" || echo "[]")
    echo "    addresses:"
    echo "${BC_ADDRESSES[$i]}" | python3 -c "
import sys,json
try:
    addrs = json.load(sys.stdin)
    for a in addrs:
        print(f'      {a[\"address\"]}: {a[\"amount\"]} BTC (txs={a[\"txids\"].__len__()})')
    if not addrs:
        print('      (none)')
except: print('      (parse error)')
" 2>/dev/null || echo "      (parse error)"

    # Check address is importable/in wallet
    if [ -n "${KEY_BTC_ADDR[$i]}" ]; then
        ADDR_INFO=$($SSH ubuntu@${IP} "$BTC_CLI -signet -datadir=$BTC_DD -rpcwallet=$BTC_W getaddressinfo ${KEY_BTC_ADDR[$i]} 2>/dev/null" || echo '{}')
        IS_MINE=$(echo "$ADDR_INFO" | python3 -c "import sys,json; print(json.load(sys.stdin).get('ismine', False))" 2>/dev/null || echo "unknown")
        IS_WATCH=$(echo "$ADDR_INFO" | python3 -c "import sys,json; print(json.load(sys.stdin).get('iswatchonly', False))" 2>/dev/null || echo "unknown")
        echo "    btc.json addr in wallet: ismine=$IS_MINE, iswatchonly=$IS_WATCH"
    fi

    # --- LP server (only for LPs) ---
    if [ -n "${LP_URL[$i]}" ]; then
        echo -e "  ${BOLD}LP Server (${LP_URL[$i]}):${NC}"
        LP_WALLETS=$(curl -s "${LP_URL[$i]}/api/wallets" 2>/dev/null || echo '{}')
        LP_BTC=$(echo "$LP_WALLETS" | python3 -c "import sys,json; d=json.load(sys.stdin).get('btc',{}); print(f'addr={d.get(\"address\",\"?\")}, bal={d.get(\"balance\",0)}')" 2>/dev/null || echo "(error)")
        LP_M1=$(echo "$LP_WALLETS" | python3 -c "import sys,json; d=json.load(sys.stdin).get('m1',{}); print(f'addr={d.get(\"address\",\"?\")}, bal={d.get(\"balance\",0)}')" 2>/dev/null || echo "(error)")
        LP_USDC=$(echo "$LP_WALLETS" | python3 -c "import sys,json; d=json.load(sys.stdin).get('usdc',{}); print(f'addr={d.get(\"address\",\"?\")}, bal={d.get(\"balance\",0)}')" 2>/dev/null || echo "(error)")
        echo "    BTC:  $LP_BTC"
        echo "    M1:   $LP_M1"
        echo "    USDC: $LP_USDC"
    fi

    echo ""
done

# =============================================================================
# SECTION 2: Consistency checks
# =============================================================================

echo -e "${BOLD}${CYAN}============================================================${NC}"
echo -e "${BOLD}${CYAN}  CONSISTENCY CHECKS${NC}"
echo -e "${BOLD}${CYAN}============================================================${NC}"
echo ""

# --- Check 1: btc.json address matches wallet.json btc_address ---
echo -e "${BOLD}1. btc.json ↔ wallet.json consistency:${NC}"
for i in 1 2 3; do
    BTC_A="${KEY_BTC_ADDR[$i]}"
    WAL_A="${KEY_WALLET_BTC_ADDR[$i]}"
    if [ -z "$BTC_A" ]; then
        check_warn "${VPS_NAME[$i]}: btc.json has no address"
    elif [ "$BTC_A" = "$WAL_A" ]; then
        check_pass "${VPS_NAME[$i]}: btc.json = wallet.json = $BTC_A"
    elif [ -z "$WAL_A" ]; then
        check_warn "${VPS_NAME[$i]}: wallet.json has no btc_address (btc.json=$BTC_A)"
    else
        check_fail "${VPS_NAME[$i]}: MISMATCH btc.json=$BTC_A vs wallet.json=$WAL_A"
    fi
done
echo ""

# --- Check 2: LP server shows correct address ---
echo -e "${BOLD}2. LP server displays correct BTC address:${NC}"
for i in 1 2; do
    LP_WALLETS=$(curl -s "${LP_URL[$i]}/api/wallets" 2>/dev/null || echo '{}')
    LP_ADDR=$(echo "$LP_WALLETS" | python3 -c "import sys,json; print(json.load(sys.stdin).get('btc',{}).get('address',''))" 2>/dev/null || echo "")
    BTC_A="${KEY_BTC_ADDR[$i]}"
    if [ "$LP_ADDR" = "$BTC_A" ]; then
        check_pass "${VPS_NAME[$i]}: LP server shows $LP_ADDR (matches btc.json)"
    else
        check_fail "${VPS_NAME[$i]}: LP server shows $LP_ADDR but btc.json has $BTC_A"
    fi
done
echo ""

# --- Check 3: Pubkey independence ---
echo -e "${BOLD}3. Pubkey independence (all different):${NC}"
PK1="${KEY_BTC_PUBKEY[1]}"
PK2="${KEY_BTC_PUBKEY[2]}"
PK3="${KEY_BTC_PUBKEY[3]}"

ALL_UNIQUE=true
if [ -n "$PK1" ] && [ -n "$PK2" ] && [ "$PK1" = "$PK2" ]; then
    check_fail "LP1 and LP2 share SAME pubkey: $PK1"
    ALL_UNIQUE=false
fi
if [ -n "$PK1" ] && [ -n "$PK3" ] && [ "$PK1" = "$PK3" ]; then
    check_fail "LP1 and User share SAME pubkey: $PK1"
    ALL_UNIQUE=false
fi
if [ -n "$PK2" ] && [ -n "$PK3" ] && [ "$PK2" = "$PK3" ]; then
    check_fail "LP2 and User share SAME pubkey: $PK2"
    ALL_UNIQUE=false
fi
if $ALL_UNIQUE; then
    check_pass "All 3 pubkeys are independent"
    echo "    LP1: ${PK1:-(none)}"
    echo "    LP2: ${PK2:-(none)}"
    echo "    User: ${PK3:-(none)}"
fi
echo ""

# --- Check 4: Address independence ---
echo -e "${BOLD}4. BTC address independence (all different):${NC}"
A1="${KEY_BTC_ADDR[1]}"
A2="${KEY_BTC_ADDR[2]}"
A3="${KEY_BTC_ADDR[3]}"

ADDR_UNIQUE=true
if [ -n "$A1" ] && [ -n "$A2" ] && [ "$A1" = "$A2" ]; then
    check_fail "LP1 and LP2 share SAME BTC address: $A1"
    ADDR_UNIQUE=false
fi
if [ -n "$A1" ] && [ -n "$A3" ] && [ "$A1" = "$A3" ]; then
    check_fail "LP1 and User share SAME BTC address: $A1"
    ADDR_UNIQUE=false
fi
if [ -n "$A2" ] && [ -n "$A3" ] && [ "$A2" = "$A3" ]; then
    check_fail "LP2 and User share SAME BTC address: $A2"
    ADDR_UNIQUE=false
fi
if $ADDR_UNIQUE; then
    check_pass "All BTC addresses are independent"
    echo "    LP1:  ${A1:-(none)}"
    echo "    LP2:  ${A2:-(none)}"
    echo "    User: ${A3:-(none)}"
fi
echo ""

# --- Check 5: WIF independence ---
echo -e "${BOLD}5. WIF key independence (all different prefixes):${NC}"
W1="${KEY_BTC_WIF_PREFIX[1]}"
W2="${KEY_BTC_WIF_PREFIX[2]}"
W3="${KEY_BTC_WIF_PREFIX[3]}"
if [ "$W1" != "$W2" ] && [ "$W1" != "$W3" ] && [ "$W2" != "$W3" ]; then
    check_pass "All WIF keys have different prefixes"
else
    check_warn "Some WIF prefixes match (could be coincidence in first 8 chars)"
fi
echo "    LP1:  $W1"
echo "    LP2:  $W2"
echo "    User: $W3"
echo ""

# --- Check 6: BTC address is in Bitcoin Core wallet (ismine) ---
echo -e "${BOLD}6. btc.json address owned by Bitcoin Core wallet:${NC}"
for i in 1 2 3; do
    IP="${VPS_IP[$i]}"
    BTC_CLI="${VPS_BTC_CLI[$i]}"
    BTC_DD="${VPS_BTC_DATADIR[$i]}"
    BTC_W="${VPS_BTC_WALLET[$i]}"
    BTC_A="${KEY_BTC_ADDR[$i]}"

    if [ -z "$BTC_A" ]; then
        check_warn "${VPS_NAME[$i]}: no btc.json address to check"
        continue
    fi

    ADDR_INFO=$($SSH ubuntu@${IP} "$BTC_CLI -signet -datadir=$BTC_DD -rpcwallet=$BTC_W getaddressinfo $BTC_A 2>/dev/null" || echo '{}')
    IS_MINE=$(echo "$ADDR_INFO" | python3 -c "import sys,json; print(json.load(sys.stdin).get('ismine', False))" 2>/dev/null || echo "unknown")

    if [ "$IS_MINE" = "True" ]; then
        check_pass "${VPS_NAME[$i]}: $BTC_A is owned by wallet '$BTC_W' (ismine=True)"
    else
        check_warn "${VPS_NAME[$i]}: $BTC_A is NOT owned by wallet '$BTC_W' (ismine=$IS_MINE)"
        echo "           This means the LP claims BTC to an address it can sign for (btc.json WIF),"
        echo "           but Bitcoin Core wallet doesn't track it. getbalance won't include it."
    fi
done
echo ""

# --- Check 7: LP flow addresses — check completed swaps ---
echo -e "${BOLD}7. Flow address consistency (completed swaps):${NC}"
for i in 1 2; do
    SWAPS=$(curl -s "${LP_URL[$i]}/api/flowswap/list" 2>/dev/null || echo '{"swaps":[]}')
    echo "$SWAPS" | python3 -c "
import sys, json
data = json.load(sys.stdin)
swaps = data.get('swaps', []) if isinstance(data, dict) else data
completed = [s for s in swaps if s.get('state') == 'completed']
if not completed:
    print('  (no completed swaps to verify)')
else:
    for s in completed:
        sid = s.get('swap_id','?')
        direction = s.get('direction', 'forward' if s.get('btc_htlc_address') else 'reverse')
        btc_htlc = s.get('btc_htlc_address', '(none)')
        print(f'  {sid}: direction={direction}, btc_htlc_addr={btc_htlc}')
" 2>/dev/null || echo "  (error parsing)"
done
echo ""

# --- Check 8: EVM address independence ---
echo -e "${BOLD}8. EVM address independence:${NC}"
E1="${KEY_EVM_ADDR[1]}"
E2="${KEY_EVM_ADDR[2]}"
E3="${KEY_EVM_ADDR[3]}"
EVM_UNIQUE=true
if [ -n "$E1" ] && [ -n "$E2" ] && [ "$E1" = "$E2" ]; then
    check_fail "LP1 and LP2 share SAME EVM address"
    EVM_UNIQUE=false
fi
if [ -n "$E1" ] && [ -n "$E3" ] && [ "$E1" = "$E3" ]; then
    check_fail "LP1 and User share SAME EVM address"
    EVM_UNIQUE=false
fi
if $EVM_UNIQUE; then
    check_pass "All EVM addresses are independent"
    echo "    LP1:  ${E1:-(none)}"
    echo "    LP2:  ${E2:-(none)}"
    echo "    User: ${E3:-(none)}"
fi
echo ""

# --- Check 9: M1 address independence ---
echo -e "${BOLD}9. M1 (BATHRON) address independence:${NC}"
M1="${KEY_M1_ADDR[1]}"
M2="${KEY_M1_ADDR[2]}"
M3="${KEY_M1_ADDR[3]}"
M1_UNIQUE=true
if [ -n "$M1" ] && [ -n "$M2" ] && [ "$M1" = "$M2" ]; then
    check_fail "LP1 and LP2 share SAME M1 address"
    M1_UNIQUE=false
fi
if [ -n "$M1" ] && [ -n "$M3" ] && [ "$M1" = "$M3" ]; then
    check_fail "LP1 and User share SAME M1 address"
    M1_UNIQUE=false
fi
if $M1_UNIQUE; then
    check_pass "All M1 addresses are independent"
    echo "    LP1:  ${M1:-(none)}"
    echo "    LP2:  ${M2:-(none)}"
    echo "    User: ${M3:-(none)}"
fi
echo ""

# =============================================================================
# SUMMARY
# =============================================================================

echo -e "${BOLD}${CYAN}============================================================${NC}"
echo -e "${BOLD}${CYAN}  SUMMARY${NC}"
echo -e "${BOLD}${CYAN}============================================================${NC}"
echo ""
echo -e "  ${GREEN}PASS: $PASS${NC}"
echo -e "  ${RED}FAIL: $FAIL${NC}"
echo -e "  ${BLUE}WARN: $WARN${NC}"
echo ""

echo -e "${BOLD}  Address Map:${NC}"
echo "  ┌──────────────┬────────────────────────────────────────────────────────┬──────────────┐"
echo "  │ Actor        │ BTC Address                                            │ Balance      │"
echo "  ├──────────────┼────────────────────────────────────────────────────────┼──────────────┤"
printf "  │ %-12s │ %-54s │ %12s │\n" "LP1 (alice)" "${KEY_BTC_ADDR[1]:-(not set)}" "${BC_BALANCE[1]} BTC"
printf "  │ %-12s │ %-54s │ %12s │\n" "LP2 (dev)" "${KEY_BTC_ADDR[2]:-(not set)}" "${BC_BALANCE[2]} BTC"
printf "  │ %-12s │ %-54s │ %12s │\n" "User (charlie)" "${KEY_BTC_ADDR[3]:-(not set)}" "${BC_BALANCE[3]} BTC"
echo "  └──────────────┴────────────────────────────────────────────────────────┴──────────────┘"
echo ""

if [ $FAIL -gt 0 ]; then
    echo -e "  ${RED}${BOLD}⚠ FAILURES DETECTED — review above${NC}"
    exit 1
else
    echo -e "  ${GREEN}${BOLD}✓ All critical checks passed${NC}"
fi
