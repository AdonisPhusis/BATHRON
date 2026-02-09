#!/bin/bash
#
# List FlowSwap swaps from LP1 and/or LP2
#
# Usage:
#   ./contrib/testnet/list_flowswaps.sh [lp1|lp2|all]
#

set -uo pipefail

SSH_KEY="$HOME/.ssh/id_ed25519_vps"
SSH_OPTS="-i $SSH_KEY -o StrictHostKeyChecking=no -o ConnectTimeout=10 -o BatchMode=yes"

OP1_IP="57.131.33.152"
OP2_IP="57.131.33.214"

TARGET="${1:-all}"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

fetch_swaps() {
    local ip="$1"
    local name="$2"
    echo -e "\n${CYAN}${BOLD}=== FlowSwaps on ${name} (${ip}) ===${NC}\n"

    local json
    json=$(ssh -i "$SSH_KEY" $SSH_OPTS "ubuntu@${ip}" \
        "curl -s http://localhost:8080/api/flowswap/list" 2>/dev/null)

    if [[ -z "$json" || "$json" == *"error"* ]]; then
        echo -e "  ${RED}Failed to fetch swaps${NC}"
        return 1
    fi

    echo "$json" | python3 -c "
import sys, json
from datetime import datetime, timezone

try:
    data = json.load(sys.stdin)
    swaps = data if isinstance(data, list) else data.get('swaps', data.get('flowswaps', []))

    if not swaps:
        print('  No swaps found')
        sys.exit(0)

    # Sort by creation time (most recent first)
    swaps.sort(key=lambda s: s.get('created_at', 0), reverse=True)

    print(f'  Total: {len(swaps)} swaps\n')
    print(f'  {\"ID\":40s} {\"State\":15s} {\"Direction\":15s} {\"BTC\":>15s} {\"USDC\":>10s} {\"Created\":20s}')
    print(f'  {\"-\"*40} {\"-\"*15} {\"-\"*15} {\"-\"*15} {\"-\"*10} {\"-\"*20}')

    for s in swaps:
        sid = s.get('swap_id', s.get('id', '?'))[:40]
        state = s.get('state', s.get('status', '?'))
        fa = s.get('from_asset', '')
        ta = s.get('to_asset', '')
        direction = s.get('direction', f'{fa}->{ta}' if fa else '?')

        btc_sats = s.get('btc_amount_sats', s.get('btc_amount', 0))
        if isinstance(btc_sats, (int, float)) and btc_sats > 100:
            btc = f'{btc_sats/1e8:.8f}'
        else:
            btc = str(btc_sats)

        usdc = s.get('usdc_amount', s.get('to_amount', '?'))

        created = s.get('created_at', 0)
        if isinstance(created, (int, float)) and created > 1000000000:
            dt = datetime.fromtimestamp(created, tz=timezone.utc)
            created_str = dt.strftime('%Y-%m-%d %H:%M')
        else:
            created_str = str(created)

        # Color state
        if state in ('completed', 'settled'):
            state_display = f'\033[0;32m{state:15s}\033[0m'
        elif state in ('failed', 'expired', 'refunded'):
            state_display = f'\033[0;31m{state:15s}\033[0m'
        else:
            state_display = f'\033[1;33m{state:15s}\033[0m'

        print(f'  {sid:40s} {state_display} {direction:15s} {btc:>15s} {str(usdc):>10s} {created_str:20s}')

    # Summary
    states = {}
    for s in swaps:
        st = s.get('state', s.get('status', '?'))
        states[st] = states.get(st, 0) + 1
    print(f'\n  Summary: {dict(states)}')

except Exception as e:
    print(f'  Parse error: {e}')
    print(f'  Raw: {sys.stdin.read()[:500]}')
" 2>/dev/null
}

case "$TARGET" in
    lp1) fetch_swaps "$OP1_IP" "LP1 (alice, OP1)" ;;
    lp2) fetch_swaps "$OP2_IP" "LP2 (dev, OP2)" ;;
    all|*)
        fetch_swaps "$OP1_IP" "LP1 (alice, OP1)"
        fetch_swaps "$OP2_IP" "LP2 (dev, OP2)"
        ;;
esac

echo ""
