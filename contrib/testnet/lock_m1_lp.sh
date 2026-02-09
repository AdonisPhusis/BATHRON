#!/bin/bash
# Lock M0 → M1 on LP node to ensure M1 liquidity for swaps.
# Usage: ./lock_m1_lp.sh [amount] [lp1|lp2]

set -e

AMOUNT="${1:-20000}"
LP_TARGET="${2:-lp1}"

SSH_KEY="$HOME/.ssh/id_ed25519_vps"
SSH_OPTS="-o StrictHostKeyChecking=no -o ConnectTimeout=10"
SSH="ssh -i $SSH_KEY $SSH_OPTS"

case "$LP_TARGET" in
    lp1) IP="57.131.33.152"; CLI="/home/ubuntu/bathron-cli -testnet" ;;
    lp2) IP="57.131.33.214"; CLI="/home/ubuntu/bathron/bin/bathron-cli -testnet" ;;
    *) echo "Usage: $0 [amount] [lp1|lp2]"; exit 1 ;;
esac

echo "=== LP $LP_TARGET ($IP): Lock $AMOUNT M0 → M1 ==="

# Check current state
echo "--- Current wallet state ---"
WALLET_RAW=$($SSH ubuntu@$IP "$CLI getwalletstate true" 2>/dev/null || echo "{}")
echo "$WALLET_RAW" | python3 -c "
import sys,json
try:
    d=json.load(sys.stdin)
    print(f'  M0 balance: {d.get(\"m0_balance\",0)}')
    print(f'  M1 supply:  {d.get(\"m1_supply\",0)}')
    print(f'  Receipts:   {len(d.get(\"receipts\",[]))}')
except: print('  (parse error)')
" 2>/dev/null

# Also check regular balance
M0_BAL=$($SSH ubuntu@$IP "$CLI getbalance" 2>/dev/null || echo "?")
echo "  getbalance: $M0_BAL"

# Lock
echo "--- Locking $AMOUNT M0 → M1 ---"
RESULT=$($SSH ubuntu@$IP "$CLI lock $AMOUNT" 2>&1 || true)
echo "  Result: $RESULT"

# Verify
sleep 2
echo "--- After lock ---"
$SSH ubuntu@$IP "$CLI getwalletstate true" 2>/dev/null | python3 -c "
import sys,json
d=json.load(sys.stdin)
print(f'  M0 balance: {d.get(\"m0_balance\",0)}')
print(f'  M1 balance: {d.get(\"m1_supply\",0)}')
print(f'  Receipts:   {len(d.get(\"receipts\",[]))}')
" 2>/dev/null || echo "  (wallet state unavailable)"

echo "=== Done ==="
