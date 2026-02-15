#!/bin/bash
#
# Check M0/M1 balances on all VPS
#

set -euo pipefail

SSH_KEY="$HOME/.ssh/id_ed25519_vps"
SSH_OPTS="-i $SSH_KEY -o StrictHostKeyChecking=no -o ConnectTimeout=10"

# VPS: NAME:IP:WALLET:CLI_PATH
declare -a VPS_LIST=(
    "SEED:57.131.33.151:pilpous:/home/ubuntu/BATHRON-Core/src/bathron-cli -testnet"
    "CoreSDK:162.19.251.75:bob:/home/ubuntu/BATHRON-Core/src/bathron-cli -testnet"
    "OP1:57.131.33.152:alice:/home/ubuntu/bathron-cli -testnet"
    "OP2:57.131.33.214:dev:/home/ubuntu/bathron/bin/bathron-cli -testnet"
    "OP3:51.75.31.44:charlie:/home/ubuntu/bathron-cli -testnet"
)

echo "╔══════════════════════════════════════════════════════════════╗"
echo "║              All VPS M0/M1 Balances                          ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""

for VPS in "${VPS_LIST[@]}"; do
    NAME=$(echo "$VPS" | cut -d: -f1)
    IP=$(echo "$VPS" | cut -d: -f2)
    WALLET=$(echo "$VPS" | cut -d: -f3)
    CLI=$(echo "$VPS" | cut -d: -f4-)

    printf "%-10s (%s) [%s]\n" "$NAME" "$IP" "$WALLET"

    RESULT=$(ssh $SSH_OPTS "ubuntu@$IP" "$CLI getwalletstate true" 2>/dev/null || echo '{"error": true}')

    if echo "$RESULT" | grep -q '"error"'; then
        echo "  ERROR: Could not get wallet state"
    else
        echo "$RESULT" | python3 -c "
import sys, json
d = json.load(sys.stdin)
m0 = d.get('m0', {}).get('balance', 0)
m0_unconf = d.get('m0', {}).get('unconfirmed', 0)
m1_obj = d.get('m1', {})
m1_total = m1_obj.get('total', 0)
m1_count = m1_obj.get('count', 0)
total = d.get('total_value', m0 + m1_total)
print(f'  M0: {m0:>12,} sats' + (f' (+{m0_unconf:,} unconf)' if m0_unconf else ''))
print(f'  M1: {m1_total:>12,} sats ({m1_count} receipts)')
print(f'  Total: {total:>10,} sats')
# Show M1 receipt details if any
for r in m1_obj.get('receipts', []):
    print(f'    - {r[\"outpoint\"]} = {r[\"amount\"]:,} sats [{r.get(\"settlement_status\",\"?\")}]')
"
    fi
    echo ""
done

# Global state from Seed
SEED_IP="57.131.33.151"
SEED_CLI="/home/ubuntu/BATHRON-Core/src/bathron-cli -testnet"

echo "═══ Global Settlement State ═══"
ssh $SSH_OPTS "ubuntu@$SEED_IP" "$SEED_CLI getstate" 2>/dev/null | python3 -c "
import sys, json
d = json.load(sys.stdin)
supply = d.get('supply', {})
totals = d.get('totals', {})
# supply uses FormatAmount (string integers), totals uses int64
m0_total = int(supply.get('m0_total', totals.get('total_m0', 0)))
m0_vaulted = int(supply.get('m0_vaulted', 0))
m1_supply = int(supply.get('m1_supply', totals.get('total_m1', 0)))
m0_circ = m0_total - m0_vaulted
print(f'  M0 total supply: {m0_total:,} sats')
print(f'  M0 vaulted:      {m0_vaulted:,} sats')
print(f'  M0 circulating:  {m0_circ:,} sats')
print(f'  M1 supply:       {m1_supply:,} sats')
" || echo "  Could not get global state"
echo ""
