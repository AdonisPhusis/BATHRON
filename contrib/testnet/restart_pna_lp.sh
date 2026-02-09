#!/bin/bash
OP1_IP="57.131.33.152"
SSH_KEY="$HOME/.ssh/id_ed25519_vps"
SSH_OPTS="-o StrictHostKeyChecking=no -o ConnectTimeout=15 -o BatchMode=yes"
SSH="ssh -i $SSH_KEY $SSH_OPTS"

echo "=== Kill all pna-lp related processes ==="
$SSH ubuntu@$OP1_IP "pkill -9 -f 'server.py' 2>/dev/null; pkill -9 -f 'uvicorn' 2>/dev/null; sleep 2"

echo "=== Start pna-lp ==="
$SSH ubuntu@$OP1_IP "cd ~/pna-sdk && nohup ./venv/bin/python -m uvicorn server:app --host 0.0.0.0 --port 8080 > /tmp/pna-sdk.log 2>&1 &"
sleep 3

echo "=== Verify ==="
$SSH ubuntu@$OP1_IP "netstat -tlnp 2>/dev/null | grep 8080 || curl -s http://localhost:8080/api/status | head -3"
