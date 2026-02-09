#!/bin/bash
# audit_global_invariants_v2.sh - Fixed version
set -uo pipefail

SSH_KEY="$HOME/.ssh/id_ed25519_vps"
SSH_OPTS="-o StrictHostKeyChecking=no -o ConnectTimeout=10 -o BatchMode=yes"
SSH="ssh -i $SSH_KEY $SSH_OPTS"

echo "=== Wallet balances (getwalletstate true) ==="
echo ""
for info in "Seed:57.131.33.151:/home/ubuntu/BATHRON-Core/src/bathron-cli -testnet" \
            "CoreSDK:162.19.251.75:/home/ubuntu/BATHRON-Core/src/bathron-cli -testnet" \
            "OP1:57.131.33.152:/home/ubuntu/bathron-cli -testnet" \
            "OP2:57.131.33.214:/home/ubuntu/bathron/bin/bathron-cli -testnet" \
            "OP3:51.75.31.44:/home/ubuntu/bathron-cli -testnet"; do
    IFS=: read label ip cli <<< "$info"
    echo "  $label ($ip):"
    raw=$($SSH ubuntu@$ip "$cli getwalletstate true" 2>/dev/null || echo "ERROR")
    if [ "$raw" != "ERROR" ]; then
        echo "$raw" | python3 -c '
import sys, json
try:
    d = json.load(sys.stdin)
    # Print key balance fields
    for k in sorted(d.keys()):
        v = d[k]
        if isinstance(v, (int, float, str)) and k not in ["address"]:
            print(f"    {k}: {v}")
        elif isinstance(v, list) and len(v) > 0:
            print(f"    {k}: [{len(v)} items]")
except Exception as e:
    print(f"    parse error: {e}")
' 2>/dev/null
    else
        echo "    (unreachable)"
    fi
    echo ""
done

echo "=== Simple getbalance ==="
for info in "Seed:57.131.33.151:/home/ubuntu/BATHRON-Core/src/bathron-cli -testnet" \
            "CoreSDK:162.19.251.75:/home/ubuntu/BATHRON-Core/src/bathron-cli -testnet" \
            "OP1:57.131.33.152:/home/ubuntu/bathron-cli -testnet" \
            "OP2:57.131.33.214:/home/ubuntu/bathron/bin/bathron-cli -testnet" \
            "OP3:51.75.31.44:/home/ubuntu/bathron-cli -testnet"; do
    IFS=: read label ip cli <<< "$info"
    bal=$($SSH ubuntu@$ip "$cli getbalance" 2>/dev/null || echo "ERROR")
    echo "  $label: $bal"
done

echo ""
echo "=== MN list (mncount) ==="
$SSH ubuntu@57.131.33.151 "/home/ubuntu/BATHRON-Core/src/bathron-cli -testnet masternode count" 2>/dev/null || echo "(error)"

echo ""
echo "=== Finality status ==="
$SSH ubuntu@57.131.33.151 "/home/ubuntu/BATHRON-Core/src/bathron-cli -testnet getfinalitystatus" 2>/dev/null || echo "(error)"
