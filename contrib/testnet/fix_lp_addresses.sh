#!/bin/bash
# Fix LP addresses configuration on OP1
# Moves .lp_addresses.json from ~/pna-sdk/ to ~/pna-lp/

SSH_KEY=~/.ssh/id_ed25519_vps
OP1_IP="57.131.33.152"

echo "=== Fixing LP Addresses Configuration on OP1 ==="

ssh -i $SSH_KEY ubuntu@$OP1_IP << 'REMOTE'
set -e

echo "1. Checking for .lp_addresses.json files..."
if [ -f ~/pna-sdk/.lp_addresses.json ]; then
    echo "   ✓ Found ~/pna-sdk/.lp_addresses.json"
    cat ~/pna-sdk/.lp_addresses.json | python3 -m json.tool
else
    echo "   ✗ ~/pna-sdk/.lp_addresses.json not found"
fi

if [ -f ~/pna-lp/.lp_addresses.json ]; then
    echo "   ✓ ~/pna-lp/.lp_addresses.json already exists"
else
    echo "   ○ ~/pna-lp/.lp_addresses.json does not exist"
fi

echo ""
echo "2. Copying to correct location..."
if [ -f ~/pna-sdk/.lp_addresses.json ]; then
    cp ~/pna-sdk/.lp_addresses.json ~/pna-lp/.lp_addresses.json
    echo "   ✓ Copied to ~/pna-lp/.lp_addresses.json"
else
    echo "   ✗ Source file missing, cannot copy"
    exit 1
fi

echo ""
echo "3. Restarting pna-lp server..."
pkill -f 'uvicorn.*server:app' 2>/dev/null || true
sleep 1

cd ~/pna-lp
nohup python3 -m uvicorn server:app --host 0.0.0.0 --port 8080 > /tmp/pna-lp.log 2>&1 &
sleep 3

if pgrep -f 'uvicorn.*server:app' > /dev/null; then
    echo "   ✓ Server restarted (PID: $(pgrep -f 'uvicorn.*server:app'))"
else
    echo "   ✗ Server failed to start"
    echo ""
    echo "Last 20 lines of log:"
    tail -20 /tmp/pna-lp.log
    exit 1
fi

echo ""
echo "4. Verifying wallets endpoint..."
sleep 1
WALLETS_OUTPUT=$(curl -s http://localhost:8080/api/wallets)
if echo "$WALLETS_OUTPUT" | python3 -m json.tool > /dev/null 2>&1; then
    echo "   ✓ Wallets endpoint working"
    echo ""
    echo "Response:"
    echo "$WALLETS_OUTPUT" | python3 -m json.tool
else
    echo "   ✗ Wallets endpoint returned invalid JSON"
    echo ""
    echo "Response:"
    echo "$WALLETS_OUTPUT"
    exit 1
fi

echo ""
echo "✓ Configuration fixed successfully"
REMOTE

if [ $? -eq 0 ]; then
    echo ""
    echo "=== Success ==="
    echo "LP addresses configured correctly on OP1"
    echo "Dashboard: http://$OP1_IP:8080"
else
    echo ""
    echo "=== Failed ==="
    echo "Check errors above"
    exit 1
fi
