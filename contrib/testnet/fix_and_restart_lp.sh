#!/bin/bash
# Fix LP server dependencies and restart
OP1_IP="57.131.33.152"
SSH_KEY="$HOME/.ssh/id_ed25519_vps"

echo "=== Fixing LP server dependencies on OP1 ==="
ssh -i "$SSH_KEY" ubuntu@${OP1_IP} << 'REMOTE_EOF'
cd /home/ubuntu/pna-lp

echo "Installing dependencies..."
pip3 install -r requirements.txt --break-system-packages --quiet

echo ""
echo "Starting LP server..."
pkill -f "python.*pna-lp" || true
sleep 2

nohup python3 server.py > /tmp/pna-lp.log 2>&1 &
sleep 3

# Check if running
if ps aux | grep -v grep | grep "python.*server.py" > /dev/null; then
    echo "LP server started successfully"
    ps aux | grep "python.*server.py" | grep -v grep
    echo ""
    echo "Testing API..."
    sleep 2
    curl -s http://localhost:8080/api/status | jq '.' || echo "API not ready yet"
else
    echo "ERROR: LP server failed to start"
    echo "Last 30 lines of log:"
    tail -30 /tmp/pna-lp.log
    exit 1
fi
REMOTE_EOF
