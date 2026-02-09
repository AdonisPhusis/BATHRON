#!/bin/bash
# =============================================================================
# AUDIT: Reverse FlowSwap (USDC → BTC)
# Checks all legs of a specific reverse swap: EVM, M1, BTC
# Usage: ./audit_reverse_swap.sh <swap_id> [lp_target]
#   lp_target: lp1 (default) or lp2
# =============================================================================
set -uo pipefail

SWAP_ID="${1:-fs_352debd3c83347ef}"
LP_TARGET="${2:-lp1}"

SSH_KEY="$HOME/.ssh/id_ed25519_vps"
SSH_OPTS="-o StrictHostKeyChecking=no -o ConnectTimeout=10 -o BatchMode=yes"
SSH="ssh -i $SSH_KEY $SSH_OPTS"

# VPS addresses
SEED_IP="57.131.33.151"
CORESDK_IP="162.19.251.75"
OP1_IP="57.131.33.152"
OP2_IP="57.131.33.214"
OP3_IP="51.75.31.44"

if [ "$LP_TARGET" = "lp2" ]; then
    LP_IP="$OP2_IP"
    LP_NAME="LP2 (OP2)"
    LP_BATHRON_CLI="/home/ubuntu/bathron/bin/bathron-cli -testnet"
    LP_BTC_CLI="/home/ubuntu/bitcoin/bin/bitcoin-cli -signet -datadir=/home/ubuntu/.bitcoin-signet"
else
    LP_IP="$OP1_IP"
    LP_NAME="LP1 (OP1)"
    LP_BATHRON_CLI="/home/ubuntu/bathron-cli -testnet"
    LP_BTC_CLI="/home/ubuntu/bitcoin/bin/bitcoin-cli -signet -datadir=/home/ubuntu/.bitcoin-signet"
fi

# OP3 CLI paths
OP3_BTC_CLI="/home/ubuntu/bitcoin/bin/bitcoin-cli -signet -datadir=/home/ubuntu/.bitcoin-signet"
OP3_BATHRON_CLI="/home/ubuntu/bathron-cli -testnet"

RED='\033[0;31m'; GREEN='\033[0;32m'; BLUE='\033[0;34m'
CYAN='\033[0;36m'; YELLOW='\033[0;33m'; BOLD='\033[1m'; NC='\033[0m'

PASS=0; FAIL=0; WARN=0; INFO=0

ok()   { echo -e "  ${GREEN}[PASS]${NC} $1"; PASS=$((PASS+1)); }
fail() { echo -e "  ${RED}[FAIL]${NC} $1"; FAIL=$((FAIL+1)); }
warn() { echo -e "  ${YELLOW}[WARN]${NC} $1"; WARN=$((WARN+1)); }
info() { echo -e "  ${BLUE}[INFO]${NC} $1"; INFO=$((INFO+1)); }

echo -e "${BOLD}${CYAN}"
echo "=========================================================="
echo "  AUDIT: Reverse FlowSwap (USDC -> BTC)"
echo "  Swap ID: $SWAP_ID"
echo "  LP: $LP_NAME ($LP_IP)"
echo "  Date: $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
echo "=========================================================="
echo -e "${NC}"

# =========================================================================
# 1. SWAP RECORD FROM LP
# =========================================================================
echo -e "${BOLD}=== 1. Swap Record from $LP_NAME ===${NC}"
echo ""

SWAP_JSON=$($SSH ubuntu@$LP_IP "curl -s http://localhost:8080/api/flowswap/$SWAP_ID" 2>/dev/null)

if [ -z "$SWAP_JSON" ] || [ "$SWAP_JSON" = "null" ] || echo "$SWAP_JSON" | grep -q '"error"'; then
    fail "Could not retrieve swap record from $LP_NAME"
    echo "  Response: $SWAP_JSON"
    # Set empty defaults so rest of script doesn't crash
    SWAP_STATUS="unknown"; SWAP_DIR="unknown"; FROM_ASSET="unknown"; TO_ASSET="unknown"
    FROM_AMOUNT="?"; TO_AMOUNT="?"
    M1_HTLC_OUTPOINT=""; M1_HTLC_STATUS=""
    BTC_HTLC_ADDR=""; BTC_FUND_TXID=""; BTC_CLAIM_TXID=""
    EVM_HTLC_ID=""; EVM_CLAIM_TXID=""
else
    ok "Swap record retrieved successfully"
    echo ""
    echo "$SWAP_JSON" | python3 -m json.tool 2>/dev/null || echo "$SWAP_JSON"
    echo ""

    # Parse key fields
    SWAP_STATUS=$(echo "$SWAP_JSON" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('status','unknown'))" 2>/dev/null)
    SWAP_DIR=$(echo "$SWAP_JSON" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('direction','unknown'))" 2>/dev/null)
    FROM_ASSET=$(echo "$SWAP_JSON" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('from_asset','unknown'))" 2>/dev/null)
    TO_ASSET=$(echo "$SWAP_JSON" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('to_asset','unknown'))" 2>/dev/null)
    FROM_AMOUNT=$(echo "$SWAP_JSON" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('from_amount','?'))" 2>/dev/null)
    TO_AMOUNT=$(echo "$SWAP_JSON" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('to_amount','?'))" 2>/dev/null)

    # M1 HTLC fields
    M1_HTLC_OUTPOINT=$(echo "$SWAP_JSON" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('m1_htlc_outpoint',''))" 2>/dev/null)
    M1_HTLC_STATUS=$(echo "$SWAP_JSON" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('m1_htlc_status',''))" 2>/dev/null)

    # BTC HTLC fields
    BTC_HTLC_ADDR=$(echo "$SWAP_JSON" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('btc_htlc_address',''))" 2>/dev/null)
    BTC_FUND_TXID=$(echo "$SWAP_JSON" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('btc_fund_txid',''))" 2>/dev/null)
    BTC_CLAIM_TXID=$(echo "$SWAP_JSON" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('btc_claim_txid',''))" 2>/dev/null)

    # EVM HTLC fields
    EVM_HTLC_ID=$(echo "$SWAP_JSON" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('evm_htlc_id',''))" 2>/dev/null)
    EVM_CLAIM_TXID=$(echo "$SWAP_JSON" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('evm_claim_txid','') or d.get('evm_claim_tx',''))" 2>/dev/null)

    echo -e "${BOLD}  Summary:${NC}"
    echo "    Direction: $SWAP_DIR ($FROM_ASSET -> $TO_ASSET)"
    echo "    Amount: $FROM_AMOUNT $FROM_ASSET -> $TO_AMOUNT $TO_ASSET"
    echo "    Status: $SWAP_STATUS"
    echo ""

    if [ "$SWAP_STATUS" = "completed" ] || [ "$SWAP_STATUS" = "complete" ]; then
        ok "Swap status is COMPLETED"
    elif [ "$SWAP_STATUS" = "failed" ] || [ "$SWAP_STATUS" = "refunded" ]; then
        fail "Swap status is $SWAP_STATUS"
    else
        warn "Swap status is $SWAP_STATUS (not completed)"
    fi

    if [ "$SWAP_DIR" = "reverse" ] || [ "$FROM_ASSET" = "USDC" ]; then
        ok "Confirmed reverse direction (USDC -> BTC)"
    else
        warn "Direction is '$SWAP_DIR' / from=$FROM_ASSET — expected reverse/USDC"
    fi
fi

# =========================================================================
# 2. BTC LEG — LP funded HTLC, user claims BTC
# =========================================================================
echo ""
echo -e "${BOLD}=== 2. BTC Leg (LP funds HTLC, user claims BTC) ===${NC}"
echo ""

# Check the BTC wallets on LP
echo "  LP BTC wallets:"
$SSH ubuntu@$LP_IP "
    BTC_CLI='$LP_BTC_CLI'
    for w in \$(\$BTC_CLI listwallets 2>/dev/null | python3 -c 'import sys,json; [print(x) for x in json.load(sys.stdin)]' 2>/dev/null); do
        bal=\$(\$BTC_CLI -rpcwallet=\"\$w\" getbalance 2>/dev/null)
        echo \"    \$w: \$bal BTC\"
    done
" 2>/dev/null

# Check OP3 (charlie) BTC balance — user should have received BTC
echo ""
echo "  OP3 (charlie) BTC wallets:"
$SSH ubuntu@$OP3_IP "
    BTC_CLI='$OP3_BTC_CLI'
    for w in \$(\$BTC_CLI listwallets 2>/dev/null | python3 -c 'import sys,json; [print(x) for x in json.load(sys.stdin)]' 2>/dev/null); do
        bal=\$(\$BTC_CLI -rpcwallet=\"\$w\" getbalance 2>/dev/null)
        echo \"    \$w: \$bal BTC\"
    done
" 2>/dev/null

# Check the specific BTC fund TX on LP
if [ -n "$BTC_FUND_TXID" ] && [ "$BTC_FUND_TXID" != "" ] && [ "$BTC_FUND_TXID" != "None" ]; then
    echo ""
    echo "  BTC fund TX: $BTC_FUND_TXID"
    BTC_TX_DETAIL=$($SSH ubuntu@$LP_IP "
        BTC_CLI='$LP_BTC_CLI'
        for w in \$(\$BTC_CLI listwallets 2>/dev/null | python3 -c 'import sys,json; [print(x) for x in json.load(sys.stdin)]' 2>/dev/null); do
            result=\$(\$BTC_CLI -rpcwallet=\"\$w\" gettransaction \"$BTC_FUND_TXID\" 2>/dev/null)
            if [ -n \"\$result\" ]; then
                echo \"\$result\"
                break
            fi
        done
    " 2>/dev/null)
    if [ -n "$BTC_TX_DETAIL" ]; then
        echo "$BTC_TX_DETAIL" | python3 -c "
import sys,json
try:
    d=json.load(sys.stdin)
    print(f'    Confirmations: {d.get(\"confirmations\",0)}')
    print(f'    Amount: {d.get(\"amount\",\"?\")} BTC')
    print(f'    Fee: {d.get(\"fee\",\"?\")} BTC')
    print(f'    Time: {d.get(\"time\",\"?\")}')
    confs = d.get('confirmations',0)
    if confs > 0:
        print(f'    Block: {d.get(\"blockhash\",\"?\")[:16]}...')
except Exception as e:
    print(f'    Parse error: {e}')
" 2>/dev/null
        BTC_CONFS=$(echo "$BTC_TX_DETAIL" | python3 -c "import sys,json; print(json.load(sys.stdin).get('confirmations',0))" 2>/dev/null)
        if [ "${BTC_CONFS:-0}" -gt 0 ] 2>/dev/null; then
            ok "BTC fund TX confirmed ($BTC_CONFS confs)"
        else
            warn "BTC fund TX has $BTC_CONFS confirmations"
        fi
    else
        info "BTC fund TX not found in LP wallets (may be HTLC spend)"
    fi
else
    info "No BTC fund TX recorded in swap"
fi

# Check if user claimed from BTC HTLC
if [ -n "$BTC_CLAIM_TXID" ] && [ "$BTC_CLAIM_TXID" != "" ] && [ "$BTC_CLAIM_TXID" != "None" ]; then
    echo ""
    echo "  BTC claim TX (user claimed): $BTC_CLAIM_TXID"
    ok "BTC claim TX recorded in swap"
else
    info "No BTC claim TX recorded in swap record"
fi

# =========================================================================
# 3. EVM LEG — User locks USDC, LP claims
# =========================================================================
echo ""
echo -e "${BOLD}=== 3. EVM Leg (User locks USDC in HTLC, LP claims) ===${NC}"
echo ""

if [ -n "$EVM_HTLC_ID" ] && [ "$EVM_HTLC_ID" != "" ] && [ "$EVM_HTLC_ID" != "None" ]; then
    echo "  EVM HTLC ID: $EVM_HTLC_ID"
    ok "EVM HTLC ID recorded"
else
    info "No EVM HTLC ID in swap record"
fi

if [ -n "$EVM_CLAIM_TXID" ] && [ "$EVM_CLAIM_TXID" != "" ] && [ "$EVM_CLAIM_TXID" != "None" ]; then
    echo "  LP claim TX: $EVM_CLAIM_TXID"
    # Add 0x prefix if not present
    if [[ "$EVM_CLAIM_TXID" != 0x* ]]; then
        echo "  Explorer: https://sepolia.basescan.org/tx/0x$EVM_CLAIM_TXID"
    else
        echo "  Explorer: https://sepolia.basescan.org/tx/$EVM_CLAIM_TXID"
    fi
    ok "EVM claim TX recorded (LP claimed USDC)"
else
    warn "No EVM claim TX recorded in swap"
fi

# Check USDC balance on LP EVM wallet via status API
echo ""
echo "  LP EVM/USDC status:"
$SSH ubuntu@$LP_IP "curl -s http://localhost:8080/api/status" 2>/dev/null | python3 -c "
import sys,json
try:
    d=json.load(sys.stdin)
    bal = d.get('balances',{})
    if bal:
        for k,v in bal.items():
            if 'evm' in k.lower() or 'usdc' in k.lower() or 'eth' in k.lower():
                print(f'    {k}: {v}')
    # Also check if there's a direct usdc field
    if 'usdc_balance' in d:
        print(f'    USDC balance: {d[\"usdc_balance\"]}')
except:
    pass
" 2>/dev/null

# =========================================================================
# 4. M1 LEG — Settlement rail (invisible)
# =========================================================================
echo ""
echo -e "${BOLD}=== 4. M1 Leg (Settlement Rail — invisible to user) ===${NC}"
echo ""

if [ -n "$M1_HTLC_OUTPOINT" ] && [ "$M1_HTLC_OUTPOINT" != "" ] && [ "$M1_HTLC_OUTPOINT" != "None" ]; then
    echo "  M1 HTLC outpoint: $M1_HTLC_OUTPOINT"
    echo "  M1 HTLC status: $M1_HTLC_STATUS"
    if [ "$M1_HTLC_STATUS" = "settled" ] || [ "$M1_HTLC_STATUS" = "claimed" ] || [ "$M1_HTLC_STATUS" = "completed" ]; then
        ok "M1 HTLC settled successfully"
    elif [ "$M1_HTLC_STATUS" = "refunded" ]; then
        fail "M1 HTLC was refunded (settlement failed)"
    else
        warn "M1 HTLC status: $M1_HTLC_STATUS"
    fi
else
    info "No M1 HTLC outpoint in swap record"
fi

# Get LP wallet state for M1 details
echo ""
echo "  LP wallet state (M0/M1):"
WALLET_STATE=$($SSH ubuntu@$LP_IP "$LP_BATHRON_CLI getwalletstate true" 2>/dev/null)
if [ -n "$WALLET_STATE" ]; then
    echo "$WALLET_STATE" | python3 -c "
import sys,json
try:
    d=json.load(sys.stdin)
    print(f'    M0 balance: {d.get(\"m0_balance\",d.get(\"balance\",\"?\"))}')
    print(f'    M1 balance: {d.get(\"m1_balance\",\"?\")}')
    print(f'    M0 vaulted: {d.get(\"m0_vaulted\",\"?\")}')
    receipts = d.get('m1_receipts',[])
    if receipts:
        print(f'    M1 receipts count: {len(receipts)}')
        for r in receipts:
            out = r.get('outpoint', r.get('txid','?'))
            amt = r.get('amount','?')
            print(f'      - outpoint: {out}, amount: {amt}')
    else:
        print('    M1 receipts: none')
except Exception as e:
    print(f'    Parse error: {e}')
" 2>/dev/null
else
    warn "Could not retrieve LP wallet state"
fi

# Also check global state for invariant A6
echo ""
echo "  Network settlement state:"
$SSH ubuntu@$LP_IP "$LP_BATHRON_CLI getstate" 2>/dev/null | python3 -c "
import sys,json
try:
    d=json.load(sys.stdin)
    s = d.get('settlement',{})
    print(f'    M0 total supply: {s.get(\"m0_total_supply\",\"?\")}')
    print(f'    M0 vaulted: {s.get(\"m0_vaulted\",\"?\")}')
    print(f'    M1 supply: {s.get(\"m1_supply\",\"?\")}')
    mv = s.get('m0_vaulted',0)
    ms = s.get('m1_supply',0)
    if mv == ms:
        print(f'    Invariant A6 (M0_vaulted == M1_supply): OK ({mv} == {ms})')
    else:
        print(f'    Invariant A6 (M0_vaulted == M1_supply): VIOLATION ({mv} != {ms})')
except Exception as e:
    print(f'    Parse error: {e}')
" 2>/dev/null

# =========================================================================
# 5. LP STATUS — Active/stuck swaps
# =========================================================================
echo ""
echo -e "${BOLD}=== 5. LP Status — Active/Stuck Swaps ===${NC}"
echo ""

LP_STATUS=$($SSH ubuntu@$LP_IP "curl -s http://localhost:8080/api/status" 2>/dev/null)
if [ -n "$LP_STATUS" ]; then
    echo "$LP_STATUS" | python3 -c "
import sys,json
try:
    d=json.load(sys.stdin)
    print(f'  LP ID: {d.get(\"lp_id\",\"?\")}')
    print(f'  LP Name: {d.get(\"lp_name\",\"?\")}')
    
    # Try various field names for swap counts
    active = d.get('swaps_active', d.get('active_swaps', d.get('flowswap_3s_active', '?')))
    total = d.get('swaps_total', d.get('total_swaps', d.get('flowswap_3s_total', '?')))
    print(f'  Active swaps: {active}')
    print(f'  Total swaps: {total}')
    
    # FlowSwap specific
    fs_active = d.get('flowswap_3s_active', d.get('flowswap_active', '?'))
    fs_total = d.get('flowswap_3s_total', d.get('flowswap_total', '?'))
    if fs_active != '?':
        print(f'  FlowSwap 3S active: {fs_active}')
    if fs_total != '?':
        print(f'  FlowSwap 3S total: {fs_total}')

    # Balances
    bal = d.get('balances',{})
    if bal:
        print(f'  Balances:')
        for k,v in bal.items():
            print(f'    {k}: {v}')

    # Check for any stuck/pending swaps
    pending = d.get('pending_swaps',[]) or d.get('active_swap_ids',[])
    if pending:
        print(f'  Pending/Active swap IDs: {pending}')
    
    # Uptime/version
    if 'uptime' in d:
        print(f'  Server uptime: {d[\"uptime\"]}')
    if 'version' in d:
        print(f'  Version: {d[\"version\"]}')
except Exception as e:
    print(f'  Parse error: {e}')
" 2>/dev/null
    
    # Check if our swap is still active (stuck)
    echo ""
    IS_ACTIVE=$(echo "$LP_STATUS" | python3 -c "
import sys,json
try:
    d=json.load(sys.stdin)
    active_ids = d.get('active_swap_ids',[]) or d.get('pending_swaps',[])
    if '$SWAP_ID' in str(active_ids):
        print('yes')
    else:
        print('no')
except:
    print('unknown')
" 2>/dev/null)
    if [ "$IS_ACTIVE" = "yes" ]; then
        warn "Swap $SWAP_ID is still in active/pending list (may be stuck)"
    elif [ "$IS_ACTIVE" = "no" ]; then
        ok "Swap $SWAP_ID is NOT in active/pending list (properly settled)"
    fi
else
    fail "Could not reach LP status endpoint"
fi

# =========================================================================
# 6. CROSS-CHECK: Network consistency
# =========================================================================
echo ""
echo -e "${BOLD}=== 6. Network Consistency Check ===${NC}"
echo ""

echo "  Block heights across nodes:"
for NODE_SPEC in "57.131.33.151:Seed:/home/ubuntu/BATHRON-Core/src/bathron-cli -testnet" \
                  "162.19.251.75:CoreSDK:/home/ubuntu/BATHRON-Core/src/bathron-cli -testnet" \
                  "57.131.33.152:OP1:/home/ubuntu/bathron-cli -testnet" \
                  "57.131.33.214:OP2:/home/ubuntu/bathron/bin/bathron-cli -testnet" \
                  "51.75.31.44:OP3:/home/ubuntu/bathron-cli -testnet"; do
    IP=$(echo "$NODE_SPEC" | cut -d: -f1)
    NAME=$(echo "$NODE_SPEC" | cut -d: -f2)
    CLI=$(echo "$NODE_SPEC" | cut -d: -f3-)
    
    HEIGHT=$($SSH ubuntu@$IP "$CLI getblockcount" 2>/dev/null)
    HASH=$($SSH ubuntu@$IP "$CLI getbestblockhash" 2>/dev/null)
    SHORT_HASH=$(echo "$HASH" | cut -c1-16)
    echo "    $NAME ($IP): height=$HEIGHT hash=${SHORT_HASH}..."
done

# =========================================================================
# SUMMARY
# =========================================================================
echo ""
echo -e "${BOLD}${CYAN}=========================================================="
echo "  AUDIT SUMMARY"
echo "==========================================================${NC}"
echo -e "  ${GREEN}PASS: $PASS${NC}"
echo -e "  ${RED}FAIL: $FAIL${NC}"
echo -e "  ${YELLOW}WARN: $WARN${NC}"
echo -e "  ${BLUE}INFO: $INFO${NC}"
echo ""

if [ $FAIL -eq 0 ]; then
    echo -e "  ${GREEN}${BOLD}VERDICT: SWAP AUDIT CLEAN${NC}"
else
    echo -e "  ${RED}${BOLD}VERDICT: ISSUES FOUND ($FAIL failures)${NC}"
fi

echo ""
echo "  Swap: $SWAP_ID"
echo "  LP: $LP_NAME"
echo "  Audited: $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
echo ""
