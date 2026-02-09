#!/bin/bash
# Sync pna-lp SDK and server to OP1
# Usage: ./sync_pna_lp.sh [restart]

SSH_KEY=~/.ssh/id_ed25519_vps
OP1_IP="57.131.33.152"
SOURCE_DIR="/home/ubuntu/BATHRON/contrib/dex/pna-lp"
DEST_DIR="/home/ubuntu/pna-lp"

echo "=== Syncing pna-lp to OP1 ($OP1_IP) ==="

# Sync files (excluding __pycache__ and .pyc files)
rsync -avz --delete \
    --exclude '__pycache__' \
    --exclude '*.pyc' \
    --exclude '.lp_addresses.json' \
    -e "ssh -i $SSH_KEY" \
    "$SOURCE_DIR/" \
    "ubuntu@$OP1_IP:$DEST_DIR/"

if [ $? -eq 0 ]; then
    echo "✓ Files synced successfully"
else
    echo "✗ Sync failed"
    exit 1
fi

# Install dependencies if needed
echo ""
echo "=== Installing Python dependencies ==="
ssh -i $SSH_KEY ubuntu@$OP1_IP '
pip3 install web3 eth-account --break-system-packages -q 2>/dev/null || \
pip3 install web3 eth-account -q 2>/dev/null
'

# Restart if requested
if [ "$1" = "restart" ] || [ "$1" = "start" ]; then
    echo ""
    echo "=== Restarting pna-lp server ==="
    ssh -i $SSH_KEY ubuntu@$OP1_IP '
    pkill -f "uvicorn.*server:app" 2>/dev/null
    sleep 1
    cd ~/pna-lp && nohup uvicorn server:app --host 0.0.0.0 --port 8080 > /tmp/pna-lp.log 2>&1 &
    sleep 2
    if pgrep -f "uvicorn.*server:app" > /dev/null; then
        echo "✓ Server restarted (PID: $(pgrep -f "uvicorn.*server:app"))"
    else
        echo "✗ Server failed to start"
        tail -20 /tmp/pna-lp.log
    fi
    '
fi

echo ""
echo "=== Status ==="
ssh -i $SSH_KEY ubuntu@$OP1_IP '
if pgrep -f "uvicorn.*server:app" > /dev/null; then
    echo "✓ pna-lp server running"
    curl -s http://localhost:8080/api/status | python3 -m json.tool 2>/dev/null || echo "(API check failed)"
else
    echo "○ pna-lp server not running"
fi
'

echo ""
echo "Done. Access dashboard at: http://$OP1_IP:8080"
