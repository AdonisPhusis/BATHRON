#!/bin/bash
# Restart LP server on OP1
OP1_IP="57.131.33.152"
SSH_KEY="$HOME/.ssh/id_ed25519_vps"

echo "=== Restarting LP server on OP1 ==="
ssh -i "$SSH_KEY" ubuntu@${OP1_IP} << 'REMOTE_EOF'
# Kill existing server if running
pkill -f "python.*pna-lp" || true
sleep 2

# Start LP server
cd /home/ubuntu/pna-lp
nohup python3 server.py > /tmp/pna-lp.log 2>&1 &
sleep 3

# Check if running
if ps aux | grep -v grep | grep "python.*pna-lp" > /dev/null; then
    echo "LP server started successfully"
    ps aux | grep "python.*pna-lp" | grep -v grep
else
    echo "ERROR: LP server failed to start"
    echo "Last 20 lines of log:"
    tail -20 /tmp/pna-lp.log
    exit 1
fi
REMOTE_EOF
