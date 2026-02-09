#!/bin/bash
#
# Audit a specific FlowSwap (forward BTC->USDC or reverse USDC->BTC)
#
# Usage:
#   ./contrib/testnet/audit_flowswap.sh <swap_id> [lp1|lp2]
#

set -euo pipefail

SWAP_ID="${1:-}"
LP_TARGET="${2:-lp1}"

if [[ -z "$SWAP_ID" ]]; then
    echo "Usage: $0 <swap_id> [lp1|lp2]"
    exit 1
fi

SSH_KEY="$HOME/.ssh/id_ed25519_vps"
SSH_OPTS="-i $SSH_KEY -o StrictHostKeyChecking=no -o ConnectTimeout=10 -o BatchMode=yes"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

log_ok()      { echo -e "  ${GREEN}[OK]${NC} $1"; }
log_warn()    { echo -e "  ${YELLOW}[WARN]${NC} $1"; }
log_err()     { echo -e "  ${RED}[FAIL]${NC} $1"; }
log_section() { echo -e "\n${CYAN}${BOLD}=== $1 ===${NC}"; }

ssh_cmd() {
    local ip="$1"; shift
    ssh $SSH_OPTS "ubuntu@$ip" "$@" 2>/dev/null
}

OP1_IP="57.131.33.152"
OP2_IP="57.131.33.214"

if [[ "$LP_TARGET" == "lp2" ]]; then
    LP_IP="$OP2_IP"; LP_NAME="LP2 (dev, OP2)"
    BATHRON_CLI="/home/ubuntu/bathron/bin/bathron-cli -testnet"
else
    LP_IP="$OP1_IP"; LP_NAME="LP1 (alice, OP1)"
    BATHRON_CLI="/home/ubuntu/bathron-cli -testnet"
fi

BTC_CLI="/home/ubuntu/bitcoin/bin/bitcoin-cli -signet -datadir=/home/ubuntu/.bitcoin-signet"

echo ""
echo "======================================================================"
echo "                     FlowSwap Audit Report"
echo "======================================================================"
echo "  Swap ID: ${SWAP_ID}"
echo "  LP:      ${LP_NAME}"
echo "  Date:    $(date '+%Y-%m-%d %H:%M:%S UTC')"
echo "======================================================================"

# ============================================================================
# 1. Swap Record
# ============================================================================
log_section "1. Swap Record from ${LP_NAME}"

SWAP_JSON=$(ssh_cmd "$LP_IP" "curl -s http://localhost:8080/api/flowswap/${SWAP_ID}" || echo '{"error":"failed"}')
echo "$SWAP_JSON" | python3 -m json.tool 2>/dev/null || echo "$SWAP_JSON"

# Write a temp file for parsed values
TMPFILE=$(mktemp /tmp/audit_swap_XXXXXX.env)
echo "$SWAP_JSON" | python3 -c "
import sys, json

d = json.load(sys.stdin)

state = d.get('state', d.get('status', 'UNKNOWN'))
fa = d.get('from_asset', ''); ta = d.get('to_asset', '')
direction = d.get('direction', f'{fa} -> {ta}' if fa else 'UNKNOWN')

btc_sats = d.get('btc_amount_sats', d.get('btc_amount', 'N/A'))
if isinstance(btc_sats, (int, float)) and btc_sats > 1000:
    btc_display = f'{btc_sats} sats ({btc_sats/1e8:.8f} BTC)'
else:
    btc_display = str(btc_sats)

usdc = d.get('usdc_amount', d.get('to_amount', 'N/A'))
rate = d.get('rate_executed', d.get('rate_display', 'N/A'))
pnl = d.get('lp_pnl', {}).get('display', 'N/A') if isinstance(d.get('lp_pnl'), dict) else 'N/A'

btc = d.get('btc', {})
m1 = d.get('m1', {})
evm = d.get('evm', {})
hl = d.get('hashlocks', {})
sec = d.get('secrets', {})

def s(v): return str(v) if v else 'N/A'

lines = [
    f\"STATE={s(state)}\",
    f\"DIRECTION={s(direction)}\",
    f\"BTC_DISPLAY={s(btc_display)}\",
    f\"USDC_AMOUNT={s(usdc)}\",
    f\"RATE={s(rate)}\",
    f\"PNL={s(pnl)}\",
    f\"BTC_HTLC_ADDR={s(btc.get('htlc_address'))}\",
    f\"BTC_TIMELOCK={s(btc.get('timelock'))}\",
    f\"BTC_FUND_TX={s(btc.get('fund_txid', d.get('btc_fund_txid')))}\",
    f\"BTC_CLAIM_TX={s(btc.get('claim_txid', d.get('btc_claim_txid')))}\",
    f\"EVM_HTLC_ID={s(evm.get('htlc_id'))}\",
    f\"EVM_LOCK_TX={s(evm.get('lock_txhash'))}\",
    f\"EVM_CLAIM_TX={s(evm.get('claim_txhash'))}\",
    f\"M1_OUTPOINT={s(m1.get('htlc_outpoint'))}\",
    f\"M1_TXID={s(m1.get('txid'))}\",
    f\"M1_CLAIM_TXID={s(m1.get('claim_txid'))}\",
    f\"USER_USDC={s(d.get('user_usdc_address'))}\",
    f\"CREATED={s(d.get('created_at'))}\",
    f\"UPDATED={s(d.get('updated_at'))}\",
    f\"COMPLETED={s(d.get('completed_at', d.get('settled_at')))}\",
    f\"LP_LOCKED={s(d.get('lp_locked_at'))}\",
    f\"EXPIRES={s(d.get('plan_expires_at'))}\",
    f\"H_USER={s(hl.get('H_user'))}\",
    f\"H_LP1={s(hl.get('H_lp1'))}\",
    f\"H_LP2={s(hl.get('H_lp2'))}\",
    f\"S_LP1={s(sec.get('S_lp1'))}\",
    f\"S_LP2={s(sec.get('S_lp2'))}\",
]
for l in lines:
    print(l)
" > "$TMPFILE" 2>/dev/null

# Read values from temp file (line by line, safe for spaces)
get_val() {
    local key="$1"
    grep "^${key}=" "$TMPFILE" 2>/dev/null | head -1 | sed "s/^${key}=//" || echo "N/A"
}

STATE=$(get_val STATE)
DIRECTION=$(get_val DIRECTION)
BTC_DISPLAY=$(get_val BTC_DISPLAY)
USDC_AMOUNT=$(get_val USDC_AMOUNT)
RATE=$(get_val RATE)
PNL=$(get_val PNL)
BTC_HTLC_ADDR=$(get_val BTC_HTLC_ADDR)
BTC_TIMELOCK=$(get_val BTC_TIMELOCK)
BTC_FUND_TX=$(get_val BTC_FUND_TX)
BTC_CLAIM_TX=$(get_val BTC_CLAIM_TX)
EVM_HTLC_ID=$(get_val EVM_HTLC_ID)
EVM_LOCK_TX=$(get_val EVM_LOCK_TX)
EVM_CLAIM_TX=$(get_val EVM_CLAIM_TX)
M1_OUTPOINT=$(get_val M1_OUTPOINT)
M1_TXID=$(get_val M1_TXID)
M1_CLAIM_TXID=$(get_val M1_CLAIM_TXID)
USER_USDC=$(get_val USER_USDC)
CREATED=$(get_val CREATED)
UPDATED=$(get_val UPDATED)
COMPLETED=$(get_val COMPLETED)
LP_LOCKED=$(get_val LP_LOCKED)
EXPIRES=$(get_val EXPIRES)
H_USER=$(get_val H_USER)
H_LP1=$(get_val H_LP1)
H_LP2=$(get_val H_LP2)
S_LP1=$(get_val S_LP1)
S_LP2=$(get_val S_LP2)

rm -f "$TMPFILE"

echo ""
echo "  ----------------------------------------------------------------"
echo "  Parsed Summary"
echo "  ----------------------------------------------------------------"
echo "  State:            $STATE"
echo "  Direction:        $DIRECTION"
echo "  BTC Amount:       $BTC_DISPLAY"
echo "  USDC Amount:      $USDC_AMOUNT USDC"
echo "  Rate Executed:    $RATE"
echo "  LP PnL:           $PNL"
echo "  User USDC Addr:   $USER_USDC"
echo ""
echo "  BTC HTLC Address: $BTC_HTLC_ADDR"
echo "  BTC Fund TX:      $BTC_FUND_TX"
echo "  BTC Claim TX:     $BTC_CLAIM_TX"
echo "  BTC Timelock:     $BTC_TIMELOCK"
echo ""
echo "  M1 HTLC Outpoint: $M1_OUTPOINT"
echo "  M1 TX:            $M1_TXID"
echo "  M1 Claim TX:      $M1_CLAIM_TXID"
echo ""
echo "  EVM HTLC ID:      $EVM_HTLC_ID"
echo "  EVM Lock TX:      $EVM_LOCK_TX"
echo "  EVM Claim TX:     $EVM_CLAIM_TX"
echo ""
echo "  Hashlocks:"
echo "    H_user: $H_USER"
echo "    H_lp1:  $H_LP1"
echo "    H_lp2:  $H_LP2"
echo "  Secrets:"
echo "    S_lp1:  $S_LP1"
echo "    S_lp2:  $S_LP2"
echo "  ----------------------------------------------------------------"

if [[ "$STATE" == "completed" || "$STATE" == "settled" ]]; then
    log_ok "Swap state: $STATE"
elif [[ "$STATE" == "UNKNOWN" || "$STATE" == "PARSE_ERROR" ]]; then
    log_err "Could not parse swap state"
else
    log_warn "Swap state: $STATE (not completed)"
fi

# ============================================================================
# 2. BTC Leg
# ============================================================================
log_section "2. BTC Leg -- Verify LP Claimed BTC"

echo "  BTC HTLC Address: $BTC_HTLC_ADDR"
echo "  User Fund TX:     $BTC_FUND_TX"
echo "  LP Claim TX:      $BTC_CLAIM_TX"
echo ""

echo "  BTC wallets on ${LP_NAME}:"
ssh_cmd "$LP_IP" "
    BTC_CLI='$BTC_CLI'
    for w in \$(\$BTC_CLI listwallets 2>/dev/null | python3 -c 'import sys,json; [print(x) for x in json.load(sys.stdin)]' 2>/dev/null); do
        bal=\$(\$BTC_CLI -rpcwallet=\"\$w\" getbalance 2>/dev/null || echo 'ERROR')
        echo \"    \$w: \$bal BTC\"
    done
" || log_err "Failed to query BTC wallets"

# Verify BTC claim TX in wallet
if [[ "$BTC_CLAIM_TX" != "N/A" && "$BTC_CLAIM_TX" != "None" ]]; then
    echo ""
    echo "  Verifying LP BTC claim TX in wallet..."
    ssh_cmd "$LP_IP" "
        BTC_CLI='$BTC_CLI'
        FOUND=0
        for w in \$(\$BTC_CLI listwallets 2>/dev/null | python3 -c 'import sys,json; [print(x) for x in json.load(sys.stdin)]' 2>/dev/null); do
            result=\$(\$BTC_CLI -rpcwallet=\"\$w\" gettransaction '$BTC_CLAIM_TX' 2>/dev/null || echo '')
            if [[ -n \"\$result\" ]] && echo \"\$result\" | python3 -c 'import sys,json; json.load(sys.stdin)' 2>/dev/null; then
                FOUND=1
                echo \"  Found claim TX in wallet: \$w\"
                echo \"\$result\" | python3 -c '
import sys,json
d=json.load(sys.stdin)
print(f\"    Amount: {d.get(\\\"amount\\\",\\\"?\\\")} BTC\")
print(f\"    Fee: {d.get(\\\"fee\\\",\\\"N/A\\\")} BTC\")
print(f\"    Confirmations: {d.get(\\\"confirmations\\\",\\\"?\\\")}\")
for dd in d.get(\"details\",[]):
    print(f\"    Detail: category={dd.get(\\\"category\\\",\\\"?\\\")}, amount={dd.get(\\\"amount\\\",\\\"?\\\")}, address={dd.get(\\\"address\\\",\\\"?\\\")}\")
' 2>/dev/null
            fi
        done
        if [[ \$FOUND -eq 0 ]]; then
            echo '  Claim TX not found in any wallet (may be HTLC-spent externally)'
        fi
    " || log_warn "Could not verify BTC claim TX"
fi

echo ""
[[ "$BTC_FUND_TX" != "N/A" && "$BTC_FUND_TX" != "None" ]] && echo "  Fund TX:  https://mempool.space/signet/tx/$BTC_FUND_TX"
[[ "$BTC_CLAIM_TX" != "N/A" && "$BTC_CLAIM_TX" != "None" ]] && echo "  Claim TX: https://mempool.space/signet/tx/$BTC_CLAIM_TX"
[[ "$BTC_HTLC_ADDR" != "N/A" ]] && echo "  HTLC:     https://mempool.space/signet/address/$BTC_HTLC_ADDR"

# ============================================================================
# 3. EVM Leg
# ============================================================================
log_section "3. EVM Leg -- USDC HTLC Claim"

echo "  HTLC3S Contract:  0x2493EaaaBa6B129962c8967AaEE6bF11D0277756"
echo "  HTLC ID:          $EVM_HTLC_ID"
echo "  Lock TX:          $EVM_LOCK_TX"
echo "  Claim TX:         $EVM_CLAIM_TX"
echo "  User USDC Addr:   $USER_USDC"
echo ""

if [[ "$EVM_CLAIM_TX" != "N/A" && "$EVM_CLAIM_TX" != "None" ]]; then
    log_ok "EVM claim TX recorded"
    echo "  Claim: https://sepolia.basescan.org/tx/0x$EVM_CLAIM_TX"
else
    log_warn "No EVM claim TX"
fi

if [[ "$EVM_LOCK_TX" != "N/A" && "$EVM_LOCK_TX" != "None" ]]; then
    log_ok "EVM lock TX recorded"
    echo "  Lock:  https://sepolia.basescan.org/tx/0x$EVM_LOCK_TX"
fi

# ============================================================================
# 4. M1 Leg
# ============================================================================
log_section "4. M1 Leg -- BATHRON Settlement"

echo "  M1 HTLC Outpoint: $M1_OUTPOINT"
echo "  M1 TX:            $M1_TXID"
echo "  M1 Claim TX:      $M1_CLAIM_TXID"
echo ""

echo "  LP BATHRON balance:"
ssh_cmd "$LP_IP" "$BATHRON_CLI getbalance" | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    for k,v in d.items():
        print(f'    {k}: {v}')
except:
    print('    ' + sys.stdin.read().strip())
" 2>/dev/null || echo "    (error)"

echo ""
echo "  LP wallet state (M1 receipts):"
ssh_cmd "$LP_IP" "$BATHRON_CLI getwalletstate true" | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    for k, v in d.items():
        if isinstance(v, list):
            print(f'    {k}: {len(v)} items')
            for item in v[:10]:
                if isinstance(item, dict):
                    op = item.get('outpoint', item.get('txid', ''))
                    amt = item.get('amount', item.get('nValue', '?'))
                    print(f'      - {op}: {amt}')
                else:
                    print(f'      - {item}')
        elif isinstance(v, dict):
            print(f'    {k}:')
            for kk, vv in v.items():
                print(f'      {kk}: {vv}')
        else:
            print(f'    {k}: {v}')
except:
    pass
" 2>/dev/null || echo "    (error)"

# Check M1 TX on-chain
if [[ "$M1_TXID" != "N/A" && "$M1_TXID" != "None" ]]; then
    echo ""
    echo "  Checking M1 HTLC TX on-chain..."
    ssh_cmd "$LP_IP" "$BATHRON_CLI getrawtransaction $M1_TXID 1" 2>/dev/null | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    print(f'    Confirmations: {d.get(\"confirmations\", \"?\")}')
    bh = d.get('blockhash', '')
    print(f'    Block Hash:    {bh[:20]}...' if bh else '    Block Hash:    unconfirmed')
    print(f'    Size:          {d.get(\"size\", \"?\")} bytes')
    if 'm0_fee_info' in d:
        fi = d['m0_fee_info']
        print(f'    Settlement:')
        print(f'      tx_type:   {fi.get(\"tx_type\", \"?\")}')
        print(f'      complete:  {fi.get(\"complete\", \"?\")}')
        print(f'      m0_in:     {fi.get(\"m0_in\", \"?\")}')
        print(f'      m0_out:    {fi.get(\"m0_out\", \"?\")}')
        print(f'      vault_in:  {fi.get(\"vault_in\", \"?\")}')
        print(f'      vault_out: {fi.get(\"vault_out\", \"?\")}')
        print(f'      m0_fee:    {fi.get(\"m0_fee\", \"?\")}')
    for i, vout in enumerate(d.get('vout', [])):
        val = vout.get('value', '?')
        spk = vout.get('scriptPubKey', {})
        addrs = spk.get('addresses', [])
        addr = addrs[0] if addrs else spk.get('address', '?')
        stype = spk.get('type', '?')
        print(f'    vout[{i}]: {val} -> {addr} ({stype})')
except Exception as e:
    print(f'    (could not parse: {e})')
" 2>/dev/null || log_warn "Could not fetch M1 TX"
fi

# ============================================================================
# 5. Timing Analysis
# ============================================================================
log_section "5. Timing Analysis"

python3 << PYEOF
from datetime import datetime, timezone

events = {
    'created_at':      '$CREATED',
    'lp_locked_at':    '$LP_LOCKED',
    'completed_at':    '$COMPLETED',
    'updated_at':      '$UPDATED',
    'plan_expires_at': '$EXPIRES',
}

parsed = []
for name, val in events.items():
    if val and val != 'N/A' and val != 'None' and val.isdigit():
        ts = int(val)
        dt = datetime.fromtimestamp(ts, tz=timezone.utc)
        parsed.append((name, ts, dt))

parsed.sort(key=lambda x: x[1])

print('  Chronological events:')
prev_ts = None
for name, ts, dt in parsed:
    delta = ''
    if prev_ts is not None:
        diff = ts - prev_ts
        delta = f'  (+{diff}s)'
    print(f'    {name:25s} = {dt.strftime("%Y-%m-%d %H:%M:%S UTC")}  (epoch {ts}){delta}')
    prev_ts = ts

# Duration created -> completed
created_ts = None
completed_ts = None
for name, ts, dt in parsed:
    if name == 'created_at': created_ts = ts
    if name == 'completed_at': completed_ts = ts
if created_ts and completed_ts:
    total = completed_ts - created_ts
    print(f'')
    print(f'  Total duration (created -> completed): {total}s ({total/60:.1f} min)')
PYEOF

# ============================================================================
# 6. Hashlock Verification
# ============================================================================
log_section "6. Hashlock/Secret Verification"

python3 << PYEOF
import hashlib

secrets = {'S_lp1': '$S_LP1', 'S_lp2': '$S_LP2'}
hashes = {'H_user': '$H_USER', 'H_lp1': '$H_LP1', 'H_lp2': '$H_LP2'}

print('  Verifying SHA256(secret) == hashlock:')
for sname, sval in secrets.items():
    if sval == 'N/A' or not sval:
        print(f'    {sname}: NOT REVEALED')
        continue
    computed = hashlib.sha256(bytes.fromhex(sval)).hexdigest()
    hname = sname.replace('S_', 'H_')
    expected = hashes.get(hname, 'N/A')
    match = (computed == expected)
    status = 'MATCH' if match else 'MISMATCH'
    print(f'    {sname} -> {hname}: {status}')
    if not match:
        print(f'      computed: {computed}')
        print(f'      expected: {expected}')

print(f'')
print(f'  H_user = {hashes["H_user"]}')
print(f'    S_user: not stored in LP record (revealed on BTC chain by user claim)')
PYEOF

# ============================================================================
# 7. LP Server Logs
# ============================================================================
log_section "7. LP Server Logs for ${SWAP_ID}"

ssh_cmd "$LP_IP" "
    found=0
    for logfile in /tmp/pna_lp.log /tmp/pna-lp.log /home/ubuntu/pna-lp/pna_lp.log; do
        if [[ -f \"\$logfile\" ]]; then
            matches=\$(grep -c '$SWAP_ID' \"\$logfile\" 2>/dev/null || echo 0)
            if [[ \"\$matches\" -gt 0 ]]; then
                echo \"  Found \$matches entries in \$logfile:\"
                grep '$SWAP_ID' \"\$logfile\" | tail -20
                found=1
            fi
        fi
    done
    journal=\$(journalctl -u pna-lp --no-pager -n 1000 2>/dev/null | grep '$SWAP_ID' | tail -10 || true)
    if [[ -n \"\$journal\" ]]; then
        echo \"  From systemd journal:\"
        echo \"\$journal\"
        found=1
    fi
    if [[ \$found -eq 0 ]]; then
        echo '  No log entries found for this swap ID'
    fi
" || log_warn "Could not fetch LP logs"

# ============================================================================
# AUDIT SUMMARY
# ============================================================================
log_section "AUDIT SUMMARY"

echo ""
echo "  Swap ID:     $SWAP_ID"
echo "  Direction:   $DIRECTION"
echo "  State:       $STATE"
echo "  BTC Amount:  $BTC_DISPLAY"
echo "  USDC Amount: $USDC_AMOUNT USDC"
echo "  Rate:        $RATE"
echo "  LP PnL:      $PNL"
echo ""

ISSUES=0; CHECKS=0

# Check 1: State
CHECKS=$((CHECKS + 1))
if [[ "$STATE" == "completed" || "$STATE" == "settled" ]]; then
    log_ok "State is $STATE"
else
    log_warn "State is $STATE"; ISSUES=$((ISSUES + 1))
fi

# Check 2: BTC fund TX
CHECKS=$((CHECKS + 1))
if [[ "$BTC_FUND_TX" != "N/A" && "$BTC_FUND_TX" != "None" ]]; then
    log_ok "BTC fund TX recorded"
else
    log_err "No BTC fund TX"; ISSUES=$((ISSUES + 1))
fi

# Check 3: BTC claim TX
CHECKS=$((CHECKS + 1))
if [[ "$BTC_CLAIM_TX" != "N/A" && "$BTC_CLAIM_TX" != "None" ]]; then
    log_ok "BTC claim TX recorded (LP claimed from HTLC)"
else
    log_warn "No BTC claim TX"; ISSUES=$((ISSUES + 1))
fi

# Check 4: EVM lock TX
CHECKS=$((CHECKS + 1))
if [[ "$EVM_LOCK_TX" != "N/A" && "$EVM_LOCK_TX" != "None" ]]; then
    log_ok "EVM USDC lock TX recorded"
else
    log_err "No EVM lock TX"; ISSUES=$((ISSUES + 1))
fi

# Check 5: EVM claim TX
CHECKS=$((CHECKS + 1))
if [[ "$EVM_CLAIM_TX" != "N/A" && "$EVM_CLAIM_TX" != "None" ]]; then
    log_ok "EVM USDC claim TX recorded (user claimed USDC)"
else
    log_warn "No EVM claim TX"; ISSUES=$((ISSUES + 1))
fi

# Check 6: M1 HTLC
CHECKS=$((CHECKS + 1))
if [[ "$M1_TXID" != "N/A" && "$M1_TXID" != "None" ]]; then
    log_ok "M1 HTLC TX recorded"
else
    log_warn "No M1 TX"; ISSUES=$((ISSUES + 1))
fi

# Check 7: Secrets revealed
CHECKS=$((CHECKS + 1))
if [[ "$S_LP1" != "N/A" && -n "$S_LP1" && "$S_LP2" != "N/A" && -n "$S_LP2" ]]; then
    log_ok "LP secrets revealed (S_lp1, S_lp2)"
else
    log_warn "Not all secrets revealed"; ISSUES=$((ISSUES + 1))
fi

echo ""
echo "  Checks: $CHECKS total, $((CHECKS - ISSUES)) passed, $ISSUES issue(s)"
echo ""

if [[ $ISSUES -eq 0 ]]; then
    echo -e "  ${GREEN}${BOLD}VERDICT: ALL CLEAR -- All $CHECKS checks passed${NC}"
else
    echo -e "  ${YELLOW}${BOLD}VERDICT: $ISSUES of $CHECKS checks flagged -- review details above${NC}"
fi

echo ""
echo "  Explorer Links:"
[[ "$BTC_FUND_TX" != "N/A" && "$BTC_FUND_TX" != "None" ]] && echo "    BTC Fund:     https://mempool.space/signet/tx/$BTC_FUND_TX"
[[ "$BTC_CLAIM_TX" != "N/A" && "$BTC_CLAIM_TX" != "None" ]] && echo "    BTC Claim:    https://mempool.space/signet/tx/$BTC_CLAIM_TX"
[[ "$BTC_HTLC_ADDR" != "N/A" ]] && echo "    BTC HTLC:     https://mempool.space/signet/address/$BTC_HTLC_ADDR"
[[ "$EVM_LOCK_TX" != "N/A" && "$EVM_LOCK_TX" != "None" ]] && echo "    EVM Lock:     https://sepolia.basescan.org/tx/0x$EVM_LOCK_TX"
[[ "$EVM_CLAIM_TX" != "N/A" && "$EVM_CLAIM_TX" != "None" ]] && echo "    EVM Claim:    https://sepolia.basescan.org/tx/0x$EVM_CLAIM_TX"
echo "    HTLC3S:       https://sepolia.basescan.org/address/0x2493EaaaBa6B129962c8967AaEE6bF11D0277756"
[[ "$USER_USDC" != "N/A" ]] && echo "    User wallet:  https://sepolia.basescan.org/address/$USER_USDC"
echo ""
