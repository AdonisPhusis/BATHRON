#!/bin/bash
# Force restart LP server on OP1
OP1_IP="57.131.33.152"
SSH_KEY="$HOME/.ssh/id_ed25519_vps"

echo "=== Force restarting LP server on OP1 ==="
ssh -i "$SSH_KEY" ubuntu@${OP1_IP} << 'REMOTE_EOF'
# Find all processes using port 8080
echo "Processes using port 8080:"
lsof -ti:8080 || echo "No processes found"

# Kill them
lsof -ti:8080 | xargs kill -9 2>/dev/null || true
sleep 2

# Also kill any python server.py processes
pkill -9 -f "python.*server.py" || true
sleep 2

# Verify port is free
if lsof -ti:8080 > /dev/null 2>&1; then
    echo "ERROR: Port 8080 still in use"
    lsof -i:8080
    exit 1
fi

echo "Port 8080 is free"
echo ""
echo "Starting LP server..."
cd /home/ubuntu/pna-lp
nohup python3 server.py > /tmp/pna-lp.log 2>&1 &
sleep 5

# Check if running
if lsof -ti:8080 > /dev/null 2>&1; then
    echo "LP server started successfully"
    ps aux | grep "python.*server.py" | grep -v grep
    echo ""
    echo "Testing API..."
    curl -s http://localhost:8080/api/status | jq '.' || echo "API response not JSON"
else
    echo "ERROR: LP server failed to start on port 8080"
    echo "Last 30 lines of log:"
    tail -30 /tmp/pna-lp.log
    exit 1
fi
REMOTE_EOF
