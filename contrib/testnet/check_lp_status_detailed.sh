#!/bin/bash
# Check LP server status and recent activity
OP1_IP="57.131.33.152"
SSH_KEY="$HOME/.ssh/id_ed25519_vps"

echo "=== Checking LP server on OP1 ==="
ssh -i "$SSH_KEY" ubuntu@${OP1_IP} << 'REMOTE_EOF'
echo "LP server process:"
ps aux | grep pna-lp | grep -v grep

echo ""
echo "Recent log entries (last 50 lines):"
if [ -f /tmp/pna-lp.log ]; then
    tail -50 /tmp/pna-lp.log
else
    echo "No log file at /tmp/pna-lp.log"
fi

echo ""
echo "Checking for server output/error files:"
ls -lah /tmp/pna-lp* 2>/dev/null || echo "No pna-lp files in /tmp"
REMOTE_EOF
