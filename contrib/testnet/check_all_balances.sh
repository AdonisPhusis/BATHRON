#!/bin/bash
#
# Check M0/M1 balances on all VPS
#

set -euo pipefail

SSH_KEY="$HOME/.ssh/id_ed25519_vps"
SSH_OPTS="-i $SSH_KEY -o StrictHostKeyChecking=no -o ConnectTimeout=10"

SEED_IP="57.131.33.151"
CORESDK_IP="162.19.251.75"
OP1_IP="57.131.33.152"
OP2_IP="57.131.33.214"
OP3_IP="51.75.31.44"

BATHRON_CLI="/home/ubuntu/bathron-cli -testnet"

echo "╔══════════════════════════════════════════════════════════════╗"
echo "║              All VPS M0/M1 Balances                          ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""

for VPS in "SEED:$SEED_IP:pilpous" "CoreSDK:$CORESDK_IP:bob" "OP1:$OP1_IP:alice" "OP2:$OP2_IP:dev" "OP3:$OP3_IP:charlie"; do
    NAME=$(echo $VPS | cut -d: -f1)
    IP=$(echo $VPS | cut -d: -f2)
    WALLET=$(echo $VPS | cut -d: -f3)

    printf "%-10s (%s) [%s]\n" "$NAME" "$IP" "$WALLET"

    RESULT=$(ssh $SSH_OPTS "ubuntu@$IP" "$BATHRON_CLI getwalletstate true" 2>/dev/null || echo '{"error": true}')

    if echo "$RESULT" | grep -q '"error"'; then
        echo "  ERROR: Could not get wallet state"
    else
        echo "$RESULT" | python3 -c "
import sys, json
d = json.load(sys.stdin)
m0 = d.get('m0_available', 0)
m0_vaulted = d.get('m0_vaulted', 0)
m1_receipts = d.get('m1_receipts', [])
m1_total = sum(r['amount'] for r in m1_receipts)
total = m0 + m1_total
print(f'  M0: {m0:>12,} sats')
print(f'  M1: {m1_total:>12,} sats ({len(m1_receipts)} receipts)')
print(f'  Total: {total:>10,} sats')
"
    fi
    echo ""
done

# Also check global state
echo "═══ Global Settlement State ═══"
ssh $SSH_OPTS "ubuntu@$SEED_IP" "$BATHRON_CLI getstate" 2>/dev/null | python3 -c "
import sys, json
d = json.load(sys.stdin)
m0_total = d.get('m0_total', 0)
m0_vaulted = d.get('m0_vaulted', 0)
m1_supply = d.get('m1_supply', 0)
print(f'  M0 total supply: {m0_total:,} sats')
print(f'  M0 in vault: {m0_vaulted:,} sats')
print(f'  M1 supply: {m1_supply:,} sats')
print(f'  M0 circulating: {m0_total - m0_vaulted:,} sats')
" || echo "  Could not get global state"
echo ""
