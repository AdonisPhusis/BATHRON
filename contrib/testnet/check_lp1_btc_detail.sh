#!/bin/bash
#
# Check LP1 (OP1) BTC wallet balances + specific flowswap status
# Usage: ./check_lp1_btc_detail.sh [flowswap_id]
#

set -euo pipefail

SSH_KEY="$HOME/.ssh/id_ed25519_vps"
SSH_OPTS="-o StrictHostKeyChecking=no -o ConnectTimeout=10 -o BatchMode=yes"

OP1_IP="57.131.33.152"
FLOWSWAP_ID="${1:-fs_6c0c6777b332458e}"

echo "╔══════════════════════════════════════════════════════════════╗"
echo "║        LP1 (OP1) BTC Wallet Detail Check                    ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""

echo "=== LP1 BTC wallet (OP1 - $OP1_IP) ==="
ssh -i "$SSH_KEY" $SSH_OPTS "ubuntu@$OP1_IP" '
    BTC_CLI="/home/ubuntu/bitcoin/bin/bitcoin-cli -signet -datadir=/home/ubuntu/.bitcoin-signet"

    echo "--- loaded wallets ---"
    $BTC_CLI listwallets 2>/dev/null || echo "(listwallets error)"

    echo ""
    echo "--- lp_wallet balance ---"
    $BTC_CLI -rpcwallet=lp_wallet getbalance 2>/dev/null || echo "(no lp_wallet)"

    echo ""
    echo "--- alice_lp balance ---"
    $BTC_CLI -rpcwallet=alice_lp getbalance 2>/dev/null || echo "(no alice_lp)"

    echo ""
    echo "--- alice_btc balance ---"
    $BTC_CLI -rpcwallet=alice_btc getbalance 2>/dev/null || echo "(no alice_btc)"

    echo ""
    echo "--- all wallet balances ---"
    for w in $($BTC_CLI listwallets 2>/dev/null | python3 -c "import sys,json; [print(x) for x in json.load(sys.stdin)]" 2>/dev/null); do
        bal=$($BTC_CLI -rpcwallet="$w" getbalance 2>/dev/null || echo "?")
        echo "  $w: $bal BTC"
    done
' 2>/dev/null

echo ""
echo "=== LP1 FlowSwap detail ($FLOWSWAP_ID) ==="
ssh -i "$SSH_KEY" $SSH_OPTS "ubuntu@$OP1_IP" "
    curl -s http://localhost:8080/api/flowswap/$FLOWSWAP_ID 2>/dev/null | python3 -c '
import sys,json
try:
    d=json.load(sys.stdin)
    print(f\"State: {d.get(\\\"state\\\",\\\"?\\\")}\")
    print(f\"Error: {d.get(\\\"error\\\",\\\"none\\\")}\")
    legs = d.get(\"legs\",{})
    for name,leg in legs.items():
        print(f\"  {name}: {leg.get(\\\"state\\\",\\\"?\\\")}\")
except Exception as e:
    print(f\"Parse error: {e}\")
' 2>/dev/null || echo '(no swap data or LP server not running)'
" 2>/dev/null

echo ""
echo "=== Done ==="
