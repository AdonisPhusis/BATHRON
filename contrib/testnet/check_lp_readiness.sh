#!/bin/bash
# Check LP readiness for swap tests after wallet isolation
set -uo pipefail
SSH_KEY="$HOME/.ssh/id_ed25519_vps"
SSH_OPTS="-o StrictHostKeyChecking=no -o ConnectTimeout=10 -o BatchMode=yes"
SSH="ssh -i $SSH_KEY $SSH_OPTS"

echo "============================================================"
echo "  LP READINESS CHECK (post wallet isolation)"
echo "============================================================"
echo ""

# LP1 (alice) — OP1
echo "=== LP1 (alice) — 57.131.33.152 ==="
$SSH ubuntu@57.131.33.152 "
    CLI='/home/ubuntu/bathron-cli -testnet'

    echo '  BATHRON:'
    BAL=\$(\$CLI getbalance 2>/dev/null || echo '?')
    echo \"    getbalance: \$BAL\"

    \$CLI getwalletstate true 2>/dev/null | python3 -c '
import sys,json
d = json.load(sys.stdin)
m0 = d.get(\"m0\", {})
m1 = d.get(\"m1\", {})
print(f\"    M0 balance: {m0.get(\\\"balance\\\",0)} sats\")
print(f\"    M0 locked:  {m0.get(\\\"locked\\\",0)} sats\")
print(f\"    M1 total:   {m1.get(\\\"total\\\",0)} sats ({len(m1.get(\\\"receipts\\\",[]))} receipts)\")
' 2>/dev/null || echo '    (getwalletstate error)'

    echo '  LP server:'
    if pgrep -f 'python.*server.py' > /dev/null 2>&1; then
        echo '    RUNNING'
        curl -s http://localhost:8080/api/status 2>/dev/null | python3 -c '
import sys,json
d = json.load(sys.stdin)
w = d.get(\"wallets\",{})
for k,v in w.items():
    print(f\"    {k}: addr={v.get(\\\"address\\\",\\\"?\\\")[:20]}... bal={v.get(\\\"balance\\\",0)}\")
inv = d.get(\"inventory\",{})
print(f\"    inventory_ok: {inv.get(\\\"ok\\\",\\\"?\\\")}\")
' 2>/dev/null || echo '    (curl error)'
    else
        echo '    NOT RUNNING'
    fi
" 2>/dev/null
echo ""

# LP2 (dev) — OP2
echo "=== LP2 (dev) — 57.131.33.214 ==="
$SSH ubuntu@57.131.33.214 "
    CLI='/home/ubuntu/bathron/bin/bathron-cli -testnet'

    echo '  BATHRON:'
    BAL=\$(\$CLI getbalance 2>/dev/null || echo '?')
    echo \"    getbalance: \$BAL\"

    \$CLI getwalletstate true 2>/dev/null | python3 -c '
import sys,json
d = json.load(sys.stdin)
m0 = d.get(\"m0\", {})
m1 = d.get(\"m1\", {})
print(f\"    M0 balance: {m0.get(\\\"balance\\\",0)} sats\")
print(f\"    M1 total:   {m1.get(\\\"total\\\",0)} sats ({len(m1.get(\\\"receipts\\\",[]))} receipts)\")
' 2>/dev/null || echo '    (getwalletstate error)'

    echo '  LP server:'
    if pgrep -f 'python.*server.py' > /dev/null 2>&1; then
        echo '    RUNNING'
    else
        echo '    NOT RUNNING'
    fi
" 2>/dev/null
echo ""

# bob (CoreSDK)
echo "=== bob (CoreSDK) — 162.19.251.75 ==="
$SSH ubuntu@162.19.251.75 "
    CLI='/home/ubuntu/BATHRON-Core/src/bathron-cli -testnet'
    BAL=\$(\$CLI getbalance 2>/dev/null || echo '?')
    echo \"  getbalance: \$BAL\"

    \$CLI getwalletstate true 2>/dev/null | python3 -c '
import sys,json
d = json.load(sys.stdin)
m0 = d.get(\"m0\", {})
m1 = d.get(\"m1\", {})
print(f\"  M0: {m0.get(\\\"balance\\\",0)} sats\")
print(f\"  M1: {m1.get(\\\"total\\\",0)} sats ({len(m1.get(\\\"receipts\\\",[]))} receipts)\")
for r in m1.get(\"receipts\",[]):
    print(f\"    {r[\\\"outpoint\\\"][:20]}... {r[\\\"amount\\\"]} sats\")
' 2>/dev/null || echo '  (getwalletstate error)'
" 2>/dev/null
echo ""

# Seed balance
echo "=== Seed (pilpous) — fund source ==="
$SSH ubuntu@57.131.33.151 "
    CLI='/home/ubuntu/BATHRON-Core/src/bathron-cli -testnet'
    BAL=\$(\$CLI getbalance 2>/dev/null || echo '?')
    echo \"  getbalance: \$BAL\"

    \$CLI getwalletstate true 2>/dev/null | python3 -c '
import sys,json
d = json.load(sys.stdin)
m0 = d.get(\"m0\", {})
m1 = d.get(\"m1\", {})
print(f\"  M0 balance: {m0.get(\\\"balance\\\",0)} sats\")
print(f\"  M0 locked:  {m0.get(\\\"locked\\\",0)} sats\")
print(f\"  M1 total:   {m1.get(\\\"total\\\",0)} sats\")
avail = m0.get(\"balance\",0) - m0.get(\"locked\",0)
print(f\"  Available to send: {avail} sats\")
' 2>/dev/null || echo '  (getwalletstate error)'
" 2>/dev/null
echo ""

# OP3 (charlie) — fake user
echo "=== OP3 (charlie) — fake user ==="
$SSH ubuntu@51.75.31.44 "
    CLI='/home/ubuntu/bathron-cli -testnet'
    \$CLI getwalletstate true 2>/dev/null | python3 -c '
import sys,json
d = json.load(sys.stdin)
m0 = d.get(\"m0\", {})
m1 = d.get(\"m1\", {})
print(f\"  M0: {m0.get(\\\"balance\\\",0)} sats\")
print(f\"  M1: {m1.get(\\\"total\\\",0)} sats ({len(m1.get(\\\"receipts\\\",[]))} receipts)\")
' 2>/dev/null || echo '  (error)'

    BTC_CLI='/home/ubuntu/bitcoin/bin/bitcoin-cli -signet -datadir=/home/ubuntu/.bitcoin-signet'
    BTC=\$(\$BTC_CLI -rpcwallet=fake_user getbalance 2>/dev/null || echo '?')
    echo \"  BTC: \$BTC\"
" 2>/dev/null
